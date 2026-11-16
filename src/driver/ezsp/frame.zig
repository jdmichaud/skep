//! EZSP frames (Silicon Labs UG100): the commands a host sends to an EmberZNet NCP and the
//! responses and callbacks it gets back, carried in ASH DATA frames.
//!
//! A frame is a sequence number, a frame control and a frame id, then the parameters. Since EZSP 8
//! the frame control and the frame id take two bytes each (the extended format). Older NCPs only
//! know the legacy format, with one byte each, so the first command, `version`, is sent in that
//! format, which every NCP understands, and answered in it.

const std = @import("std");

/// The oldest EZSP version supported: the one EmberZNet 6.10 speaks, the firmware our ZBDongle-E
/// came with. Frames have the extended format since this version.
pub const min_version: u8 = 8;
/// The newest EZSP version supported: the newest that zigbee-herdsman v11.2.0 knows, whose frame
/// layouts ours follow. Layouts that differ between versions are kept apart.
pub const max_version: u8 = 19;

pub const FrameId = enum(u16) {
  version = 0x0000,
  add_endpoint = 0x0002,
  network_init = 0x0017,
  network_state = 0x0018,
  stack_status_handler = 0x0019,
  form_network = 0x001e,
  leave_network = 0x0020,
  permit_joining = 0x0022,
  trust_center_join_handler = 0x0024,
  get_eui64 = 0x0026,
  get_network_parameters = 0x0028,
  set_configuration_value = 0x0053,
  set_policy = 0x0055,
  invalid_command = 0x0058,
  set_initial_security_state = 0x0068,
  get_key = 0x006a,
  clear_transient_link_keys = 0x006b,
  add_transient_link_key = 0x00af,
  get_value = 0x00aa,
  set_value = 0x00ab,
  clear_key_table = 0x00b1,
  import_transient_key = 0x0111,
  export_key = 0x0114,
  get_network_key_info = 0x0116,
  _,
};

// Frame control, low byte.
const control_response: u8 = 0x80;
const control_async_callback: u8 = 0x10;
const control_truncated: u8 = 0x02;
// Frame control, high byte: the format version in bits 0 and 1, reserved bits 2 to 5.
const control_format_extended: u8 = 0x01;
const control_format_mask: u8 = 0x03;
const control_reserved_mask: u8 = 0x3c;

/// Longest parameters of a command. An EZSP frame fits an ASH DATA frame (220 bytes).
pub const max_parameters_len = 220 - 5;

/// Encodes a command in the extended format. `out` needs 5 bytes more than the parameters.
pub fn encode(out: []u8, sequence: u8, id: FrameId, parameters: []const u8) []u8 {
  std.debug.assert(parameters.len <= max_parameters_len);
  const header = [5]u8{
    sequence,
    // A command, for network 0, with the NCP free to sleep when idle.
    0x00,
    control_format_extended,
    @truncate(@backingInt(id)),
    @truncate(@backingInt(id) >> 8),
  };
  @memcpy(out[0..5], &header);
  @memcpy(out[5..][0..parameters.len], parameters);
  return out[0..5 + parameters.len];
}

/// Encodes `version` in the legacy format.
pub fn encodeLegacyVersion(out: *[4]u8, sequence: u8, desired_version: u8) []u8 {
  out.* = .{ sequence, 0x00, @backingInt(FrameId.version), desired_version };
  return out;
}

/// A response or callback from the NCP.
pub const Frame = struct {
  sequence: u8,
  id: FrameId,
  /// A callback the NCP sent by itself, rather than the response to a command.
  callback: bool,
  /// Points into the bytes decoded.
  parameters: []const u8,
};

pub const DecodeError = error{
  /// Shorter than its header.
  TooShort,
  /// The frame control says it goes from the host to the NCP.
  NotFromNcp,
  /// The NCP cut the response short: it did not fit.
  Truncated,
  /// Reserved bits of the frame control are set: a format we do not know.
  UnknownFormat,
};

pub fn decode(bytes: []const u8) DecodeError!Frame {
  if (bytes.len < 3) return error.TooShort;
  const extended = bytes.len >= 5 and bytes[2] & control_format_mask == control_format_extended;
  const control = bytes[1];
  if (control & control_response == 0) return error.NotFromNcp;
  if (control & control_truncated != 0) return error.Truncated;
  if (!extended) {
    return .{
      .sequence = bytes[0],
      .id = @fromBackingInt(@intCast(bytes[2])),
      .callback = control & control_async_callback != 0,
      .parameters = bytes[3..],
    };
  }
  if (bytes[2] & control_reserved_mask != 0) return error.UnknownFormat;
  return .{
    .sequence = bytes[0],
    .id = @fromBackingInt(@intCast(std.mem.readInt(u16, bytes[3..5], .little))),
    .callback = control & control_async_callback != 0,
    .parameters = bytes[5..],
  };
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}

test "the first version command uses the legacy format" {
  var out: [4]u8 = undefined;
  // As in the frame sent by zigbee-herdsman's tests (test/adapter/ember/consts.ts).
  try testing.expectEqualSlices(u8, &hex("0000000d"), encodeLegacyVersion(&out, 0, 13));
}

test "commands use the extended format" {
  var out: [5 + 1]u8 = undefined;
  try testing.expectEqualSlices(u8, &hex("02000100000d"), encode(&out, 2, .version, &.{ 13 }));
  try testing.expectEqualSlices(u8, &hex("030001aa0011"), encode(&out, 3, .get_value, &.{ 0x11 }));
}

test "decode the legacy version response" {
  // Recorded from a real NCP by zigbee-herdsman's tests: EZSP 13, EmberZNet 7.4.1.
  const frame = try decode(&hex("0080000d021074"));
  try testing.expectEqual(0, frame.sequence);
  try testing.expectEqual(FrameId.version, frame.id);
  try testing.expect(!frame.callback);
  try testing.expectEqualSlices(u8, &hex("0d021074"), frame.parameters);
}

test "decode extended responses and callbacks" {
  // Recorded by zigbee-herdsman's tests: a setPolicy response and a messageSentHandler callback.
  const response = try decode(&hex("4f8001550000000000"));
  try testing.expectEqual(0x4f, response.sequence);
  try testing.expectEqual(@as(FrameId, @fromBackingInt(@intCast(0x55))), response.id);
  try testing.expect(!response.callback);
  try testing.expectEqualSlices(u8, &hex("00000000"), response.parameters);

  const callback = try decode(&hex("2790013f000000000000dec9040106000101401100009a030000"));
  try testing.expect(callback.callback);
  try testing.expectEqual(@as(FrameId, @fromBackingInt(@intCast(0x3f))), callback.id);
}

test "reject frames that are not from the NCP, truncated, or of an unknown format" {
  try testing.expectError(error.TooShort, decode(&hex("0080")));
  try testing.expectError(error.NotFromNcp, decode(&hex("0000010000")));
  try testing.expectError(error.Truncated, decode(&hex("0082010000")));
  try testing.expectError(error.UnknownFormat, decode(&hex("0080050000")));
}

test "fuzz: decoding survives any frame" {
  try testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *testing.Smith) !void {
  var bytes: [220]u8 = undefined;
  const len = smith.slice(&bytes);
  _ = decode(bytes[0..len]) catch return;
}
