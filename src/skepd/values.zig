//! ZCL values as skep-protocol(7) writes them in JSON: their types by name, and their values as
//! the type says, numbers, strings of decimal digits for 56 and 64 bits, booleans, text or
//! hexadecimal digits.

const std = @import("std");
const c = @import("skep_h");

pub const Kind = enum {
  none,
  boolean,
  unsigned,
  signed,
  float,
  /// Character strings: text.
  text,
  /// Octet strings, keys, arrays, sets, bags and structures: their bytes, in hexadecimal.
  bytes,
  /// IEEE addresses: 16 hexadecimal digits.
  ieee,
};

pub const Type = struct {
  id: u8,
  name: []const u8,
  kind: Kind,
  /// For integers.
  bits: u8 = 0,
};

/// The ZCL's data types (ZCL revision 8, 2.6.2).
pub const types = [_]Type{
  .{ .id = 0x00, .name = "nodata", .kind = .none },
  .{ .id = 0x08, .name = "data8", .kind = .unsigned, .bits = 8 },
  .{ .id = 0x09, .name = "data16", .kind = .unsigned, .bits = 16 },
  .{ .id = 0x0a, .name = "data24", .kind = .unsigned, .bits = 24 },
  .{ .id = 0x0b, .name = "data32", .kind = .unsigned, .bits = 32 },
  .{ .id = 0x0c, .name = "data40", .kind = .unsigned, .bits = 40 },
  .{ .id = 0x0d, .name = "data48", .kind = .unsigned, .bits = 48 },
  .{ .id = 0x0e, .name = "data56", .kind = .unsigned, .bits = 56 },
  .{ .id = 0x0f, .name = "data64", .kind = .unsigned, .bits = 64 },
  .{ .id = 0x10, .name = "bool", .kind = .boolean },
  .{ .id = 0x18, .name = "bitmap8", .kind = .unsigned, .bits = 8 },
  .{ .id = 0x19, .name = "bitmap16", .kind = .unsigned, .bits = 16 },
  .{ .id = 0x1a, .name = "bitmap24", .kind = .unsigned, .bits = 24 },
  .{ .id = 0x1b, .name = "bitmap32", .kind = .unsigned, .bits = 32 },
  .{ .id = 0x1c, .name = "bitmap40", .kind = .unsigned, .bits = 40 },
  .{ .id = 0x1d, .name = "bitmap48", .kind = .unsigned, .bits = 48 },
  .{ .id = 0x1e, .name = "bitmap56", .kind = .unsigned, .bits = 56 },
  .{ .id = 0x1f, .name = "bitmap64", .kind = .unsigned, .bits = 64 },
  .{ .id = 0x20, .name = "uint8", .kind = .unsigned, .bits = 8 },
  .{ .id = 0x21, .name = "uint16", .kind = .unsigned, .bits = 16 },
  .{ .id = 0x22, .name = "uint24", .kind = .unsigned, .bits = 24 },
  .{ .id = 0x23, .name = "uint32", .kind = .unsigned, .bits = 32 },
  .{ .id = 0x24, .name = "uint40", .kind = .unsigned, .bits = 40 },
  .{ .id = 0x25, .name = "uint48", .kind = .unsigned, .bits = 48 },
  .{ .id = 0x26, .name = "uint56", .kind = .unsigned, .bits = 56 },
  .{ .id = 0x27, .name = "uint64", .kind = .unsigned, .bits = 64 },
  .{ .id = 0x28, .name = "int8", .kind = .signed, .bits = 8 },
  .{ .id = 0x29, .name = "int16", .kind = .signed, .bits = 16 },
  .{ .id = 0x2a, .name = "int24", .kind = .signed, .bits = 24 },
  .{ .id = 0x2b, .name = "int32", .kind = .signed, .bits = 32 },
  .{ .id = 0x2c, .name = "int40", .kind = .signed, .bits = 40 },
  .{ .id = 0x2d, .name = "int48", .kind = .signed, .bits = 48 },
  .{ .id = 0x2e, .name = "int56", .kind = .signed, .bits = 56 },
  .{ .id = 0x2f, .name = "int64", .kind = .signed, .bits = 64 },
  .{ .id = 0x30, .name = "enum8", .kind = .unsigned, .bits = 8 },
  .{ .id = 0x31, .name = "enum16", .kind = .unsigned, .bits = 16 },
  .{ .id = 0x38, .name = "semi", .kind = .float },
  .{ .id = 0x39, .name = "single", .kind = .float },
  .{ .id = 0x3a, .name = "double", .kind = .float },
  .{ .id = 0x41, .name = "octet_string", .kind = .bytes },
  .{ .id = 0x42, .name = "char_string", .kind = .text },
  .{ .id = 0x43, .name = "long_octet_string", .kind = .bytes },
  .{ .id = 0x44, .name = "long_char_string", .kind = .text },
  .{ .id = 0x48, .name = "array", .kind = .bytes },
  .{ .id = 0x4c, .name = "struct", .kind = .bytes },
  .{ .id = 0x50, .name = "set", .kind = .bytes },
  .{ .id = 0x51, .name = "bag", .kind = .bytes },
  .{ .id = 0xe0, .name = "time_of_day", .kind = .unsigned, .bits = 32 },
  .{ .id = 0xe1, .name = "date", .kind = .unsigned, .bits = 32 },
  .{ .id = 0xe2, .name = "utc", .kind = .unsigned, .bits = 32 },
  .{ .id = 0xe8, .name = "cluster_id", .kind = .unsigned, .bits = 16 },
  .{ .id = 0xe9, .name = "attribute_id", .kind = .unsigned, .bits = 16 },
  .{ .id = 0xea, .name = "bacnet_oid", .kind = .unsigned, .bits = 32 },
  .{ .id = 0xf0, .name = "ieee_address", .kind = .ieee },
  .{ .id = 0xf1, .name = "key128", .kind = .bytes },
};

pub fn byId(id: u8) ?*const Type {
  for (&types) |*t| {
    if (t.id == id) return t;
  }
  return null;
}

pub fn byName(name: []const u8) ?*const Type {
  for (&types) |*t| {
    if (std.mem.eql(u8, t.name, name)) return t;
  }
  return null;
}

/// Writes the members "type" and "value" of a value into the current object.
pub fn write(j: *std.json.Stringify, gpa: std.mem.Allocator, v: c.struct_skep_value) !void {
  try j.objectField("type");
  const t = byId(v.type) orelse {
    // A type the ZCL does not define: libskep does not decode those, so its value is unknown.
    try j.write(v.type);
    return;
  };
  try j.write(t.name);
  if (t.kind == .none) return;
  try j.objectField("value");
  try writeValue(j, gpa, t, v);
}

/// Writes a value as its type says.
pub fn writeValue(
  j: *std.json.Stringify,
  gpa: std.mem.Allocator,
  t: *const Type,
  v: c.struct_skep_value,
) !void {
  switch (t.kind) {
    .none => try j.write(null),
    .boolean => try j.write(v.v.u != 0),
    .unsigned => if (t.bits > 48) try j.print("\"{d}\"", .{ v.v.u }) else try j.write(v.v.u),
    .signed => if (t.bits > 48) try j.print("\"{d}\"", .{ v.v.i }) else try j.write(v.v.i),
    .float => if (!std.math.isFinite(v.v.f))
      try j.write(null)
    else if (t.id == 0x3a)
      try j.write(v.v.f)
    else
      // At the precision of the type: a single 0.1 is not printed as 0.10000000149011612.
      try j.print("{d}", .{ @as(f32, @floatCast(v.v.f)) }),
    .text => {
      const text = try validUtf8(gpa, bytesOf(v));
      defer gpa.free(text);
      try j.write(text);
    },
    .bytes => try j.print("\"{x}\"", .{ bytesOf(v) }),
    .ieee => try j.print("\"{x:0>16}\"", .{ v.v.u }),
  }
}

pub fn bytesOf(v: c.struct_skep_value) []const u8 {
  const data = v.v.bytes.data orelse return &.{};
  return data[0..v.v.bytes.len];
}

/// A copy of `bytes` with what is not UTF-8 replaced by U+FFFD.
pub fn validUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
  var out: std.ArrayList(u8) = .empty;
  errdefer out.deinit(gpa);
  var i: usize = 0;
  while (i < bytes.len) {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
    if (len > 0 and i + len <= bytes.len and isCodepoint(bytes[i..][0..len])) {
      try out.appendSlice(gpa, bytes[i..][0..len]);
      i += len;
    } else {
      try out.appendSlice(gpa, "\u{fffd}");
      i += 1;
    }
  }
  return out.toOwnedSlice(gpa);
}

fn isCodepoint(sequence: []const u8) bool {
  _ = std.unicode.utf8Decode(sequence) catch return false;
  return true;
}

pub const ReadError = error{
  /// Not a value of its type, or of a type that does not exist.
  Invalid,
  /// A member other than "type" and "value".
  UnknownMember,
  OutOfMemory,
};

/// Reads a value given as {"type": ..., "value": ...}. Bytes are allocated with `arena`.
pub fn read(arena: std.mem.Allocator, value: std.json.Value) ReadError!c.struct_skep_value {
  const object = switch (value) {
    .object => |o| o,
    else => return error.Invalid,
  };
  for (object.keys()) |key| {
    if (!std.mem.eql(u8, key, "type") and !std.mem.eql(u8, key, "value")) {
      return error.UnknownMember;
    }
  }
  const t = typeOf(object.get("type") orelse return error.Invalid) orelse return error.Invalid;
  if (t.kind == .none) return .{ .type = t.id, .v = .{ .u = 0 } };
  return valueOf(arena, t, object.get("value") orelse return error.Invalid);
}

/// The type named, or numbered, by a JSON value.
pub fn typeOf(value: std.json.Value) ?*const Type {
  return switch (value) {
    .string => |name| byName(name),
    .integer => |id| byId(std.math.cast(u8, id) orelse return null),
    else => null,
  };
}

/// Reads a value of type `t`, given as the type says.
pub fn valueOf(
  arena: std.mem.Allocator,
  t: *const Type,
  value: std.json.Value,
) ReadError!c.struct_skep_value {
  var v: c.struct_skep_value = .{ .type = t.id, .v = .{ .u = 0 } };
  switch (t.kind) {
    .none => {},
    .boolean => v.v.u = switch (value) {
      .bool => |b| @intFromBool(b),
      else => return error.Invalid,
    },
    .unsigned => v.v.u = unsignedOf(u64, value) orelse return error.Invalid,
    .signed => v.v.i = signedOf(value) orelse return error.Invalid,
    .float => v.v.f = switch (value) {
      .integer => |i| @floatFromInt(i),
      .float => |f| f,
      else => return error.Invalid,
    },
    .text => {
      const text = switch (value) {
        .string => |s| s,
        else => return error.Invalid,
      };
      v.v.bytes = .{ .data = text.ptr, .len = text.len };
    },
    .bytes => {
      const digits = switch (value) {
        .string => |s| s,
        else => return error.Invalid,
      };
      if (digits.len % 2 != 0) return error.Invalid;
      const bytes = try arena.alloc(u8, digits.len / 2);
      _ = std.fmt.hexToBytes(bytes, digits) catch return error.Invalid;
      v.v.bytes = .{ .data = bytes.ptr, .len = bytes.len };
    },
    .ieee => v.v.u = ieeeOf(value) orelse return error.Invalid,
  }
  return v;
}

/// An unsigned number: a JSON integer, or a string of decimal digits, or of hexadecimal digits
/// after "0x".
pub fn unsignedOf(comptime T: type, value: std.json.Value) ?T {
  return switch (value) {
    .integer => |i| std.math.cast(T, i),
    .number_string => |s| std.fmt.parseInt(T, s, 10) catch null,
    .string => |s| if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
      std.fmt.parseInt(T, s[2..], 16) catch null
    else
      std.fmt.parseInt(T, s, 10) catch null,
    else => null,
  };
}

fn signedOf(value: std.json.Value) ?i64 {
  return switch (value) {
    .integer => |i| i,
    .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
    else => null,
  };
}

/// An IEEE address: 16 hexadecimal digits, with or without "0x".
pub fn ieeeOf(value: std.json.Value) ?u64 {
  const text = switch (value) {
    .string => |s| s,
    else => return null,
  };
  return parseIeee(text);
}

pub fn parseIeee(text: []const u8) ?u64 {
  const digits = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
    text[2..]
  else
    text;
  if (digits.len != 16) return null;
  for (digits) |d| {
    if (!std.ascii.isHex(d)) return null;
  }
  return std.fmt.parseInt(u64, digits, 16) catch null;
}

const testing = std.testing;

fn written(v: c.struct_skep_value) ![]u8 {
  var out: std.Io.Writer.Allocating = .init(testing.allocator);
  defer out.deinit();
  var j: std.json.Stringify = .{ .writer = &out.writer };
  try j.beginObject();
  try write(&j, testing.allocator, v);
  try j.endObject();
  return testing.allocator.dupe(u8, out.written());
}

test "values are written as their types say" {
  const cases = [_]struct { c.struct_skep_value, []const u8 }{
    .{.{ .type = 0x29, .v = .{ .i = 2154 } }, "{\"type\":\"int16\",\"value\":2154}" },
    .{.{ .type = 0x27, .v = .{ .u = 5 } }, "{\"type\":\"uint64\",\"value\":\"5\"}" },
    .{.{ .type = 0x2f, .v = .{ .i = -5 } }, "{\"type\":\"int64\",\"value\":\"-5\"}" },
    .{.{ .type = 0x10, .v = .{ .u = 1 } }, "{\"type\":\"bool\",\"value\":true}" },
    .{.{ .type = 0x39, .v = .{ .f = 0.1 } }, "{\"type\":\"single\",\"value\":0.1}" },
    .{.{ .type = 0x39, .v = .{ .f = std.math.nan(f64) } }, "{\"type\":\"single\",\"value\":null}" },
    .{
      .{ .type = 0xf0, .v = .{ .u = 0xf44250000d350000 } },
      "{\"type\":\"ieee_address\",\"value\":\"f44250000d350000\"}",
    },
    .{.{ .type = 0x00, .v = .{ .u = 0 } }, "{\"type\":\"nodata\"}" },
    .{
      .{ .type = 0x41, .v = .{ .bytes = .{ .data = "\x01\xab", .len = 2 } } },
      "{\"type\":\"octet_string\",\"value\":\"01ab\"}",
    },
    .{
      .{ .type = 0x42, .v = .{ .bytes = .{ .data = "ab\xffc", .len = 4 } } },
      "{\"type\":\"char_string\",\"value\":\"ab\u{fffd}c\"}",
    },
  };
  for (cases) |case| {
    const out = try written(case[0]);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(case[1], out);
  }
}

test "values are read as their types say" {
  var arena: std.heap.ArenaAllocator = .init(testing.allocator);
  defer arena.deinit();
  const a = arena.allocator();
  const parse = struct {
    fn f(al: std.mem.Allocator, text: []const u8) !std.json.Value {
      return std.json.parseFromSliceLeaky(std.json.Value, al, text, .{});
    }
  }.f;
  try testing.expectEqual(
    2154,
    (try read(a, try parse(a, "{\"type\": \"int16\", \"value\": 2154}"))).v.i,
  );
  try testing.expectEqual(
    5,
    (try read(a, try parse(a, "{\"type\": \"uint64\", \"value\": \"5\"}"))).v.u,
  );
  try testing.expectEqual(
    5,
    (try read(a, try parse(a, "{\"type\": \"uint64\", \"value\": 5}"))).v.u,
  );
  try testing.expectEqual(
    0x21,
    (try read(a, try parse(a, "{\"type\": 33, \"value\": \"0x10\"}"))).type,
  );
  const octets = try read(a, try parse(a, "{\"type\": \"octet_string\", \"value\": \"01ab\"}"));
  try testing.expectEqualSlices(u8, &.{ 0x01, 0xab }, octets.v.bytes.data[0..octets.v.bytes.len]);
  try testing.expectEqual(
    0xf44250000d350000,
    (try read(
      a,
      try parse(a, "{\"type\": \"ieee_address\", \"value\": \"0xF44250000D350000\"}"),
    )).v.u,
  );
  try testing.expectError(
    error.Invalid,
    read(a, try parse(a, "{\"type\": \"bool\", \"value\": 1}")),
  );
  try testing.expectError(
    error.Invalid,
    read(a, try parse(a, "{\"type\": \"uint65\", \"value\": 1}")),
  );
  try testing.expectError(
    error.Invalid,
    read(a, try parse(a, "{\"type\": \"octet_string\", \"value\": \"abc\"}")),
  );
  try testing.expectError(
    error.UnknownMember,
    read(a, try parse(a, "{\"type\": \"uint8\", \"value\": 1, \"unit\": \"%\"}")),
  );
}
