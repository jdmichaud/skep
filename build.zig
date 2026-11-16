const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
  const target = b.standardTargetOptions(.{});
  // Release builds (`-Drelease` or `--release`) are always ReleaseSafe: runtime safety checks stay
  // on. This also removes `-Doptimize`, so a build is either debug or ReleaseSafe.
  const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

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
  addProbe(b, test_step, target, optimize);
  if (b.isRoot()) {
    try addFormatSteps(b);
  }
}

/// `zig build probe -- <device>` resets a Silicon Labs dongle and reports its versions: the
/// minimal I/O loop around the ezsp driver. The tests build it too, so that it keeps compiling.
fn addProbe(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
) void {
  const ezsp = b.createModule(.{
    .root_source_file = b.path("src/driver/ezsp/ezsp.zig"),
    .target = target,
    .optimize = optimize,
  });
  const probe = b.addExecutable(.{
    .name = "ezsp-probe",
    .root_module = b.createModule(.{
      .root_source_file = b.path("tools/ezsp-probe.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{.{ .name = "ezsp", .module = ezsp }},
    }),
  });
  const run = b.addRunArtifact(probe);
  run.addPassthruArgs();
  b.step("probe", "Reset a Silicon Labs dongle and report its versions (-- <device>)").dependOn(
    &run.step,
  );
  test_step.dependOn(&probe.step);
}

/// `zig build fmt` formats the Zig code and `zig build fmt-check` checks it, with the zigfmt pinned
/// in build.zig.zon, so that everyone formats with the same version. Only when skep is the project
/// being built: projects that depend on skep never fetch zigfmt.
fn addFormatSteps(b: *std.Build) !void {
  const zigfmt = try b.dependencyLazy("zigfmt", .{
    .target = b.graph.host,
    .optimize = .ReleaseSafe,
  });
  const steps = [_]struct { name: []const u8, description: []const u8, args: []const []const u8 }{
    .{ .name = "fmt", .description = "Format the Zig code", .args = &.{ "." } },
    .{
      .name = "fmt-check",
      .description = "Check that the Zig code is formatted",
      .args = &.{ "--check", "." },
    },
  };
  for (steps) |step| {
    const run = b.addRunArtifact(zigfmt.artifact("zigfmt"));
    run.setCwd(b.path("."));
    run.addArgs(step.args);
    b.step(step.name, step.description).dependOn(&run.step);
  }
}

/// The headers must compile on their own as strict C99 and as C++, and translate to Zig, which is
/// how skepd uses them.
fn addHeaderChecks(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
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
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
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
