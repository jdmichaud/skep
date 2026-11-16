//! The parameters of EZSP commands, responses and callbacks, which `frame.zig` carries. Layouts
//! that differ between EZSP versions are kept apart here.

const std = @import("std");

/// Values read with `get_value`.
pub const ValueId = enum(u8) { version_info = 0x11, _ };

/// The stack type of EmberZNet's mesh stack, the only one supported.
pub const stack_type_mesh: u8 = 2;

/// Reads parameters in order, little-endian.
pub const Reader = struct {
  bytes: []const u8,

  pub fn int(r: *Reader, comptime T: type) error{ TooShort }!T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    if (r.bytes.len < size) return error.TooShort;
    defer r.bytes = r.bytes[size..];
    return std.mem.readInt(T, r.bytes[0..size], .little);
  }

  pub fn slice(r: *Reader, len: usize) error{ TooShort }![]const u8 {
    if (r.bytes.len < len) return error.TooShort;
    defer r.bytes = r.bytes[len..];
    return r.bytes[0..len];
  }

  /// A status, whose size depends on the EZSP version: an EmberStatus byte before 14, an
  /// sl_status_t of 4 bytes since.
  pub fn status(r: *Reader, version: u8) error{ TooShort }!u32 {
    return if (version < 14) try r.int(u8) else try r.int(u32);
  }
};

/// The parameters of the response to `version`.
pub const Version = struct {
  protocol_version: u8,
  stack_type: u8,
  /// One version digit per nibble: 0x7410 is 7.4.1.0.
  stack_version: u16,

  pub fn parse(parameters: []const u8) error{ TooShort }!Version {
    var r: Reader = .{ .bytes = parameters };
    return .{
      .protocol_version = try r.int(u8),
      .stack_type = try r.int(u8),
      .stack_version = try r.int(u16),
    };
  }
};

/// The firmware version, read with `get_value` and `version_info`.
pub const VersionInfo = struct {
  build: u16,
  major: u8,
  minor: u8,
  patch: u8,
  special: u8,
  /// 0xaa for a general availability release, anything else for a pre-release.
  type: u8,

  pub const len = 7;

  pub fn parse(value: []const u8) error{ TooShort }!VersionInfo {
    var r: Reader = .{ .bytes = value };
    return .{
      .build = try r.int(u16),
      .major = try r.int(u8),
      .minor = try r.int(u8),
      .patch = try r.int(u8),
      .special = try r.int(u8),
      .type = try r.int(u8),
    };
  }
};

/// The parameters of the response to `get_value`: a status, then the value.
pub fn parseGetValue(parameters: []const u8, version: u8) error{ TooShort }!struct {
  status: u32,
  value: []const u8,
} {
  var r: Reader = .{ .bytes = parameters };
  const status = try r.status(version);
  const len = try r.int(u8);
  return .{ .status = status, .value = try r.slice(len) };
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}

test "parse the version response" {
  // Recorded from a real NCP by zigbee-herdsman's tests: EZSP 13, EmberZNet 7.4.1.
  try testing.expectEqual(
    Version{ .protocol_version = 13, .stack_type = stack_type_mesh, .stack_version = 0x7410 },
    try Version.parse(&hex("0d021074")),
  );
}

test "the size of a status depends on the EZSP version" {
  const old = try parseGetValue(&hex("00070102070401aaaa"), 13);
  try testing.expectEqual(0, old.status);
  try testing.expectEqual(
    VersionInfo{
      .build = 0x0201,
      .major = 7,
      .minor = 4,
      .patch = 1,
      .special = 0xaa,
      .type = 0xaa,
    },
    try VersionInfo.parse(old.value),
  );
  const new = try parseGetValue(&hex("0000000007010207040100aa"), 14);
  try testing.expectEqual(0, new.status);
  try testing.expectEqual(VersionInfo.len, new.value.len);
  try testing.expectError(error.TooShort, parseGetValue(&hex("00080102"), 13));
}

test "fuzz: parsing survives any parameters" {
  try testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *testing.Smith) !void {
  var bytes: [220]u8 = undefined;
  const len = smith.slice(&bytes);
  _ = Version.parse(bytes[0..len]) catch {};
  const value = parseGetValue(bytes[0..len], smith.value(u8)) catch return;
  _ = VersionInfo.parse(value.value) catch {};
}
