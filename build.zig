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
  addHeaderChecks(b, test_step, target, optimize, build_options);
}

/// skep.h must compile on its own as strict C99 and as C++, and translate to Zig, which is how
/// skepd uses it.
fn addHeaderChecks(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.builtin.OptimizeMode,
  build_options: *std.Build.Step.Options,
) void {
  const warnings: []const []const u8 = &.{ "-Wall", "-Wextra", "-Wpedantic", "-Werror" };
  const sources = [_]struct { name: []const u8, file: []const u8, flags: []const []const u8 }{
    .{
      .name = "header_c",
      .file = "test/header.c",
      .flags = &.{ "-std=c99", "-Wstrict-prototypes", "-Wmissing-prototypes" },
    },
    .{ .name = "header_cpp", .file = "test/header.cpp", .flags = &.{ "-std=c++11" } },
  };
  for (sources) |source| {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{
      .file = b.path(source.file),
      .flags = std.mem.concat(b.allocator, []const u8, &.{ warnings, source.flags }) catch
        @panic("OOM"),
    });
    const object = b.addObject(.{ .name = source.name, .root_module = module });
    test_step.dependOn(&object.step);
  }

  const skep_h = b.addTranslateC(.{
    .root_source_file = b.path("include/skep.h"),
    .target = target,
    .optimize = optimize,
  });
  const translated = b.addTest(.{
    .root_module = b.createModule(.{
      .root_source_file = b.path("test/header.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{
        .{ .name = "skep_h", .module = skep_h.createModule() },
        .{ .name = "build_options", .module = build_options.createModule() },
      },
    }),
  });
  test_step.dependOn(&b.addRunArtifact(translated).step);
}
