//! libskep, a small Zigbee stack.
//!
//! This is the root of the library. It will export the C API declared in `include/skep.h`.

const std = @import("std");
const build_options = @import("build_options");

/// Version of libskep, taken from `.version` in `build.zig.zon`.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(build_options.version) catch
  @compileError("invalid version in build.zig.zon");

test {
  _ = @import("allocator.zig");
  _ = @import("driver/driver.zig");
  _ = @import("driver/ezsp/ezsp.zig");
  std.testing.refAllDecls(@This());
}
