//! ASH link layer, host side (Silicon Labs UG101): resets the NCP, then carries EZSP frames to and
//! from it reliably, with frame numbers, acknowledgements and retransmissions.
//!
//! Like the rest of libskep it does no I/O: the caller passes the bytes it reads and the time, and
//! writes the bytes the link produces. Timers start when bytes are written, so the caller reports
//! writes with `outputDone`.
//!
//! The behaviour follows zigbee-herdsman's port of the EmberZNet host (src/adapter/ember/uart/ash.ts,
//! MIT licensed), which works with real dongles, including its timer values. Two differences: the
//! host never tells the NCP it is not ready, and rejects a DATA frame it has no room for instead;
//! and software flow control (XON/XOFF) is handled here, not by the operating system.

const std = @import("std");
const ash = @import("ash.zig");

/// Most DATA frames sent and not yet acknowledged (1 to 7).
pub const window = 3;
/// How long the NCP has to answer a reset with RSTACK, in milliseconds.
pub const reset_timeout = 5000;
/// Bounds of the adaptive acknowledgement timeout, in milliseconds.
pub const ack_timeout_initial = 800;
pub const ack_timeout_min = 400;
pub const ack_timeout_max = 2400;
/// Consecutive acknowledgement timeouts after which the link fails.
pub const max_timeouts = 6;
/// How long the NCP may hold the output with XOFF while frames wait, in milliseconds: it sends
/// XON once its buffer drains, which takes milliseconds.
pub const max_pause = 5000;
/// Received EZSP frames the link holds until the caller takes them.
pub const receive_slots = 8;

/// Reset code of an RSTACK answering a RST frame.
pub const reset_software: u8 = 0x0b;

/// Why the link is down.
pub const Failure = union(enum) {
  /// No RSTACK within `reset_timeout`.
  reset_timeout,
  /// The NCP speaks another ASH version.
  version: u8,
  /// The NCP sent an ERROR frame, with this code.
  ncp_error: u8,
  /// The NCP reset by itself, for this reason.
  ncp_reset: u8,
  /// `max_timeouts` acknowledgement timeouts in a row.
  ack_timeouts,
  /// XOFF, then no XON within `max_pause`, while frames waited.
  paused,
};

pub const Event = union(enum) {
  /// The NCP answered the reset: EZSP frames can be sent.
  connected,
  /// An EZSP frame from the NCP. Valid until the next call to `input`.
  frame: []const u8,
  /// The link is down. `reset` starts it again.
  failed: Failure,
  /// XON or XOFF arrived although software flow control was not expected: the firmware and the
  /// serial settings disagree. Reported once per reset. The link honours them anyway.
  unexpected_flow_control,
};

pub const Options = struct {
  /// Whether the NCP is expected to use XON/XOFF.
  software_flow_control: bool,
};

pub const SendError = error{
  /// The link is not connected.
  NotConnected,
  /// Shorter than `ash.min_data_len` or longer than `ash.max_data_len`.
  InvalidLength,
  /// Too many frames waiting to be sent or acknowledged.
  QueueFull,
};

const Payload = struct {
  len: u8 = 0,
  data: [ash.max_data_len]u8 = undefined,

  fn set(p: *Payload, bytes: []const u8) void {
    @memcpy(p.data[0..bytes.len], bytes);
    p.len = @intCast(bytes.len);
  }

  fn slice(p: *const Payload) []const u8 {
    return p.data[0..p.len];
  }
};

/// Whether `x` is in the circular range from `low` to `high`, both included.
fn within(low: u3, x: u3, high: u3) bool {
  return x -% low <= high -% low;
}

pub const Link = struct {
  options: Options,
  state: enum { idle, resetting, connected, failed } = .idle,
  decoder: ash.Decoder = .{},

  /// Bytes to write: from `out_start` to `out_end`. A new frame is encoded only once the previous
  /// one is written.
  out: [1 + ash.max_encoded_len]u8 = undefined,
  out_start: usize = 0,
  out_end: usize = 0,
  /// XOFF received: output waits for XON.
  paused: bool = false,
  /// When the last XOFF came.
  paused_at: u64 = 0,

  // Frames to send, in order of priority.
  send_cancel: bool = false,
  send_rst: bool = false,
  send_nak: bool = false,
  send_ack: bool = false,

  /// Next DATA frame number to send.
  frm_tx: u3 = 0,
  /// Oldest DATA frame sent and not acknowledged; equal to `frm_tx` when there is none.
  ack_rx: u3 = 0,
  /// Next DATA frame to send again, while retransmitting.
  frm_retx: u3 = 0,
  retransmitting: bool = false,
  /// Next DATA frame number expected from the NCP.
  frm_rx: u3 = 0,
  /// Acknowledgement number last sent to the NCP.
  ack_tx: u3 = 0,
  /// A frame was rejected with a NAK; no other NAK until a frame is accepted.
  rejecting: bool = false,

  /// Payloads of the DATA frames sent and not acknowledged, then of those waiting to be sent,
  /// indexed by frame number.
  tx: [8]Payload = @splat(.{}),
  queued: u3 = 0,

  /// When the running timer started: the reset timer while resetting, the acknowledgement timer
  /// when connected.
  timer_started: ?u64 = null,
  /// Start the timer when the output is written.
  timer_on_write: bool = false,
  ack_timeout: u32 = ack_timeout_initial,
  timeouts: u8 = 0,

  received: [receive_slots]Payload = @splat(.{}),
  received_head: usize = 0,
  received_count: usize = 0,
  connected_pending: bool = false,
  failure_pending: ?Failure = null,
  flow_control_pending: bool = false,
  flow_control_reported: bool = false,
  /// XON and XOFF bytes received since the last reset.
  flow_control_bytes: u32 = 0,

  pub fn init(options: Options) Link {
    return .{ .options = options };
  }

  /// Resets the NCP, dropping everything in progress: a cancel byte and RST are sent, and the link
  /// is connected when the NCP answers with RSTACK.
  pub fn reset(link: *Link) void {
    const options = link.options;
    link.* = .{ .options = options, .state = .resetting, .send_cancel = true, .send_rst = true };
    link.fill();
  }

  /// Queues an EZSP frame for the NCP. The payload is copied.
  pub fn send(link: *Link, payload: []const u8) SendError!void {
    if (link.state != .connected) return error.NotConnected;
    if (payload.len < ash.min_data_len or payload.len > ash.max_data_len) {
      return error.InvalidLength;
    }
    // Payloads are indexed by frame number: 8 slots, and the oldest unacknowledged must survive.
    if (@as(u4, link.frm_tx -% link.ack_rx) + link.queued >= 7) return error.QueueFull;
    link.tx[link.frm_tx +% link.queued].set(payload);
    link.queued += 1;
    link.fill();
  }

  /// Bytes read from the NCP, at time `now` (milliseconds).
  pub fn input(link: *Link, bytes: []const u8, now: u64) void {
    for (bytes) |byte| {
      if (byte == ash.xon or byte == ash.xoff) {
        link.paused = byte == ash.xoff;
        if (link.paused) {
          link.paused_at = now;
        }
        link.flow_control_bytes +|= 1;
        if (!link.options.software_flow_control and !link.flow_control_reported) {
          link.flow_control_reported = true;
          link.flow_control_pending = true;
        }
        continue;
      }
      const event = link.decoder.feed(byte) orelse continue;
      switch (event) {
        .frame => |frame| link.receive(frame, now),
        .invalid => link.reject(),
      }
    }
    link.fill();
  }

  /// Bytes waiting to be written. Empty while the NCP holds the output with XOFF.
  pub fn output(link: *const Link) []const u8 {
    if (link.paused) return &.{};
    return link.out[link.out_start..link.out_end];
  }

  /// The first `len` bytes of `output()` were written at time `now`.
  pub fn outputDone(link: *Link, len: usize, now: u64) void {
    std.debug.assert(len <= link.out_end - link.out_start);
    link.out_start += len;
    if (link.out_start < link.out_end) return;
    link.out_start = 0;
    link.out_end = 0;
    if (link.timer_on_write) {
      link.timer_on_write = false;
      if (link.timer_started == null) {
        link.timer_started = now;
      }
    }
    link.fill();
  }

  /// When `advance` must next be called, if a timer is running.
  pub fn nextDeadline(link: *const Link) ?u64 {
    const timer = link.timerDeadline() orelse return link.pauseDeadline();
    const pause = link.pauseDeadline() orelse return timer;
    return @min(timer, pause);
  }

  fn timerDeadline(link: *const Link) ?u64 {
    const started = link.timer_started orelse return null;
    return switch (link.state) {
      .resetting => started + reset_timeout,
      .connected => started + link.ack_timeout,
      .idle, .failed => null,
    };
  }

  /// While XOFF holds output back, until when it may: no frame is sent, so no acknowledgement
  /// is due, and only this ends a pause that does not.
  fn pauseDeadline(link: *const Link) ?u64 {
    if (!link.paused or link.out_start == link.out_end) return null;
    return switch (link.state) {
      .resetting, .connected => link.paused_at + max_pause,
      .idle, .failed => null,
    };
  }

  /// Runs the timers due at time `now`.
  pub fn advance(link: *Link, now: u64) void {
    if (link.pauseDeadline()) |deadline| {
      if (now >= deadline) return link.fail(.paused);
    }
    const deadline = link.timerDeadline() orelse return;
    if (now < deadline) return;
    switch (link.state) {
      .resetting => link.fail(.reset_timeout),
      .connected => {
        const expected = if (link.retransmitting) link.frm_retx else link.frm_tx;
        if (link.ack_rx == expected) {
          link.timer_started = null;
        } else {
          link.ack_timeout = @min(2 * link.ack_timeout, ack_timeout_max);
          link.timer_started = null;
          link.timeouts += 1;
          if (link.timeouts >= max_timeouts) return link.fail(.ack_timeouts);
          link.startRetransmission();
        }
      },
      .idle, .failed => unreachable,
    }
    link.fill();
  }

  /// The next thing that happened, if any.
  pub fn nextEvent(link: *Link) ?Event {
    if (link.connected_pending) {
      link.connected_pending = false;
      return .connected;
    }
    if (link.flow_control_pending) {
      link.flow_control_pending = false;
      return .unexpected_flow_control;
    }
    if (link.received_count > 0) {
      const slot = &link.received[link.received_head];
      link.received_head = (link.received_head + 1) % receive_slots;
      link.received_count -= 1;
      return .{ .frame = slot.slice() };
    }
    if (link.failure_pending) |failure| {
      link.failure_pending = null;
      return .{ .failed = failure };
    }
    return null;
  }

  fn fail(link: *Link, failure: Failure) void {
    link.state = .failed;
    link.failure_pending = failure;
    link.timer_started = null;
    link.timer_on_write = false;
    link.out_start = 0;
    link.out_end = 0;
  }

  fn receive(link: *Link, frame: ash.Frame, now: u64) void {
    switch (link.state) {
      .idle, .failed => {},
      .resetting => switch (frame) {
        .rstack => |status| {
          if (status.version != ash.version) return link.fail(.{ .version = status.version });
          // An RSTACK for another reason, such as power-on, does not answer our RST.
          if (status.code != reset_software) return;
          link.state = .connected;
          link.timer_started = null;
          link.timer_on_write = false;
          link.ack_timeout = ack_timeout_initial;
          link.send_ack = true;
          link.connected_pending = true;
        },
        // Frames sent before the NCP reset.
        else => {},
      },
      .connected => {
        const ack_number: ?u3 = switch (frame) {
          .data => |data| data.ack_number,
          .ack, .nak => |ack| ack.ack_number,
          .rst, .rstack, .err => null,
        };
        if (ack_number) |number| {
          if (!within(link.ack_rx, number, link.frm_tx)) return link.reject();
          if (number != link.ack_rx) {
            link.acknowledged(number, now);
          }
        }
        switch (frame) {
          .data => |data| link.receiveData(data),
          .ack => {},
          .nak => link.startRetransmission(),
          // Only a host sends RST.
          .rst => link.reject(),
          .rstack => |status| link.fail(.{ .ncp_reset = status.code }),
          .err => |status| link.fail(.{ .ncp_error = status.code }),
        }
      },
    }
  }

  /// The NCP acknowledged the frames before `number`.
  fn acknowledged(link: *Link, number: u3, now: u64) void {
    link.ack_rx = number;
    link.timeouts = 0;
    if (link.retransmitting) {
      link.timer_started = if (number != link.frm_retx) now else null;
      return;
    }
    if (link.timer_started) |started| {
      // T = 7/8 T + 1/2 elapsed (UG101), within bounds.
      const elapsed: u64 = @min(now -| started, ack_timeout_max);
      const adapted = (7 * @as(u64, link.ack_timeout) + 4 * elapsed) / 8;
      link.ack_timeout = @intCast(std.math.clamp(adapted, ack_timeout_min, ack_timeout_max));
    }
    link.timer_started = if (number != link.frm_tx) now else null;
  }

  fn receiveData(link: *Link, data: ash.Frame.Data) void {
    if (data.frame_number != link.frm_rx) {
      // A copy of a frame already received: acknowledge it again.
      if (data.retransmitted) {
        link.send_ack = true;
      } else {
        link.reject();
      }
      return;
    }
    if (link.received_count == receive_slots) return link.reject();
    if (data.retransmitted) {
      link.send_ack = true;
    }
    link.rejecting = false;
    link.send_nak = false;
    link.frm_rx +%= 1;
    link.received[(link.received_head + link.received_count) % receive_slots].set(data.payload);
    link.received_count += 1;
  }

  /// Asks the NCP to send its frames again, once until a frame is accepted.
  fn reject(link: *Link) void {
    if (link.state != .connected or link.rejecting) return;
    link.rejecting = true;
    link.send_nak = true;
  }

  fn startRetransmission(link: *Link) void {
    if (link.retransmitting or link.ack_rx == link.frm_tx) return;
    link.timer_started = null;
    link.frm_retx = link.ack_rx;
    link.retransmitting = true;
    // Cancels the frame the NCP may be receiving.
    link.send_cancel = true;
  }

  /// Encodes the next frame to send, if the previous one is written.
  fn fill(link: *Link) void {
    if (link.out_end != 0) return;
    if (link.state != .resetting and link.state != .connected) return;
    if (link.retransmitting) {
      if (within(link.frm_retx, link.ack_rx, link.frm_tx)) {
        link.frm_retx = link.ack_rx;
      }
      if (link.frm_retx == link.frm_tx) {
        link.retransmitting = false;
      }
    }
    if (link.send_cancel) {
      link.send_cancel = false;
      link.out[0] = ash.cancel;
      link.out_end = 1;
    }
    if (link.send_rst) {
      link.send_rst = false;
      link.put(.rst);
      link.timer_on_write = true;
      return;
    }
    if (link.state != .connected) return;
    const acknowledgement: ash.Frame.Ack = .{ .ack_number = link.frm_rx, .not_ready = false };
    if (link.send_nak) {
      link.send_nak = false;
      link.send_ack = false;
      link.put(.{ .nak = acknowledgement });
    } else if (link.send_ack or link.ack_tx != link.frm_rx) {
      link.send_ack = false;
      link.put(.{ .ack = acknowledgement });
    } else if (link.retransmitting) {
      link.putData(link.frm_retx, true);
      link.frm_retx +%= 1;
    } else if (link.queued > 0 and link.frm_tx -% link.ack_rx < window) {
      link.putData(link.frm_tx, false);
      link.frm_tx +%= 1;
      link.queued -= 1;
    } else {
      return;
    }
    link.ack_tx = link.frm_rx;
  }

  fn putData(link: *Link, number: u3, retransmitted: bool) void {
    link.put(.{
      .data = .{
        .frame_number = number,
        .ack_number = link.frm_rx,
        .retransmitted = retransmitted,
        .payload = link.tx[number].slice(),
      },
    });
    if (link.timer_started == null) {
      link.timer_on_write = true;
    }
  }

  fn put(link: *Link, frame: ash.Frame) void {
    // `out` holds a cancel byte and the longest frame, and payloads were checked by `send`.
    const encoded = ash.encode(frame, link.out[link.out_end..]) catch unreachable;
    link.out_end += encoded.len;
  }
};

// Tests: the link against a scripted NCP, built from the frame codec.

const testing = std.testing;

/// The NCP side of the tests: decodes what the host writes and encodes what the NCP answers.
const Ncp = struct {
  link: *Link,
  now: u64 = 0,

  /// Writes all the host's output and returns the frames in it.
  fn take(ncp: *Ncp, frames: []ash.Frame, payloads: [][ash.max_data_len]u8) ![]ash.Frame {
    var count: usize = 0;
    var decoder: ash.Decoder = .{};
    while (true) {
      const bytes = ncp.link.output();
      if (bytes.len == 0) break;
      for (bytes) |byte| {
        const event = decoder.feed(byte) orelse continue;
        var frame = event.frame;
        if (frame == .data) {
          @memcpy(payloads[count][0..frame.data.payload.len], frame.data.payload);
          frame.data.payload = payloads[count][0..frame.data.payload.len];
        }
        frames[count] = frame;
        count += 1;
      }
      ncp.link.outputDone(bytes.len, ncp.now);
    }
    return frames[0..count];
  }

  fn expectFrames(ncp: *Ncp, expected: []const ash.Frame) !void {
    var frames: [16]ash.Frame = undefined;
    var payloads: [16][ash.max_data_len]u8 = undefined;
    const got = try ncp.take(&frames, &payloads);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
      try testing.expectEqual(std.meta.activeTag(e), std.meta.activeTag(g));
      switch (e) {
        .data => |data| {
          try testing.expectEqual(data.frame_number, g.data.frame_number);
          try testing.expectEqual(data.ack_number, g.data.ack_number);
          try testing.expectEqual(data.retransmitted, g.data.retransmitted);
          try testing.expectEqualSlices(u8, data.payload, g.data.payload);
        },
        .ack => |ack| try testing.expectEqual(ack, g.ack),
        .nak => |nak| try testing.expectEqual(nak, g.nak),
        .rst => {},
        .rstack => |status| try testing.expectEqual(status, g.rstack),
        .err => |status| try testing.expectEqual(status, g.err),
      }
    }
  }

  fn expectSilence(ncp: *Ncp) !void {
    try testing.expectEqual(0, ncp.link.output().len);
  }

  fn send(ncp: *Ncp, frame: ash.Frame) void {
    var out: [ash.max_encoded_len]u8 = undefined;
    ncp.link.input(ash.encode(frame, &out) catch unreachable, ncp.now);
  }

  fn sendData(ncp: *Ncp, frame_number: u3, ack_number: u3, payload: []const u8) void {
    ncp.send(.{
      .data = .{
        .frame_number = frame_number,
        .ack_number = ack_number,
        .retransmitted = false,
        .payload = payload,
      },
    });
  }

  fn advanceTo(ncp: *Ncp, now: u64) void {
    ncp.now = now;
    ncp.link.advance(now);
  }

  fn expectEvent(ncp: *Ncp, expected: Event) !void {
    const event = ncp.link.nextEvent() orelse return error.TestExpectedEvent;
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(event));
    switch (expected) {
      .frame => |payload| try testing.expectEqualSlices(u8, payload, event.frame),
      .failed => |failure| try testing.expectEqual(failure, event.failed),
      .connected, .unexpected_flow_control => {},
    }
  }

  fn expectNoEvent(ncp: *Ncp) !void {
    try testing.expectEqual(null, ncp.link.nextEvent());
  }
};

fn dataFrame(frame_number: u3, ack_number: u3, retransmitted: bool, payload: []const u8) ash.Frame {
  return .{
    .data = .{
      .frame_number = frame_number,
      .ack_number = ack_number,
      .retransmitted = retransmitted,
      .payload = payload,
    },
  };
}

fn ackFrame(number: u3) ash.Frame {
  return .{ .ack = .{ .ack_number = number, .not_ready = false } };
}

fn nakFrame(number: u3) ash.Frame {
  return .{ .nak = .{ .ack_number = number, .not_ready = false } };
}

const rstack_software: ash.Frame = .{
  .rstack = .{ .version = ash.version, .code = reset_software },
};

/// A link connected to `ncp` at time 0, its first ACK taken.
fn connected(link: *Link) !Ncp {
  link.* = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .link = link };
  link.reset();
  try ncp.expectFrames(&.{ .rst });
  ncp.send(rstack_software);
  try ncp.expectEvent(.connected);
  try ncp.expectFrames(&.{ ackFrame(0) });
  return ncp;
}

test "a reset sends a cancel byte and RST, and RSTACK connects" {
  var link: Link = .init(.{ .software_flow_control = true });
  link.reset();
  try testing.expectEqualSlices(u8, &.{ ash.cancel, 0xc0, 0x38, 0xbc, ash.flag }, link.output());
  try testing.expectEqual(null, link.nextDeadline());
  link.outputDone(link.output().len, 100);
  try testing.expectEqual(100 + reset_timeout, link.nextDeadline());

  var ncp: Ncp = .{ .link = &link, .now = 1100 };
  ncp.send(rstack_software);
  try ncp.expectEvent(.connected);
  try ncp.expectNoEvent();
  try testing.expectEqual(null, link.nextDeadline());
  try ncp.expectFrames(&.{ ackFrame(0) });
}

test "an RSTACK for another reason does not answer the reset" {
  var link: Link = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .link = &link };
  link.reset();
  try ncp.expectFrames(&.{ .rst });
  // Power-on.
  ncp.send(.{ .rstack = .{ .version = ash.version, .code = 0x02 } });
  try ncp.expectNoEvent();
  ncp.send(rstack_software);
  try ncp.expectEvent(.connected);
}

test "the reset fails without RSTACK, or with another ASH version" {
  var link: Link = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .link = &link };
  link.reset();
  try ncp.expectFrames(&.{ .rst });
  ncp.advanceTo(reset_timeout - 1);
  try ncp.expectNoEvent();
  ncp.advanceTo(reset_timeout);
  try ncp.expectEvent(.{ .failed = .reset_timeout });
  try testing.expectEqual(null, link.nextDeadline());

  link.reset();
  try ncp.expectFrames(&.{ .rst });
  ncp.send(.{ .rstack = .{ .version = 3, .code = reset_software } });
  try ncp.expectEvent(.{ .failed = .{ .version = 3 } });
}

test "frames before the RSTACK are ignored" {
  var link: Link = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .link = &link };
  link.reset();
  try ncp.expectFrames(&.{ .rst });
  ncp.sendData(3, 0, "abc");
  ncp.send(.{ .err = .{ .version = ash.version, .code = 0x51 } });
  try ncp.expectNoEvent();
  try ncp.expectSilence();
}

test "a command and its response" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  try testing.expectError(error.InvalidLength, link.send("ab"));
  try link.send("command");
  try ncp.expectFrames(&.{ dataFrame(0, 0, false, "command") });
  try testing.expectEqual(ack_timeout_initial, link.nextDeadline());

  ncp.now = 40;
  ncp.sendData(0, 1, "response");
  try ncp.expectEvent(.{ .frame = "response" });
  try ncp.expectNoEvent();
  try testing.expectEqual(null, link.nextDeadline());
  try ncp.expectFrames(&.{ ackFrame(1) });
  // The timeout adapts to the time the NCP took: (7 * 800 + 4 * 40) / 8.
  try testing.expectEqual(720, link.ack_timeout);
}

test "sending before the reset is answered fails" {
  var link: Link = .init(.{ .software_flow_control = true });
  try testing.expectError(error.NotConnected, link.send("command"));
  link.reset();
  try testing.expectError(error.NotConnected, link.send("command"));
}

test "at most `window` frames wait for an acknowledgement" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  for ([_][]const u8{ "one", "two", "three", "four" }) |payload| {
    try link.send(payload);
  }
  try ncp.expectFrames(
    &.{
      dataFrame(0, 0, false, "one"),
      dataFrame(1, 0, false, "two"),
      dataFrame(2, 0, false, "three"),
    },
  );
  ncp.send(ackFrame(2));
  try ncp.expectFrames(&.{ dataFrame(3, 0, false, "four") });
}

test "the queue holds seven frames" {
  var link: Link = undefined;
  _ = try connected(&link);
  for (0..7) |_| {
    try link.send("frame");
  }
  try testing.expectError(error.QueueFull, link.send("frame"));
}

test "unacknowledged frames are sent again, until the link fails" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  try link.send("command");
  try ncp.expectFrames(&.{ dataFrame(0, 0, false, "command") });
  // The timeout doubles each time, up to its maximum.
  const timeouts = [_]u64{ 800, 1600, 2400, 2400, 2400 };
  for (timeouts) |timeout| {
    ncp.advanceTo(ncp.now + timeout - 1);
    try ncp.expectSilence();
    ncp.advanceTo(ncp.now + 1);
    try testing.expectEqual(ash.cancel, link.output()[0]);
    try ncp.expectFrames(&.{ dataFrame(0, 0, true, "command") });
  }
  ncp.advanceTo(ncp.now + ack_timeout_max);
  try ncp.expectEvent(.{ .failed = .ack_timeouts });
  try ncp.expectSilence();
  try testing.expectEqual(null, link.nextDeadline());
}

test "a timeout sends every unacknowledged frame again" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  try link.send("one");
  try link.send("two");
  try ncp.expectFrames(&.{ dataFrame(0, 0, false, "one"), dataFrame(1, 0, false, "two") });
  ncp.advanceTo(ack_timeout_initial);
  try ncp.expectFrames(&.{ dataFrame(0, 0, true, "one"), dataFrame(1, 0, true, "two") });
  ncp.send(ackFrame(2));
  try ncp.expectSilence();
  try testing.expectEqual(null, link.nextDeadline());
  try link.send("three");
  try ncp.expectFrames(&.{ dataFrame(2, 0, false, "three") });
}

test "a NAK makes the host send its frames again" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  try link.send("one");
  try link.send("two");
  try ncp.expectFrames(&.{ dataFrame(0, 0, false, "one"), dataFrame(1, 0, false, "two") });
  ncp.send(nakFrame(1));
  try ncp.expectFrames(&.{ dataFrame(1, 0, true, "two") });
}

test "an out-of-sequence frame is rejected once, a repeated one acknowledged again" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  ncp.sendData(1, 0, "second");
  ncp.sendData(2, 0, "third");
  try ncp.expectNoEvent();
  try ncp.expectFrames(&.{ nakFrame(0) });

  ncp.send(dataFrame(0, 0, true, "first"));
  ncp.send(dataFrame(1, 0, true, "second"));
  try ncp.expectEvent(.{ .frame = "first" });
  try ncp.expectEvent(.{ .frame = "second" });
  try ncp.expectFrames(&.{ ackFrame(1), ackFrame(2) });
  // The NCP did not get the ACK and sends the frame again.
  ncp.send(dataFrame(1, 0, true, "second"));
  try ncp.expectNoEvent();
  try ncp.expectFrames(&.{ ackFrame(2) });
}

test "a damaged frame, or a bad acknowledgement number, is rejected" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  link.input(&.{ 0x01, 0x02, 0x03, 0x04, 0x05, ash.flag }, 0);
  try ncp.expectFrames(&.{ nakFrame(0) });

  link.rejecting = false;
  // Nothing was sent, so nothing can be acknowledged.
  ncp.sendData(0, 3, "response");
  try ncp.expectNoEvent();
  try ncp.expectFrames(&.{ nakFrame(0) });
}

test "frames wait when the receive slots are full" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  for (0..receive_slots) |i| {
    ncp.sendData(@intCast(i % 8), 0, "callback");
    try ncp.expectFrames(&.{ ackFrame(@intCast((i + 1) % 8)) });
  }
  ncp.sendData(0, 0, "one more");
  try ncp.expectFrames(&.{ nakFrame(0) });
  try ncp.expectEvent(.{ .frame = "callback" });
  ncp.send(dataFrame(0, 0, true, "one more"));
  try ncp.expectFrames(&.{ ackFrame(1) });
}

test "an ERROR frame or an unexpected RSTACK takes the link down" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  ncp.send(.{ .err = .{ .version = ash.version, .code = 0x51 } });
  try ncp.expectEvent(.{ .failed = .{ .ncp_error = 0x51 } });
  try testing.expectError(error.NotConnected, link.send("command"));

  ncp = try connected(&link);
  ncp.send(.{ .rstack = .{ .version = ash.version, .code = 0x02 } });
  try ncp.expectEvent(.{ .failed = .{ .ncp_reset = 0x02 } });
}

test "XOFF holds the output until XON" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  link.input(&.{ ash.xoff }, 0);
  try link.send("command");
  try ncp.expectSilence();
  link.input(&.{ ash.xon }, 0);
  try ncp.expectFrames(&.{ dataFrame(0, 0, false, "command") });
  try ncp.expectNoEvent();
  try testing.expectEqual(2, link.flow_control_bytes);
}

test "XOFF without XON fails the link once frames wait" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  link.input(&.{ ash.xoff }, 1000);
  // Nothing waits: nothing is due.
  try testing.expectEqual(null, link.nextDeadline());
  try link.send("command");
  try testing.expectEqual(1000 + max_pause, link.nextDeadline());
  ncp.advanceTo(1000 + max_pause - 1);
  try ncp.expectNoEvent();
  ncp.advanceTo(1000 + max_pause);
  try ncp.expectEvent(.{ .failed = .paused });
}

test "XON or XOFF without software flow control is reported once" {
  var link: Link = .init(.{ .software_flow_control = false });
  link.reset();
  link.input(&.{ ash.xoff, ash.xon, ash.xoff, ash.xon }, 0);
  var ncp: Ncp = .{ .link = &link };
  try ncp.expectEvent(.unexpected_flow_control);
  try ncp.expectNoEvent();
}

test "frame numbers wrap around" {
  var link: Link = undefined;
  var ncp = try connected(&link);
  for (0..20) |i| {
    const number: u3 = @intCast(i % 8);
    try link.send("command");
    try ncp.expectFrames(&.{ dataFrame(number, number, false, "command") });
    ncp.sendData(number, number +% 1, "response");
    try ncp.expectEvent(.{ .frame = "response" });
    try ncp.expectFrames(&.{ ackFrame(number +% 1) });
  }
}

test "fuzz: the link survives any NCP" {
  try testing.fuzz({}, fuzzLink, .{});
}

/// Feeds the link random frames, bytes, time and commands, and checks what must always hold.
fn fuzzLink(_: void, smith: *testing.Smith) !void {
  var link: Link = .init(.{ .software_flow_control = smith.value(bool) });
  link.reset();
  var now: u64 = 0;
  var payload: [ash.max_data_len]u8 = undefined;
  var out: [ash.max_encoded_len]u8 = undefined;
  for (0..smith.valueRangeAtMost(u8, 1, 64)) |_| {
    switch (smith.value(enum { frame, bytes, time, send, write, events, reset })) {
      .frame => {
        const len = smith.valueRangeAtMost(u8, ash.min_data_len, ash.max_data_len);
        smith.bytes(payload[0..len]);
        const frame: ash.Frame = switch (smith.value(enum { data, ack, nak, rst, rstack, err })) {
          .data => dataFrame(smith.value(u3), smith.value(u3), smith.value(bool), payload[0..len]),
          .ack => .{ .ack = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) } },
          .nak => .{ .nak = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) } },
          .rst => .rst,
          .rstack => .{ .rstack = .{ .version = smith.value(u8), .code = smith.value(u8) } },
          .err => .{ .err = .{ .version = smith.value(u8), .code = smith.value(u8) } },
        };
        link.input(try ash.encode(frame, &out), now);
      },
      .bytes => {
        const len = smith.slice(&payload);
        link.input(payload[0..len], now);
      },
      .time => {
        now += smith.valueRangeAtMost(u16, 0, 6000);
        link.advance(now);
        // Every timer due has run.
        if (link.nextDeadline()) |deadline| {
          try testing.expect(deadline > now);
        }
      },
      .send => {
        const len = smith.valueRangeAtMost(u8, ash.min_data_len, ash.max_data_len);
        link.send(payload[0..len]) catch {};
      },
      .write => {
        const pending: u16 = @intCast(link.output().len);
        link.outputDone(smith.valueRangeAtMost(u16, 0, pending), now);
      },
      .events => while (link.nextEvent()) |event| {
        if (event == .frame) {
          try testing.expect(event.frame.len >= ash.min_data_len);
          try testing.expect(event.frame.len <= ash.max_data_len);
        }
      },
      .reset => link.reset(),
    }
    try testing.expect(link.frm_tx -% link.ack_rx <= window);
    try testing.expect(link.received_count <= receive_slots);
    try testing.expect(link.out_start <= link.out_end);
  }
}
