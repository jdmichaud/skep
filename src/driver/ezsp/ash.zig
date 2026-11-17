//! Frame codec of ASH (Asynchronous Serial Host), the serial link protocol between a host and a
//! Silicon Labs EmberZNet network co-processor (Silicon Labs UG101).
//!
//! A frame on the wire is a control byte, a data field, a CRC and a flag byte:
//!
//! - the CRC is CRC-CCITT over the control byte and the data field, sent high byte first;
//! - the data field of DATA frames is XORed with a pseudo-random sequence, so that long runs of
//!   identical bytes do not reach the line;
//! - reserved bytes (flag, escape, XON, XOFF, substitute, cancel) are escaped everywhere but in
//!   the final flag.
//!
//! This file only turns frames into bytes and back. Sequence numbers, acknowledgements and
//! retransmissions are the business of the link layer.

const std = @import("std");

/// Ends a frame.
pub const flag: u8 = 0x7e;
/// Escapes the next byte, which is sent XORed with 0x20.
pub const escape: u8 = 0x7d;
/// Software flow control: resume sending.
pub const xon: u8 = 0x11;
/// Software flow control: stop sending.
pub const xoff: u8 = 0x13;
/// Replaces a byte received with a framing or overrun error. The frame is then invalid.
pub const substitute: u8 = 0x18;
/// Cancels the frame being received.
pub const cancel: u8 = 0x1a;
/// Sent by the NCP between frames to wake the host. Ignored outside frames.
pub const wake: u8 = 0xff;

/// XOR mask of escaped bytes.
const flip: u8 = 0x20;

/// ASH protocol version, carried by RSTACK and ERROR frames.
pub const version: u8 = 2;

/// Shortest data field of a DATA frame: an EZSP frame of at least 3 bytes.
pub const min_data_len = 3;
/// Longest data field of a DATA frame.
pub const max_data_len = 220;
/// Longest frame before byte stuffing: control byte, data field and CRC.
const max_frame_len = 1 + max_data_len + 2;
/// Longest encoded frame: every byte escaped, plus the flag.
pub const max_encoded_len = 2 * max_frame_len + 1;

/// A decoded frame.
pub const Frame = union(enum) {
  /// Carries an EZSP frame.
  data: Data,
  /// Acknowledges DATA frames up to, but not including, `ack_number`.
  ack: Ack,
  /// Rejects the DATA frame numbered `ack_number`, asking for it again.
  nak: Ack,
  /// Asks the NCP to reset.
  rst,
  /// The NCP reset.
  rstack: Status,
  /// The NCP stopped because of an error.
  err: Status,

  pub const Data = struct {
    frame_number: u3,
    ack_number: u3,
    retransmitted: bool,
    /// The EZSP frame, in clear. When decoding, it points into the decoder and is valid until
    /// the next byte is fed.
    payload: []const u8,
  };

  pub const Ack = struct {
    ack_number: u3,
    /// The sender cannot receive DATA frames for now.
    not_ready: bool,
  };

  pub const Status = struct {
    version: u8,
    /// RSTACK: why the NCP reset. ERROR: what went wrong.
    code: u8,
  };
};

const control_rst: u8 = 0xc0;
const control_rstack: u8 = 0xc1;
const control_error: u8 = 0xc2;

/// CRC-CCITT: polynomial 0x1021, initial value 0xffff.
pub const Crc = struct {
  value: u16 = 0xffff,

  pub fn update(crc: *Crc, byte: u8) void {
    crc.value ^= @as(u16, byte) << 8;
    for (0..8) |_| {
      crc.value = if (crc.value & 0x8000 != 0) (crc.value << 1) ^ 0x1021 else crc.value << 1;
    }
  }

  pub fn compute(bytes: []const u8) u16 {
    var crc: Crc = .{};
    for (bytes) |byte| {
      crc.update(byte);
    }
    return crc.value;
  }
};

/// The pseudo-random sequence XORed with the data field of DATA frames. It restarts with every
/// frame, so applying it twice gives the data back.
pub const Randomizer = struct {
  state: u8 = 0x42,

  pub fn next(r: *Randomizer) u8 {
    const value = r.state;
    r.state = if (r.state & 1 == 0) r.state >> 1 else (r.state >> 1) ^ 0xb8;
    return value;
  }

  pub fn apply(data: []u8) void {
    var r: Randomizer = .{};
    for (data) |*byte| {
      byte.* ^= r.next();
    }
  }
};

fn isReserved(byte: u8) bool {
  return switch (byte) {
    flag, escape, xon, xoff, substitute, cancel => true,
    else => false,
  };
}

/// Appends bytes to a buffer, escaping reserved ones and keeping the CRC up to date.
const Writer = struct {
  out: []u8,
  len: usize = 0,
  crc: Crc = .{},

  fn put(w: *Writer, byte: u8) error{ NoSpaceLeft }!void {
    if (w.len == w.out.len) return error.NoSpaceLeft;
    w.out[w.len] = byte;
    w.len += 1;
  }

  fn putStuffed(w: *Writer, byte: u8) error{ NoSpaceLeft }!void {
    if (isReserved(byte)) {
      try w.put(escape);
      try w.put(byte ^ flip);
    } else {
      try w.put(byte);
    }
  }

  /// A byte covered by the CRC.
  fn putField(w: *Writer, byte: u8) error{ NoSpaceLeft }!void {
    w.crc.update(byte);
    try w.putStuffed(byte);
  }

  fn finish(w: *Writer) error{ NoSpaceLeft }![]u8 {
    const crc = w.crc.value;
    try w.putStuffed(@intCast(crc >> 8));
    try w.putStuffed(@truncate(crc));
    try w.put(flag);
    return w.out[0..w.len];
  }
};

pub const EncodeError = error{
  /// The data field of a DATA frame is shorter than `min_data_len` or longer than `max_data_len`.
  InvalidLength,
  NoSpaceLeft,
};

/// Encodes a frame into `out` and returns the bytes to send. `max_encoded_len` bytes are always
/// enough. A host sends a cancel byte before RST, to flush what the NCP may have received; that
/// byte is not part of the frame.
pub fn encode(frame: Frame, out: []u8) EncodeError![]u8 {
  var w: Writer = .{ .out = out };
  switch (frame) {
    .data => |data| {
      if (data.payload.len < min_data_len or data.payload.len > max_data_len) {
        return error.InvalidLength;
      }
      try w.putField(
        @as(u8, data.frame_number) << 4 |
          @as(u8, @intFromBool(data.retransmitted)) << 3 |
          data.ack_number,
      );
      var r: Randomizer = .{};
      for (data.payload) |byte| {
        try w.putField(byte ^ r.next());
      }
    },
    .ack, .nak => |ack| {
      const kind: u8 = if (frame == .ack) 0x80 else 0xa0;
      try w.putField(kind | @as(u8, @intFromBool(ack.not_ready)) << 3 | ack.ack_number);
    },
    .rst => try w.putField(control_rst),
    .rstack, .err => |status| {
      try w.putField(if (frame == .rstack) control_rstack else control_error);
      try w.putField(status.version);
      try w.putField(status.code);
    },
  }
  return w.finish();
}

/// Why a received frame was dropped.
pub const Invalid = enum {
  /// The CRC does not match.
  bad_crc,
  /// Shorter than a control byte and a CRC.
  too_short,
  /// Longer than the longest frame.
  too_long,
  /// The data field length does not fit the frame type.
  bad_length,
  /// Unknown control byte.
  bad_control,
  /// A byte arrived with a framing or overrun error (substitute byte).
  substituted,
  /// An escape byte was followed by the flag or by another escape.
  bad_escape,
};

/// What feeding a byte to the decoder produced.
pub const Event = union(enum) {
  frame: Frame,
  invalid: Invalid,
};

/// Turns received bytes back into frames, one byte at a time.
pub const Decoder = struct {
  /// Unescaped bytes of the frame being received: control byte, data field and CRC.
  buf: [max_frame_len]u8 = undefined,
  len: usize = 0,
  escaped: bool = false,
  /// The frame being received is already known to be invalid; it is reported at its flag.
  failed: ?Invalid = null,

  /// Feeds one received byte. Returns an event when the byte ends a frame.
  pub fn feed(d: *Decoder, byte: u8) ?Event {
    switch (byte) {
      flag => return d.endFrame(),
      cancel => {
        d.reset();
        return null;
      },
      substitute => {
        d.fail(.substituted);
        return null;
      },
      // Flow control is handled by whoever writes; these never appear inside a frame.
      xon, xoff => return null,
      escape => {
        if (d.escaped) {
          d.fail(.bad_escape);
        } else {
          d.escaped = true;
        }
        return null;
      },
      else => {},
    }
    if (byte == wake and d.len == 0 and !d.escaped and d.failed == null) return null;
    const value = if (d.escaped) byte ^ flip else byte;
    d.escaped = false;
    if (d.failed != null) return null;
    if (d.len == d.buf.len) {
      d.fail(.too_long);
      return null;
    }
    d.buf[d.len] = value;
    d.len += 1;
    return null;
  }

  fn reset(d: *Decoder) void {
    d.len = 0;
    d.escaped = false;
    d.failed = null;
  }

  fn fail(d: *Decoder, reason: Invalid) void {
    if (d.failed == null) {
      d.failed = reason;
    }
  }

  fn endFrame(d: *Decoder) ?Event {
    defer d.reset();
    if (d.escaped) {
      d.fail(.bad_escape);
    }
    if (d.failed) |reason| return .{ .invalid = reason };
    // Consecutive flags delimit nothing.
    if (d.len == 0) return null;
    if (d.len < 3) return .{ .invalid = .too_short };

    const body = d.buf[0..d.len - 2];
    const crc = std.mem.readInt(u16, d.buf[d.len - 2..][0..2], .big);
    if (Crc.compute(body) != crc) return .{ .invalid = .bad_crc };

    const control = body[0];
    const field = body[1..];
    if (control & 0x80 == 0) {
      if (field.len < min_data_len or field.len > max_data_len) return .{ .invalid = .bad_length };
      Randomizer.apply(field);
      return .{
        .frame = .{
          .data = .{
            .frame_number = @intCast(control >> 4 & 0x07),
            .ack_number = @intCast(control & 0x07),
            .retransmitted = control & 0x08 != 0,
            .payload = field,
          },
        },
      };
    }
    const ack: Frame.Ack = .{
      .ack_number = @intCast(control & 0x07),
      .not_ready = control & 0x08 != 0,
    };
    const frame: Frame = switch (control & 0xe0) {
      0x80 => .{ .ack = ack },
      0xa0 => .{ .nak = ack },
      else => switch (control) {
        control_rst => .rst,
        control_rstack => if (field.len == 2)
          .{ .rstack = .{ .version = field[0], .code = field[1] } }
        else
          return .{ .invalid = .bad_length },
        control_error => if (field.len == 2)
          .{ .err = .{ .version = field[0], .code = field[1] } }
        else
          return .{ .invalid = .bad_length },
        else => return .{ .invalid = .bad_control },
      },
    };
    if ((frame == .ack or frame == .nak or frame == .rst) and field.len != 0) {
      return .{ .invalid = .bad_length };
    }
    return .{ .frame = frame };
  }
};

// Tests. The byte sequences come from frames exchanged with real NCPs, recorded in the
// zigbee-herdsman test suite (test/adapter/ember/consts.ts, MIT licensed).

const testing = std.testing;

const hex = @import("test_ncp.zig").hex;

fn expectEncoded(frame: Frame, comptime expected: []const u8) !void {
  var out: [max_encoded_len]u8 = undefined;
  try testing.expectEqualSlices(u8, &hex(expected), try encode(frame, &out));
}

/// Feeds all bytes and returns the last event.
fn decodeAll(d: *Decoder, bytes: []const u8) ?Event {
  var last: ?Event = null;
  for (bytes) |byte| {
    if (d.feed(byte)) |event| {
      last = event;
    }
  }
  return last;
}

fn expectDecodedData(
  comptime wire: []const u8,
  frame_number: u3,
  ack_number: u3,
  comptime payload: []const u8,
) !void {
  var d: Decoder = .{};
  const event = decodeAll(&d, &hex(wire)) orelse return error.TestExpectedFrame;
  const data = event.frame.data;
  try testing.expectEqual(frame_number, data.frame_number);
  try testing.expectEqual(ack_number, data.ack_number);
  try testing.expect(!data.retransmitted);
  try testing.expectEqualSlices(u8, &hex(payload), data.payload);
}

test "CRC" {
  try testing.expectEqual(0x38bc, Crc.compute(&.{ control_rst }));
  try testing.expectEqual(0x7078, Crc.compute(&.{ 0x80 }));
  // CRC-CCITT check value.
  try testing.expectEqual(0x29b1, Crc.compute("123456789"));
}

test "pseudo-random sequence" {
  var r: Randomizer = .{};
  const expected = [_]u8{ 0x42, 0x21, 0xa8, 0x54, 0x2a, 0x15, 0xb2, 0x59, 0x94, 0x4a };
  for (expected) |byte| {
    try testing.expectEqual(byte, r.next());
  }
}

test "encode control frames" {
  try expectEncoded(.rst, "c038bc7e");
  try expectEncoded(.{ .ack = .{ .ack_number = 0, .not_ready = false } }, "8070787e");
  try expectEncoded(.{ .ack = .{ .ack_number = 1, .not_ready = false } }, "8160597e");
}

test "encode the EZSP version command" {
  // version(13) in the legacy EZSP frame format: sequence 0, frame control 0, frame id 0.
  try expectEncoded(
    .{
      .data = .{
        .frame_number = 0,
        .ack_number = 0,
        .retransmitted = false,
        .payload = &.{ 0x00, 0x00, 0x00, 0x0d },
      },
    },
    "004221a8597c057e",
  );
}

test "decode RSTACK after a cancel byte" {
  var d: Decoder = .{};
  const event = decodeAll(&d, &hex("1ac1020b0a527e")).?;
  // Reset code 0x0b: software reset.
  try testing.expectEqual(Frame.Status{ .version = version, .code = 0x0b }, event.frame.rstack);
}

test "decode ERROR" {
  var d: Decoder = .{};
  const event = decodeAll(&d, &hex("c20251a8bd7e")).?;
  // Error 0x51: too many ACK timeouts.
  try testing.expectEqual(Frame.Status{ .version = version, .code = 0x51 }, event.frame.err);
}

test "decode the EZSP version response" {
  // Protocol version 13, stack type 2, stack version 0x7410 (EmberZNet 7.4.1).
  try expectDecodedData("0142a1a8592805c6a8777e", 0, 1, "0080000d021074");
}

test "decode frames with escaped bytes" {
  try expectDecodedData(
    "1065b1a96b2a15b259944afb6351934f9c4f26ebfcce677d31fec66357897e",
    1,
    0,
    "2790013f000000000000dec9040106000101401100009a030000",
  );
  try expectDecodedData(
    "2065b1a97d312a15b658924a24ab5593499c3ef962edce678bfdc6638903813ca7edcdde6f8ae7c3d0d5d26b68937e",
    2,
    0,
    "2790014500000401060001010001000070dec90000000000000000ffff0300060000000518040b000002",
  );
}

test "reject a frame with a bad CRC" {
  var d: Decoder = .{};
  const wire = hex("b658904124ab5593499cdd93623cd29874f5de5083f97b1e66efc9af417e");
  try testing.expectEqual(Event{ .invalid = .bad_crc }, decodeAll(&d, &wire).?);
}

test "reject malformed frames" {
  var d: Decoder = .{};
  try testing.expectEqual(Event{ .invalid = .too_short }, decodeAll(&d, &.{ 0x80, 0x70, flag }).?);
  try testing.expectEqual(
    Event{ .invalid = .substituted },
    decodeAll(&d, &.{ 0x80, substitute, 0x70, 0x78, flag }).?,
  );
  try testing.expectEqual(
    Event{ .invalid = .bad_escape },
    decodeAll(&d, &.{ 0x80, escape, flag }).?,
  );
  var long: [max_frame_len + 2]u8 = @splat(0x00);
  long[long.len - 1] = flag;
  try testing.expectEqual(Event{ .invalid = .too_long }, decodeAll(&d, &long).?);
  // The decoder recovers after each of them.
  try testing.expectEqual(@as(Frame, .rst), decodeAll(&d, &hex("c038bc7e")).?.frame);
}

test "ignore cancelled frames, flow control, wake bytes and repeated flags" {
  var d: Decoder = .{};
  try testing.expectEqual(null, decodeAll(&d, &.{ 0x80, 0x70, cancel, flag, flag, wake, xon }));
  const event = decodeAll(&d, &.{ 0x80, xoff, 0x70, 0x78, flag }).?;
  try testing.expectEqual(Frame.Ack{ .ack_number = 0, .not_ready = false }, event.frame.ack);
}

test "encoding rejects data fields of invalid length" {
  var out: [max_encoded_len]u8 = undefined;
  const data: Frame.Data = .{
    .frame_number = 0,
    .ack_number = 0,
    .retransmitted = false,
    .payload = &.{ 0 },
  };
  try testing.expectError(error.InvalidLength, encode(.{ .data = data }, &out));
}

test "fuzz: the decoder survives any input" {
  try testing.fuzz({}, fuzzDecoder, .{});
}

fn fuzzDecoder(_: void, smith: *testing.Smith) !void {
  var input: [2 * max_encoded_len]u8 = undefined;
  const len = smith.slice(&input);
  var d: Decoder = .{};
  for (input[0..len]) |byte| {
    const event = d.feed(byte) orelse continue;
    switch (event) {
      .frame => |frame| if (frame == .data) {
        try testing.expect(frame.data.payload.len >= min_data_len);
        try testing.expect(frame.data.payload.len <= max_data_len);
      },
      .invalid => {},
    }
  }
}

test "fuzz: decoding gives back what was encoded" {
  try testing.fuzz({}, fuzzRoundTrip, .{});
}

fn fuzzRoundTrip(_: void, smith: *testing.Smith) !void {
  var payload: [max_data_len]u8 = undefined;
  const frame: Frame = switch (smith.value(enum { data, ack, nak, rst, rstack, err })) {
    .data => frame: {
      const len = smith.valueRangeAtMost(u8, min_data_len, max_data_len);
      smith.bytes(payload[0..len]);
      break :frame .{
        .data = .{
          .frame_number = smith.value(u3),
          .ack_number = smith.value(u3),
          .retransmitted = smith.value(bool),
          .payload = payload[0..len],
        },
      };
    },
    .ack => .{ .ack = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) } },
    .nak => .{ .nak = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) } },
    .rst => .rst,
    .rstack => .{ .rstack = .{ .version = smith.value(u8), .code = smith.value(u8) } },
    .err => .{ .err = .{ .version = smith.value(u8), .code = smith.value(u8) } },
  };
  var out: [max_encoded_len]u8 = undefined;
  const wire = try encode(frame, &out);
  // Only the final byte is a flag: everything else is escaped.
  try testing.expectEqual(null, std.mem.indexOfScalar(u8, wire[0..wire.len - 1], flag));

  var d: Decoder = .{};
  const event = decodeAll(&d, wire) orelse return error.TestExpectedFrame;
  const decoded = switch (event) {
    .frame => |decoded| decoded,
    .invalid => |reason| {
      std.debug.print("encoded frame decoded as invalid: {t}\n", .{ reason });
      return error.TestUnexpectedInvalidFrame;
    },
  };
  try testing.expectEqual(std.meta.activeTag(frame), std.meta.activeTag(decoded));
  switch (frame) {
    .data => |data| {
      try testing.expectEqual(data.frame_number, decoded.data.frame_number);
      try testing.expectEqual(data.ack_number, decoded.data.ack_number);
      try testing.expectEqual(data.retransmitted, decoded.data.retransmitted);
      try testing.expectEqualSlices(u8, data.payload, decoded.data.payload);
    },
    .ack => |ack| try testing.expectEqual(ack, decoded.ack),
    .nak => |nak| try testing.expectEqual(nak, decoded.nak),
    .rst => {},
    .rstack => |status| try testing.expectEqual(status, decoded.rstack),
    .err => |status| try testing.expectEqual(status, decoded.err),
  }
}
