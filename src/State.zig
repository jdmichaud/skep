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

pub const Device = struct {
  ieee: u64,
  /// Null when not known.
  nwk: ?u16,
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
pub fn update(s: *State, coordinator_ieee: u64, h: driver.Held) bool {
  const before = s.*;
  s.coordinator_ieee = coordinator_ieee;
  s.network = h.network;
  s.network_key = h.security.network_key;
  s.network_key_sequence_number = h.security.network_key_sequence_number;
  s.network_frame_counter = h.security.network_frame_counter;
  s.trust_center_link_key = h.security.trust_center_link_key;
  // A dongle that does not tell keeps the counter known so far.
  if (h.security.trust_center_frame_counter) |counter| {
    s.trust_center_frame_counter = counter;
  }
  return !std.meta.eql(before, s.*);
}

/// Records a device that joined or rejoined. Returns whether anything changed.
pub fn addDevice(s: *State, gpa: std.mem.Allocator, device: Device) error{ OutOfMemory }!bool {
  try s.devices.ensureUnusedCapacity(gpa, 1);
  return s.addDeviceAssumeCapacity(device);
}

/// `addDevice`, once `devices` has room for one more.
pub fn addDeviceAssumeCapacity(s: *State, device: Device) bool {
  for (s.devices.items) |*known| {
    if (known.ieee != device.ieee) continue;
    if (std.meta.eql(known.*, device)) return false;
    known.* = device;
    return true;
  }
  s.devices.appendAssumeCapacity(device);
  return true;
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
  for (s.devices.items) |device| {
    try j.beginObject();
    try j.objectField("nwk_address");
    if (device.nwk) |nwk| {
      try j.print("\"{x:0>4}\"", .{ nwk });
    } else {
      try j.write(null);
    }
    try j.objectField("ieee_address");
    try j.print("\"{x:0>16}\"", .{ device.ieee });
    // Whether a device is the coordinator's child takes its type, which libskep does not learn
    // yet. Readers take a missing value for true, which would be wrong for routers.
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
  try j.endObject();

  try j.endObject();
  try out.writeByte('\n');
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
  for (d.devices) |device| {
    _ = try s.addDevice(gpa, .{
      .ieee = parseHex(u64, device.ieee_address, 16) orelse return error.Invalid,
      // zigbee-herdsman leaves out leading zeros.
      .nwk = if (device.nwk_address) |nwk|
        parseHex(u16, nwk, 1) orelse return error.Invalid
      else
        null,
    });
  }
  return s;
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
  skep: ?struct { trust_center_frame_counter: u32 = 0 } = null,
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
  \\    "trust_center_frame_counter": 16384
  \\  }
  \\}
  \\
;

test "the state is written as an Open Coordinator Backup, and read back" {
  var s = testState();
  defer s.deinit(testing.allocator);
  try testing.expect(
    try s.addDevice(testing.allocator, .{ .ieee = 0xf44250000d350000, .nwk = 0x035e }),
  );
  try testing.expect(
    !try s.addDevice(testing.allocator, .{ .ieee = 0xf44250000d350000, .nwk = 0x035e }),
  );
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
  try testing.expectEqualSlices(Device, s.devices.items, read.devices.items);
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
  try testing.expectEqualSlices(Device, s.devices.items, again.devices.items);
}
