//! The Zigbee Device Object's requests and responses: what devices tell about themselves, and
//! how they are bound, told to leave, or to let others join (Zigbee specification, 2.4).
//!
//! ZDO frames go to endpoint 0 with profile 0. Their first byte is a transaction sequence number;
//! a response's cluster is its request's with bit 15 set, and its second byte is a status.
//! Parsing never trusts its input.

const std = @import("std");

pub const profile: u16 = 0x0000;
pub const endpoint: u8 = 0;

pub const Cluster = struct {
  pub const node_descriptor_request: u16 = 0x0002;
  pub const simple_descriptor_request: u16 = 0x0004;
  pub const active_endpoints_request: u16 = 0x0005;
  pub const device_announce: u16 = 0x0013;
  pub const bind_request: u16 = 0x0021;
  pub const unbind_request: u16 = 0x0022;
  pub const leave_request: u16 = 0x0034;
  pub const permit_joining_request: u16 = 0x0036;
  /// Added to a request's cluster for its response.
  pub const response: u16 = 0x8000;
};

pub const Status = struct {
  pub const success: u8 = 0x00;
  pub const not_supported: u8 = 0x84;
};

pub const Error = error{ TooShort };

/// The start of every response: its sequence number and status.
pub fn parseResponse(payload: []const u8) Error!struct { sequence: u8, status: u8 } {
  if (payload.len < 2) return error.TooShort;
  return .{ .sequence = payload[0], .status = payload[1] };
}

pub const LogicalType = enum(u3) { coordinator = 0, router = 1, end_device = 2, _ };

/// What a node descriptor tells libskep.
pub const NodeDescriptor = struct {
  logical_type: LogicalType,
  manufacturer_code: u16,
  /// Its receiver is on when idle: not a sleepy end device.
  rx_on_when_idle: bool,
  mains_powered: bool,

  /// From a successful Node_Desc_rsp: sequence, status, address, then the descriptor.
  pub fn parse(payload: []const u8) Error!NodeDescriptor {
    if (payload.len < 4 + 13) return error.TooShort;
    const d = payload[4..];
    return .{
      .logical_type = @fromBackingInt(@truncate(d[0])),
      .manufacturer_code = std.mem.readInt(u16, d[3..5], .little),
      .rx_on_when_idle = d[2] & 0x08 != 0,
      .mains_powered = d[2] & 0x04 != 0,
    };
  }
};

/// The endpoints of a successful Active_EP_rsp.
pub fn parseActiveEndpoints(payload: []const u8) Error![]const u8 {
  if (payload.len < 5) return error.TooShort;
  const count = payload[4];
  if (payload.len < 5 + @as(usize, count)) return error.TooShort;
  return payload[5..][0..count];
}

/// A simple descriptor: what an endpoint does.
pub const SimpleDescriptor = struct {
  endpoint: u8,
  profile: u16,
  device: u16,
  /// Cluster ids, two bytes each, little-endian.
  input_clusters: []const u8,
  output_clusters: []const u8,

  /// From a successful Simple_Desc_rsp: sequence, status, address, length, then the descriptor.
  pub fn parse(payload: []const u8) Error!SimpleDescriptor {
    if (payload.len < 5) return error.TooShort;
    const len = payload[4];
    if (len < 8 or payload.len < 5 + @as(usize, len)) return error.TooShort;
    const d = payload[5..][0..len];
    const inputs = @as(usize, d[6]) * 2;
    if (d.len < 7 + inputs + 1) return error.TooShort;
    const outputs = @as(usize, d[7 + inputs]) * 2;
    if (d.len < 8 + inputs + outputs) return error.TooShort;
    return .{
      .endpoint = d[0],
      .profile = std.mem.readInt(u16, d[1..3], .little),
      .device = std.mem.readInt(u16, d[3..5], .little),
      .input_clusters = d[7..][0..inputs],
      .output_clusters = d[8 + inputs..][0..outputs],
    };
  }
};

/// The cluster at `index` of a list from a simple descriptor.
pub fn clusterAt(clusters: []const u8, index: usize) u16 {
  return std.mem.readInt(u16, clusters[index * 2..][0..2], .little);
}

/// A device that joined or rejoined announces itself.
pub const DeviceAnnounce = struct {
  nwk: u16,
  ieee: u64,
  capabilities: u8,

  pub fn parse(payload: []const u8) Error!DeviceAnnounce {
    if (payload.len < 12) return error.TooShort;
    return .{
      .nwk = std.mem.readInt(u16, payload[1..3], .little),
      .ieee = std.mem.readInt(u64, payload[3..11], .little),
      .capabilities = payload[11],
    };
  }
};

/// Node_Desc_req and Active_EP_req: the address of the node asked about.
pub fn addressRequest(out: *[3]u8, sequence: u8, nwk: u16) []const u8 {
  out[0] = sequence;
  std.mem.writeInt(u16, out[1..3], nwk, .little);
  return out;
}

pub fn simpleDescriptorRequest(out: *[4]u8, sequence: u8, nwk: u16, ep: u8) []const u8 {
  out[0] = sequence;
  std.mem.writeInt(u16, out[1..3], nwk, .little);
  out[3] = ep;
  return out;
}

/// Bind_req and Unbind_req: the source's cluster, to a destination by IEEE address and endpoint.
pub fn bindRequest(
  out: *[22]u8,
  sequence: u8,
  source: u64,
  source_endpoint: u8,
  cluster: u16,
  destination: u64,
  destination_endpoint: u8,
) []const u8 {
  out[0] = sequence;
  std.mem.writeInt(u64, out[1..9], source, .little);
  out[9] = source_endpoint;
  std.mem.writeInt(u16, out[10..12], cluster, .little);
  // An IEEE address and an endpoint, not a group.
  out[12] = 0x03;
  std.mem.writeInt(u64, out[13..21], destination, .little);
  out[21] = destination_endpoint;
  return out;
}

/// Mgmt_Permit_Joining_req: open for `seconds`, 0 to close; the trust center decides.
pub fn permitJoiningRequest(out: *[3]u8, sequence: u8, seconds: u8) []const u8 {
  out.* = .{ sequence, seconds, 0x01 };
  return out;
}

/// Mgmt_Leave_req: the device itself leaves, without its children, and does not rejoin.
pub fn leaveRequest(out: *[10]u8, sequence: u8, ieee: u64) []const u8 {
  out[0] = sequence;
  std.mem.writeInt(u64, out[1..9], ieee, .little);
  out[9] = 0x00;
  return out;
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}

test "what the sensor says about itself" {
  // Node_Desc_rsp: an end device of manufacturer 0x1407, its receiver off when idle.
  const node = try NodeDescriptor.parse(
    &hex(
      "05" ++
        "00" ++
        "ce1b" ++
        "02" ++
        "40" ++
        "80" ++
        "0714" ++
        "52" ++
        "8000" ++
        "002c" ++
        "8000" ++
        "00",
    ),
  );
  try testing.expectEqual(LogicalType.end_device, node.logical_type);
  try testing.expectEqual(0x1407, node.manufacturer_code);
  try testing.expect(!node.rx_on_when_idle);
  try testing.expect(!node.mains_powered);
  try testing.expectEqualSlices(
    u8,
    &.{ 1 },
    try parseActiveEndpoints(&hex("06" ++ "00" ++ "ce1b" ++ "01" ++ "01")),
  );
  // Simple_Desc_rsp: endpoint 1, Home Automation, a temperature sensor with five input
  // clusters and one output cluster.
  const simple = try SimpleDescriptor.parse(
    &hex(
      "07" ++ "00" ++ "ce1b" ++ "14" ++
        "01" ++ "0401" ++ "0203" ++ "00" ++
        "05" ++ "0000" ++ "0100" ++ "0300" ++ "0204" ++ "0504" ++
        "01" ++ "1900",
    ),
  );
  try testing.expectEqual(1, simple.endpoint);
  try testing.expectEqual(0x0104, simple.profile);
  try testing.expectEqual(0x0302, simple.device);
  try testing.expectEqual(5, simple.input_clusters.len / 2);
  try testing.expectEqual(0x0405, clusterAt(simple.input_clusters, 4));
  try testing.expectEqual(0x0019, clusterAt(simple.output_clusters, 0));
  try testing.expectError(
    error.TooShort,
    SimpleDescriptor.parse(
      &hex("07" ++ "00" ++ "ce1b" ++ "08" ++ "01" ++ "0401" ++ "0203" ++ "00" ++ "05"),
    ),
  );

  // As the plug announced itself.
  const announce = try DeviceAnnounce.parse(&hex("00" ++ "7371" ++ "971700060eb4ffff" ++ "8e"));
  try testing.expectEqual(0x7173, announce.nwk);
  try testing.expectEqual(0xffffb40e06001797, announce.ieee);
}

test "requests" {
  var bind: [22]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("09" ++ "0000350d005042f4" ++ "01" ++ "0204" ++ "03" ++ "1de149feffb6c67c" ++ "01"),
    bindRequest(&bind, 9, 0xf44250000d350000, 1, 0x0402, 0x7cc6b6fffe49e11d, 1),
  );
  var permit: [3]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    &hex("0a" ++ "3c" ++ "01"),
    permitJoiningRequest(&permit, 10, 60),
  );
  var address: [3]u8 = undefined;
  try testing.expectEqualSlices(u8, &hex("0b" ++ "7371"), addressRequest(&address, 11, 0x7173));
}

test "fuzz: ZDO responses are parsed safely" {
  try testing.fuzz({}, fuzzParse, .{
    .corpus = &.{
      &hex(
        "07" ++
          "00" ++
          "ce1b" ++
          "14" ++
          "01" ++
          "0401" ++
          "0203" ++
          "00" ++
          "05" ++
          "0000" ++
          "0100" ++
          "0300" ++
          "0204" ++
          "0504" ++
          "01" ++
          "1900",
      ),
    },
  });
}

fn fuzzParse(_: void, smith: *testing.Smith) !void {
  var bytes: [96]u8 = undefined;
  const len = smith.slice(&bytes);
  const payload = bytes[0..len];
  _ = parseResponse(payload) catch {};
  _ = NodeDescriptor.parse(payload) catch {};
  _ = parseActiveEndpoints(payload) catch {};
  _ = DeviceAnnounce.parse(payload) catch {};
  const simple = SimpleDescriptor.parse(payload) catch return;
  for (0..simple.input_clusters.len / 2) |i| {
    _ = clusterAt(simple.input_clusters, i);
  }
  for (0..simple.output_clusters.len / 2) |i| {
    _ = clusterAt(simple.output_clusters, i);
  }
}
