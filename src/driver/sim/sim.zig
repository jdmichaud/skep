//! The sim driver: a simulated dongle, for tests that need no hardware. No byte goes to any line.
//!
//! It holds a network and its keys, as the test gave them or as it formed them, and reports
//! devices the test makes join; it grows with the driver interface, so that each feature can be
//! tested without a dongle.

const std = @import("std");
const driver = @import("../driver.zig");

pub const Driver = struct {
  /// The network the simulated dongle holds. Tests set it before `start`, and advance its
  /// frame counters as they like.
  network: ?driver.Held = null,
  /// The coordinator's IEEE address: a locally administered one (bit 1 of the first byte), which
  /// no manufactured device carries.
  ieee: u64 = 0x0200_0000_0000_0001,
  pending: [32]driver.Event = undefined,
  pending_len: usize = 0,
  /// The messages sent, the last ones if more were.
  sent: [16]driver.Frame = undefined,
  sent_len: usize = 0,

  pub fn start(d: *Driver) void {
    d.pending_len = 0;
    d.post(.{
      .ready = .{
        .ieee = d.ieee,
        .network = d.network,
        .firmware = .init("simulated dongle", .{}),
      },
    });
  }

  /// Forms the network: the simulated dongle holds it from now on.
  pub fn form(d: *Driver, f: driver.Form) void {
    var held: driver.Held = .{ .network = f.network, .security = f.security };
    if (!f.restore) {
      held.security.network_frame_counter = 0;
      held.security.trust_center_frame_counter = 0;
    }
    d.network = held;
    d.post(.{ .formed = held });
  }

  pub fn refresh(d: *Driver) void {
    d.post(.{ .refreshed = d.network.? });
  }

  pub fn permitJoin(d: *Driver, seconds: u8) void {
    d.post(.{ .permit_join_done = null });
    d.post(.{ .join_window = seconds > 0 });
  }

  /// Takes the message; it is delivered at once.
  pub fn send(d: *Driver, message: *const driver.Frame) void {
    if (d.sent_len == d.sent.len) {
      std.mem.copyForwards(driver.Frame, d.sent[0..d.sent.len - 1], d.sent[1..]);
      d.sent_len -= 1;
    }
    d.sent[d.sent_len] = message.*;
    d.sent_len += 1;
    d.post(.{ .send_done = .{ .tag = message.tag, .failure = null } });
    d.post(.{ .delivered = .{ .tag = message.tag, .ok = true } });
  }

  /// A message comes in from a device. For tests.
  pub fn receive(d: *Driver, message: driver.Frame) void {
    d.post(.{ .message = message });
  }

  /// A simulated device joins, rejoins or leaves. For tests.
  pub fn device(d: *Driver, change: driver.Device) void {
    d.post(.{ .device = change });
  }

  fn post(d: *Driver, event: driver.Event) void {
    // Tests post few events between calls.
    d.pending[d.pending_len] = event;
    d.pending_len += 1;
  }

  pub fn input(_: *Driver, _: []const u8, _: u64) void {}

  pub fn output(_: *const Driver) []const u8 {
    return &.{};
  }

  pub fn outputDone(_: *Driver, _: usize, _: u64) void {}

  pub fn nextDeadline(_: *const Driver) ?u64 {
    return null;
  }

  pub fn advance(_: *Driver, _: u64) void {}

  pub fn nextEvent(d: *Driver) ?driver.Event {
    if (d.pending_len == 0) return null;
    const event = d.pending[0];
    std.mem.copyForwards(
      driver.Event,
      d.pending[0..d.pending_len - 1],
      d.pending[1..d.pending_len],
    );
    d.pending_len -= 1;
    return event;
  }
};

/// A network for tests, with keys of no importance.
pub fn testNetwork(network: driver.Network) driver.Held {
  return .{
    .network = network,
    .security = .{ .network_key = @splat(0x22), .trust_center_link_key = @splat(0x11) },
  };
}

test "the simulated dongle reports the network it was given" {
  var d: Driver = .{
    .network = testNetwork(.{ .channel = 20, .pan_id = 0x1a62, .extended_pan_id = 1 }),
  };
  d.start();
  const ready = d.nextEvent().?.ready;
  try std.testing.expectEqual(20, ready.network.?.network.channel);
  try std.testing.expectEqual(null, d.nextEvent());
}
