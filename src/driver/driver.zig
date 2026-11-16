//! The interface between libskep and the drivers that talk to dongles. Drivers do no I/O either:
//! the context hands them the bytes and the time it gets from the application.
//!
//! Drivers form a tagged union rather than a table of function pointers: they are internal and
//! few, chosen by name at run time, and a switch lets the compiler check that each one implements
//! every operation. What a driver reports is translated here into events that know nothing of the
//! dongle, so nothing outside a driver depends on one.

const std = @import("std");
const ezsp = @import("ezsp/ezsp.zig");
const sim = @import("sim/sim.zig");

pub const Name = enum { ezsp, sim };

pub const FlowControl = enum { none, software, hardware };

pub const SerialDefaults = struct {
  baudrate: u32,
  flow_control: FlowControl,
};

/// A Zigbee network, as far as the rest of libskep cares.
pub const Network = struct {
  channel: u8,
  pan_id: u16,
  extended_pan_id: u64,
};

/// A short text for the log, kept in the event that carries it.
pub const Message = struct {
  buffer: [160]u8 = undefined,
  len: usize = 0,

  /// Formats a message, cut short if it does not fit.
  pub fn init(comptime format: []const u8, args: anytype) Message {
    var m: Message = .{};
    var w: std.Io.Writer = .fixed(&m.buffer);
    w.print(format, args) catch {};
    m.len = w.end;
    return m;
  }

  pub fn text(m: *const Message) []const u8 {
    return m.buffer[0..m.len];
  }
};

pub const Level = enum { err, warning, info, debug };

pub const Ready = struct {
  /// The coordinator's IEEE address.
  ieee: u64,
  /// The network the dongle holds, now up, or null if it holds none.
  network: ?Network,
  /// What the dongle runs, for the log.
  firmware: Message,
};

pub const Failure = struct {
  kind: Kind,
  message: Message,

  pub const Kind = enum {
    /// The dongle stopped answering.
    timeout,
    /// The dongle broke the protocol.
    protocol,
    /// The dongle runs firmware the driver does not support.
    unsupported,
    /// The dongle refused something the driver needs.
    refused,
  };
};

pub const Event = union(enum) {
  ready: Ready,
  failed: Failure,
  log: struct { level: Level, message: Message },
};

pub const Driver = union(Name) {
  ezsp: ezsp.driver.Driver,
  sim: sim.Driver,

  pub fn init(name: Name) Driver {
    return switch (name) {
      .ezsp => .{
        .ezsp = .init(.{
          .software_flow_control = serialDefaults(.ezsp).?.flow_control == .software,
        }),
      },
      .sim => .{ .sim = .{} },
    };
  }

  /// The serial settings the driver's dongles usually need, or null if it talks to none.
  pub fn serialDefaults(name: Name) ?SerialDefaults {
    return switch (name) {
      // The ZBDongle-E's EmberZNet firmware, as delivered; other firmware builds use RTS/CTS.
      .ezsp => .{ .baudrate = 115200, .flow_control = .software },
      .sim => null,
    };
  }

  pub fn start(d: *Driver) void {
    switch (d.*) {
      inline else => |*driver| driver.start(),
    }
  }

  pub fn input(d: *Driver, bytes: []const u8, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.input(bytes, now),
    }
  }

  pub fn output(d: *const Driver) []const u8 {
    return switch (d.*) {
      inline else => |*driver| driver.output(),
    };
  }

  pub fn outputDone(d: *Driver, len: usize, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.outputDone(len, now),
    }
  }

  pub fn nextDeadline(d: *const Driver) ?u64 {
    return switch (d.*) {
      inline else => |*driver| driver.nextDeadline(),
    };
  }

  pub fn advance(d: *Driver, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.advance(now),
    }
  }

  pub fn nextEvent(d: *Driver) ?Event {
    return switch (d.*) {
      .ezsp => |*driver| fromEzsp(driver.nextEvent() orelse return null),
      .sim => |*driver| driver.nextEvent(),
    };
  }
};

fn fromEzsp(event: ezsp.driver.Event) Event {
  return switch (event) {
    .ready => |ready| .{
      .ready = .{
        .ieee = ready.ieee,
        .network = if (ready.network) |network|
          .{
            .channel = network.parameters.channel,
            .pan_id = network.parameters.pan_id,
            .extended_pan_id = network.parameters.extended_pan_id,
          }
        else
          null,
        .firmware = .init("EmberZNet {d}.{d}.{d}.{d} build {d}{s}, EZSP {d}", .{
          ready.firmware.major,
          ready.firmware.minor,
          ready.firmware.patch,
          ready.firmware.special,
          ready.firmware.build,
          if (ready.firmware.type == 0xaa) "" else " (pre-release)",
          ready.version.protocol_version,
        }),
      },
    },
    .failed => |failure| .{ .failed = fromEzspFailure(failure) },
    .configuration_refused => |refused| .{
      .log = .{
        .level = .warning,
        .message = .init(
          "ezsp: the firmware refused configuration value {t} (status 0x{x}) and keeps its own",
          .{ refused.id, refused.status.value },
        ),
      },
    },
  };
}

fn fromEzspFailure(failure: ezsp.driver.Failure) Failure {
  return switch (failure) {
    .startup => |startup| switch (startup) {
      .link => |link| fromLinkFailure(link),
      .unsupported_version => |version| .{
        .kind = .unsupported,
        .message = .init("ezsp: the dongle speaks EZSP {d}, supported are {d} to {d}", .{
          version.protocol_version,
          ezsp.frame.min_version,
          ezsp.frame.max_version,
        }),
      },
      .unsupported_stack => |version| .{
        .kind = .unsupported,
        .message = .init("ezsp: the dongle runs stack type {d}, not EmberZNet's mesh stack", .{
          version.stack_type,
        }),
      },
      .response_timeout => .{
        .kind = .timeout,
        .message = .init("ezsp: the dongle did not answer a command", .{}),
      },
      .invalid_command => |status| .{
        .kind = .protocol,
        .message = .init("ezsp: the dongle rejected a command (status 0x{x})", .{ status }),
      },
      .get_value => |status| .{
        .kind = .refused,
        .message = .init("ezsp: the dongle did not give its firmware version (status 0x{x})", .{
          status,
        }),
      },
      .bad_response => .{
        .kind = .protocol,
        .message = .init("ezsp: an answer from the dongle cannot be decoded", .{}),
      },
    },
    .link => |link| fromLinkFailure(link),
    .response_timeout => .{
      .kind = .timeout,
      .message = .init("ezsp: the dongle did not answer, or did not bring its network up", .{}),
    },
    .invalid_command => |status| .{
      .kind = .protocol,
      .message = .init("ezsp: the dongle rejected a command (status 0x{x})", .{ status }),
    },
    .add_endpoint => |status| .{
      .kind = .refused,
      .message = .init("ezsp: the dongle refused the coordinator's endpoint (status 0x{x})", .{
        status.value,
      }),
    },
    .network_init => |status| .{
      .kind = .refused,
      .message = .init("ezsp: the dongle could not bring its network up (status 0x{x})", .{
        status.value,
      }),
    },
    .network_parameters => |status| .{
      .kind = .refused,
      .message = .init("ezsp: the dongle did not give its network parameters (status 0x{x})", .{
        status.value,
      }),
    },
    .bad_response => .{
      .kind = .protocol,
      .message = .init("ezsp: an answer from the dongle cannot be decoded", .{}),
    },
  };
}

fn fromLinkFailure(failure: ezsp.link.Failure) Failure {
  return switch (failure) {
    .reset_timeout => .{
      .kind = .timeout,
      .message = .init("ezsp: the dongle did not answer the reset", .{}),
    },
    .ack_timeouts => .{
      .kind = .timeout,
      .message = .init("ezsp: the dongle stopped acknowledging frames", .{}),
    },
    .version => |version| .{
      .kind = .unsupported,
      .message = .init("ezsp: the dongle speaks ASH version {d}, not 2", .{ version }),
    },
    .ncp_error => |code| .{
      .kind = .protocol,
      .message = .init("ezsp: the dongle reported an error (code 0x{x})", .{ code }),
    },
    .ncp_reset => |code| .{
      .kind = .protocol,
      .message = .init("ezsp: the dongle reset unexpectedly (reason 0x{x})", .{ code }),
    },
  };
}

const testing = std.testing;

test "messages are cut short rather than lost" {
  const x: [300]u8 = @splat('x');
  const long: Message = .init("{s}", .{ &x });
  try testing.expectEqual(160, long.text().len);
  const short: Message = .init("EZSP {d}", .{ 8 });
  try testing.expectEqualStrings("EZSP 8", short.text());
}

test "ezsp events become events that know nothing of EZSP" {
  const ready = fromEzsp(.{
    .ready = .{
      .version = .{ .protocol_version = 8, .stack_type = 2, .stack_version = 0x6a30 },
      .firmware = .{
        .build = 297,
        .major = 6,
        .minor = 10,
        .patch = 3,
        .special = 0,
        .type = 0xaa,
      },
      .ieee = 0x7cc6b6fffe49e11d,
      .network = .{
        .node_type = .coordinator,
        .parameters = .{
          .extended_pan_id = 0x814298be16f0fe69,
          .pan_id = 0x21e0,
          .tx_power = 8,
          .channel = 15,
          .join_method = 0,
          .manager_id = 0,
          .update_id = 0,
          .channels = 0,
        },
      },
    },
  }).ready;
  try testing.expectEqualStrings("EmberZNet 6.10.3.0 build 297, EZSP 8", ready.firmware.text());
  try testing.expectEqual(
    Network{ .channel = 15, .pan_id = 0x21e0, .extended_pan_id = 0x814298be16f0fe69 },
    ready.network.?,
  );

  const failure = fromEzsp(.{ .failed = .{ .link = .ack_timeouts } }).failed;
  try testing.expectEqual(Failure.Kind.timeout, failure.kind);
}

test "the sim driver talks to no serial device" {
  try testing.expectEqual(null, Driver.serialDefaults(.sim));
  try testing.expectEqual(115200, Driver.serialDefaults(.ezsp).?.baudrate);
}
