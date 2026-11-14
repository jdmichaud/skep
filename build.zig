const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
  // `zig build --release` means ReleaseSafe: runtime safety checks stay on in releases.
  const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

  const build_options = b.addOptions();
  build_options.addOption([]const u8, "version", manifest.version);

  const skep = b.addModule("skep", .{
    .root_source_file = b.path("src/skep.zig"),
    .target = target,
    .optimize = optimize,
  });
  skep.addOptions("build_options", build_options);

  const test_step = b.step("test", "Run the unit tests");
  const unit_tests = b.addTest(.{ .root_module = skep });
  test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
