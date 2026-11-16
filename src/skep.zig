//! libskep, a small Zigbee stack.
//!
//! This is the root of the library. It will export the C API declared in `include/skep.h`.

const std = @import("std");
const build_options = @import("build_options");

/// Version of libskep, taken from `.version` in `build.zig.zon`.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(build_options.version) catch
  @compileError("invalid version in build.zig.zon");

test {
  _ = @import("driver/ezsp/ash.zig");
  _ = @import("driver/ezsp/link.zig");
  _ = @import("driver/ezsp/frame.zig");
  std.testing.refAllDecls(@This());
}
