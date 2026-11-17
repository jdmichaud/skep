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
    // Without an allocator from the application, memory comes from malloc().
    .link_libc = true,
  });
  skep.addOptions("build_options", build_options);

  const library = addLibrary(b, skep);

  const test_step = b.step("test", "Run the unit tests");
  // skep.h as Zig sees it: how skepd uses libskep.
  const skep_h = b.addTranslateC(.{
    .root_source_file = b.path("include/skep.h"),
    .target = target,
    .optimize = optimize,
  }).createModule();
  // The unit tests, which also compare the structs of skep.h with libskep's: the header is
  // theirs to import, not the library's.
  const tested = b.createModule(.{
    .root_source_file = b.path("src/skep.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
    .imports = &.{.{ .name = "skep_h", .module = skep_h }},
  });
  tested.addOptions("build_options", build_options);
  test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tested })).step);
  addHeaderChecks(b, test_step, target, optimize, build_options, skep_h);
  addAbiCheck(b, test_step, target, optimize, library);
  // Opening a dongle's serial port, for the programs that do.
  const serial = b.createModule(.{
    .root_source_file = b.path("src/serial/serial.zig"),
    .target = target,
    .optimize = optimize,
  });
  test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = serial })).step);
  addProbe(b, test_step, target, optimize, serial);
  // Escaping text from devices, for the programs that print it.
  const printable = b.createModule(.{
    .root_source_file = b.path("src/printable.zig"),
    .target = target,
    .optimize = optimize,
  });
  test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = printable })).step);
  const skepd_tested =
    addSkepd(
      b,
      test_step,
      target,
      optimize,
      skep_h,
      serial,
      printable,
      library,
      skep,
      build_options,
    );
  addSkep(b, test_step, target, optimize, printable, build_options);
  addFuzzStep(
    b,
    &.{
      .{
        .module = tested,
        .tests = &.{
          "fuzz: libskep survives whatever the dongle sends",
          "fuzz: ZDO responses are parsed safely",
          "fuzz: reading survives any document, and what it reads is written back the same",
          "fuzz: frames and values from devices are parsed safely",
          "fuzz: decoding survives any frame",
          "fuzz: the link survives any NCP",
          "fuzz: the decoder survives any input",
          "fuzz: decoding gives back what was encoded",
          "fuzz: parsing survives any parameters",
        },
      },
      .{
        .module = skepd_tested,
        .tests = &.{ "fuzz: whatever a client sends, skepd answers in JSON" },
      },
      .{ .module = printable, .tests = &.{ "fuzz: what is escaped prints as it is" } },
    },
  );
  if (b.isRoot()) {
    try addFormatSteps(b);
    try addManpages(b);
    addSystemdFiles(b);
  }
}

/// `zig build` installs libskep as a static and a shared library, whose soname carries the major
/// version, the ABI version; its headers; and libskep.pc for pkg-config. Returns the static
/// library, for programs built here.
fn addLibrary(b: *std.Build, skep: *std.Build.Module) *std.Build.Step.Compile {
  const version = std.SemanticVersion.parse(manifest.version) catch
    @panic("invalid version in build.zig.zon");
  const static = b.addLibrary(.{ .name = "skep", .linkage = .static, .root_module = skep });
  const shared = b.addLibrary(.{
    .name = "skep",
    .linkage = .dynamic,
    .root_module = skep,
    .version = version,
  });
  b.installArtifact(static);
  b.installArtifact(shared);
  // One by one: with Zig 0.17, installing the include directory into a prefix that does not exist
  // yet installs nothing.
  for ([_][]const u8{ "skep.h", "skep/zcl.h" }) |header| {
    b.getInstallStep().dependOn(
      &b.addInstallHeaderFile(b.path(b.fmt("include/{s}", .{ header })), header).step,
    );
  }
  const pc = b.addWriteFiles().add(
    "libskep.pc",
    b.fmt(
      \\prefix=${{pcfiledir}}/../..
      \\libdir=${{prefix}}/lib
      \\includedir=${{prefix}}/include
      \\
      \\Name: libskep
      \\Description: A small Zigbee stack
      \\Version: {s}
      \\Libs: -L${{libdir}} -lskep
      \\Cflags: -I${{includedir}}
      \\
    , .{ manifest.version }),
  );
  b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/libskep.pc").step);
  return static;
}

/// A C program linked with the static library checks that the implementation matches skep.h:
/// struct layouts, enums, pointers and errno values, through the real C ABI.
fn addAbiCheck(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
  library: *std.Build.Step.Compile,
) void {
  const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
  module.addIncludePath(b.path("include"));
  module.addCSourceFile(.{
    .file = b.path("test/abi.c"),
    .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
  });
  module.linkLibrary(library);
  const abi = b.addExecutable(.{ .name = "abi", .root_module = module });
  test_step.dependOn(&b.addRunArtifact(abi).step);
}

/// skepd, which uses libskep through skep.h only: its module, in src/skepd/, imports nothing of
/// libskep's sources, which a Zig module cannot reach outside its directory.
fn addSkepd(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
  skep_h: *std.Build.Module,
  serial: *std.Build.Module,
  printable: *std.Build.Module,
  library: *std.Build.Step.Compile,
  skep: *std.Build.Module,
  build_options: *std.Build.Step.Options,
) *std.Build.Module {
  const module = b.createModule(.{
    .root_source_file = b.path("src/skepd/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
      .{ .name = "skep_h", .module = skep_h },
      .{ .name = "serial", .module = serial },
      .{ .name = "printable", .module = printable },
    },
  });
  module.linkLibrary(library);
  module.addOptions("build_options", build_options);
  const skepd = b.addExecutable(.{ .name = "skepd", .root_module = module });
  b.installArtifact(skepd);
  const run = b.addRunArtifact(skepd);
  run.addPassthruArgs();
  b.step("skepd", "Run skepd (-- --device <path>)").dependOn(&run.step);
  // The parts of skepd that need no dongle, with libskep's sources rather than the library, so
  // that tests can give the sim driver its devices: skepd itself knows libskep by skep.h only.
  const tested = b.createModule(.{
    .root_source_file = b.path("src/skepd/main.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
    .imports = &.{
      .{ .name = "skep_h", .module = skep_h },
      .{ .name = "serial", .module = serial },
      .{ .name = "printable", .module = printable },
      .{ .name = "libskep", .module = skep },
      // libskep's own: a file belongs to one module of a binary.
      .{ .name = "build_options", .module = skep.import_table.get("build_options").? },
    },
  });
  test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tested })).step);
  return tested;
}

/// The fuzz tests of a module, by name.
const Fuzzed = struct {
  module: *std.Build.Module,
  tests: []const []const u8,
};

/// `zig build fuzz --fuzz[=N] -Drelease` fuzzes every fuzz test at once, each in a process of
/// its own: the fuzzer runs one process per run of a test binary, which fuzzes its tests in turn,
/// and refuses two processes on one test. Each test is a binary of its own, filtered to it. A
/// fuzz test missing from the list is fuzzed by `zig build test --fuzz` only.
fn addFuzzStep(b: *std.Build, fuzzed: []const Fuzzed) void {
  const step = b.step("fuzz", "Fuzz every fuzz test at once (with --fuzz and -Drelease)");
  for (fuzzed) |f| {
    for (f.tests) |name| {
      const binary = b.addTest(.{ .root_module = f.module, .filters = &.{ name } });
      step.dependOn(&b.addRunArtifact(binary).step);
    }
  }
}

/// `zig build probe -- <device>` resets a Silicon Labs dongle and reports its versions: the
/// minimal I/O loop around the ezsp driver. The tests build it too, so that it keeps compiling.
fn addProbe(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
  serial: *std.Build.Module,
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
      .imports = &.{.{ .name = "ezsp", .module = ezsp }, .{ .name = "serial", .module = serial }},
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
  skep_h: *std.Build.Module,
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

  const translated = b.addTest(.{
    .root_module = b.createModule(.{
      .root_source_file = b.path("test/header.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{
        .{ .name = "skep_h", .module = skep_h },
        .{ .name = "build_options", .module = build_options.createModule() },
      },
    }),
  });
  test_step.dependOn(&b.addRunArtifact(translated).step);
}

/// The man pages, written in scdoc in man/: `zig build` renders them with the zzdoc pinned in
/// build.zig.zon and installs them. Only when skep is the project being built.
fn addManpages(b: *std.Build) !void {
  const zzdoc = try b.dependencyLazy("zzdoc", .{
    .target = b.graph.host,
    .optimize = .ReleaseSafe,
  });
  const run = b.addRunArtifact(zzdoc.artifact("zzdoc"));
  // The build system caches directory arguments by path, not contents: render every time, which
  // takes milliseconds.
  run.has_side_effects = true;
  run.addDirectoryArg2(b.path("man"), .{});
  const rendered = run.addOutputDirectoryArg2("man", .{});
  // One at a time: with Zig 0.17, installing a directory into a prefix that does not exist yet
  // installs nothing.
  for ([_][]const u8{ "man1/skep.1", "man7/skep-protocol.7", "man8/skepd.8" }) |page| {
    const install = b.addInstallFileWithDir(
      rendered.path(b, page),
      .{ .custom = b.fmt("share/man/{s}", .{ std.fs.path.dirname(page).? }) },
      std.fs.path.basename(page),
    );
    b.getInstallStep().dependOn(&install.step);
  }
}

/// skep, the command-line client of skepd: a program of its own, which talks to skepd's socket and
/// knows nothing of libskep. `zig build skep -- <command>` runs it.
fn addSkep(
  b: *std.Build,
  test_step: *std.Build.Step,
  target: std.Build.ResolvedTarget,
  optimize: std.lang.Optimize,
  printable: *std.Build.Module,
  build_options: *std.Build.Step.Options,
) void {
  const module = b.createModule(.{
    .root_source_file = b.path("src/skep/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "printable", .module = printable }},
  });
  module.addOptions("build_options", build_options);
  const skep = b.addExecutable(.{ .name = "skep", .root_module = module });
  b.installArtifact(skep);
  const run = b.addRunArtifact(skep);
  run.addPassthruArgs();
  b.step("skep", "Run skep (-- <command>)").dependOn(&run.step);
  test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

/// The systemd units of skepd, for the system and for users, and the user its system unit runs as:
/// `zig build` installs them where systemd looks under the prefix, lib/systemd and lib/sysusers.d.
/// Only when skep is the project being built.
fn addSystemdFiles(b: *std.Build) void {
  for ([_][2][]const u8{
    .{ "systemd/system/skepd@.service", "lib/systemd/system" },
    .{ "systemd/user/skepd@.service", "lib/systemd/user" },
    .{ "systemd/sysusers.d/skep.conf", "lib/sysusers.d" },
  }) |file| {
    const install = b.addInstallFileWithDir(
      b.path(file[0]),
      .{ .custom = file[1] },
      std.fs.path.basename(file[0]),
    );
    b.getInstallStep().dependOn(&install.step);
  }
}
