//! A context: everything libskep knows about one dongle and the network it coordinates. Applications
//! hold it as the opaque `skep_ctx`; skep.zig turns the C API into calls on it.
//!
//! There is no global state: two contexts share nothing, so a program can drive several dongles.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;
const Event = @import("Event.zig");
const driver_layer = @import("driver/driver.zig");
const sim = @import("driver/sim/sim.zig");

const Context = @This();

const E = std.posix.E;

/// The application's allocator, or null for the C library's. `gpa` points at it.
c_allocator: ?CAllocator,
gpa: std.mem.Allocator,
random: std.Random.DefaultCsprng,
options: Options = .{},
status: Status = .idle,
driver: ?driver_layer.Driver = null,
/// The simulated dongle the sim driver starts with. Tests change it before `start`.
sim_dongle: sim.Driver = .{},
ieee: u64 = 0,
network: ?driver_layer.Network = null,
events: Event.Queue = .{},
/// Events allocated ahead, so that taking an event from the driver never loses it to a failed
/// allocation, and `linkLost` can report without allocating.
spares: Event.Queue = .{},
/// `linkLost` found no spare event: the STOPPED event is still to be queued.
lost_pending: bool = false,

pub const Status = enum { idle, starting, running, stopped };

pub const Options = struct {
  driver: ?driver_layer.Name = null,
  log_level: driver_layer.Level = .warning,
  frame_counter_margin: u32 = 100000,
  replace_network: bool = false,
  channel: u8 = 15,
  pan_id: ?u16 = null,
  extended_pan_id: ?u64 = null,
  network_key: ?[16]u8 = null,
};

/// The names of `driver_layer.Level`, in its order.
const LogLevelName = enum { @"error", warning, info, debug };

/// Spare events kept ready: a log message and the event it explains.
const spare_count = 2;

/// Creates a context. With `allocator` null, memory comes from the C library.
pub fn create(allocator: ?CAllocator, seed: [32]u8) error{ OutOfMemory }!*Context {
  var copy = allocator;
  const gpa = if (copy) |*c| c.allocator() else std.heap.c_allocator;
  const ctx = try gpa.create(Context);
  ctx.* = .{ .c_allocator = allocator, .gpa = undefined, .random = .init(seed) };
  ctx.gpa = if (ctx.c_allocator) |*c| c.allocator() else std.heap.c_allocator;
  ctx.fillSpares() catch {
    ctx.spares.destroyAll();
    gpa.destroy(ctx);
    return error.OutOfMemory;
  };
  return ctx;
}

pub fn destroy(ctx: *Context) void {
  ctx.events.destroyAll();
  ctx.spares.destroyAll();
  var copy = ctx.c_allocator;
  const gpa = if (copy) |*c| c.allocator() else std.heap.c_allocator;
  gpa.destroy(ctx);
}

/// Sets an option, as `skep_set_option`. Returns 0 or a negative errno value.
pub fn setOption(ctx: *Context, name: []const u8, value: []const u8) c_int {
  const running = ctx.status == .starting or ctx.status == .running;
  if (std.mem.eql(u8, name, "log-level")) {
    const level = std.meta.stringToEnum(LogLevelName, value) orelse return err(.INVAL);
    ctx.options.log_level = @fromBackingInt(@intCast(@backingInt(level)));
    return 0;
  }
  const field = std.meta.stringToEnum(OptionName, name) orelse return err(.NOENT);
  if (running) return err(.BUSY);
  const o = &ctx.options;
  switch (field) {
    .driver => o.driver = std.meta.stringToEnum(driver_layer.Name, value) orelse return err(.INVAL),
    .@"frame-counter-margin" => o.frame_counter_margin = std.fmt.parseInt(u32, value, 10) catch
      return err(.INVAL),
    .@"replace-network" => o.replace_network = parseYesNo(value) orelse return err(.INVAL),
    .channel => {
      const channel = std.fmt.parseInt(u8, value, 10) catch return err(.INVAL);
      if (channel < 11 or channel > 26) return err(.INVAL);
      o.channel = channel;
    },
    .@"pan-id" => {
      const pan_id = parseHex(u16, value) orelse return err(.INVAL);
      // 0xffff addresses every PAN.
      if (pan_id == 0xffff) return err(.INVAL);
      o.pan_id = pan_id;
    },
    .@"extended-pan-id" => {
      const extended = parseHex(u64, value) orelse return err(.INVAL);
      if (extended == 0 or extended == std.math.maxInt(u64)) return err(.INVAL);
      o.extended_pan_id = extended;
    },
    .@"network-key" => {
      // All 32 digits, so that a key cut short is not taken for one with leading zeros.
      const digits = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
      if (digits.len != 32) return err(.INVAL);
      const key = parseHex(u128, value) orelse return err(.INVAL);
      var bytes: [16]u8 = undefined;
      std.mem.writeInt(u128, &bytes, key, .big);
      o.network_key = bytes;
    },
  }
  return 0;
}

const OptionName = enum {
  driver,
  @"frame-counter-margin",
  @"replace-network",
  channel,
  @"pan-id",
  @"extended-pan-id",
  @"network-key",
};

fn parseYesNo(value: []const u8) ?bool {
  if (std.mem.eql(u8, value, "yes")) return true;
  if (std.mem.eql(u8, value, "no")) return false;
  return null;
}

/// Hexadecimal digits, with or without 0x, as many as the type holds at most.
fn parseHex(comptime T: type, value: []const u8) ?T {
  const digits = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
  if (digits.len == 0 or digits.len > @typeInfo(T).int.bits / 4) return null;
  return std.fmt.parseInt(T, digits, 16) catch null;
}

pub fn serialDefaults(ctx: *const Context) error{
  NoDriver,
  NotSerial,
}!driver_layer.SerialDefaults {
  const name = ctx.options.driver orelse return error.NoDriver;
  return driver_layer.Driver.serialDefaults(name) orelse error.NotSerial;
}

/// Starts the driver, as `skep_start`.
pub fn start(ctx: *Context) c_int {
  const name = ctx.options.driver orelse return err(.INVAL);
  if (ctx.status == .starting or ctx.status == .running) return err(.BUSY);
  ctx.driver = switch (name) {
    .sim => .{ .sim = ctx.sim_dongle },
    else => .init(name),
  };
  ctx.driver.?.start();
  ctx.status = .starting;
  ctx.network = null;
  return 0;
}

/// Stops cleanly, as `skep_stop`.
pub fn stop(ctx: *Context) c_int {
  if (ctx.status != .starting and ctx.status != .running) return err(.NETDOWN);
  const event = ctx.takeSpare() catch return err(.NOMEM);
  ctx.finish(event, 0);
  return 0;
}

/// The dongle is gone, as `skep_link_lost`. Never fails: a spare event reports it.
pub fn linkLost(ctx: *Context) void {
  if (ctx.status != .starting and ctx.status != .running) return;
  if (ctx.spares.pop()) |event| {
    ctx.finish(event, err(.NOTCONN));
  } else {
    ctx.driver = null;
    ctx.status = .stopped;
    ctx.lost_pending = true;
  }
}

/// Queues `event` as STOPPED with `error_code`, and lets the driver go.
fn finish(ctx: *Context, event: *Event, error_code: c_int) void {
  event.type = .stopped;
  event.error_code = error_code;
  ctx.events.push(event);
  ctx.driver = null;
  ctx.status = .stopped;
  ctx.network = null;
}

pub fn input(ctx: *Context, bytes: []const u8, now: u64) c_int {
  const d = if (ctx.driver) |*d| d else return 0;
  d.input(bytes, now);
  return ctx.process();
}

pub fn output(ctx: *const Context) []const u8 {
  const d = if (ctx.driver) |*d| d else return &.{};
  return d.output();
}

pub fn outputDone(ctx: *Context, len: usize, now: u64) void {
  // The driver's events wait for the next call that can report a failed allocation.
  if (ctx.driver) |*d| {
    d.outputDone(len, now);
  }
}

pub fn nextDeadline(ctx: *const Context) ?u64 {
  const d = if (ctx.driver) |*d| d else return null;
  return d.nextDeadline();
}

pub fn advance(ctx: *Context, now: u64) c_int {
  if (ctx.driver) |*d| {
    d.advance(now);
  }
  return ctx.process();
}

pub fn nextEvent(ctx: *Context) ?*Event {
  return ctx.events.pop();
}

/// Turns the driver's events into the application's. Returns 0 or -ENOMEM; on -ENOMEM nothing
/// is lost, and the next call goes on.
fn process(ctx: *Context) c_int {
  ctx.fillSpares() catch return err(.NOMEM);
  if (ctx.lost_pending) {
    ctx.lost_pending = false;
    const event = ctx.spares.pop().?;
    event.type = .stopped;
    event.error_code = err(.NOTCONN);
    ctx.events.push(event);
    ctx.fillSpares() catch return err(.NOMEM);
  }
  while (ctx.driver) |*d| {
    const driver_event = d.nextEvent() orelse break;
    switch (driver_event) {
      .ready => |ready| ctx.onReady(ready),
      .formed => |network| ctx.onFormed(network),
      .failed => |failure| {
        ctx.logMessage(.err, failure.message.text());
        ctx.finish(
          ctx.spares.pop().?,
          err(
            switch (failure.kind) {
              .timeout => .TIMEDOUT,
              .protocol => .PROTO,
              .unsupported => .PROTONOSUPPORT,
              .refused => .IO,
            },
          ),
        );
      },
      .log => |entry| ctx.logMessage(entry.level, entry.message.text()),
    }
    ctx.fillSpares() catch return err(.NOMEM);
  }
  return 0;
}

fn onReady(ctx: *Context, r: driver_layer.Ready) void {
  ctx.ieee = r.ieee;
  if (r.network) |network| {
    if (!ctx.options.replace_network) {
      const message: driver_layer.Message = .init(
        "resumed the dongle's network: channel {d}, PAN ID 0x{x:0>4} ({s})",
        .{ network.channel, network.pan_id, r.firmware.text() },
      );
      ctx.logMessage(.info, message.text());
      return ctx.started(network, .resumed);
    }
  }
  const f = ctx.newNetwork();
  const message: driver_layer.Message = if (r.network) |old|
    .init(
      "replacing the dongle's network (PAN ID 0x{x:0>4}) with a new one on channel {d} ({s})",
      .{ old.pan_id, f.network.channel, r.firmware.text() },
    )
  else
    .init("forming a new network on channel {d} ({s})", .{ f.network.channel, r.firmware.text() });
  ctx.logMessage(.info, message.text());
  ctx.driver.?.form(f);
}

fn onFormed(ctx: *Context, network: driver_layer.Network) void {
  const message: driver_layer.Message = .init(
    "formed a new network: channel {d}, PAN ID 0x{x:0>4}, extended PAN ID 0x{x:0>16}",
    .{ network.channel, network.pan_id, network.extended_pan_id },
  );
  ctx.logMessage(.info, message.text());
  ctx.started(network, .formed);
}

fn started(ctx: *Context, network: driver_layer.Network, origin: Event.Origin) void {
  ctx.network = network;
  ctx.status = .running;
  const event = ctx.spares.pop().?;
  event.type = .started;
  event.origin = origin;
  ctx.events.push(event);
}

/// The parameters of a new network: the options, or values drawn from the seeded generator.
fn newNetwork(ctx: *Context) driver_layer.Form {
  const random = ctx.random.random();
  const o = ctx.options;
  var f: driver_layer.Form = .{
    .network = .{
      .channel = o.channel,
      // 0xffff addresses every PAN.
      .pan_id = o.pan_id orelse while (true) {
        const pan_id = random.int(u16);
        if (pan_id != 0xffff) break pan_id;
      },
      // 0 and all ones are reserved.
      .extended_pan_id = o.extended_pan_id orelse while (true) {
        const extended = random.int(u64);
        if (extended != 0 and extended != std.math.maxInt(u64)) break extended;
      },
    },
    .network_key = undefined,
    .trust_center_link_key = undefined,
  };
  if (o.network_key) |key| {
    f.network_key = key;
  } else {
    random.bytes(&f.network_key);
  }
  random.bytes(&f.trust_center_link_key);
  return f;
}

/// Queues a log message if the log level lets it through. Uses a spare event.
fn logMessage(ctx: *Context, level: driver_layer.Level, message: []const u8) void {
  if (@backingInt(level) > @backingInt(ctx.options.log_level)) return;
  const event = ctx.spares.pop().?;
  event.type = .log;
  event.setLog(@backingInt(level), message);
  ctx.events.push(event);
}

fn takeSpare(ctx: *Context) error{ OutOfMemory }!*Event {
  try ctx.fillSpares();
  return ctx.spares.pop().?;
}

fn fillSpares(ctx: *Context) error{ OutOfMemory }!void {
  while (ctx.spares.len < spare_count) {
    const event = try Event.create(ctx.c_allocator);
    ctx.spares.push(event);
  }
}

pub fn err(e: E) c_int {
  return -@as(c_int, @intCast(@backingInt(e)));
}

test "options are checked" {
  var ctx = try create(.wrap(&std.testing.allocator), @splat(0));
  defer ctx.destroy();
  try std.testing.expectEqual(0, ctx.setOption("driver", "sim"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("driver", "zstack"));
  try std.testing.expectEqual(err(.NOENT), ctx.setOption("colour", "blue"));
  try std.testing.expectEqual(0, ctx.setOption("channel", "20"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("channel", "27"));
  try std.testing.expectEqual(0, ctx.setOption("pan-id", "0x1a62"));
  try std.testing.expectEqual(0x1a62, ctx.options.pan_id);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("pan-id", "ffff"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("pan-id", "12345"));
  try std.testing.expectEqual(0, ctx.setOption("network-key", "000102030405060708090a0b0c0d0e0f"));
  try std.testing.expectEqual(0x0f, ctx.options.network_key.?[15]);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("extended-pan-id", "0"));
  try std.testing.expectEqual(0, ctx.setOption("replace-network", "yes"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("log-level", "loud"));
  try std.testing.expectEqual(0, ctx.setOption("log-level", "debug"));
  try std.testing.expectEqual(driver_layer.Level.debug, ctx.options.log_level);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("network-key", "0f"));
}
