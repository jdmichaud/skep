//! A connection to the bus, without I/O: the bytes the bus sent go in, the bytes to send come out,
//! as for libskep and its dongle. It authenticates, says Hello, which gives it its unique name,
//! cuts what comes into messages, and numbers what it sends.
//!
//! What the bus may cost is bounded: a message longer than `max_message` is skipped unread, and
//! more than `max_output` of output the bus does not take ends the connection.

const std = @import("std");
const Auth = @import("auth.zig").Client;
const wire = @import("wire.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;
const Message = wire.Message;

const Connection = @This();

/// Longest message read: those for the methods a service answers are small, and a longer one,
/// which a peer may send to waste its memory, is skipped.
pub const max_message = 64 * 1024;
/// Most output the bus may leave unwritten before the connection is given up.
pub const max_output = 1 << 20;

pub const Error = error{
  /// The bus refused the uid, or the Hello.
  Rejected,
  /// What the bus sent is not the protocol.
  Protocol,
  /// The bus does not take what is sent.
  Backlog,
  OutOfMemory,
};

gpa: Allocator,
auth: Auth = .{},
/// What is to be sent: `sent` bytes of it are.
output: std.ArrayList(u8) = .empty,
sent: usize = 0,
/// What was received: `taken` bytes of it are taken.
input: std.ArrayList(u8) = .empty,
taken: usize = 0,
/// Bytes of a message too long to read, still to skip.
skipping: u64 = 0,
next_serial: u32 = 1,
hello_serial: u32 = 0,
/// Given by the bus in answer to Hello: the connection is ready once it has it.
unique_name: ?[]u8 = null,

pub fn init(gpa: Allocator, uid: u32) Error!Connection {
  var c: Connection = .{ .gpa = gpa };
  errdefer c.output.deinit(gpa);
  try Auth.start(gpa, &c.output, uid);
  return c;
}

pub fn deinit(c: *Connection) void {
  c.output.deinit(c.gpa);
  c.input.deinit(c.gpa);
  if (c.unique_name) |name| {
    c.gpa.free(name);
  }
}

/// Whether the bus answered Hello: messages can be exchanged.
pub fn ready(c: *const Connection) bool {
  return c.unique_name != null;
}

/// What is to be written to the bus.
pub fn pending(c: *const Connection) []const u8 {
  return c.output.items[c.sent..];
}

/// `n` bytes of what was pending are written.
pub fn written(c: *Connection, n: usize) void {
  c.sent += n;
  if (c.sent == c.output.items.len) {
    c.output.clearRetainingCapacity();
    c.sent = 0;
  }
}

/// Takes bytes the bus sent. Messages are then taken with `next`.
pub fn receive(c: *Connection, bytes: []const u8) Error!void {
  var rest = bytes;
  if (!c.auth.done) {
    rest = rest[try c.auth.feed(c.gpa, &c.output, rest)..];
    if (!c.auth.done) return;
    // Hello must be the first message.
    c.hello_serial = try c.send(
      .{
        .type = .method_call,
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "Hello",
      },
      &.{},
    );
  }
  // Only what is not taken yet is kept: what is received is taken before more is.
  const left = c.input.items.len - c.taken;
  std.mem.copyForwards(u8, c.input.items[0..left], c.input.items[c.taken..]);
  c.input.items.len = left;
  c.taken = 0;
  try c.input.appendSlice(c.gpa, rest);
}

/// The next message received, with what it holds in `arena`, or null if none is whole yet. The
/// answer to Hello is taken here.
pub fn next(c: *Connection, arena: Allocator) Error!?Message {
  while (true) {
    const rest = c.input.items[c.taken..];
    if (c.skipping > 0) {
      const n: usize = @intCast(@min(c.skipping, rest.len));
      c.taken += n;
      c.skipping -= n;
      if (c.skipping > 0) return null;
      continue;
    }
    if (rest.len < wire.fixed_header_len) return null;
    const len = wire.frameLength(rest[0..wire.fixed_header_len]) catch return error.Protocol;
    if (len > max_message) {
      c.skipping = len;
      continue;
    }
    if (rest.len < len) return null;
    const bytes = try arena.dupe(u8, rest[0..@intCast(len)]);
    c.taken += @intCast(len);
    const m = wire.decode(arena, bytes) catch |e| return switch (e) {
      error.Invalid => error.Protocol,
      error.OutOfMemory => error.OutOfMemory,
    };
    if (c.hello_serial != 0 and m.reply_serial == c.hello_serial) {
      try c.helloAnswered(arena, &m);
      continue;
    }
    return m;
  }
}

fn helloAnswered(c: *Connection, arena: Allocator, m: *const Message) Error!void {
  c.hello_serial = 0;
  if (m.type != .method_return or !std.mem.eql(u8, m.signature, "s")) return error.Rejected;
  const values = m.values(arena) catch return error.Protocol;
  c.unique_name = try c.gpa.dupe(u8, values[0].string);
}

/// Sends a message with `body`, and returns its serial, which its reply will name.
pub fn send(c: *Connection, m: Message, body: []const Value) Error!u32 {
  if (c.output.items.len - c.sent > max_output) return error.Backlog;
  const serial = c.next_serial;
  wire.encode(c.gpa, &c.output, m, serial, body) catch |e| switch (e) {
    error.OutOfMemory => return error.OutOfMemory,
    // The values were checked as they were given.
    error.InvalidValue => unreachable,
  };
  // Serials are not zero.
  c.next_serial = if (serial == std.math.maxInt(u32)) 1 else serial + 1;
  return serial;
}

const testing = std.testing;

/// What a bus sends after authentication: Hello's answer, `name`, to serial 1.
fn helloReply(gpa: Allocator, name: []const u8) ![]u8 {
  var bytes: std.ArrayList(u8) = .empty;
  try wire.encode(
    gpa,
    &bytes,
    .{
      .type = .method_return,
      .reply_serial = 1,
      .destination = name,
      .sender = "org.freedesktop.DBus",
    },
    1,
    &.{.{ .string = name }},
  );
  return bytes.toOwnedSlice(gpa);
}

test "a connection authenticates, says Hello, and is ready with its name" {
  var c: Connection = try .init(testing.allocator, 1000);
  defer c.deinit();
  try testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\n", c.pending());
  c.written(c.pending().len);
  try testing.expectEqual(0, c.pending().len);

  try c.receive("OK 0123456789abcdef0123456789abcdef\r\n");
  // BEGIN, then Hello.
  try testing.expect(std.mem.startsWith(u8, c.pending(), "BEGIN\r\nl\x01"));
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const hello = try wire.decode(arena.allocator(), c.pending()["BEGIN\r\n".len..]);
  try testing.expectEqualStrings("Hello", hello.member.?);
  try testing.expect(!c.ready());

  const reply = try helloReply(testing.allocator, ":1.42");
  defer testing.allocator.free(reply);
  // In two pieces, as the socket may give it.
  try c.receive(reply[0..10]);
  try testing.expectEqual(null, try c.next(arena.allocator()));
  try c.receive(reply[10..]);
  try testing.expectEqual(null, try c.next(arena.allocator()));
  try testing.expectEqualStrings(":1.42", c.unique_name.?);
}

test "the messages of a real bus are all read, and read the same once encoded again" {
  // dbus-daemon's, busctl's and gdbus's messages, as dbus-monitor --binary wrote them on a session
  // bus of their own: Hello and its answer, NameAcquired, introspection, Properties.GetAll and Get.
  const capture = @embedFile("testdata/session.bin");
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const a = arena.allocator();
  var c: Connection = .{ .gpa = testing.allocator, .auth = .{ .done = true } };
  defer c.deinit();
  try c.receive(capture);
  var count: usize = 0;
  var features: ?[]const Value = null;
  while (try c.next(a)) |m| {
    count += 1;
    const values = try m.values(a);
    var bytes: std.ArrayList(u8) = .empty;
    try wire.encode(a, &bytes, m, m.serial, values);
    const again = try wire.decode(a, bytes.items);
    for (values, try again.values(a)) |x, y| {
      try testing.expect(x.eql(y));
    }
    // The answer to GetAll: Features and Interfaces, arrays of strings in variants.
    if (m.type == .method_return and std.mem.eql(u8, m.signature, "a{sv}")) {
      for (values[0].dict.entries) |entry| {
        if (std.mem.eql(u8, entry.key.string, "Features")) {
          features = entry.value.variant.array.items;
        }
      }
    }
  }
  try testing.expectEqual(c.input.items.len, c.taken);
  try testing.expectEqual(20, count);
  try testing.expect(features.?.len > 0);
}

test "a message too long is skipped, and what follows it read" {
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const a = arena.allocator();
  var c: Connection = .{ .gpa = testing.allocator, .auth = .{ .done = true } };
  defer c.deinit();
  var bytes: std.ArrayList(u8) = .empty;
  const long = try a.alloc(u8, max_message);
  @memset(long, 'x');
  try wire.encode(
    a,
    &bytes,
    .{ .type = .signal, .path = "/a", .interface = "a.b", .member = "C" },
    1,
    &.{.{ .string = long }},
  );
  try wire.encode(
    a,
    &bytes,
    .{ .type = .signal, .path = "/a", .interface = "a.b", .member = "D" },
    2,
    &.{},
  );
  // A piece at a time, as the socket gives it.
  var i: usize = 0;
  var got: ?Message = null;
  while (i < bytes.items.len) : (i += 4096) {
    try c.receive(bytes.items[i..@min(i + 4096, bytes.items.len)]);
    if (try c.next(a)) |m| {
      got = m;
    }
  }
  try testing.expectEqualStrings("D", got.?.member.?);
  try testing.expect(c.input.items.len < 2 * 4096);
}

test "a bus that does not take what is sent ends the connection" {
  var c: Connection = .{ .gpa = testing.allocator, .auth = .{ .done = true } };
  defer c.deinit();
  const m: Message = .{ .type = .signal, .path = "/a", .interface = "a.b", .member = "C" };
  const filler: [1000]u8 = @splat('x');
  while (c.output.items.len <= max_output) {
    _ = try c.send(m, &.{.{ .string = &filler }});
  }
  try testing.expectError(error.Backlog, c.send(m, &.{}));
}

test "fuzz: a connection survives whatever the bus sends" {
  try testing.fuzz({}, fuzzConnection, .{});
}

fn fuzzConnection(_: void, smith: *testing.Smith) !void {
  var c: Connection = try .init(testing.allocator, 1000);
  defer c.deinit();
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  // Authenticated, or not, as the bytes say.
  if (smith.value(bool)) {
    try c.receive("OK 0123456789abcdef0123456789abcdef\r\n");
  }
  var input: [512]u8 = undefined;
  while (!smith.eos()) {
    const len = smith.slice(&input);
    c.receive(input[0..len]) catch return;
    while (c.next(arena.allocator()) catch return) |m| {
      _ = m.values(arena.allocator()) catch {};
    }
    _ = arena.reset(.retain_capacity);
  }
}
