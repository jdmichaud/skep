//! The sim driver: a simulated dongle, for tests that need no hardware. No byte goes to any line.
//!
//! For now it only starts, reporting the network the test gave it; it grows with the driver
//! interface, so that each feature can be tested without a dongle.

const std = @import("std");
const driver = @import("../driver.zig");

pub const Driver = struct {
  /// The network the simulated dongle holds. Tests set it before `start`.
  network: ?driver.Network = null,
  /// The coordinator's IEEE address: a locally administered one (bit 1 of the first byte), which
  /// no manufactured device carries.
  ieee: u64 = 0x0200_0000_0000_0001,
  pending: ?driver.Event = null,

  pub fn start(d: *Driver) void {
    d.pending = .{
      .ready = .{
        .ieee = d.ieee,
        .network = d.network,
        .firmware = .init("simulated dongle", .{}),
      },
    };
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
    defer d.pending = null;
    return d.pending;
  }
};

test "the simulated dongle reports the network it was given" {
  var d: Driver = .{ .network = .{ .channel = 20, .pan_id = 0x1a62, .extended_pan_id = 1 } };
  d.start();
  const ready = d.nextEvent().?.ready;
  try std.testing.expectEqual(20, ready.network.?.channel);
  try std.testing.expectEqual(null, d.nextEvent());
}
