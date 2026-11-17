//! libskep's side of the ezsp driver: it drives ezsp/driver.zig as driver.zig has every driver
//! do, translating to and from EZSP's own types and messages. Not part of the ezsp module the
//! tools build on: that one knows nothing of libskep.

const std = @import("std");
const driver = @import("../driver.zig");
const ezsp = @import("ezsp.zig");

const Event = driver.Event;
const Frame = driver.Frame;
const Failure = driver.Failure;
const Held = driver.Held;
const Message = driver.Message;
const Network = driver.Network;

/// The ZBDongle-E's EmberZNet firmware, as delivered; other firmware builds use RTS/CTS.
pub const serial_defaults: driver.SerialDefaults = .{
  .baudrate = 115200,
  .flow_control = .software,
};

pub const Adapter = struct {
  driver: ezsp.driver.Driver,

  /// For a port opened with `flow_control`, or the usual one if null, and a dongle that
  /// transmits at `tx_power` dBm, or at its own power if null.
  pub fn init(flow_control: ?driver.FlowControl, tx_power: ?i8) Adapter {
    var a: Adapter = .{
      .driver = .init(.{
        .software_flow_control = (flow_control orelse serial_defaults.flow_control) == .software,
      }),
    };
    a.driver.radio_power = tx_power;
    return a;
  }

  pub fn start(a: *Adapter) void {
    a.driver.start();
  }

  pub fn form(a: *Adapter, f: driver.Form) void {
    a.driver.form(.{
      .channel = f.network.channel,
      .pan_id = f.network.pan_id,
      .extended_pan_id = f.network.extended_pan_id,
      .update_id = f.network.update_id,
      .tx_power = a.driver.radio_power orelse ezsp.driver.default_radio_power,
      .network_key = f.security.network_key,
      .network_key_sequence_number = f.security.network_key_sequence_number,
      .trust_center_link_key = f.security.trust_center_link_key,
      .frame_counters = if (f.restore)
        .{
          .network = f.security.network_frame_counter,
          .trust_center = f.security.trust_center_frame_counter orelse 0,
          .required = f.counters_required,
        }
      else
        null,
    });
  }

  pub fn send(a: *Adapter, message: *const driver.Frame) void {
    var m: ezsp.driver.Message = .{
      .address = message.address,
      .broadcast = message.broadcast,
      .aps = .{
        .profile = message.profile,
        .cluster = message.cluster,
        .source_endpoint = message.source_endpoint,
        .destination_endpoint = message.destination_endpoint,
        .options = if (message.broadcast) 0 else ezsp.command.ApsFrame.unicast_options,
      },
      .tag = message.tag,
      .len = message.len,
    };
    @memcpy(m.payload[0..m.len], message.bytes());
    a.driver.sendMessage(&m);
  }

  pub fn refresh(a: *Adapter) void {
    a.driver.refresh();
  }

  pub fn permitJoin(a: *Adapter, seconds: u8) void {
    a.driver.permitJoin(seconds);
  }

  pub fn sendNetworkKey(a: *Adapter, nwk: u16, ieee: u64, key: [16]u8) void {
    a.driver.sendNetworkKey(nwk, ieee, key);
  }

  pub fn broadcastNetworkKey(a: *Adapter, key: [16]u8) void {
    a.driver.broadcastNetworkKey(key);
  }

  pub fn switchNetworkKey(a: *Adapter) void {
    a.driver.switchNetworkKey();
  }

  pub fn input(a: *Adapter, bytes: []const u8, now: u64) void {
    a.driver.input(bytes, now);
  }

  pub fn output(a: *const Adapter) []const u8 {
    return a.driver.output();
  }

  pub fn outputDone(a: *Adapter, len: usize, now: u64) void {
    a.driver.outputDone(len, now);
  }

  pub fn nextDeadline(a: *const Adapter) ?u64 {
    return a.driver.nextDeadline();
  }

  pub fn advance(a: *Adapter, now: u64) void {
    a.driver.advance(now);
  }

  pub fn nextEvent(a: *Adapter) ?Event {
    const dropped = a.driver.takeDropped();
    if (dropped > 0) {
      return .{
        .log = .{
          .level = .err,
          .message = .init("ezsp: {d} events lost: the queue was full", .{ dropped }),
        },
      };
    }
    return fromEzsp(a.driver.nextEvent() orelse return null);
  }
};

fn fromEzsp(event: ezsp.driver.Event) Event {
  return switch (event) {
    .ready => |ready| .{
      .ready = .{
        .ieee = ready.ieee,
        .network = if (ready.network) |network| fromEzspNetwork(network) else null,
        .coordinator = if (ready.network) |network| network.node_type == .coordinator else true,
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
    .key_sent => |refused| .{
      .key_sent = if (refused) |r| fromEzspFailure(.{ .refused = r }) else null,
    },
    .key_switched => |refused| .{
      .key_switched = if (refused) |r| fromEzspFailure(.{ .refused = r }) else null,
    },
    .send_done => |done| .{
      .send_done = .{
        .tag = done.tag,
        .failure = if (done.refused) |r| fromEzspFailure(.{ .refused = r }) else null,
      },
    },
    .delivered => |delivered| .{
      .delivered = .{ .tag = delivered.tag, .ok = delivered.status.is(.ok) },
    },
    .message => |m| blk: {
      var message: Frame = .{
        .address = m.address,
        .broadcast = m.broadcast,
        .profile = m.aps.profile,
        .cluster = m.aps.cluster,
        .source_endpoint = m.aps.source_endpoint,
        .destination_endpoint = m.aps.destination_endpoint,
        .lqi = m.lqi,
        .rssi = m.rssi,
      };
      message.setPayload(m.bytes());
      break :blk .{ .message = message };
    },
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
    .restored_network_lost => .{
      .kind = .refused,
      .message = .init(
        "ezsp: the dongle did not bring the saved network back up after restarting",
        .{},
      ),
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
    .paused => .{
      .kind = .timeout,
      .message = .init("ezsp: the dongle held the line with XOFF for more than {d} s", .{
        ezsp.link.max_pause / 1000,
      }),
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
