//! What skepd publishes on D-Bus, as skep-dbus(7) says: an object per device, with its address,
//! its name and its last readings, for desktop widgets and scripts. Through the dbus module's
//! interface, Bus, only: how they are carried is the module's business.
//!
//! What is published follows what skepd knows: each turn of the loop, the devices whose readings
//! or name changed are published again, and all of them once devices joined, left or were set up,
//! or the network came up. The bus is told only what differs.

const std = @import("std");
const c = @import("skep_h");
const dbus = @import("dbus");
const libskep = @import("libskep.zig");
const Protocol = @import("protocol.zig");
const Readings = @import("Readings.zig");

const Published = @This();

/// The name skepd owns on the bus, and where its objects are: "zigbee", which is no domain, so
/// the name claims none (see design.md), then skep's interface with its major version, as
/// D-Bus's API guidelines ask, so that one that breaks clients can come next to this one.
pub const bus_name = "zigbee.Skep1";
pub const root = "/zigbee/Skep1";
pub const device_interface = "zigbee.Skep1.Device";

pub const interfaces = [_]dbus.Interface{.{
  .name = device_interface,
  .properties = &.{
    .{ .name = "Address", .signature = "s" },
    .{ .name = "Name", .signature = "s" },
    .{ .name = "Readings", .signature = "a{sv}" },
  },
}};

gpa: std.mem.Allocator,
bus: dbus.Bus,
/// The devices published, by IEEE address.
devices: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
/// Devices joined, left or were set up, or none is published yet: all are published again.
all: bool = true,

/// Publishes on the bus at `address`, once it is reached.
pub fn init(gpa: std.mem.Allocator, address: []const u8) dbus.Bus.Error!Published {
  return .{
    .gpa = gpa,
    .bus = try .init(gpa, .{
      .name = bus_name,
      .root = root,
      .interfaces = &interfaces,
      .address = address,
    }),
  };
}

pub fn deinit(p: *Published) void {
  p.devices.deinit(p.gpa);
  p.bus.deinit();
}

/// An event of libskep's, which may change which devices there are, or what they can be read
/// for.
pub fn event(p: *Published, e: *const c.skep_event) void {
  switch (c.skep_event_get_type(e)) {
    c.SKEP_EVENT_STARTED,
    c.SKEP_EVENT_DEVICE_JOINED,
    c.SKEP_EVENT_DEVICE_LEFT,
    c.SKEP_EVENT_DEVICE_READY,
    => p.all = true,
    else => {},
  }
}

/// Publishes what changed since the last turn.
pub fn sync(p: *Published, protocol: *Protocol) void {
  var arena: std.heap.ArenaAllocator = .init(p.gpa);
  defer arena.deinit();
  const a = arena.allocator();
  defer protocol.readings.changed.clearRetainingCapacity();
  defer protocol.names.changed.clearRetainingCapacity();
  if (p.all) {
    p.all = false;
    var count: usize = 0;
    _ = c.skep_get_devices(protocol.ctx, null, 0, &count);
    const devices = a.alloc(u64, count) catch return p.later();
    _ = c.skep_get_devices(protocol.ctx, devices.ptr, devices.len, &count);
    const known = devices[0..@min(count, devices.len)];
    // Those gone, removed from the network.
    var i: usize = 0;
    while (i < p.devices.count()) {
      const ieee = p.devices.keys()[i];
      if (std.mem.indexOfScalar(u64, known, ieee) == null) {
        var path: [root.len + 32]u8 = undefined;
        p.bus.remove(pathOf(&path, ieee));
        p.devices.swapRemoveAt(i);
      } else {
        i += 1;
      }
    }
    for (known) |ieee| {
      p.publish(protocol, a, ieee);
      _ = arena.reset(.retain_capacity);
    }
    return;
  }
  for ([_][]const u64{
    protocol.readings.changed.keys(),
    protocol.names.changed.keys(),
  }) |changed| {
    for (changed) |ieee| {
      if (!p.devices.contains(ieee)) continue;
      p.publish(protocol, a, ieee);
      _ = arena.reset(.retain_capacity);
    }
  }
}

/// Out of memory: all are published again next turn.
fn later(p: *Published) void {
  p.all = true;
}

/// A device's object path: below the root, by IEEE address.
fn pathOf(buffer: *[root.len + 32]u8, ieee: u64) []const u8 {
  return std.fmt.bufPrint(buffer, root ++ "/devices/{x:0>16}", .{ ieee }) catch unreachable;
}

fn publish(p: *Published, protocol: *Protocol, a: std.mem.Allocator, ieee: u64) void {
  p.devices.put(p.gpa, ieee, {}) catch return p.later();
  var path: [root.len + 32]u8 = undefined;
  var address: [16]u8 = undefined;
  _ = std.fmt.bufPrint(&address, "{x:0>16}", .{ ieee }) catch unreachable;
  const name = protocol.names.get(ieee) orelse "";
  const readings = readingsOf(protocol, a, ieee) catch return p.later();
  p.bus.put(
    pathOf(&path, ieee),
    device_interface,
    &.{
      .{ .name = "Address", .value = .{ .string = &address } },
      // A name given by hand in names.json that the bus would not take, not valid UTF-8: none.
      .{ .name = "Name", .value = .{ .string = if (isText(name)) name else "" } },
      .{ .name = "Readings", .value = readings },
    },
  ) catch |e| switch (e) {
    error.OutOfMemory => p.later(),
    // What is published is as the interface declares it.
    error.Invalid => unreachable,
  };
}

/// UTF-8, without NUL, as the bus takes strings.
fn isText(s: []const u8) bool {
  return std.unicode.utf8ValidateSlice(s) and std.mem.indexOfScalar(u8, s, 0) == null;
}

/// The last value of each reading of a device, by name, in its unit: of the first endpoint
/// with it, as skep-protocol names readings. Those with no value yet are left out.
fn readingsOf(protocol: *Protocol, a: std.mem.Allocator, ieee: u64) error{
  OutOfMemory,
}!dbus.Value {
  const sources = libskep.readings(protocol.ctx, a, ieee) catch |e| switch (e) {
    error.OutOfMemory => return error.OutOfMemory,
    error.NoDevice, error.NotInterviewed => &.{},
  };
  var entries: std.ArrayList(dbus.Value.Entry) = .empty;
  var names: std.ArrayList([]const u8) = .empty;
  for (sources) |source| {
    const name = std.mem.span(source.name);
    for (names.items) |known| {
      if (std.mem.eql(u8, known, name)) break;
    } else {
      try names.append(a, name);
      const last = protocol.readings.get(.{
        .device = ieee,
        .endpoint = source.endpoint,
        .cluster = source.cluster,
        .attribute = source.attribute,
      }) orelse continue;
      if (!std.math.isFinite(last.scaled)) continue;
      const value = try a.create(dbus.Value);
      value.* = .{ .double = last.scaled };
      try entries.append(a, .{ .key = .{ .string = name }, .value = .{ .variant = value } });
    }
  }
  return .{ .dict = .{ .key = "s", .value = "v", .entries = entries.items } };
}

const testing = std.testing;
const TestBench = Protocol.TestBench;

/// What a device's Readings say of `reading`, if anything.
fn readingOf(p: *const Published, ieee: u64, reading: []const u8) ?f64 {
  var path: [root.len + 32]u8 = undefined;
  const readings = p.bus.get(pathOf(&path, ieee), device_interface, "Readings") orelse return null;
  for (readings.dict.entries) |entry| {
    if (std.mem.eql(u8, entry.key.string, reading)) return entry.value.variant.double;
  }
  return null;
}

test "a device is published once it joins, with its readings and its name, until removed" {
  const sim = TestBench.libskep_internal.sim;
  const zcl = TestBench.libskep_internal.zcl;
  const ieee = 0xc4d7fdba7b600000;
  var devices = [_]sim.Device{.{
    .ieee = ieee,
    .nwk = 0x6442,
    .model = "3RCB02070Z",
    .input_clusters = &.{ 0x0000, 0x0003, 0x0006, 0x0008, 0x0300 },
    .color_temperature_range = .{ 142, 454 },
    .attributes = &.{
      .{ .cluster = 0x0006, .id = 0x0000, .value = .unsigned(zcl.Type.boolean, 1) },
      .{ .cluster = 0x0008, .id = 0x0000, .value = .unsigned(zcl.Type.uint8, 254) },
      .{ .cluster = 0x0300, .id = 0x0007, .value = .unsigned(zcl.Type.uint16, 370) },
    },
  }};
  var bench: TestBench = undefined;
  try bench.initWith(&devices);
  defer bench.deinit();
  // Never connected: what is published is kept all the same.
  var published: Published = try .init(testing.allocator, "unix:path=/nonexistent/bus");
  defer published.deinit();
  bench.published = &published;
  var buffer: [16384]u8 = undefined;

  bench.pump();
  try testing.expectEqual(0, published.devices.count());
  bench.ask("{\"id\": 1, \"method\": \"permit_join\", \"params\": {\"seconds\": 254}}\n");
  bench.sim().device(.{ .ieee = ieee, .nwk = 0x6442, .kind = .joined });
  for (0..8) |_| {
    bench.pump();
  }
  _ = bench.received(&buffer);
  var path: [root.len + 32]u8 = undefined;
  const device = pathOf(&path, ieee);
  try testing.expectEqualStrings("/zigbee/Skep1/devices/c4d7fdba7b600000", device);
  try testing.expectEqualStrings(
    "c4d7fdba7b600000",
    published.bus.get(device, device_interface, "Address").?.string,
  );
  try testing.expectEqualStrings("", published.bus.get(device, device_interface, "Name").?.string);
  // Read by skepd once it was set up.
  try testing.expectEqual(1, readingOf(&published, ieee, "on"));
  try testing.expectEqual(100, readingOf(&published, ieee, "level"));
  try testing.expectEqual(null, readingOf(&published, ieee, "hue"));

  // Renamed, and reporting.
  bench.ask(
    "{\"id\": 2, \"method\": \"rename\", \"params\": {\"device\": \"c4d7fdba7b600000\", \"name\": \"lamp\"}}\n",
  );
  bench.sim().report(&devices[0], 0x0006, &.{ 0x00, 0x00, zcl.Type.boolean, 0x00 });
  for (0..2) |_| {
    bench.pump();
  }
  try testing.expectEqualStrings(
    "lamp",
    published.bus.get(device, device_interface, "Name").?.string,
  );
  try testing.expectEqual(0, readingOf(&published, ieee, "on"));

  // Removed: gone.
  bench.ask("{\"id\": 3, \"method\": \"remove\", \"params\": {\"device\": \"lamp\"}}\n");
  for (0..4) |_| {
    bench.pump();
  }
  try testing.expectEqual(null, published.bus.get(device, device_interface, "Address"));
  try testing.expectEqual(0, published.devices.count());
}
