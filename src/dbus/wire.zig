//! The D-Bus wire format: values marshalled as the specification says, and messages, a header
//! and a body of values. Messages are sent little-endian, and received in either order.
//!
//! What comes from the bus is untrusted: every length is checked against what is there, every
//! padding byte must be zero, strings must be UTF-8, nesting is bounded, and a message that
//! breaks a rule is refused as a whole.

const std = @import("std");
const signature = @import("signature.zig");
const names = @import("names.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;

/// The protocol's version, in each message's header.
pub const protocol_version = 1;
/// Longest message the specification allows, in bytes.
pub const spec_max_message = 128 * 1024 * 1024;
/// Longest array the specification allows, in bytes.
pub const max_array = 64 * 1024 * 1024;
/// The fixed part of the header: endianness, type, flags, version, body length, serial, and the
/// length of the header fields' array.
pub const fixed_header_len = 16;

pub const MessageType = enum(u8) {
  method_call = 1,
  method_return = 2,
  @"error" = 3,
  signal = 4,
  /// Received, and ignored as the specification asks.
  _,
};

pub const Flags = packed struct(u8) {
  no_reply_expected: bool = false,
  no_auto_start: bool = false,
  allow_interactive_authorization: bool = false,
  _: u5 = 0,
};

const Field = enum(u8) {
  path = 1,
  interface = 2,
  member = 3,
  error_name = 4,
  reply_serial = 5,
  destination = 6,
  sender = 7,
  signature = 8,
  unix_fds = 9,
  _,
};

pub const Message = struct {
  type: MessageType,
  flags: Flags = .{},
  /// Set as it is sent.
  serial: u32 = 0,
  path: ?[]const u8 = null,
  interface: ?[]const u8 = null,
  member: ?[]const u8 = null,
  error_name: ?[]const u8 = null,
  reply_serial: ?u32 = null,
  destination: ?[]const u8 = null,
  /// Set by the bus.
  sender: ?[]const u8 = null,
  /// Of the body: received, or computed from the values as it is sent.
  signature: []const u8 = "",
  /// Received: the body's bytes, in `endian` order.
  body: []const u8 = "",
  endian: Endian = .little,

  /// The body, as values of its signature, in `arena`.
  pub fn values(m: *const Message, arena: Allocator) Decoder.Error![]Value {
    var d: Decoder = .{ .bytes = m.body, .endian = m.endian };
    var list: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < m.signature.len) {
      const len = signature.completeLen(m.signature[i..]) orelse return error.Invalid;
      try list.append(arena, try d.read(arena, m.signature[i..][0..len], true, 0));
      i += len;
    }
    if (d.pos != d.bytes.len) return error.Invalid;
    return list.items;
  }
};

/// Writes values into a message, aligned from the message's start, at `base` in `bytes`.
pub const Encoder = struct {
  gpa: Allocator,
  bytes: *std.ArrayList(u8),
  base: usize,

  pub const Error = error{ OutOfMemory, InvalidValue };

  fn pad(e: Encoder, alignment: usize) Error!void {
    const len = e.bytes.items.len - e.base;
    try e.bytes.appendNTimes(e.gpa, 0, std.mem.alignForward(usize, len, alignment) - len);
  }

  fn int(e: Encoder, comptime T: type, v: T) Error!void {
    try e.pad(@sizeOf(T));
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try e.bytes.appendSlice(e.gpa, &b);
  }

  fn string(e: Encoder, s: []const u8) Error!void {
    try e.int(u32, std.math.cast(u32, s.len) orelse return error.InvalidValue);
    try e.bytes.appendSlice(e.gpa, s);
    try e.bytes.append(e.gpa, 0);
  }

  fn sig(e: Encoder, s: []const u8) Error!void {
    try e.bytes.append(e.gpa, std.math.cast(u8, s.len) orelse return error.InvalidValue);
    try e.bytes.appendSlice(e.gpa, s);
    try e.bytes.append(e.gpa, 0);
  }

  /// Starts an array of elements aligned as `element`, whose length `patch` writes: returns
  /// where the length is.
  fn beginArray(e: Encoder, element: u8) Error!usize {
    try e.int(u32, 0);
    const at = e.bytes.items.len - 4;
    try e.pad(signature.alignment(element));
    return at;
  }

  pub fn value(e: Encoder, v: Value) Error!void {
    switch (v) {
      .byte => |b| try e.bytes.append(e.gpa, b),
      .boolean => |b| try e.int(u32, @intFromBool(b)),
      .int16 => |x| try e.int(i16, x),
      .uint16 => |x| try e.int(u16, x),
      .int32 => |x| try e.int(i32, x),
      .uint32 => |x| try e.int(u32, x),
      .int64 => |x| try e.int(i64, x),
      .uint64 => |x| try e.int(u64, x),
      .double => |x| try e.int(u64, @bitCast(x)),
      .string, .object_path => |s| try e.string(s),
      .signature => |s| try e.sig(s),
      .variant => |inner| {
        var buffer: [signature.max_len]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        inner.writeSignature(&w) catch return error.InvalidValue;
        try e.sig(w.buffered());
        try e.value(inner.*);
      },
      .array => |a| {
        if (a.element.len == 0) return error.InvalidValue;
        const at = try e.beginArray(a.element[0]);
        const start = e.bytes.items.len;
        for (a.items) |item| {
          try e.value(item);
        }
        try e.patch(at, start);
      },
      .dict => |d| {
        const at = try e.beginArray('{');
        const start = e.bytes.items.len;
        for (d.entries) |entry| {
          try e.pad(8);
          try e.value(entry.key);
          try e.value(entry.value);
        }
        try e.patch(at, start);
      },
      .structure => |fields| {
        try e.pad(8);
        for (fields) |field| {
          try e.value(field);
        }
      },
    }
  }

  /// Writes the length of the array whose length is at `at` and whose elements start at `start`.
  fn patch(e: Encoder, at: usize, start: usize) Error!void {
    const len = e.bytes.items.len - start;
    if (len > max_array) return error.InvalidValue;
    std.mem.writeInt(u32, e.bytes.items[at..][0..4], @intCast(len), .little);
  }
};

/// Reads values from bytes, aligned from their start, which must be aligned to 8 in the message.
pub const Decoder = struct {
  bytes: []const u8,
  pos: usize = 0,
  endian: Endian,

  pub const Error = error{ Invalid, OutOfMemory };

  fn alignTo(d: *Decoder, alignment: usize) Error!void {
    const to = std.mem.alignForward(usize, d.pos, alignment);
    if (to > d.bytes.len) return error.Invalid;
    for (d.bytes[d.pos..to]) |b| {
      if (b != 0) return error.Invalid;
    }
    d.pos = to;
  }

  fn take(d: *Decoder, n: usize) Error![]const u8 {
    if (d.bytes.len - d.pos < n) return error.Invalid;
    defer d.pos += n;
    return d.bytes[d.pos..][0..n];
  }

  fn int(d: *Decoder, comptime T: type) Error!T {
    try d.alignTo(@sizeOf(T));
    return std.mem.readInt(T, (try d.take(@sizeOf(T)))[0..@sizeOf(T)], d.endian);
  }

  fn string(d: *Decoder) Error![]const u8 {
    const len = try d.int(u32);
    const s = try d.take(len);
    if ((try d.take(1))[0] != 0 or !names.isString(s)) return error.Invalid;
    return s;
  }

  fn sig(d: *Decoder) Error![]const u8 {
    const len = (try d.take(1))[0];
    const s = try d.take(len);
    if ((try d.take(1))[0] != 0) return error.Invalid;
    return s;
  }

  fn Result(comptime build: bool) type {
    return if (build) Value else void;
  }

  /// Reads a value of the complete type `t`, at `depth` of nesting, and returns it if `build`,
  /// with what it refers to in `arena` or in the bytes; or only checks it.
  pub fn read(
    d: *Decoder,
    arena: Allocator,
    t: []const u8,
    comptime build: bool,
    depth: usize,
  ) Error!Result(build) {
    // Arrays, structures and variants all count, so that recursion is bounded whatever the bytes.
    if (depth > 2 * signature.max_depth) return error.Invalid;
    const v: Value = switch (t[0]) {
      'y' => .{ .byte = (try d.take(1))[0] },
      'b' => .{
        .boolean = switch (try d.int(u32)) {
          0 => false,
          1 => true,
          else => return error.Invalid,
        },
      },
      'n' => .{ .int16 = try d.int(i16) },
      'q' => .{ .uint16 = try d.int(u16) },
      'i' => .{ .int32 = try d.int(i32) },
      'u' => .{ .uint32 = try d.int(u32) },
      'x' => .{ .int64 = try d.int(i64) },
      't' => .{ .uint64 = try d.int(u64) },
      'd' => .{ .double = @bitCast(try d.int(u64)) },
      's' => .{ .string = try d.string() },
      'o' => .{
        .object_path = blk: {
          const p = try d.string();
          if (!names.isObjectPath(p)) return error.Invalid;
          break :blk p;
        },
      },
      'g' => .{
        .signature = blk: {
          const s = try d.sig();
          if (!signature.isValid(s)) return error.Invalid;
          break :blk s;
        },
      },
      'v' => {
        const s = try d.sig();
        if (!signature.isSingle(s)) return error.Invalid;
        const inner = try d.read(arena, s, build, depth + 1);
        if (!build) return;
        const copy = try arena.create(Value);
        copy.* = inner;
        return .{ .variant = copy };
      },
      'a' => {
        const len = try d.int(u32);
        if (len > max_array) return error.Invalid;
        const element = t[1..];
        try d.alignTo(signature.alignment(element[0]));
        if (d.bytes.len - d.pos < len) return error.Invalid;
        const end = d.pos + len;
        if (element[0] == '{') {
          const key = element[1..2];
          const value_type = element[2..element.len - 1];
          var entries: std.ArrayList(Value.Entry) = .empty;
          while (d.pos < end) {
            try d.alignTo(8);
            const k = try d.read(arena, key, build, depth + 1);
            const value = try d.read(arena, value_type, build, depth + 1);
            if (build) {
              try entries.append(arena, .{ .key = k, .value = value });
            }
          }
          if (d.pos != end) return error.Invalid;
          if (!build) return;
          return .{ .dict = .{ .key = key, .value = value_type, .entries = entries.items } };
        }
        var items: std.ArrayList(Value) = .empty;
        while (d.pos < end) {
          const item = try d.read(arena, element, build, depth + 1);
          if (build) {
            try items.append(arena, item);
          }
        }
        if (d.pos != end) return error.Invalid;
        if (!build) return;
        return .{ .array = .{ .element = element, .items = items.items } };
      },
      '(' => {
        try d.alignTo(8);
        var fields: std.ArrayList(Value) = .empty;
        var i: usize = 1;
        while (t[i] != ')') {
          const len = signature.completeLen(t[i..]).?;
          const field = try d.read(arena, t[i..][0..len], build, depth + 1);
          if (build) {
            try fields.append(arena, field);
          }
          i += len;
        }
        if (!build) return;
        return .{ .structure = fields.items };
      },
      // Unix file descriptors are not asked for, so none can come.
      else => return error.Invalid,
    };
    if (build) return v;
  }
};

/// The length of the message whose fixed header is `fixed`, or an error if it is none.
pub fn frameLength(fixed: *const [fixed_header_len]u8) error{ Invalid }!u64 {
  const endian = try endianOf(fixed[0]);
  if (fixed[3] != protocol_version) return error.Invalid;
  const body_len = std.mem.readInt(u32, fixed[4..8], endian);
  const fields_len = std.mem.readInt(u32, fixed[12..16], endian);
  if (fields_len > max_array) return error.Invalid;
  const total = std.mem.alignForward(u64, fixed_header_len + @as(u64, fields_len), 8) + body_len;
  if (total > spec_max_message) return error.Invalid;
  return total;
}

fn endianOf(b: u8) error{ Invalid }!Endian {
  return switch (b) {
    'l' => .little,
    'B' => .big,
    else => error.Invalid,
  };
}

/// Decodes a whole message, whose strings are left in `bytes`. Checks its header and that its
/// body is as long as its header says; its values are read by `Message.values`, or not at all.
pub fn decode(arena: Allocator, bytes: []const u8) Decoder.Error!Message {
  if (bytes.len < fixed_header_len) return error.Invalid;
  if (try frameLength(bytes[0..fixed_header_len]) != bytes.len) return error.Invalid;
  var m: Message = .{
    .type = @fromBackingInt(@intCast(bytes[1])),
    .flags = @bitCast(bytes[2]),
    .endian = try endianOf(bytes[0]),
  };
  var d: Decoder = .{ .bytes = bytes, .pos = 8, .endian = m.endian };
  m.serial = try d.int(u32);
  if (m.serial == 0) return error.Invalid;
  const fields_len = try d.int(u32);
  const fields_end = d.pos + fields_len;
  while (d.pos < fields_end) {
    try d.alignTo(8);
    const code: Field = @fromBackingInt(@intCast((try d.take(1))[0]));
    const s = try d.sig();
    if (!signature.isSingle(s)) return error.Invalid;
    const expected: []const u8 = switch (code) {
      .path => "o",
      .interface, .member, .error_name, .destination, .sender => "s",
      .reply_serial, .unix_fds => "u",
      .signature => "g",
      // Unknown fields are accepted and ignored, as the specification asks.
      _ => {
        try d.read(arena, s, false, 1);
        continue;
      },
    };
    if (!std.mem.eql(u8, s, expected)) return error.Invalid;
    const v = try d.read(arena, s, true, 1);
    switch (code) {
      .path => m.path = v.object_path,
      .interface => m.interface = v.string,
      .member => m.member = v.string,
      .error_name => m.error_name = v.string,
      .reply_serial => m.reply_serial = v.uint32,
      .destination => m.destination = v.string,
      .sender => m.sender = v.string,
      .signature => m.signature = v.signature,
      .unix_fds => if (v.uint32 != 0) return error.Invalid,
      _ => unreachable,
    }
  }
  if (d.pos != fields_end) return error.Invalid;
  try d.alignTo(8);
  m.body = bytes[d.pos..];
  if (m.body.len > 0 and m.signature.len == 0) return error.Invalid;
  const required: []const ?[]const u8 = switch (m.type) {
    .method_call => &.{ m.path, m.member },
    .method_return => &.{ if (m.reply_serial != null) "" else null },
    .@"error" => &.{ m.error_name, if (m.reply_serial != null) "" else null },
    .signal => &.{ m.path, m.interface, m.member },
    _ => &.{},
  };
  for (required) |field| {
    if (field == null) return error.Invalid;
  }
  return m;
}

/// Appends the message `m`, with `body` and the serial `serial`, to `bytes`.
pub fn encode(
  gpa: Allocator,
  bytes: *std.ArrayList(u8),
  m: Message,
  serial: u32,
  body: []const Value,
) Encoder.Error!void {
  var sig_buffer: [signature.max_len]u8 = undefined;
  var w: std.Io.Writer = .fixed(&sig_buffer);
  for (body) |v| {
    v.writeSignature(&w) catch return error.InvalidValue;
  }
  const body_sig = w.buffered();

  const base = bytes.items.len;
  errdefer bytes.shrinkRetainingCapacity(base);
  const e: Encoder = .{ .gpa = gpa, .bytes = bytes, .base = base };
  try bytes.appendSlice(gpa, &.{ 'l', @backingInt(m.type), @bitCast(m.flags), protocol_version });
  try e.int(u32, 0);
  try e.int(u32, serial);

  const strings = [_]struct { Field, ?[]const u8, u8 }{
    .{ .path, m.path, 'o' },
    .{ .interface, m.interface, 's' },
    .{ .member, m.member, 's' },
    .{ .error_name, m.error_name, 's' },
    .{ .destination, m.destination, 's' },
    // Set by the bus: given here by tests that play it.
    .{ .sender, m.sender, 's' },
  };
  const at = try e.beginArray('(');
  const start = bytes.items.len;
  for (strings) |field| {
    const s = field[1] orelse continue;
    try e.pad(8);
    try bytes.append(gpa, @backingInt(field[0]));
    try e.sig(&.{ field[2] });
    try e.string(s);
  }
  if (m.reply_serial) |reply| {
    try e.pad(8);
    try bytes.append(gpa, @backingInt(Field.reply_serial));
    try e.sig("u");
    try e.int(u32, reply);
  }
  if (body_sig.len > 0) {
    try e.pad(8);
    try bytes.append(gpa, @backingInt(Field.signature));
    try e.sig("g");
    try e.sig(body_sig);
  }
  try e.patch(at, start);
  try e.pad(8);

  const body_start = bytes.items.len;
  for (body) |v| {
    try e.value(v);
  }
  const body_len = bytes.items.len - body_start;
  if (bytes.items.len - base > spec_max_message) return error.InvalidValue;
  std.mem.writeInt(u32, bytes.items[base + 4..][0..4], @intCast(body_len), .little);
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var out: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&out, text) catch unreachable;
  return out;
}

test "a method call is encoded as the specification says" {
  var bytes: std.ArrayList(u8) = .empty;
  defer bytes.deinit(testing.allocator);
  try encode(
    testing.allocator,
    &bytes,
    .{
      .type = .method_call,
      .path = "/org/freedesktop/DBus",
      .interface = "org.freedesktop.DBus",
      .member = "RequestName",
      .destination = "org.freedesktop.DBus",
    },
    2,
    &.{.{ .string = "a.b" }, .{ .uint32 = 4 }},
  );
  // Written out by hand from the specification: fixed header, then each field aligned to 8, its
  // code, its signature and its value; the body aligned to 8.
  const expected = "6c0100010c000000" ++ "0200000080000000" ++
    // PATH, "o", "/org/freedesktop/DBus"
    "01016f0015000000" ++ "2f6f72672f667265" ++ "656465736b746f70" ++ "2f44427573000000" ++
    // INTERFACE, "s", "org.freedesktop.DBus"
    "0201730014000000" ++ "6f72672e66726565" ++ "6465736b746f702e" ++ "4442757300000000" ++
    // MEMBER, "s", "RequestName"
    "030173000b000000" ++ "526571756573744e" ++ "616d650000000000" ++
    // DESTINATION, "s", "org.freedesktop.DBus"
    "0601730014000000" ++ "6f72672e66726565" ++ "6465736b746f702e" ++ "4442757300000000" ++
    // SIGNATURE, "g", "su"
    "0801670002737500" ++
    // the body: "a.b", 4
    "03000000612e6200" ++ "04000000";
  try testing.expectEqualSlices(u8, &hex(expected), bytes.items);

  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const m = try decode(arena.allocator(), bytes.items);
  try testing.expectEqual(MessageType.method_call, m.type);
  try testing.expectEqual(2, m.serial);
  try testing.expectEqualStrings("RequestName", m.member.?);
  try testing.expectEqualStrings("su", m.signature);
  const values = try m.values(arena.allocator());
  try testing.expectEqualStrings("a.b", values[0].string);
  try testing.expectEqual(4, values[1].uint32);
}

test "a big-endian message is read as well" {
  // A signal from the bus, serial 3: NameAcquired(":1.7") on /org/freedesktop/DBus.
  const bytes = hex(
    "42040001" ++ "00000009" ++ "00000003" ++ "0000005f" ++
      // PATH, "o", "/org/freedesktop/DBus"
      "01016f00" ++ "00000015" ++ "2f6f72672f667265656465736b746f702f44427573000000" ++
      // INTERFACE, "s", "org.freedesktop.DBus"
      "02017300" ++ "00000014" ++ "6f72672e667265656465736b746f702e4442757300000000" ++
      // MEMBER, "s", "NameAcquired"
      "03017300" ++ "0000000c" ++ "4e616d654163717569726564" ++ "00000000" ++
      // SIGNATURE, "g", "s", then the padding before the body
      "08016700" ++ "017300" ++ "00" ++
      // the body: ":1.7"
      "00000004" ++ "3a312e3700",
  );
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const m = try decode(arena.allocator(), &bytes);
  try testing.expectEqual(MessageType.signal, m.type);
  try testing.expectEqual(3, m.serial);
  try testing.expectEqualStrings("NameAcquired", m.member.?);
  try testing.expectEqualStrings(":1.7", (try m.values(arena.allocator()))[0].string);
}

test "messages that break the rules are refused" {
  var bytes: std.ArrayList(u8) = .empty;
  defer bytes.deinit(testing.allocator);
  try encode(
    testing.allocator,
    &bytes,
    .{ .type = .method_call, .path = "/a", .member = "M" },
    1,
    &.{.{ .boolean = true }},
  );
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const a = arena.allocator();
  const good = try testing.allocator.dupe(u8, bytes.items);
  defer testing.allocator.free(good);
  _ = try (try decode(a, good)).values(a);

  // A boolean that is neither 0 nor 1.
  const body = good.len - 4;
  good[body] = 2;
  try testing.expectError(error.Invalid, (try decode(a, good)).values(a));
  good[body] = 1;
  // A padding byte that is not zero: the one after the path's NUL.
  const padding = std.mem.indexOf(u8, good, "/a").? + 3;
  good[padding] = 1;
  try testing.expectError(error.Invalid, decode(a, good));
  good[padding] = 0;
  // Serial 0, then a body longer than the bytes.
  @memset(good[8..12], 0);
  try testing.expectError(error.Invalid, decode(a, good));
  std.mem.writeInt(u32, good[8..12], 1, .little);
  std.mem.writeInt(u32, good[4..8], 8, .little);
  try testing.expectError(error.Invalid, decode(a, good));
  std.mem.writeInt(u32, good[4..8], 4, .little);
  // A method call without its member.
  var no_member: std.ArrayList(u8) = .empty;
  defer no_member.deinit(testing.allocator);
  try encode(testing.allocator, &no_member, .{ .type = .method_call, .path = "/a" }, 1, &.{});
  try testing.expectError(error.Invalid, decode(a, no_member.items));
  _ = try decode(a, good);
}

test "values come back as they were encoded" {
  const inner: Value = .{ .double = -21.5 };
  const entries = [_]Value.Entry{
    .{ .key = .{ .string = "temperature" }, .value = .{ .variant = &inner } },
    .{ .key = .{ .string = "on" }, .value = .{ .variant = &.{ .boolean = false } } },
  };
  const fields = [_]Value{.{ .byte = 7 }, .{ .int64 = -1 }, .{ .signature = "a{sv}" }};
  const items = [_]Value{.{ .uint16 = 1 }, .{ .uint16 = 65535 }};
  const body = [_]Value{
    .{ .object_path = "/x/y" },
    .{ .dict = .{ .key = "s", .value = "v", .entries = &entries } },
    .{ .structure = &fields },
    .{ .array = .{ .element = "q", .items = &items } },
    .{ .array = .{ .element = "(yxg)", .items = &.{} } },
    .{ .int16 = -2 },
    .{ .uint64 = std.math.maxInt(u64) },
  };
  var bytes: std.ArrayList(u8) = .empty;
  defer bytes.deinit(testing.allocator);
  try encode(
    testing.allocator,
    &bytes,
    .{
      .type = .signal,
      .path = "/x",
      .interface = "a.b",
      .member = "C",
    },
    9,
    &body,
  );
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const m = try decode(arena.allocator(), bytes.items);
  try testing.expectEqualStrings("oa{sv}(yxg)aqa(yxg)nt", m.signature);
  const values = try m.values(arena.allocator());
  try testing.expectEqual(body.len, values.len);
  for (body, values) |sent, received| {
    try testing.expect(sent.eql(received));
  }
}

test "fuzz: decoding survives any message" {
  try testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *testing.Smith) !void {
  var input: [4096]u8 = undefined;
  const len = smith.slice(&input);
  var buffer: [1 << 16]u8 = undefined;
  var fba: std.heap.FixedBufferAllocator = .init(&buffer);
  const m = decode(fba.allocator(), input[0..len]) catch return;
  const values = m.values(fba.allocator()) catch return;
  // What was read is valid, and encodes again into a message that reads the same.
  var bytes: std.ArrayList(u8) = .empty;
  defer bytes.deinit(testing.allocator);
  for (values) |v| {
    try testing.expect(v.isValid());
  }
  if (m.type == .method_call or
    m.type == .signal or
    m.type == .method_return or
    m.type == .@"error") {
    try encode(testing.allocator, &bytes, m, m.serial, values);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const again = try decode(arena.allocator(), bytes.items);
    const values_again = try again.values(arena.allocator());
    try testing.expectEqualStrings(m.signature, again.signature);
    for (values, values_again) |a, b| {
      try testing.expect(a.eql(b));
    }
  }
}
