//! The parameters of EZSP commands, responses and callbacks, which `frame.zig` carries. Layouts
//! that differ between EZSP versions are kept apart here.

const std = @import("std");

/// Values read with `get_value`.
pub const ValueId = enum(u8) { version_info = 0x11, _ };

/// The stack type of EmberZNet's mesh stack, the only one supported.
pub const stack_type_mesh: u8 = 2;

/// A status from the NCP, as sent. Before EZSP 14 it is an EmberStatus or EzspStatus byte, since
/// then an sl_status_t, with other codes: compare with `is`.
pub const Status = struct {
  value: u32,
  /// An sl_status_t (EZSP 14 and later).
  sl: bool,

  pub const Name = enum { ok, not_joined, network_up, network_down };

  pub fn is(s: Status, name: Name) bool {
    const codes: [2]u32 = switch (name) {
      .ok => .{ 0x00, 0x0000 },
      .not_joined => .{ 0x93, 0x0017 },
      .network_up => .{ 0x90, 0x0015 },
      .network_down => .{ 0x91, 0x0016 },
    };
    return s.value == codes[@intFromBool(s.sl)];
  }
};

/// Configuration values: set after the startup and before `network_init`, as they size the NCP's
/// tables. A value the firmware refuses keeps its default.
pub const ConfigId = enum(u8) {
  stack_profile = 0x0c,
  security_level = 0x0d,
  max_hops = 0x10,
  max_end_device_children = 0x11,
  indirect_transmission_timeout = 0x12,
  trust_center_address_cache_size = 0x19,
  _,
};

pub const NodeType = enum(u8) {
  unknown = 0,
  coordinator = 1,
  router = 2,
  end_device = 3,
  sleepy_end_device = 4,
  _,
};

/// Writes parameters in order, little-endian.
pub const Writer = struct {
  buffer: []u8,
  len: usize = 0,

  pub fn int(w: *Writer, comptime T: type, value: T) void {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    std.mem.writeInt(T, w.buffer[w.len..][0..size], value, .little);
    w.len += size;
  }

  pub fn written(w: *const Writer) []const u8 {
    return w.buffer[0..w.len];
  }
};

/// Parameters of `set_configuration_value`.
pub fn setConfigurationValue(out: *[3]u8, id: ConfigId, value: u16) []const u8 {
  var w: Writer = .{ .buffer = out };
  w.int(u8, @backingInt(id));
  w.int(u16, value);
  return w.written();
}

/// An application endpoint of the coordinator, described to the devices that ask.
pub const Endpoint = struct {
  endpoint: u8,
  profile_id: u16,
  device_id: u16,
  device_version: u8,
  input_clusters: []const u16,
  output_clusters: []const u16,

  /// Parameters of `add_endpoint`. `out` needs 8 bytes and 2 per cluster.
  pub fn encode(e: Endpoint, out: []u8) []const u8 {
    var w: Writer = .{ .buffer = out };
    w.int(u8, e.endpoint);
    w.int(u16, e.profile_id);
    w.int(u16, e.device_id);
    w.int(u8, e.device_version);
    w.int(u8, @intCast(e.input_clusters.len));
    w.int(u8, @intCast(e.output_clusters.len));
    for (e.input_clusters) |cluster| {
      w.int(u16, cluster);
    }
    for (e.output_clusters) |cluster| {
      w.int(u16, cluster);
    }
    return w.written();
  }
};

/// Parameters of `network_init`: no options, both concerning end devices.
pub fn networkInit(out: *[2]u8) []const u8 {
  out.* = .{ 0, 0 };
  return out;
}

/// The parameters of a response, or of `stack_status_handler`, made of a status alone.
pub fn parseStatus(parameters: []const u8, version: u8) error{ TooShort }!Status {
  var r: Reader = .{ .bytes = parameters };
  return r.statusOf(version);
}

/// The parameters of a network, as `get_network_parameters` returns them.
pub const NetworkParameters = struct {
  extended_pan_id: u64,
  pan_id: u16,
  tx_power: i8,
  channel: u8,
  join_method: u8,
  manager_id: u16,
  update_id: u8,
  channels: u32,

  pub fn read(r: *Reader) error{ TooShort }!NetworkParameters {
    return .{
      .extended_pan_id = try r.int(u64),
      .pan_id = try r.int(u16),
      .tx_power = @bitCast(try r.int(u8)),
      .channel = try r.int(u8),
      .join_method = try r.int(u8),
      .manager_id = try r.int(u16),
      .update_id = try r.int(u8),
      .channels = try r.int(u32),
    };
  }
};

/// The parameters of the response to `get_network_parameters`.
pub fn parseGetNetworkParameters(parameters: []const u8, version: u8) error{ TooShort }!struct {
  status: Status,
  node_type: NodeType,
  network: NetworkParameters,
} {
  var r: Reader = .{ .bytes = parameters };
  return .{
    .status = try r.statusOf(version),
    .node_type = @fromBackingInt(@intCast(try r.int(u8))),
    .network = try .read(&r),
  };
}

/// The parameters of the response to `get_eui64`: the coordinator's IEEE address.
pub fn parseEui64(parameters: []const u8) error{ TooShort }!u64 {
  var r: Reader = .{ .bytes = parameters };
  return r.int(u64);
}

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

  pub fn statusOf(r: *Reader, version: u8) error{ TooShort }!Status {
    return .{ .value = try r.status(version), .sl = version >= 14 };
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

test "statuses are compared by name, whichever the EZSP version" {
  try testing.expect((try parseStatus(&hex("93"), 8)).is(.not_joined));
  try testing.expect((try parseStatus(&hex("17000000"), 14)).is(.not_joined));
  try testing.expect((try parseStatus(&hex("90"), 13)).is(.network_up));
  try testing.expect(!(try parseStatus(&hex("90000000"), 14)).is(.network_up));
  try testing.expect((try parseStatus(&hex("00"), 8)).is(.ok));
  try testing.expectError(error.TooShort, parseStatus(&hex("000000"), 14));
}

test "encode the commands that bring a network up" {
  var config: [3]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("0c0200"),
    setConfigurationValue(&config, .stack_profile, 2),
  );
  try testing.expectEqualSlices(
    u8,
    &hex("12001e"),
    setConfigurationValue(&config, .indirect_transmission_timeout, 7680),
  );
  var endpoint: [12]u8 = undefined;
  const e: Endpoint = .{
    .endpoint = 1,
    .profile_id = 0x0104,
    .device_id = 0x0005,
    .device_version = 1,
    .input_clusters = &.{ 0x0000 },
    .output_clusters = &.{ 0x0006 },
  };
  try testing.expectEqualSlices(u8, &hex("010401050001010100000600"), e.encode(&endpoint));
}

test "parse the network parameters" {
  const parsed = try parseGetNetworkParameters(
    &hex(
      "00" ++
        "01" ++
        "efcdab8967452301" ++
        "3412" ++
        "05" ++
        "0f" ++
        "00" ++
        "0000" ++
        "00" ++
        "00f8ff07",
    ),
    8,
  );
  try testing.expect(parsed.status.is(.ok));
  try testing.expectEqual(NodeType.coordinator, parsed.node_type);
  try testing.expectEqual(
    NetworkParameters{
      .extended_pan_id = 0x0123456789abcdef,
      .pan_id = 0x1234,
      .tx_power = 5,
      .channel = 15,
      .join_method = 0,
      .manager_id = 0,
      .update_id = 0,
      .channels = 0x07fff800,
    },
    parsed.network,
  );
  try testing.expectEqual(0x0123456789abcdef, try parseEui64(&hex("efcdab8967452301")));
}

test "fuzz: parsing survives any parameters" {
  try testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *testing.Smith) !void {
  var bytes: [220]u8 = undefined;
  const len = smith.slice(&bytes);
  _ = Version.parse(bytes[0..len]) catch {};
  const version = smith.value(u8);
  _ = parseStatus(bytes[0..len], version) catch {};
  _ = parseGetNetworkParameters(bytes[0..len], version) catch {};
  _ = parseEui64(bytes[0..len]) catch {};
  const value = parseGetValue(bytes[0..len], version) catch return;
  _ = VersionInfo.parse(value.value) catch {};
}
