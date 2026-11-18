//! EZSP commands over the ASH link, which the startup and the driver share: commands go out one
//! at a time, numbered, and the NCP owes an answer within `response_timeout` of when a command
//! was written. Which steps owe something, an answer or a callback, is for the state machines to
//! say; when it is late is the channel's. Like the link, it does no I/O.

const std = @import("std");
const frame = @import("frame.zig");
const link_layer = @import("link.zig");

/// How long the NCP has to answer a command once the link is up, in milliseconds: as long as the
/// link may take to give up.
pub const response_timeout = link_layer.max_timeouts * link_layer.ack_timeout_max;

pub const SendError = error{
  /// The link holds frames the NCP has not acknowledged, though commands go one at a time and
  /// the NCP acknowledges a command before answering it: an NCP answering commands it was not
  /// sent.
  QueueFull,
};

pub const Channel = struct {
  link: link_layer.Link,
  /// Sequence number of the last command.
  sequence: u8 = 0,
  /// When the last command was written, or when what is owed after its answer began.
  since: u64 = 0,
  /// The last command is queued and not written yet: nothing is owed until it is, which can be
  /// long after it was queued when the application asks after a quiet spell, then calls
  /// `advance` before writing.
  unwritten: bool = false,

  pub fn init(options: link_layer.Options) Channel {
    return .{ .link = .init(options) };
  }

  /// A new link, reset: frame and sequence numbers start again.
  pub fn reset(ch: *Channel) void {
    const options = ch.link.options;
    ch.* = .init(options);
    ch.link.reset();
  }

  /// Queues a command, in the extended format.
  pub fn send(ch: *Channel, id: frame.FrameId, parameters: []const u8, now: u64) SendError!void {
    var out: [5 + frame.max_parameters_len]u8 = undefined;
    ch.sequence +%= 1;
    return ch.queue(frame.encode(&out, ch.sequence, id, parameters), now);
  }

  /// Queues the first `version` command, in the legacy format, asking for the newest version
  /// supported.
  pub fn sendLegacyVersion(ch: *Channel, now: u64) SendError!void {
    var out: [4]u8 = undefined;
    return ch.queue(frame.encodeLegacyVersion(&out, ch.sequence, frame.max_version), now);
  }

  fn queue(ch: *Channel, bytes: []const u8, now: u64) SendError!void {
    ch.since = now;
    ch.unwritten = true;
    ch.link.send(bytes) catch |err| switch (err) {
      // The link failed after the frame being handled arrived: its event comes next. In case it
      // does not, the answer is owed from now, which it will not get, so that the response
      // timeout ends the wait rather than leave it without a deadline.
      error.NotConnected => ch.unwritten = false,
      error.QueueFull => return error.QueueFull,
      // Of the right length.
      error.InvalidLength => unreachable,
    };
  }

  /// Something more is owed from `now`: a callback after the answer, such as the network coming
  /// up.
  pub fn owe(ch: *Channel, now: u64) void {
    ch.since = now;
    ch.unwritten = false;
  }

  /// Whether a frame from the NCP answers the last command: a response, numbered as it was.
  pub fn answers(ch: *const Channel, f: frame.Frame) bool {
    return !f.callback and f.sequence == ch.sequence;
  }

  /// When what is owed is late, if anything is.
  fn deadline(ch: *const Channel, owed: bool) ?u64 {
    if (!owed or ch.unwritten) return null;
    return ch.since +| response_timeout;
  }

  /// When `advance` must next be called: for the link's timers, and for what is owed.
  pub fn nextDeadline(ch: *const Channel, owed: bool) ?u64 {
    const link_deadline = ch.link.nextDeadline() orelse return ch.deadline(owed);
    const owed_deadline = ch.deadline(owed) orelse return link_deadline;
    return @min(link_deadline, owed_deadline);
  }

  /// Whether what is owed is late at `now`.
  pub fn late(ch: *const Channel, owed: bool, now: u64) bool {
    const t = ch.deadline(owed) orelse return false;
    return now >= t;
  }

  pub fn input(ch: *Channel, bytes: []const u8, now: u64) void {
    ch.link.input(bytes, now);
  }

  pub fn output(ch: *const Channel) []const u8 {
    return ch.link.output();
  }

  /// The first `len` bytes of `output()` were written at `now`: a command queued is written,
  /// and its answer owed from now.
  pub fn outputDone(ch: *Channel, len: usize, now: u64) void {
    ch.link.outputDone(len, now);
    if (ch.unwritten and len > 0) {
      ch.since = now;
      ch.unwritten = false;
    }
  }

  pub fn advance(ch: *Channel, now: u64) void {
    ch.link.advance(now);
  }

  pub fn nextEvent(ch: *Channel) ?link_layer.Event {
    return ch.link.nextEvent();
  }
};

const testing = std.testing;

test "an answer is owed from when the command is written, and is late a timeout later" {
  var ch: Channel = .init(.{ .software_flow_control = true });
  ch.reset();
  // Not connected: the answer is owed at once, so that it times out.
  try ch.send(.version, &.{ 8 }, 100);
  try testing.expectEqual(1, ch.sequence);
  try testing.expectEqual(100 + response_timeout, ch.deadline(true));
  // Owed only when the state machine says so.
  try testing.expectEqual(null, ch.deadline(false));
  try testing.expect(ch.late(true, 100 + response_timeout));
  try testing.expect(!ch.late(true, 99 + response_timeout));
  // Something more owed, from later.
  ch.owe(5000);
  try testing.expectEqual(5000 + response_timeout, ch.deadline(true));
}
