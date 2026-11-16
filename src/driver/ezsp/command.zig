//! The parameters of EZSP commands, responses and callbacks, which `frame.zig` carries. Layouts
//! that differ between EZSP versions are kept apart here.

const std = @import("std");

/// Values read with `get_value` and written with `set_value`.
pub const ValueId = enum(u8) {
  stack_token_writing = 0x07,
  extended_security_bitmask = 0x0a,
  version_info = 0x11,
  /// The outgoing frame counter of the network key, 4 bytes.
  nwk_frame_counter = 0x23,
  /// The outgoing frame counter of the trust center link key, 4 bytes.
  aps_frame_counter = 0x24,
  _,
};

/// The stack type of EmberZNet's mesh stack, the only one supported.
pub const stack_type_mesh: u8 = 2;

/// A status from the NCP, as sent. Before EZSP 14 it is an EmberStatus or EzspStatus byte, since
/// then an sl_status_t, with other codes: compare with `is`.
pub const Status = struct {
  value: u32,
  /// An sl_status_t (EZSP 14 and later).
  sl: bool,

  pub const Name = enum {
    ok,
    not_joined,
    network_up,
    network_down,
    network_opened,
    network_closed,
  };

  pub fn is(s: Status, name: Name) bool {
    const codes: [2]u32 = switch (name) {
      .ok => .{ 0x00, 0x0000 },
      .not_joined => .{ 0x93, 0x0017 },
      .network_up => .{ 0x90, 0x0015 },
      .network_down => .{ 0x91, 0x0016 },
      .network_opened => .{ 0x9c, 0x0c18 },
      .network_closed => .{ 0x9d, 0x0c19 },
    };
    return s.value == codes[@intFromBool(s.sl)];
  }
};

/// Policies: how the NCP decides on its own, set with `set_policy`.
pub const PolicyId = enum(u8) {
  trust_center_policy = 0x00,
  tc_key_request_policy = 0x05,
  app_key_request_policy = 0x06,
  _,
};

/// Decisions of `trust_center_policy`: bits.
pub const TrustCenterDecision = struct {
  pub const allow_joins: u8 = 0x01;
  pub const allow_unsecured_rejoins: u8 = 0x02;
};

/// Decisions of the key request policies. EZSP 8 names 0x51 `ALLOW_TC_KEY_REQUESTS`.
pub const KeyRequestDecision = struct {
  pub const allow_tc_key_requests_and_send_current_key: u8 = 0x51;
  pub const deny_app_key_requests: u8 = 0x60;
};

/// Parameters of `set_policy`.
pub fn setPolicy(out: *[2]u8, id: PolicyId, decision: u8) []const u8 {
  out.* = .{ @backingInt(id), decision };
  return out;
}

/// Parameters of `permit_joining`: how long the network accepts new devices, in seconds; 0
/// closes it, 255 would open it for good.
pub fn permitJoining(out: *[1]u8, seconds: u8) []const u8 {
  out[0] = seconds;
  return out;
}

/// A key and what goes with it: how keys are read before EZSP 13 (`get_key`).
pub const KeyStruct = struct {
  key: [16]u8,
  outgoing_frame_counter: u32,
  sequence_number: u8,

  pub const Type = enum(u8) { trust_center_link_key = 0x01, current_network_key = 0x03 };

  /// The answer to `get_key`: a status, then the key and what goes with it.
  pub fn parse(parameters: []const u8, version: u8) error{ TooShort }!struct {
    status: Status,
    key: KeyStruct,
  } {
    var r: Reader = .{ .bytes = parameters };
    const status = try r.statusOf(version);
    _ = try r.int(u16); // bitmask
    _ = try r.int(u8); // type
    var key: KeyStruct = .{
      .key = undefined,
      .outgoing_frame_counter = undefined,
      .sequence_number = undefined,
    };
    @memcpy(&key.key, try r.slice(16));
    key.outgoing_frame_counter = try r.int(u32);
    _ = try r.int(u32); // incoming frame counter
    key.sequence_number = try r.int(u8);
    _ = try r.slice(8); // partner
    return .{ .status = status, .key = key };
  }
};

/// Which key `export_key` exports, from EZSP 13 (Silicon Labs' security manager).
pub const SecManKeyType = enum(u8) { network = 1, trust_center_link = 2 };

/// Parameters of `export_key`: a security manager context naming the key, the first of its kind.
pub fn exportKey(out: *[18]u8, key_type: SecManKeyType) []const u8 {
  out.* = @splat(0);
  out[0] = @backingInt(key_type);
  return out;
}

/// The answer to `export_key`: the key then the status with EZSP 13, the status, the key and the
/// context since EZSP 14.
pub fn parseExportKey(parameters: []const u8, version: u8) error{ TooShort }!struct {
  status: Status,
  key: [16]u8,
} {
  var r: Reader = .{ .bytes = parameters };
  var key: [16]u8 = undefined;
  if (version < 14) {
    @memcpy(&key, try r.slice(16));
    return .{ .status = .{ .value = try r.int(u32), .sl = true }, .key = key };
  }
  const status = try r.int(u32);
  @memcpy(&key, try r.slice(16));
  return .{ .status = .{ .value = status, .sl = true }, .key = key };
}

/// The answer to `get_network_key_info`, from EZSP 13.
pub const NetworkKeyInfo = struct {
  status: Status,
  key_set: bool,
  sequence_number: u8,
  frame_counter: u32,

  pub fn parse(parameters: []const u8) error{ TooShort }!NetworkKeyInfo {
    var r: Reader = .{ .bytes = parameters };
    const status = try r.int(u32);
    const key_set = try r.int(u8) != 0;
    _ = try r.int(u8); // alternate key set
    const sequence_number = try r.int(u8);
    _ = try r.int(u8); // alternate key sequence number
    return .{
      .status = .{ .value = status, .sl = true },
      .key_set = key_set,
      .sequence_number = sequence_number,
      .frame_counter = try r.int(u32),
    };
  }
};

/// The link key Zigbee 3.0 devices join with when no install code says otherwise.
pub const well_known_link_key = "ZigBeeAlliance09".*;

/// Parameters of `add_transient_link_key`, before EZSP 13: a link key for `eui64` to join with,
/// for a while. All ones means any device.
pub fn addTransientLinkKey(out: *[24]u8, eui64: u64, key: [16]u8) []const u8 {
  std.mem.writeInt(u64, out[0..8], eui64, .little);
  @memcpy(out[8..24], &key);
  return out;
}

/// Parameters of `import_transient_key`, which replaces `add_transient_link_key` from EZSP 13. All
/// zeros means any device. EZSP 13 takes a flags byte, which later versions dropped.
pub fn importTransientKey(out: *[25]u8, eui64: u64, key: [16]u8, version: u8) []const u8 {
  std.mem.writeInt(u64, out[0..8], eui64, .little);
  @memcpy(out[8..24], &key);
  out[24] = 0;
  return if (version < 14) out else out[0..24];
}

/// The answer to `import_transient_key`: an sl_status_t, even with EZSP 13.
pub fn parseImportTransientKey(parameters: []const u8) error{ TooShort }!Status {
  var r: Reader = .{ .bytes = parameters };
  return .{ .value = try r.int(u32), .sl = true };
}

/// What `trust_center_join_handler` reports about a device.
pub const DeviceUpdate = enum(u8) {
  secured_rejoin = 0,
  unsecured_join = 1,
  left = 2,
  unsecured_rejoin = 3,
  _,
};

/// The parameters of `trust_center_join_handler`.
pub const TrustCenterJoin = struct {
  node_id: u16,
  eui64: u64,
  update: DeviceUpdate,
  decision: u8,
  parent_id: u16,

  /// The trust center refused the device.
  pub const deny_join: u8 = 2;

  pub fn parse(parameters: []const u8) error{ TooShort }!TrustCenterJoin {
    var r: Reader = .{ .bytes = parameters };
    return .{
      .node_id = try r.int(u16),
      .eui64 = try r.int(u64),
      .update = @fromBackingInt(@intCast(try r.int(u8))),
      .decision = try r.int(u8),
      .parent_id = try r.int(u16),
    };
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

/// Parameters of `set_value`. `out` needs 2 bytes more than the value.
pub fn setValue(out: []u8, id: ValueId, value: []const u8) []const u8 {
  out[0] = @backingInt(id);
  out[1] = @intCast(value.len);
  @memcpy(out[2..][0..value.len], value);
  return out[0..2 + value.len];
}

/// How the trust center secures a network it forms, in `set_initial_security_state`.
pub const InitialSecurityState = struct {
  bitmask: u16,
  /// The trust center's link key.
  preconfigured_key: [16]u8,
  network_key: [16]u8,
  network_key_sequence_number: u8,
  /// The trust center's IEEE address, for devices that join; 0 when it forms the network itself.
  trust_center_eui64: u64 = 0,

  // Bits of the bitmask.
  pub const trust_center_global_link_key: u16 = 0x0004;
  pub const trust_center_uses_hashed_link_key: u16 = 0x0084;
  pub const have_preconfigured_key: u16 = 0x0100;
  pub const have_network_key: u16 = 0x0200;
  pub const require_encrypted_key: u16 = 0x0800;
  pub const no_frame_counter_reset: u16 = 0x1000;

  pub const len = 2 + 16 + 16 + 1 + 8;

  pub fn encode(s: InitialSecurityState, out: *[len]u8) []const u8 {
    var w: Writer = .{ .buffer = out };
    w.int(u16, s.bitmask);
    @memcpy(out[2..18], &s.preconfigured_key);
    @memcpy(out[18..34], &s.network_key);
    w.len = 34;
    w.int(u8, s.network_key_sequence_number);
    w.int(u64, s.trust_center_eui64);
    return w.written();
  }
};

/// Bits of the extended security bitmask, set with `set_value`.
pub const ExtendedSecurity = struct {
  /// Devices that join use the global link key.
  pub const joiner_global_link_key: u16 = 0x0010;
  /// The coordinator does not leave the network when another device asks it to.
  pub const nwk_leave_request_not_allowed: u16 = 0x0100;
};

/// Parameters of `form_network`. The network fields not given take the usual values: joining by
/// MAC association, the coordinator managing the network, every channel allowed.
pub fn formNetwork(out: *[20]u8, network: NetworkParameters) []const u8 {
  var w: Writer = .{ .buffer = out };
  w.int(u64, network.extended_pan_id);
  w.int(u16, network.pan_id);
  w.int(u8, @bitCast(network.tx_power));
  w.int(u8, network.channel);
  w.int(u8, network.join_method);
  w.int(u16, network.manager_id);
  w.int(u8, network.update_id);
  w.int(u32, network.channels);
  return w.written();
}

/// Parameters of `leave_network`: none before EZSP 14, an options byte since.
pub fn leaveNetwork(out: *[1]u8, version: u8) []const u8 {
  out[0] = 0;
  return if (version >= 14) out else out[0..0];
}

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

test "encode the commands that form a network" {
  var state: [InitialSecurityState.len]u8 = undefined;
  const s: InitialSecurityState = .{
    .bitmask = InitialSecurityState.have_network_key,
    .preconfigured_key = @splat(0x11),
    .network_key = @splat(0x22),
    .network_key_sequence_number = 0,
  };
  try testing.expectEqualSlices(
    u8,
    &hex(
      "0002" ++
        "11111111111111111111111111111111" ++
        "22222222222222222222222222222222" ++
        "00" ++
        "0000000000000000",
    ),
    s.encode(&state),
  );
  var network: [20]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("efcdab8967452301" ++ "3412" ++ "05" ++ "0f" ++ "00" ++ "0000" ++ "00" ++ "00f8ff07"),
    formNetwork(&network, .{
      .extended_pan_id = 0x0123456789abcdef,
      .pan_id = 0x1234,
      .tx_power = 5,
      .channel = 15,
      .join_method = 0,
      .manager_id = 0,
      .update_id = 0,
      .channels = 0x07fff800,
    }),
  );
  var value: [4]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("0a021001"),
    setValue(&value, .extended_security_bitmask, &.{ 0x10, 0x01 }),
  );
  var leave: [1]u8 = undefined;
  try testing.expectEqual(0, leaveNetwork(&leave, 8).len);
  try testing.expectEqualSlices(u8, &hex("00"), leaveNetwork(&leave, 14));
}

test "encode and parse what joining needs" {
  var policy: [2]u8 = undefined;
  try testing.expectEqualSlices(u8, &hex("0003"), setPolicy(&policy, .trust_center_policy, 3));
  var duration: [1]u8 = undefined;
  try testing.expectEqualSlices(u8, &hex("3c"), permitJoining(&duration, 60));
  const join = try TrustCenterJoin.parse(
    &hex("3412" ++ "8877665544332211" ++ "01" ++ "00" ++ "0000"),
  );
  try testing.expectEqual(0x1234, join.node_id);
  try testing.expectEqual(0x1122334455667788, join.eui64);
  try testing.expectEqual(DeviceUpdate.unsecured_join, join.update);
  try testing.expect((try parseStatus(&hex("9c"), 8)).is(.network_opened));
  try testing.expect((try parseStatus(&hex("190c0000"), 14)).is(.network_closed));
}

test "a transient link key, before and after EZSP 13 and 14" {
  var add: [24]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("ffffffffffffffff" ++ "5a6967426565416c6c69616e63653039"),
    addTransientLinkKey(&add, 0xffffffffffffffff, well_known_link_key),
  );
  var import: [25]u8 = undefined;
  try testing.expectEqual(25, importTransientKey(&import, 0, well_known_link_key, 13).len);
  try testing.expectEqual(24, importTransientKey(&import, 0, well_known_link_key, 14).len);
  try testing.expect((try parseImportTransientKey(&hex("00000000"))).is(.ok));
}

test "keys, before and since EZSP 13" {
  // get_key: status, bitmask, type, key, outgoing and incoming counters, sequence, partner.
  const old = try KeyStruct.parse(
    &hex(
      "00" ++
        "0000" ++
        "03" ++
        "00112233445566778899aabbccddeeff" ++
        "39300000" ++
        "00000000" ++
        "02" ++
        "0000000000000000",
    ),
    8,
  );
  try testing.expect(old.status.is(.ok));
  try testing.expectEqual(0x00, old.key.key[0]);
  try testing.expectEqual(0xff, old.key.key[15]);
  try testing.expectEqual(12345, old.key.outgoing_frame_counter);
  try testing.expectEqual(2, old.key.sequence_number);

  var context: [18]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("02" ++ "0000000000000000000000000000000000"),
    exportKey(&context, .trust_center_link),
  );
  const v13 = try parseExportKey(&hex("00112233445566778899aabbccddeeff" ++ "00000000"), 13);
  try testing.expect(v13.status.is(.ok));
  try testing.expectEqual(0xff, v13.key[15]);
  const v14 = try parseExportKey(
    &hex(
      "00000000" ++ "00112233445566778899aabbccddeeff" ++ "020000000000000000000000000000000000",
    ),
    14,
  );
  try testing.expectEqual(0xff, v14.key[15]);

  const info = try NetworkKeyInfo.parse(
    &hex("00000000" ++ "01" ++ "00" ++ "03" ++ "00" ++ "39300000"),
  );
  try testing.expect(info.key_set);
  try testing.expectEqual(3, info.sequence_number);
  try testing.expectEqual(12345, info.frame_counter);
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
  _ = TrustCenterJoin.parse(bytes[0..len]) catch {};
  _ = KeyStruct.parse(bytes[0..len], version) catch {};
  _ = parseExportKey(bytes[0..len], version) catch {};
  _ = NetworkKeyInfo.parse(bytes[0..len]) catch {};
  const value = parseGetValue(bytes[0..len], version) catch return;
  _ = VersionInfo.parse(value.value) catch {};
}
