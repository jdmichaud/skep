//! A service published on the session bus through the dbus module's interface, Bus, and nothing
//! else of the module, for test/dbus-contract.sh to check what clients see of it.
//!
//! It takes lines on its standard input, and answers each with "ok" on its standard output once
//! done; it prints "published" once its name is its own, and exits at the end of its input:
//!
//!   put PATH NAME TEMPERATURE   an object with Name and Readings {"temperature": TEMPERATURE}
//!   set PATH TEMPERATURE        a new temperature
//!   remove PATH

const std = @import("std");
const dbus = @import("dbus");

const linux = std.os.linux;
const posix = std.posix;

pub const name = "io.example.Contract1";
pub const root = "/io/example/Contract1";
pub const interface = "io.example.Contract1.Device";

const interfaces = [_]dbus.Interface{.{
  .name = interface,
  .properties = &.{
    .{ .name = "Name", .signature = "s" },
    .{ .name = "Readings", .signature = "a{sv}" },
  },
}};

pub fn main(init: std.process.Init) !u8 {
  const address = dbus.Bus.sessionAddress(init.environ_map) orelse {
    say("dbus-harness: no DBUS_SESSION_BUS_ADDRESS\n");
    return 1;
  };
  var bus: dbus.Bus = try .init(init.gpa, .{
    .name = name,
    .root = root,
    .interfaces = &interfaces,
    .address = address,
  });
  defer bus.deinit();
  var input: std.ArrayList(u8) = .empty;
  defer input.deinit(init.gpa);
  while (true) {
    const now = millis(init.io);
    bus.advance(now);
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }, bus.pollFd() };
    const timeout: i32 = if (bus.deadline()) |t| @intCast(@min(t -| now, 1000)) else -1;
    _ = try posix.poll(&fds, timeout);
    if (fds[0].revents != 0) {
      var buffer: [512]u8 = undefined;
      const rc = linux.read(0, &buffer, buffer.len);
      if (linux.errno(rc) != .SUCCESS or rc == 0) return 0;
      try input.appendSlice(init.gpa, buffer[0..rc]);
      while (std.mem.indexOfScalar(u8, input.items, '\n')) |end| {
        try command(&bus, input.items[0..end]);
        say("ok\n");
        std.mem.copyForwards(u8, input.items, input.items[end + 1..]);
        input.items.len -= end + 1;
      }
    }
    bus.polled(fds[1].revents, millis(init.io));
    while (bus.nextNews()) |news| {
      switch (news) {
        .published => say("published\n"),
        else => {},
      }
    }
  }
}

fn command(bus: *dbus.Bus, line: []const u8) !void {
  var words = std.mem.tokenizeScalar(u8, line, ' ');
  const verb = words.next() orelse return;
  const path = words.next() orelse return error.BadCommand;
  if (std.mem.eql(u8, verb, "remove")) return bus.remove(path);
  if (std.mem.eql(u8, verb, "put")) {
    const device = words.next() orelse return error.BadCommand;
    const t = try std.fmt.parseFloat(f64, words.next() orelse return error.BadCommand);
    return bus.put(
      path,
      interface,
      &.{
        .{ .name = "Name", .value = .{ .string = device } },
        .{ .name = "Readings", .value = readings(&t) },
      },
    );
  }
  if (std.mem.eql(u8, verb, "set")) {
    const t = try std.fmt.parseFloat(f64, words.next() orelse return error.BadCommand);
    return bus.set(path, interface, &.{.{ .name = "Readings", .value = readings(&t) }});
  }
  return error.BadCommand;
}

var entry: [1]dbus.Value.Entry = undefined;
var temperature: dbus.Value = undefined;

/// {"temperature": t}, as a dictionary of variants.
fn readings(t: *const f64) dbus.Value {
  temperature = .{ .double = t.* };
  entry = .{.{ .key = .{ .string = "temperature" }, .value = .{ .variant = &temperature } }};
  return .{ .dict = .{ .key = "s", .value = "v", .entries = &entry } };
}

fn millis(io: std.Io) u64 {
  const timestamp = std.Io.Clock.awake.now(io);
  return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
}

fn say(text: []const u8) void {
  _ = linux.write(1, text.ptr, text.len);
}
