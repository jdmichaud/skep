//! The state: what libskep keeps across restarts and dongles, and the JSON document the C API
//! exports and imports it as.
//!
//! The document is an Open Coordinator Backup (zigpy/open-coordinator-backup, version 1), which
//! zigpy and zigbee-herdsman also read and write, so that a network can move between them and
//! skep. What libskep knows beyond it is in a top-level "skep" object, with a version of its own.
//! Addresses and IDs are written most significant byte first, as zigpy writes them.

const std = @import("std");
const build_options = @import("build_options");
const driver = @import("driver/driver.zig");

const State = @This();

/// The coordinator's IEEE address.
coordinator_ieee: u64,
network: driver.Network,
network_key: [16]u8,
network_key_sequence_number: u8 = 0,
/// The network key's outgoing frame counter, as last read from the dongle.
network_frame_counter: u32 = 0,
/// The key from which the trust center derives devices' link keys. Null in a state written by a
/// stack that keeps it elsewhere, such as Z-Stack.
trust_center_link_key: ?[16]u8,
trust_center_frame_counter: u32 = 0,
/// The devices of the network, each once.
devices: std.ArrayList(Device) = .empty,

/// A device, and what libskep learnt of it.
pub const Device = struct {
  ieee: u64,
  /// Null when not known.
  nwk: ?u16,
  /// From its node descriptor, once interviewed.
  node: ?Node = null,
  /// Its endpoints, as it listed them.
  endpoints: []Endpoint = &.{},
  /// From its Basic cluster: printable ASCII only, since it comes from the radio.
  manufacturer: ?[]u8 = null,
  model: ?[]u8 = null,
  progress: Progress = .{},

  pub fn deinit(d: *Device, gpa: std.mem.Allocator) void {
    freeEndpoints(gpa, d.endpoints);
    if (d.manufacturer) |m| {
      gpa.free(m);
    }
    if (d.model) |m| {
      gpa.free(m);
    }
    d.* = .{ .ieee = d.ieee, .nwk = d.nwk };
  }

  /// Whether it sleeps, and only hears what it polls for. A device not interviewed yet is taken
  /// to be awake.
  pub fn sleepy(d: *const Device) bool {
    const node = d.node orelse return false;
    return !node.rx_on_when_idle;
  }

  pub fn endpoint(d: *const Device, id: u8) ?*const Endpoint {
    for (d.endpoints) |*e| {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Sets its manufacturer or model, keeping printable ASCII only.
  pub fn setText(gpa: std.mem.Allocator, field: *?[]u8, text: []const u8) error{
    OutOfMemory,
  }!void {
    const copy = try gpa.dupe(u8, text);
    for (copy) |*c| {
      if (c.* < 0x20 or c.* > 0x7e) {
        c.* = '?';
      }
    }
    if (field.*) |old| {
      gpa.free(old);
    }
    field.* = copy;
  }
};

pub const NodeType = enum { coordinator, router, end_device };

pub const Node = struct {
  type: NodeType,
  manufacturer_code: u16,
  rx_on_when_idle: bool,
};

pub const Endpoint = struct {
  id: u8,
  profile: u16 = 0,
  device: u16 = 0,
  /// Server clusters: those it implements. Client clusters: those it uses on others.
  input_clusters: []u16 = &.{},
  output_clusters: []u16 = &.{},

  pub fn hasInput(e: *const Endpoint, cluster: u16) bool {
    return std.mem.indexOfScalar(u16, e.input_clusters, cluster) != null;
  }
};

pub fn freeEndpoints(gpa: std.mem.Allocator, endpoints: []Endpoint) void {
  for (endpoints) |e| {
    gpa.free(e.input_clusters);
    gpa.free(e.output_clusters);
  }
  gpa.free(endpoints);
}

/// How far a device's interview and setup got: the step within the stage is the endpoint to
/// describe next, or the setup step.
pub const Progress = struct {
  stage: Stage = .node,
  step: u16 = 0,
};

pub const Stage = enum {
  /// The interview: its node descriptor, its endpoints, their descriptors, then its manufacturer
  /// and model.
  node,
  endpoints,
  descriptors,
  basic,
  /// The steps its device entry asks for: bindings and reporting.
  setup,
  ready,
  /// A step was refused; `skep_setup_device` starts again.
  failed,
};

pub const format = "zigpy/open-coordinator-backup";
pub const format_version = 1;
/// The version of the "skep" object.
pub const skep_version = 1;

/// The state of a network just up, without devices yet.
pub fn init(coordinator_ieee: u64, h: driver.Held) State {
  var s: State = .{
    .coordinator_ieee = coordinator_ieee,
    .network = h.network,
    .network_key = h.security.network_key,
    .trust_center_link_key = h.security.trust_center_link_key,
  };
  _ = s.update(coordinator_ieee, h);
  return s;
}

pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
  for (s.devices.items) |*d| {
    d.deinit(gpa);
  }
  s.devices.deinit(gpa);
}

/// The network and its keys, as a driver puts them back onto a dongle, the trust center link key
/// being that of the state.
pub fn held(s: *const State, trust_center_link_key: [16]u8) driver.Held {
  return .{
    .network = s.network,
    .security = .{
      .network_key = s.network_key,
      .network_key_sequence_number = s.network_key_sequence_number,
      .network_frame_counter = s.network_frame_counter,
      .trust_center_link_key = trust_center_link_key,
      .trust_center_frame_counter = s.trust_center_frame_counter,
    },
  };
}

/// Takes in the network as the dongle holds it. Returns whether anything changed.
///
/// A key's frame counter never goes down: devices remember the highest they saw, so a dongle
/// that counts from lower, having refused to carry on from the saved counter, does not lower
/// what the next restore must pass.
pub fn update(s: *State, coordinator_ieee: u64, h: driver.Held) bool {
  const before = s.*;
  const same_network_key = std.mem.eql(u8, &s.network_key, &h.security.network_key);
  const same_trust_center_key = if (s.trust_center_link_key) |key|
    std.mem.eql(u8, &key, &h.security.trust_center_link_key)
  else
    false;
  s.coordinator_ieee = coordinator_ieee;
  s.network = h.network;
  s.network_key = h.security.network_key;
  s.network_key_sequence_number = h.security.network_key_sequence_number;
  s.network_frame_counter = if (same_network_key)
    @max(s.network_frame_counter, h.security.network_frame_counter)
  else
    h.security.network_frame_counter;
  s.trust_center_link_key = h.security.trust_center_link_key;
  // A dongle that does not tell keeps the counter known so far.
  if (h.security.trust_center_frame_counter) |counter| {
    s.trust_center_frame_counter = if (same_trust_center_key)
      @max(s.trust_center_frame_counter, counter)
    else
      counter;
  }
  return !std.meta.eql(before, s.*);
}

/// The device of IEEE address `ieee`, if known.
pub fn device(s: *const State, ieee: u64) ?*Device {
  for (s.devices.items) |*d| {
    if (d.ieee == ieee) return d;
  }
  return null;
}

/// Records that a device is at network address `nwk`, adding it if it is new. Returns whether
/// anything changed.
pub fn noteDevice(s: *State, gpa: std.mem.Allocator, ieee: u64, nwk: ?u16) error{
  OutOfMemory,
}!bool {
  try s.devices.ensureUnusedCapacity(gpa, 1);
  return s.noteDeviceAssumeCapacity(ieee, nwk);
}

/// `noteDevice`, once `devices` has room for one more.
pub fn noteDeviceAssumeCapacity(s: *State, ieee: u64, nwk: ?u16) bool {
  if (s.device(ieee)) |known| {
    if (nwk == null or known.nwk == nwk) return false;
    known.nwk = nwk;
    return true;
  }
  s.devices.appendAssumeCapacity(.{ .ieee = ieee, .nwk = nwk });
  return true;
}

/// The device at network address `nwk`, if known.
pub fn deviceAt(s: *const State, nwk: u16) ?*Device {
  for (s.devices.items) |*d| {
    if (d.nwk == nwk) return d;
  }
  return null;
}

/// Writes the state as JSON, indented for people to read.
pub fn write(s: *const State, out: *std.Io.Writer) std.Io.Writer.Error!void {
  var j: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
  try j.beginObject();

  try j.objectField("metadata");
  try j.beginObject();
  try j.objectField("format");
  try j.write(format);
  try j.objectField("version");
  try j.write(format_version);
  try j.objectField("source");
  try j.write("skep@" ++ build_options.version);
  // Each stack's own; zigbee-herdsman's EmberZNet driver expects the object.
  try j.objectField("internal");
  try j.beginObject();
  try j.endObject();
  try j.endObject();

  // Where zigpy and zigbee-herdsman keep the trust center link key of EmberZNet dongles.
  try j.objectField("stack_specific");
  try j.beginObject();
  if (s.trust_center_link_key) |key| {
    try j.objectField("ezsp");
    try j.beginObject();
    try j.objectField("hashed_tclk");
    try j.print("\"{x}\"", .{ &key });
    try j.endObject();
  }
  try j.endObject();

  try j.objectField("coordinator_ieee");
  try j.print("\"{x:0>16}\"", .{ s.coordinator_ieee });
  try j.objectField("pan_id");
  try j.print("\"{x:0>4}\"", .{ s.network.pan_id });
  try j.objectField("extended_pan_id");
  try j.print("\"{x:0>16}\"", .{ s.network.extended_pan_id });
  try j.objectField("nwk_update_id");
  try j.write(s.network.update_id);
  // Zigbee 3.0 networks use level 5 only: encryption, with a 32-bit message integrity code.
  try j.objectField("security_level");
  try j.write(5);
  try j.objectField("channel");
  try j.write(s.network.channel);
  // The channels the coordinator may move the network to: all of them, as formed.
  try j.objectField("channel_mask");
  try j.beginArray();
  for (11..27) |channel| {
    try j.write(channel);
  }
  try j.endArray();

  try j.objectField("network_key");
  try j.beginObject();
  try j.objectField("key");
  try j.print("\"{x}\"", .{ &s.network_key });
  try j.objectField("sequence_number");
  try j.write(s.network_key_sequence_number);
  try j.objectField("frame_counter");
  try j.write(s.network_frame_counter);
  try j.endObject();

  try j.objectField("devices");
  try j.beginArray();
  for (s.devices.items) |d| {
    try j.beginObject();
    try j.objectField("nwk_address");
    if (d.nwk) |nwk| {
      try j.print("\"{x:0>4}\"", .{ nwk });
    } else {
      try j.write(null);
    }
    try j.objectField("ieee_address");
    try j.print("\"{x:0>16}\"", .{ d.ieee });
    // Whether a device is the coordinator's child takes its parent, which libskep does not keep.
    // Readers take a missing value for true, which would be wrong for routers.
    try j.objectField("is_child");
    try j.write(false);
    try j.endObject();
  }
  try j.endArray();

  try j.objectField("skep");
  try j.beginObject();
  try j.objectField("version");
  try j.write(skep_version);
  try j.objectField("trust_center_frame_counter");
  try j.write(s.trust_center_frame_counter);
  try j.objectField("devices");
  try j.beginArray();
  for (s.devices.items) |*d| {
    try writeDevice(&j, d);
  }
  try j.endArray();
  try j.endObject();

  try j.endObject();
  try out.writeByte('\n');
}

/// What libskep knows of a device beyond the backup format, in the "skep" object.
fn writeDevice(j: *std.json.Stringify, d: *const Device) std.Io.Writer.Error!void {
  try j.beginObject();
  try j.objectField("ieee_address");
  try j.print("\"{x:0>16}\"", .{ d.ieee });
  if (d.node) |node| {
    try j.objectField("node");
    try j.beginObject();
    try j.objectField("type");
    try j.write(@tagName(node.type));
    try j.objectField("manufacturer_code");
    try j.print("\"{x:0>4}\"", .{ node.manufacturer_code });
    try j.objectField("rx_on_when_idle");
    try j.write(node.rx_on_when_idle);
    try j.endObject();
  }
  if (d.manufacturer) |m| {
    try j.objectField("manufacturer");
    try j.write(m);
  }
  if (d.model) |m| {
    try j.objectField("model");
    try j.write(m);
  }
  if (d.endpoints.len > 0) {
    try j.objectField("endpoints");
    try j.beginArray();
    for (d.endpoints) |e| {
      try j.beginObject();
      try j.objectField("id");
      try j.write(e.id);
      try j.objectField("profile");
      try j.print("\"{x:0>4}\"", .{ e.profile });
      try j.objectField("device");
      try j.print("\"{x:0>4}\"", .{ e.device });
      try j.objectField("input_clusters");
      try writeClusters(j, e.input_clusters);
      try j.objectField("output_clusters");
      try writeClusters(j, e.output_clusters);
      try j.endObject();
    }
    try j.endArray();
  }
  try j.objectField("setup");
  try j.beginObject();
  try j.objectField("stage");
  try j.write(@tagName(d.progress.stage));
  try j.objectField("step");
  try j.write(d.progress.step);
  try j.endObject();
  try j.endObject();
}

fn writeClusters(j: *std.json.Stringify, clusters: []const u16) std.Io.Writer.Error!void {
  try j.beginArray();
  for (clusters) |cluster| {
    try j.print("\"{x:0>4}\"", .{ cluster });
  }
  try j.endArray();
}

/// The length of the state as `write` writes it.
pub fn writtenLen(s: *const State) usize {
  var discarding: std.Io.Writer.Discarding = .init(&.{});
  s.write(&discarding.writer) catch unreachable;
  return @intCast(discarding.fullCount());
}

pub const ParseError = error{
  /// Not a state: not JSON, or a field missing, of the wrong type or out of range.
  Invalid,
  /// Written by a newer version of the format or of libskep.
  NotSupported,
  OutOfMemory,
};

/// Reads a state written by `write`, by an older libskep, or by another stack.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!State {
  const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
  // The versions first, which a newer document may keep where it keeps nothing else.
  {
    const parsed = std.json.parseFromSlice(Versions, gpa, bytes, options) catch |err|
      return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    defer parsed.deinit();
    const v = parsed.value;
    if (!std.mem.eql(u8, v.metadata.format, format)) return error.Invalid;
    if (v.metadata.version != format_version) {
      return if (v.metadata.version > format_version) error.NotSupported else error.Invalid;
    }
    if (v.skep) |skep| {
      if (skep.version > skep_version) return error.NotSupported;
      if (skep.version == 0) return error.Invalid;
    }
  }
  const parsed = std.json.parseFromSlice(Document, gpa, bytes, options) catch |err|
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
  defer parsed.deinit();
  const d = parsed.value;

  const pan_id = parseHex(u16, d.pan_id, 1) orelse return error.Invalid;
  const extended_pan_id = parseHex(u64, d.extended_pan_id, 16) orelse return error.Invalid;
  if (d.channel < 11 or d.channel > 26) return error.Invalid;
  // 0xffff addresses every PAN; extended PAN IDs of 0 and all ones are reserved.
  if (pan_id == 0xffff) return error.Invalid;
  if (extended_pan_id == 0 or extended_pan_id == std.math.maxInt(u64)) return error.Invalid;

  var s: State = .{
    .coordinator_ieee = parseHex(u64, d.coordinator_ieee, 16) orelse return error.Invalid,
    .network = .{
      .channel = d.channel,
      .pan_id = pan_id,
      .extended_pan_id = extended_pan_id,
      .update_id = d.nwk_update_id,
    },
    .network_key = parseKey(d.network_key.key) orelse return error.Invalid,
    .network_key_sequence_number = d.network_key.sequence_number,
    .network_frame_counter = d.network_key.frame_counter,
    .trust_center_link_key = null,
    .trust_center_frame_counter = if (d.skep) |skep| skep.trust_center_frame_counter else 0,
  };
  if (d.stack_specific) |stack| {
    if (stack.ezsp) |ezsp| {
      if (ezsp.hashed_tclk) |key| {
        s.trust_center_link_key = parseKey(key) orelse return error.Invalid;
      }
    }
  }
  errdefer s.deinit(gpa);
  try s.devices.ensureTotalCapacity(gpa, d.devices.len);
  for (d.devices) |entry| {
    _ = try s.noteDevice(
      gpa,
      parseHex(u64, entry.ieee_address, 16) orelse return error.Invalid,
      // zigbee-herdsman leaves out leading zeros.
      if (entry.nwk_address) |nwk| parseHex(u16, nwk, 1) orelse return error.Invalid else null,
    );
  }
  if (d.skep) |skep| {
    for (skep.devices) |*entry| {
      try s.parseDevice(gpa, entry);
    }
  }
  return s;
}

/// Takes in what the "skep" object says of a device.
fn parseDevice(s: *State, gpa: std.mem.Allocator, entry: *const SkepDevice) ParseError!void {
  const ieee = parseHex(u64, entry.ieee_address, 16) orelse return error.Invalid;
  _ = try s.noteDevice(gpa, ieee, null);
  const d = s.device(ieee).?;
  d.deinit(gpa);
  if (entry.node) |node| {
    d.node = .{
      .type = std.meta.stringToEnum(NodeType, node.type) orelse return error.Invalid,
      .manufacturer_code = parseHex(u16, node.manufacturer_code, 1) orelse return error.Invalid,
      .rx_on_when_idle = node.rx_on_when_idle,
    };
  }
  if (entry.manufacturer) |m| {
    try Device.setText(gpa, &d.manufacturer, m);
  }
  if (entry.model) |m| {
    try Device.setText(gpa, &d.model, m);
  }
  // Assigned as soon as allocated, so that `deinit` frees what is there if a later part fails.
  d.endpoints = try gpa.alloc(Endpoint, entry.endpoints.len);
  for (d.endpoints) |*e| {
    e.* = .{ .id = 0 };
  }
  for (entry.endpoints, d.endpoints) |from, *to| {
    to.id = from.id;
    to.profile = parseHex(u16, from.profile, 1) orelse return error.Invalid;
    to.device = parseHex(u16, from.device, 1) orelse return error.Invalid;
    to.input_clusters = try parseClusters(gpa, from.input_clusters);
    to.output_clusters = try parseClusters(gpa, from.output_clusters);
  }
  if (entry.setup) |setup| {
    d.progress = .{
      .stage = std.meta.stringToEnum(Stage, setup.stage) orelse return error.Invalid,
      .step = setup.step,
    };
  }
}

fn parseClusters(gpa: std.mem.Allocator, digits: []const []const u8) ParseError![]u16 {
  const clusters = try gpa.alloc(u16, digits.len);
  errdefer gpa.free(clusters);
  for (digits, clusters) |text, *cluster| {
    cluster.* = parseHex(u16, text, 1) orelse return error.Invalid;
  }
  return clusters;
}

/// What says which versions a document follows.
const Versions = struct {
  metadata: struct { format: []const u8, version: u32 },
  skep: ?struct { version: u32 } = null,
};

/// The fields of the document that libskep reads.
const Document = struct {
  stack_specific: ?struct { ezsp: ?struct { hashed_tclk: ?[]const u8 = null } = null } = null,
  coordinator_ieee: []const u8,
  pan_id: []const u8,
  extended_pan_id: []const u8,
  nwk_update_id: u8 = 0,
  channel: u8,
  network_key: struct { key: []const u8, sequence_number: u8 = 0, frame_counter: u32 = 0 },
  devices: []const struct { ieee_address: []const u8, nwk_address: ?[]const u8 = null } = &.{},
  skep: ?struct { trust_center_frame_counter: u32 = 0, devices: []const SkepDevice = &.{} } = null,
};

/// A device in the "skep" object.
const SkepDevice = struct {
  ieee_address: []const u8,
  node: ?struct { type: []const u8, manufacturer_code: []const u8, rx_on_when_idle: bool } = null,
  manufacturer: ?[]const u8 = null,
  model: ?[]const u8 = null,
  endpoints: []const struct {
    id: u8,
    profile: []const u8,
    device: []const u8,
    input_clusters: []const []const u8 = &.{},
    output_clusters: []const []const u8 = &.{},
  } = &.{},
  setup: ?struct { stage: []const u8, step: u16 = 0 } = null,
};

/// Hexadecimal digits without 0x: at least `min_digits`, at most as many as the type holds.
fn parseHex(comptime T: type, digits: []const u8, min_digits: usize) ?T {
  if (digits.len < min_digits or digits.len > @typeInfo(T).int.bits / 4) return null;
  for (digits) |c| {
    if (!std.ascii.isHex(c)) return null;
  }
  return std.fmt.parseInt(T, digits, 16) catch null;
}

/// A key: 32 hexadecimal digits, the bytes in order.
fn parseKey(digits: []const u8) ?[16]u8 {
  if (digits.len != 32) return null;
  var key: [16]u8 = undefined;
  _ = std.fmt.hexToBytes(&key, digits) catch return null;
  return key;
}

const testing = std.testing;

fn testState() State {
  return .{
    .coordinator_ieee = 0x7cc6b6fffe49e11d,
    .network = .{
      .channel = 15,
      .pan_id = 0x0578,
      .extended_pan_id = 0x8a4f7ca9954c4cd5,
      .update_id = 1,
    },
    .network_key = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0, 1, 2, 3, 4, 5, 6, 7 },
    .network_key_sequence_number = 0,
    .network_frame_counter = 49153,
    .trust_center_link_key = @splat(0x11),
    .trust_center_frame_counter = 16384,
  };
}

const test_document =
  \\{
  \\  "metadata": {
  \\    "format": "zigpy/open-coordinator-backup",
  \\    "version": 1,
  \\    "source": "skep@
++ build_options.version ++
  \\",
  \\    "internal": {}
  \\  },
  \\  "stack_specific": {
  \\    "ezsp": {
  \\      "hashed_tclk": "11111111111111111111111111111111"
  \\    }
  \\  },
  \\  "coordinator_ieee": "7cc6b6fffe49e11d",
  \\  "pan_id": "0578",
  \\  "extended_pan_id": "8a4f7ca9954c4cd5",
  \\  "nwk_update_id": 1,
  \\  "security_level": 5,
  \\  "channel": 15,
  \\  "channel_mask": [
  \\    11,
  \\    12,
  \\    13,
  \\    14,
  \\    15,
  \\    16,
  \\    17,
  \\    18,
  \\    19,
  \\    20,
  \\    21,
  \\    22,
  \\    23,
  \\    24,
  \\    25,
  \\    26
  \\  ],
  \\  "network_key": {
  \\    "key": "0123456789abcdef0001020304050607",
  \\    "sequence_number": 0,
  \\    "frame_counter": 49153
  \\  },
  \\  "devices": [
  \\    {
  \\      "nwk_address": "035e",
  \\      "ieee_address": "f44250000d350000",
  \\      "is_child": false
  \\    }
  \\  ],
  \\  "skep": {
  \\    "version": 1,
  \\    "trust_center_frame_counter": 16384,
  \\    "devices": [
  \\      {
  \\        "ieee_address": "f44250000d350000",
  \\        "setup": {
  \\          "stage": "node",
  \\          "step": 0
  \\        }
  \\      }
  \\    ]
  \\  }
  \\}
  \\
;

test "the state is written as an Open Coordinator Backup, and read back" {
  var s = testState();
  defer s.deinit(testing.allocator);
  try testing.expect(try s.noteDevice(testing.allocator, 0xf44250000d350000, 0x035e));
  try testing.expect(!try s.noteDevice(testing.allocator, 0xf44250000d350000, 0x035e));
  var out: std.Io.Writer.Allocating = .init(testing.allocator);
  defer out.deinit();
  try s.write(&out.writer);
  try testing.expectEqualStrings(test_document, out.written());
  try testing.expectEqual(test_document.len, s.writtenLen());

  var read = try parse(testing.allocator, out.written());
  defer read.deinit(testing.allocator);
  try testing.expectEqual(s.coordinator_ieee, read.coordinator_ieee);
  try testing.expectEqual(s.network, read.network);
  try testing.expectEqual(s.network_key, read.network_key);
  try testing.expectEqual(s.network_frame_counter, read.network_frame_counter);
  try testing.expectEqual(s.trust_center_link_key, read.trust_center_link_key);
  try testing.expectEqual(s.trust_center_frame_counter, read.trust_center_frame_counter);
  try expectSameDevices(&s, &read);
}

test "frame counters never go down while their keys stay" {
  var s = testState();
  var h = s.held(s.trust_center_link_key.?);
  // A dongle that refused the saved counters, and counts from lower.
  h.security.network_frame_counter = 100;
  h.security.trust_center_frame_counter = 0;
  try testing.expect(!s.update(s.coordinator_ieee, h));
  try testing.expectEqual(49153, s.network_frame_counter);
  try testing.expectEqual(16384, s.trust_center_frame_counter);
  h.security.network_frame_counter = 50000;
  try testing.expect(s.update(s.coordinator_ieee, h));
  try testing.expectEqual(50000, s.network_frame_counter);
  // New keys start their own counters.
  h.security.network_key = @splat(0x33);
  h.security.trust_center_link_key = @splat(0x44);
  h.security.network_frame_counter = 7;
  try testing.expect(s.update(s.coordinator_ieee, h));
  try testing.expectEqual(7, s.network_frame_counter);
  try testing.expectEqual(0, s.trust_center_frame_counter);
}

/// Fails unless both states hold the same devices, with the same interviews and progress.
fn expectSameDevices(a: *const State, b: *const State) !void {
  try testing.expectEqual(a.devices.items.len, b.devices.items.len);
  for (a.devices.items, b.devices.items) |x, y| {
    try testing.expectEqual(x.ieee, y.ieee);
    try testing.expectEqual(x.nwk, y.nwk);
    try testing.expectEqual(x.node, y.node);
    try testing.expectEqual(x.progress, y.progress);
    try testing.expectEqualStrings(x.manufacturer orelse "", y.manufacturer orelse "");
    try testing.expectEqualStrings(x.model orelse "", y.model orelse "");
    try testing.expectEqual(x.endpoints.len, y.endpoints.len);
    for (x.endpoints, y.endpoints) |e, f| {
      try testing.expectEqual(e.id, f.id);
      try testing.expectEqual(e.profile, f.profile);
      try testing.expectEqual(e.device, f.device);
      try testing.expectEqualSlices(u16, e.input_clusters, f.input_clusters);
      try testing.expectEqualSlices(u16, e.output_clusters, f.output_clusters);
    }
  }
}

test "what libskep learnt of devices is kept" {
  var s = testState();
  defer s.deinit(testing.allocator);
  _ = try s.noteDevice(testing.allocator, 0xf44250000d350000, 0x1bce);
  const d = s.device(0xf44250000d350000).?;
  d.node = .{ .type = .end_device, .manufacturer_code = 0x1407, .rx_on_when_idle = false };
  // A model with what does not belong in a name.
  try Device.setText(testing.allocator, &d.manufacturer, "Third Reality, Inc");
  try Device.setText(testing.allocator, &d.model, "3RTHS0224Z\x00\"\xff");
  try testing.expectEqualStrings("3RTHS0224Z?\"?", d.model.?);
  d.endpoints = try testing.allocator.alloc(Endpoint, 1);
  d.endpoints[0] = .{
    .id = 1,
    .profile = 0x0104,
    .device = 0x0302,
    .input_clusters = try testing.allocator.dupe(u16, &.{ 0x0000, 0x0001, 0x0402, 0x0405 }),
    .output_clusters = try testing.allocator.dupe(u16, &.{ 0x0019 }),
  };
  d.progress = .{ .stage = .setup, .step = 2 };
  try testing.expect(d.sleepy());
  try testing.expect(d.endpoint(1).?.hasInput(0x0402));
  // A device known from the "skep" object only.
  _ = try s.noteDevice(testing.allocator, 0x00124b0012345678, null);

  var out: std.Io.Writer.Allocating = .init(testing.allocator);
  defer out.deinit();
  try s.write(&out.writer);
  var read = try parse(testing.allocator, out.written());
  defer read.deinit(testing.allocator);
  try expectSameDevices(&s, &read);
  try testing.expectEqual(0x1bce, read.deviceAt(0x1bce).?.nwk);
}

test "reading a state with devices survives running out of memory" {
  var s = testState();
  defer s.deinit(testing.allocator);
  _ = try s.noteDevice(testing.allocator, 0xf44250000d350000, 0x1bce);
  const d = s.device(0xf44250000d350000).?;
  try Device.setText(testing.allocator, &d.model, "3RTHS0224Z");
  d.endpoints = try testing.allocator.alloc(Endpoint, 1);
  d.endpoints[0] = .{
    .id = 1,
    .input_clusters = try testing.allocator.dupe(u16, &.{ 0x0000, 0x0402 }),
    .output_clusters = try testing.allocator.dupe(u16, &.{ 0x0019 }),
  };
  var out: std.Io.Writer.Allocating = .init(testing.allocator);
  defer out.deinit();
  try s.write(&out.writer);
  try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{ out.written() });
}

test "states from other stacks are read" {
  // As zigbee-herdsman writes them for Z-Stack: digits left out, its own fields, no "skep", and
  // a device listed twice, the last one counting.
  const herdsman =
    \\{"metadata":{"format":"zigpy/open-coordinator-backup","version":1,
    \\"source":"zigbee-herdsman@0.13.65","internal":{"date":"2021-03-03T19:15:40.524Z","znpVersion":2}},
    \\"stack_specific":{"zstack":{"tclk_seed":"928a2c479e72a9a53e3b5133fc55021f"}},
    \\"coordinator_ieee":"00124b0009d80ba7","pan_id":"7b","extended_pan_id":"00124b0009d69f77",
    \\"nwk_update_id":0,"security_level":5,"channel":21,"channel_mask":[21],
    \\"network_key":{"key":"37668fd64e35e03342e5ef9f35ccf4ab","sequence_number":0,"frame_counter":8712428},
    \\"devices":[{"nwk_address":"ddf6","ieee_address":"00124b002226ef87","is_child":false},
    \\{"nwk_address":"a3","ieee_address":"00124b002226ef87","is_child":true,
    \\"link_key":{"key":"bff550908aa1529ee90eea3c3bdc26fc","rx_counter":0,"tx_counter":275}}]}
  ;
  var s = try parse(testing.allocator, herdsman);
  defer s.deinit(testing.allocator);
  try testing.expectEqual(0x00124b0009d80ba7, s.coordinator_ieee);
  try testing.expectEqual(0x007b, s.network.pan_id);
  try testing.expectEqual(21, s.network.channel);
  try testing.expectEqual(8712428, s.network_frame_counter);
  try testing.expectEqual(null, s.trust_center_link_key);
  try testing.expectEqual(0, s.trust_center_frame_counter);
  try testing.expectEqual(1, s.devices.items.len);
  try testing.expectEqual(0x00a3, s.devices.items[0].nwk);
}

test "what is not a state is refused, and newer states are not supported" {
  const cases = [_]struct { []const u8, ParseError }{
    .{ "", error.Invalid },
    .{ "[]", error.Invalid },
    .{ "{\"metadata\":{\"format\":\"other\",\"version\":1}}", error.Invalid },
    .{
      "{\"metadata\":{\"format\":\"zigpy/open-coordinator-backup\",\"version\":2}}",
      error.NotSupported,
    },
    .{
      "{\"metadata\":{\"format\":\"zigpy/open-coordinator-backup\",\"version\":1},\"skep\":{\"version\":2}}",
      error.NotSupported,
    },
    // Version 1 without its fields.
    .{
      "{\"metadata\":{\"format\":\"zigpy/open-coordinator-backup\",\"version\":1}}",
      error.Invalid,
    },
  };
  for (cases) |case| {
    try testing.expectError(case[1], parse(testing.allocator, case[0]));
  }
  // Each field out of range in turn.
  const replacements = [_][2][]const u8{
    .{ "\"channel\": 15", "\"channel\": 27" },
    .{ "\"pan_id\": \"0578\"", "\"pan_id\": \"ffff\"" },
    .{ "\"pan_id\": \"0578\"", "\"pan_id\": \"-578\"" },
    .{ "\"extended_pan_id\": \"8a4f7ca9954c4cd5\"", "\"extended_pan_id\": \"8a4f7ca9954c4cd\"" },
    .{
      "\"key\": \"0123456789abcdef0001020304050607\"",
      "\"key\": \"0123456789abcdef000102030405060\"",
    },
    .{
      "\"hashed_tclk\": \"11111111111111111111111111111111\"",
      "\"hashed_tclk\": \"1111111111111111111111111111111x\"",
    },
    .{ "\"frame_counter\": 49153", "\"frame_counter\": 4294967296" },
    .{ "\"nwk_address\": \"035e\"", "\"nwk_address\": \"1035e\"" },
    .{ "\"ieee_address\": \"f44250000d350000\"", "\"ieee_address\": 1" },
  };
  for (replacements) |r| {
    const document = try std.mem.replaceOwned(u8, testing.allocator, test_document, r[0], r[1]);
    defer testing.allocator.free(document);
    try testing.expect(!std.mem.eql(u8, document, test_document));
    try testing.expectError(error.Invalid, parse(testing.allocator, document));
  }
}

test "reading a state survives running out of memory" {
  try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{ test_document });
}

fn parseAndFree(gpa: std.mem.Allocator, bytes: []const u8) !void {
  var s = try parse(gpa, bytes);
  s.deinit(gpa);
}

test "fuzz: reading survives any document, and what it reads is written back the same" {
  try testing.fuzz({}, fuzzParse, .{ .corpus = &.{ test_document } });
}

fn fuzzParse(_: void, smith: *testing.Smith) !void {
  var bytes: [2048]u8 = undefined;
  const len = smith.slice(&bytes);
  var s = parse(testing.allocator, bytes[0..len]) catch return;
  defer s.deinit(testing.allocator);
  var out: std.Io.Writer.Allocating = .init(testing.allocator);
  defer out.deinit();
  try s.write(&out.writer);
  var again = try parse(testing.allocator, out.written());
  defer again.deinit(testing.allocator);
  try testing.expectEqual(s.coordinator_ieee, again.coordinator_ieee);
  try testing.expectEqual(s.network, again.network);
  try testing.expectEqual(s.trust_center_link_key, again.trust_center_link_key);
  try expectSameDevices(&s, &again);
}
