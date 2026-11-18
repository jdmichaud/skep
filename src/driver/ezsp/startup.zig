//! Brings an EmberZNet NCP up: resets the ASH link, agrees on the EZSP version, and reads the
//! firmware version. Like the link, it does no I/O.
//!
//! The version is agreed as zigbee-herdsman does: the host asks for the newest version it supports
//! in the legacy format; the NCP answers with its own version, which the host asks for again if it
//! supports it. Only then does the NCP accept other commands.

const std = @import("std");
const channel = @import("channel.zig");
const command = @import("command.zig");
const frame = @import("frame.zig");
const link_layer = @import("link.zig");
const test_ncp = @import("test_ncp.zig");

const Channel = channel.Channel;

pub const response_timeout = channel.response_timeout;

pub const Info = struct {
  version: command.Version,
  firmware: command.VersionInfo,
};

pub const Failure = union(enum) {
  link: link_layer.Failure,
  /// The NCP speaks an EZSP version outside `frame.min_version` to `frame.max_version`. Its
  /// answer tells which firmware it runs, to know what to flash.
  unsupported_version: command.Version,
  /// The NCP runs another stack than EmberZNet's mesh stack.
  unsupported_stack: command.Version,
  /// The NCP did not answer a command within `response_timeout`.
  response_timeout,
  /// The NCP rejected a command, with this EZSP status.
  invalid_command: u8,
  /// The NCP failed to read the firmware version, with this status.
  get_value: u32,
  /// A response that cannot be decoded.
  bad_response,
};

pub const Result = union(enum) {
  done: Info,
  failed: Failure,
};

/// The startup's steps, over a channel it is given: the driver's, which goes on with it.
pub const Startup = struct {
  step: enum { idle, resetting, version, version_again, version_info, finished } = .idle,
  version: command.Version = undefined,
  result: ?Result = null,

  /// Starts again, resetting the link.
  pub fn start(s: *Startup, ch: *Channel) void {
    s.* = .{ .step = .resetting };
    ch.reset();
  }

  /// Whether the NCP owes an answer.
  fn owed(s: *const Startup) bool {
    return switch (s.step) {
      .version, .version_again, .version_info => true,
      .idle, .resetting, .finished => false,
    };
  }

  pub fn nextDeadline(s: *const Startup, ch: *const Channel) ?u64 {
    return ch.nextDeadline(s.owed());
  }

  pub fn advance(s: *Startup, ch: *Channel, now: u64) void {
    ch.advance(now);
    s.process(ch, now);
    if (ch.late(s.owed(), now)) {
      s.finish(.{ .failed = .response_timeout });
    }
  }

  fn finish(s: *Startup, result: Result) void {
    s.step = .finished;
    s.result = result;
  }

  /// Takes what the link reports, after `input` or `outputDone` on the channel.
  pub fn process(s: *Startup, ch: *Channel, now: u64) void {
    // Until it is finished: what the link reports after, its failure among them, is the
    // driver's to take.
    while (s.step != .finished) {
      const event = ch.nextEvent() orelse return;
      switch (event) {
        .connected => {
          s.step = .version;
          ch.sendLegacyVersion(now) catch s.finish(.{ .failed = .bad_response });
        },
        .frame => |bytes| s.receive(ch, bytes, now),
        .failed => |failure| s.finish(.{ .failed = .{ .link = failure } }),
        // The link reports it, and honours XON/XOFF anyway.
        .unexpected_flow_control => {},
      }
    }
  }

  fn sendCommand(
    s: *Startup,
    ch: *Channel,
    id: frame.FrameId,
    parameters: []const u8,
    now: u64,
  ) void {
    ch.send(id, parameters, now) catch s.finish(.{ .failed = .bad_response });
  }

  fn receive(s: *Startup, ch: *Channel, bytes: []const u8, now: u64) void {
    const response = frame.decode(bytes) catch return s.finish(.{ .failed = .bad_response });
    // Callbacks, and responses to commands we gave up on, are none of our business here.
    if (!ch.answers(response)) return;
    if (response.id == .invalid_command) {
      const status = if (response.parameters.len > 0) response.parameters[0] else 0;
      return s.finish(.{ .failed = .{ .invalid_command = status } });
    }
    switch (s.step) {
      .version, .version_again => {
        if (response.id != .version) return s.finish(.{ .failed = .bad_response });
        const version = command.Version.parse(response.parameters) catch
          return s.finish(.{ .failed = .bad_response });
        if (version.stack_type != command.stack_type_mesh) {
          return s.finish(.{ .failed = .{ .unsupported_stack = version } });
        }
        const supported = version.protocol_version >= frame.min_version and
          version.protocol_version <= frame.max_version;
        if (!supported) {
          return s.finish(.{ .failed = .{ .unsupported_version = version } });
        }
        // The second answer must agree to the version the first offered.
        if (s.step == .version_again and version.protocol_version != s.version.protocol_version) {
          return s.finish(.{ .failed = .bad_response });
        }
        s.version = version;
        if (s.step == .version and version.protocol_version != frame.max_version) {
          s.step = .version_again;
          return s.sendCommand(ch, .version, &.{ version.protocol_version }, now);
        }
        s.step = .version_info;
        s.sendCommand(ch, .get_value, &.{ @backingInt(command.ValueId.version_info) }, now);
      },
      .version_info => {
        if (response.id != .get_value) return s.finish(.{ .failed = .bad_response });
        const value = command.parseGetValue(response.parameters, s.version.protocol_version) catch
          return s.finish(.{ .failed = .bad_response });
        if (value.status != 0) return s.finish(.{ .failed = .{ .get_value = value.status } });
        if (value.value.len != command.VersionInfo.len) {
          return s.finish(.{ .failed = .bad_response });
        }
        const firmware = command.VersionInfo.parse(value.value) catch unreachable;
        s.finish(.{ .done = .{ .version = s.version, .firmware = firmware } });
      },
      .idle, .resetting, .finished => {},
    }
  }
};

// Tests: the startup against a scripted NCP, which acknowledges every DATA frame and answers with
// the EZSP frames the test gives.

const testing = std.testing;

const hex = test_ncp.hex;

/// A startup on a channel of its own, as a host for the scripted NCP.
const Alone = struct {
  channel: Channel,
  startup: Startup = .{},

  fn init(options: link_layer.Options) Alone {
    return .{ .channel = .init(options) };
  }

  pub fn start(a: *Alone) void {
    a.startup.start(&a.channel);
  }

  pub fn input(a: *Alone, bytes: []const u8, now: u64) void {
    a.channel.input(bytes, now);
    a.startup.process(&a.channel, now);
  }

  pub fn output(a: *const Alone) []const u8 {
    return a.channel.output();
  }

  pub fn outputDone(a: *Alone, len: usize, now: u64) void {
    a.channel.outputDone(len, now);
    a.startup.process(&a.channel, now);
  }

  fn nextDeadline(a: *const Alone) ?u64 {
    return a.startup.nextDeadline(&a.channel);
  }

  fn advance(a: *Alone, now: u64) void {
    a.startup.advance(&a.channel, now);
  }
};

const Ncp = test_ncp.Ncp(Alone);

test "start an NCP that speaks an older EZSP version" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  // EZSP 13, EmberZNet 7.4.1, answered in the legacy format.
  ncp.respond(&hex("0080000d021074"));
  try ncp.expectCommand(&hex("01000100000d"));
  // A callback in between is ignored.
  ncp.respond(&hex("0090011900"));
  ncp.respond(&hex("01800100000d021074"));
  try ncp.expectCommand(&hex("020001aa0011"));
  try testing.expectEqual(null, startup.startup.result);
  ncp.respond(&hex("028001aa0000" ++ "07" ++ "3412" ++ "070401" ++ "00" ++ "aa"));
  try testing.expectEqual(
    Result{
      .done = .{
        .version = .{ .protocol_version = 13, .stack_type = 2, .stack_version = 0x7410 },
        .firmware = .{
          .build = 0x1234,
          .major = 7,
          .minor = 4,
          .patch = 1,
          .special = 0,
          .type = 0xaa,
        },
      },
    },
    startup.startup.result.?,
  );
  try testing.expectEqual(null, startup.nextDeadline());
}

test "start an NCP that speaks EZSP 8" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  // The answer of our ZBDongle-E as delivered: EZSP 8, EmberZNet 6.10.3.
  ncp.respond(&hex("0080000802306a"));
  try ncp.expectCommand(&hex("010001000008"));
  ncp.respond(&hex("01800100000802306a"));
  try ncp.expectCommand(&hex("020001aa0011"));
  ncp.respond(&hex("028001aa0000" ++ "07" ++ "3412" ++ "060a03" ++ "00" ++ "aa"));
  try testing.expectEqual(
    Result{
      .done = .{
        .version = .{ .protocol_version = 8, .stack_type = 2, .stack_version = 0x6a30 },
        .firmware = .{
          .build = 0x1234,
          .major = 6,
          .minor = 10,
          .patch = 3,
          .special = 0,
          .type = 0xaa,
        },
      },
    },
    startup.startup.result.?,
  );
}

test "an NCP that answers the second version command with another version fails" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&hex("0080000802306a"));
  try ncp.expectCommand(&hex("010001000008"));
  // EZSP 9, though asked for 8, which it offered.
  ncp.respond(&hex("01800100000902306a"));
  try testing.expectEqual(Result{ .failed = .bad_response }, startup.startup.result.?);
}

test "an NCP that speaks the newest version is not asked twice" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&hex("00800013020080"));
  try ncp.expectCommand(&hex("010001aa0011"));
  // Since EZSP 14, statuses take 4 bytes.
  ncp.respond(&hex("018001aa0000000000" ++ "07" ++ "3412" ++ "080000" ++ "00" ++ "aa"));
  try testing.expectEqual(8, startup.startup.result.?.done.firmware.major);
}

test "an unsupported EZSP version or stack fails the startup" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  _ = ncp.take();
  // Older than the oldest supported.
  ncp.respond(&hex("00800007020065"));
  try testing.expectEqual(
    Result{
      .failed = .{
        .unsupported_version = .{ .protocol_version = 7, .stack_type = 2, .stack_version = 0x6500 },
      },
    },
    startup.startup.result.?,
  );

  ncp = .{ .host = &startup };
  try ncp.connect();
  _ = ncp.take();
  ncp.respond(&hex("0080000d031074"));
  try testing.expectEqual(
    Result{
      .failed = .{
        .unsupported_stack = .{ .protocol_version = 13, .stack_type = 3, .stack_version = 0x7410 },
      },
    },
    startup.startup.result.?,
  );
}

test "the startup fails when the NCP stops answering" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  _ = ncp.take();
  // The NCP acknowledges the command but never answers it.
  ncp.send(.{ .ack = .{ .ack_number = 1, .not_ready = false } });
  try testing.expectEqual(response_timeout, startup.nextDeadline());
  startup.advance(response_timeout);
  try testing.expectEqual(Result{ .failed = .response_timeout }, startup.startup.result.?);
}

test "a link failure fails the startup" {
  var startup: Alone = .init(.{ .software_flow_control = true });
  startup.start();
  startup.outputDone(startup.output().len, 0);
  startup.advance(link_layer.reset_timeout);
  try testing.expectEqual(
    Result{ .failed = .{ .link = .reset_timeout } },
    startup.startup.result.?,
  );
}
