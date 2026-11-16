//! ezsp-probe: resets a Silicon Labs EmberZNet dongle and reports its EZSP and firmware versions.
//!
//!     zig build probe -- <device> [--baud <rate>] [--rtscts] [--trace]
//!
//! A development tool, and the minimal I/O loop around the ezsp driver, which does no I/O: this
//! opens the serial port, carries bytes between it and the driver, and keeps time. Linux only.

const std = @import("std");
const ezsp = @import("ezsp");

const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const Startup = ezsp.startup.Startup;

const usage =
  \\usage: ezsp-probe <device> [--baud <rate>] [--rtscts] [--trace]
  \\
  \\Resets the EmberZNet dongle on <device> and reports its EZSP and firmware versions.
  \\
  \\  --baud <rate>  57600, 115200 (default), 230400 or 460800
  \\  --rtscts       hardware flow control (RTS/CTS); XON/XOFF are honoured either way
  \\  --trace        show the bytes exchanged, on stderr
  \\
;

const Options = struct {
  device: []const u8,
  speed: linux.speed_t = .B115200,
  rtscts: bool = false,
  trace: bool = false,
};

fn parseOptions(args: []const [:0]const u8) ?Options {
  var device: ?[]const u8 = null;
  var options: Options = .{ .device = undefined };
  var i: usize = 1;
  while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "--rtscts")) {
      options.rtscts = true;
    } else if (std.mem.eql(u8, arg, "--trace")) {
      options.trace = true;
    } else if (std.mem.eql(u8, arg, "--baud")) {
      i += 1;
      if (i == args.len) return null;
      options.speed = if (std.mem.eql(u8, args[i], "57600"))
        .B57600
      else if (std.mem.eql(u8, args[i], "115200"))
        .B115200
      else if (std.mem.eql(u8, args[i], "230400"))
        .B230400
      else if (std.mem.eql(u8, args[i], "460800"))
        .B460800
      else
        return null;
    } else if (arg.len > 0 and arg[0] == '-' or device != null) {
      return null;
    } else {
      device = arg;
    }
  }
  options.device = device orelse return null;
  return options;
}

pub fn main(init: std.process.Init) !u8 {
  const io = init.io;
  var stdout_buffer: [1024]u8 = undefined;
  var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
  const out = &stdout_writer.interface;
  defer out.flush() catch {};
  var stderr_buffer: [1024]u8 = undefined;
  var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
  const err = &stderr_writer.interface;
  defer err.flush() catch {};

  const args = try init.minimal.args.toSlice(init.arena.allocator());
  const options = parseOptions(args) orelse {
    try err.writeAll(usage);
    return 2;
  };

  const fd = posix.openat(
    posix.AT.FDCWD,
    options.device,
    .{
      .ACCMODE = .RDWR,
      .NOCTTY = true,
      .NONBLOCK = true,
      .CLOEXEC = true,
    },
    0,
  ) catch |e| {
    try err.print("ezsp-probe: {s}: {t}\n", .{ options.device, e });
    return 1;
  };
  configure(fd, options) catch |e| {
    try err.print("ezsp-probe: {s}: cannot configure the serial port: {t}\n", .{
      options.device,
      e,
    });
    return 1;
  };

  var startup: Startup = .init(.{ .software_flow_control = !options.rtscts });
  const start = milliseconds(io);
  startup.start();
  while (startup.result == null) {
    try write(fd, &startup, io, if (options.trace) err else null, start);

    const now = milliseconds(io);
    var timeout: i32 = -1;
    if (startup.nextDeadline()) |deadline| {
      timeout = if (deadline <= now) 0 else @intCast(@min(deadline - now, std.math.maxInt(i32)));
    }
    const events: i16 = if (startup.output().len > 0)
      posix.POLL.IN | posix.POLL.OUT
    else
      posix.POLL.IN;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    _ = try posix.poll(&fds, timeout);
    if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
      try err.print("ezsp-probe: {s}: the device went away\n", .{ options.device });
      return 1;
    }
    if (fds[0].revents & posix.POLL.IN != 0) {
      var buffer: [512]u8 = undefined;
      const rc = linux.read(fd, &buffer, buffer.len);
      switch (linux.errno(rc)) {
        .SUCCESS => {
          if (options.trace) {
            try trace(err, "<", buffer[0..rc], milliseconds(io) - start);
          }
          startup.input(buffer[0..rc], milliseconds(io));
        },
        .AGAIN, .INTR => {},
        else => |e| {
          try err.print("ezsp-probe: {s}: read: {t}\n", .{ options.device, e });
          return 1;
        },
      }
    }
    startup.advance(milliseconds(io));
  }

  try out.print("device: {s}\n", .{ options.device });
  try out.print("XON/XOFF received: {d}\n", .{ startup.link.flow_control_bytes });
  switch (startup.result.?) {
    .done => |info| {
      try printVersion(out, info.version);
      const f = info.firmware;
      try out.print("firmware: {d}.{d}.{d}.{d}, build {d}, {s}\n", .{
        f.major,
        f.minor,
        f.patch,
        f.special,
        f.build,
        if (f.type == 0xaa) "general availability" else "pre-release",
      });
      return 0;
    },
    .failed => |failure| {
      switch (failure) {
        .link => |link| try out.print("failed: ASH link: {any}\n", .{ link }),
        .unsupported_version => |version| {
          try printVersion(out, version);
          try out.print(
            "failed: EZSP {d} is not supported, only {d} to {d} (EmberZNet 7.4 or newer)\n",
            .{ version.protocol_version, ezsp.frame.min_version, ezsp.frame.max_version },
          );
        },
        .unsupported_stack => |version| {
          try printVersion(out, version);
          try out.print("failed: stack type {d} is not EmberZNet's mesh stack\n", .{
            version.stack_type,
          });
        },
        .response_timeout => try out.writeAll("failed: the NCP did not answer a command\n"),
        .invalid_command => |status| try out.print(
          "failed: the NCP rejected a command, status {d}\n",
          .{ status },
        ),
        .get_value => |status| try out.print(
          "failed: reading the firmware version, status {d}\n",
          .{ status },
        ),
        .bad_response => try out.writeAll("failed: an answer that cannot be decoded\n"),
      }
      return 1;
    },
  }
}

fn printVersion(out: *Io.Writer, version: ezsp.frame.Version) !void {
  const v = version.stack_version;
  try out.print("EZSP protocol version: {d}\n", .{ version.protocol_version });
  try out.print("stack: type {d}, version {d}.{d}.{d}.{d}\n", .{
    version.stack_type,
    v >> 12,
    v >> 8 & 0xf,
    v >> 4 & 0xf,
    v & 0xf,
  });
}

/// Raw mode, 8N1, at the chosen speed. XON/XOFF stay in the data: the driver handles them.
fn configure(fd: posix.fd_t, options: Options) !void {
  var t = try posix.tcgetattr(fd);
  t.iflag = .{};
  t.oflag = .{};
  t.lflag = .{};
  t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true, .CRTSCTS = options.rtscts };
  // The speed is in the CBAUD bits of cflag (asm-generic layout: x86, ARM, RISC-V).
  const cbaud: u32 = 0o010017;
  const cflag: u32 = @bitCast(t.cflag);
  t.cflag = @bitCast(cflag & ~cbaud | @backingInt(options.speed));
  t.ispeed = options.speed;
  t.ospeed = options.speed;
  t.cc[@backingInt(linux.V.MIN)] = 0;
  t.cc[@backingInt(linux.V.TIME)] = 0;
  try posix.tcsetattr(fd, .NOW, t);
  // Drop what arrived before: the reset starts afresh.
  _ = linux.ioctl(fd, linux.T.CFLSH, 0);
}

fn write(fd: posix.fd_t, startup: *Startup, io: Io, tracer: ?*Io.Writer, start: u64) !void {
  while (true) {
    const pending = startup.output();
    if (pending.len == 0) return;
    const rc = linux.write(fd, pending.ptr, pending.len);
    switch (linux.errno(rc)) {
      .SUCCESS => {
        if (tracer) |w| {
          try trace(w, ">", pending[0..rc], milliseconds(io) - start);
        }
        startup.outputDone(rc, milliseconds(io));
      },
      .AGAIN => return,
      .INTR => {},
      else => |e| {
        std.debug.print("ezsp-probe: write: {t}\n", .{ e });
        return error.WriteFailed;
      },
    }
  }
}

fn trace(w: *Io.Writer, direction: []const u8, bytes: []const u8, at: u64) !void {
  try w.print("{d:>6} ms {s} {x}\n", .{ at, direction, bytes });
  try w.flush();
}

/// A monotonic clock in milliseconds, as libskep expects.
fn milliseconds(io: Io) u64 {
  const now = Io.Clock.awake.now(io);
  return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}
