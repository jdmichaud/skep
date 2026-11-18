//! The ezsp driver: talks to Silicon Labs EmberZNet network co-processors over ASH and EZSP.

const std = @import("std");

pub const ash = @import("ash.zig");
pub const link = @import("link.zig");
pub const frame = @import("frame.zig");
pub const command = @import("command.zig");
pub const channel = @import("channel.zig");
pub const startup = @import("startup.zig");
pub const driver = @import("driver.zig");

const test_ncp = @import("test_ncp.zig");
const fake_dongle = @import("fake_dongle.zig");

test {
  std.testing.refAllDecls(@This());
  _ = test_ncp;
  _ = fake_dongle;
}
