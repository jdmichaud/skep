//! Brings an EmberZNet NCP up: resets the ASH link, agrees on the EZSP version, and reads the
//! firmware version. Like the link, it does no I/O.
//!
//! The version is agreed as zigbee-herdsman does: the host asks for the newest version it supports
//! in the legacy format; the NCP answers with its own version, which the host asks for again if it
//! supports it. Only then does the NCP accept other commands.

const std = @import("std");
const command = @import("command.zig");
const frame = @import("frame.zig");
const link_layer = @import("link.zig");
const test_ncp = @import("test_ncp.zig");

/// How long the NCP has to answer a command once the link is up, in milliseconds: as long as the
/// link may take to give up.
pub const response_timeout = link_layer.max_timeouts * link_layer.ack_timeout_max;

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

pub const Startup = struct {
  link: link_layer.Link,
  step: enum { idle, resetting, version, version_again, version_info, finished } = .idle,
  /// Sequence number of the last command.
  sequence: u8 = 0,
  /// When the last command was sent.
  sent_at: u64 = 0,
  version: command.Version = undefined,
  result: ?Result = null,

  pub fn init(options: link_layer.Options) Startup {
    return .{ .link = .init(options) };
  }

  pub fn start(s: *Startup) void {
    const options = s.link.options;
    s.* = .{ .link = .init(options), .step = .resetting };
    s.link.reset();
  }

  pub fn input(s: *Startup, bytes: []const u8, now: u64) void {
    s.link.input(bytes, now);
    s.process(now);
  }

  pub fn output(s: *const Startup) []const u8 {
    return s.link.output();
  }

  pub fn outputDone(s: *Startup, len: usize, now: u64) void {
    s.link.outputDone(len, now);
    s.process(now);
  }

  pub fn nextDeadline(s: *const Startup) ?u64 {
    const link_deadline = s.link.nextDeadline();
    const response_deadline: ?u64 = switch (s.step) {
      .version, .version_again, .version_info => s.sent_at +| response_timeout,
      .idle, .resetting, .finished => null,
    };
    if (link_deadline == null) return response_deadline;
    if (response_deadline == null) return link_deadline;
    return @min(link_deadline.?, response_deadline.?);
  }

  pub fn advance(s: *Startup, now: u64) void {
    s.link.advance(now);
    s.process(now);
    switch (s.step) {
      .version, .version_again, .version_info => {
        if (now >= s.sent_at +| response_timeout) {
          s.finish(.{ .failed = .response_timeout });
        }
      },
      .idle, .resetting, .finished => {},
    }
  }

  fn finish(s: *Startup, result: Result) void {
    s.step = .finished;
    s.result = result;
  }

  fn process(s: *Startup, now: u64) void {
    // Until it is finished: what the link reports after, its failure among them, is the
    // driver's to take.
    while (s.step != .finished) {
      const event = s.link.nextEvent() orelse return;
      switch (event) {
        .connected => {
          var out: [4]u8 = undefined;
          s.step = .version;
          s.send(frame.encodeLegacyVersion(&out, s.sequence, frame.max_version), now);
        },
        .frame => |bytes| s.receive(bytes, now),
        .failed => |failure| s.finish(.{ .failed = .{ .link = failure } }),
        // The link reports it, and honours XON/XOFF anyway.
        .unexpected_flow_control => {},
      }
    }
  }

  fn send(s: *Startup, bytes: []const u8, now: u64) void {
    s.sent_at = now;
    s.link.send(bytes) catch |err| switch (err) {
      // The link failed after the frame being handled arrived: its event comes next.
      error.NotConnected => {},
      // A command at a time, of the right length.
      error.QueueFull, error.InvalidLength => unreachable,
    };
  }

  fn sendCommand(s: *Startup, id: frame.FrameId, parameters: []const u8, now: u64) void {
    var out: [5 + frame.max_parameters_len]u8 = undefined;
    s.sequence +%= 1;
    s.send(frame.encode(&out, s.sequence, id, parameters), now);
  }

  fn receive(s: *Startup, bytes: []const u8, now: u64) void {
    const response = frame.decode(bytes) catch return s.finish(.{ .failed = .bad_response });
    // Callbacks, and responses to commands we gave up on, are none of our business here.
    if (response.callback or response.sequence != s.sequence) return;
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
          return s.sendCommand(.version, &.{ version.protocol_version }, now);
        }
        s.step = .version_info;
        s.sendCommand(.get_value, &.{ @backingInt(command.ValueId.version_info) }, now);
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

const Ncp = test_ncp.Ncp(Startup);

test "start an NCP that speaks an older EZSP version" {
  var startup: Startup = .init(.{ .software_flow_control = true });
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
  try testing.expectEqual(null, startup.result);
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
    startup.result.?,
  );
  try testing.expectEqual(null, startup.nextDeadline());
}

test "start an NCP that speaks EZSP 8" {
  var startup: Startup = .init(.{ .software_flow_control = true });
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
    startup.result.?,
  );
}

test "an NCP that answers the second version command with another version fails" {
  var startup: Startup = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&hex("0080000802306a"));
  try ncp.expectCommand(&hex("010001000008"));
  // EZSP 9, though asked for 8, which it offered.
  ncp.respond(&hex("01800100000902306a"));
  try testing.expectEqual(Result{ .failed = .bad_response }, startup.result.?);
}

test "an NCP that speaks the newest version is not asked twice" {
  var startup: Startup = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&hex("00800013020080"));
  try ncp.expectCommand(&hex("010001aa0011"));
  // Since EZSP 14, statuses take 4 bytes.
  ncp.respond(&hex("018001aa0000000000" ++ "07" ++ "3412" ++ "080000" ++ "00" ++ "aa"));
  try testing.expectEqual(8, startup.result.?.done.firmware.major);
}

test "an unsupported EZSP version or stack fails the startup" {
  var startup: Startup = .init(.{ .software_flow_control = true });
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
    startup.result.?,
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
    startup.result.?,
  );
}

test "the startup fails when the NCP stops answering" {
  var startup: Startup = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &startup };
  try ncp.connect();
  _ = ncp.take();
  // The NCP acknowledges the command but never answers it.
  ncp.send(.{ .ack = .{ .ack_number = 1, .not_ready = false } });
  try testing.expectEqual(response_timeout, startup.nextDeadline());
  startup.advance(response_timeout);
  try testing.expectEqual(Result{ .failed = .response_timeout }, startup.result.?);
}

test "a link failure fails the startup" {
  var startup: Startup = .init(.{ .software_flow_control = true });
  startup.start();
  startup.outputDone(startup.output().len, 0);
  startup.advance(link_layer.reset_timeout);
  try testing.expectEqual(Result{ .failed = .{ .link = .reset_timeout } }, startup.result.?);
}
