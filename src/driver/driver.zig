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
  /// Raised each time the network moves to another channel.
  update_id: u8 = 0,
};

/// A network's keys, and the outgoing frame counters that devices check the coordinator's frames
/// against: each frame must carry a higher counter than the last they saw.
pub const Security = struct {
  network_key: [16]u8,
  network_key_sequence_number: u8 = 0,
  network_frame_counter: u32 = 0,
  /// The key from which the trust center derives the link keys it gives devices.
  trust_center_link_key: [16]u8,
  /// Null when the dongle does not tell.
  trust_center_frame_counter: ?u32 = 0,
};

/// A network as a dongle holds it: what it is, and its keys.
pub const Held = struct {
  network: Network,
  security: Security,
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
  network: ?Held,
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

/// What `form` needs: the network, and its keys.
pub const Form = struct {
  network: Network,
  security: Security,
  /// The network is a saved one put back: its frame counters are set too, so that its devices
  /// accept the coordinator's frames. A new network starts them at 0.
  restore: bool = false,
};

/// A device the trust center saw join, rejoin or leave.
pub const Device = struct {
  ieee: u64,
  /// Its network address.
  nwk: u16,
  kind: enum { joined, rejoined, left },
};

pub const Event = union(enum) {
  ready: Ready,
  /// `form` formed the network.
  formed: Held,
  /// `refresh` read the network again.
  refreshed: Held,
  /// `permitJoin` was done: null if it worked, why not otherwise.
  permit_join_done: ?Failure,
  /// The join window opened (true) or closed.
  join_window: bool,
  device: Device,
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

  /// Forms a network, new or saved, once the driver is ready, replacing the dongle's if it holds
  /// one.
  pub fn form(d: *Driver, f: Form) void {
    switch (d.*) {
      .ezsp => |*driver| driver.form(.{
        .channel = f.network.channel,
        .pan_id = f.network.pan_id,
        .extended_pan_id = f.network.extended_pan_id,
        .update_id = f.network.update_id,
        // zigbee-herdsman's default.
        .tx_power = 5,
        .network_key = f.security.network_key,
        .network_key_sequence_number = f.security.network_key_sequence_number,
        .trust_center_link_key = f.security.trust_center_link_key,
        .frame_counters = if (f.restore)
          .{
            .network = f.security.network_frame_counter,
            .trust_center = f.security.trust_center_frame_counter orelse 0,
          }
        else
          null,
      }),
      .sim => |*driver| driver.form(f),
    }
  }

  /// Reads the network, its keys and frame counters again, once the network is up.
  pub fn refresh(d: *Driver) void {
    switch (d.*) {
      inline else => |*driver| driver.refresh(),
    }
  }

  /// Opens the network to new devices for `seconds`, or closes it with 0, once the network is up.
  /// The routers are not told yet: that takes ZDO, which comes with device interviews.
  pub fn permitJoin(d: *Driver, seconds: u8) void {
    switch (d.*) {
      inline else => |*driver| driver.permitJoin(seconds),
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
      .ezsp => |*driver| {
        const dropped = driver.takeDropped();
        if (dropped > 0) {
          return .{
            .log = .{
              .level = .err,
              .message = .init("ezsp: {d} events lost: the queue was full", .{ dropped }),
            },
          };
        }
        return fromEzsp(driver.nextEvent() orelse return null);
      },
      .sim => |*driver| driver.nextEvent(),
    };
  }
};

fn fromEzsp(event: ezsp.driver.Event) Event {
  return switch (event) {
    .ready => |ready| .{
      .ready = .{
        .ieee = ready.ieee,
        .network = if (ready.network) |network| fromEzspNetwork(network) else null,
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
    .formed => |network| .{ .formed = fromEzspNetwork(network) },
    .refreshed => |network| .{ .refreshed = fromEzspNetwork(network) },
    .permit_join_done => |refused| .{
      .permit_join_done = if (refused) |r| fromEzspFailure(.{ .refused = r }) else null,
    },
    .join_window => |open| .{ .join_window = open },
    .callback => |callback| .{
      .log = .{
        .level = .debug,
        .message = if (std.enums.tagName(ezsp.frame.FrameId, callback.id)) |name|
          .init("ezsp: callback {s}: {x}", .{ name, callback.bytes() })
        else
          .init("ezsp: callback 0x{x:0>4}: {x}", .{ @backingInt(callback.id), callback.bytes() }),
      },
    },
    .device => |change| .{
      .device = .{
        .ieee = change.eui64,
        .nwk = change.node_id,
        .kind = switch (change.kind) {
          .joined => .joined,
          .rejoined => .rejoined,
          .left => .left,
        },
      },
    },
    .failed => |failure| .{ .failed = fromEzspFailure(failure) },
    .command_refused => |refused| .{
      .log = if (refused.value == .nwk_frame_counter or refused.value == .aps_frame_counter)
        .{
          .level = .warning,
          .message = .init(
            "ezsp: the dongle refused to set the {s} frame counter (status 0x{x}): devices " ++
              "ignore the coordinator's frames until it passes the one they last saw",
            .{
              if (refused.value == .nwk_frame_counter) "network" else "trust center",
              refused.status.value,
            },
          ),
        }
      else if (refused.value == .stack_token_writing)
        .{
          // The network is kept all the same, as far as we have seen.
          .level = .info,
          .message = .init("ezsp: the dongle refused to start writing its tokens (status 0x{x})", .{
            refused.status.value,
          }),
        }
      else
        .{
          .level = .warning,
          .message = .init("ezsp: the dongle refused {t} (status 0x{x}), which is not needed", .{
            refused.command,
            refused.status.value,
          }),
        },
    },
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

fn fromEzspNetwork(network: ezsp.driver.Network) Held {
  const p = network.parameters;
  const s = network.security;
  return .{
    .network = .{
      .channel = p.channel,
      .pan_id = p.pan_id,
      .extended_pan_id = p.extended_pan_id,
      .update_id = p.update_id,
    },
    .security = .{
      .network_key = s.network_key,
      .network_key_sequence_number = s.network_key_sequence_number,
      .network_frame_counter = s.network_frame_counter,
      .trust_center_link_key = s.trust_center_link_key,
      .trust_center_frame_counter = s.trust_center_frame_counter,
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
      .message = .init(
        "ezsp: the dongle did not answer, or did not bring its network up or down",
        .{},
      ),
    },
    .invalid_command => |status| .{
      .kind = .protocol,
      .message = .init("ezsp: the dongle rejected a command (status 0x{x})", .{ status }),
    },
    .refused => |refused| .{
      .kind = .refused,
      .message = if (refused.value) |value|
        .init("ezsp: the dongle refused {t} of {t} (status 0x{x})", .{
          refused.command,
          value,
          refused.status.value,
        })
      else
        .init("ezsp: the dongle refused {t} (status 0x{x})", .{
          refused.command,
          refused.status.value,
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
          .update_id = 2,
          .channels = 0,
        },
        .security = .{
          .network_key = @splat(0x22),
          .network_key_sequence_number = 0,
          .network_frame_counter = 70000,
          .trust_center_link_key = @splat(0x11),
          .trust_center_frame_counter = null,
        },
      },
    },
  }).ready;
  try testing.expectEqualStrings("EmberZNet 6.10.3.0 build 297, EZSP 8", ready.firmware.text());
  try testing.expectEqual(
    Network{
      .channel = 15,
      .pan_id = 0x21e0,
      .extended_pan_id = 0x814298be16f0fe69,
      .update_id = 2,
    },
    ready.network.?.network,
  );
  try testing.expectEqual(70000, ready.network.?.security.network_frame_counter);
  try testing.expectEqual(null, ready.network.?.security.trust_center_frame_counter);

  const failure = fromEzsp(.{ .failed = .{ .link = .ack_timeouts } }).failed;
  try testing.expectEqual(Failure.Kind.timeout, failure.kind);
}

test "the sim driver talks to no serial device" {
  try testing.expectEqual(null, Driver.serialDefaults(.sim));
  try testing.expectEqual(115200, Driver.serialDefaults(.ezsp).?.baudrate);
}
