//! ezsp-probe: starts a Silicon Labs EmberZNet dongle as the ezsp driver does, and reports its
//! versions, its IEEE address and the network it holds.
//!
//!     zig build probe -- <device> [--baud <rate>] [--rtscts] [--trace]
//!
//! A development tool, and the minimal I/O loop around the ezsp driver, which does no I/O: this
//! opens the serial port, carries bytes between it and the driver, and keeps time. Linux only.

const std = @import("std");
const ezsp = @import("ezsp");
const serial = @import("serial");

const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const Driver = ezsp.driver.Driver;

const usage =
  \\usage: ezsp-probe <device> [--baud <rate>] [--rtscts] [--trace]
  \\
  \\Resets the EmberZNet dongle on <device> and reports its EZSP and firmware versions.
  \\
  \\  --baud <rate>  57600, 115200 (default), 230400, 460800 or 921600
  \\  --rtscts       hardware flow control (RTS/CTS); XON/XOFF are honoured either way
  \\  --trace        show the bytes exchanged, on stderr
  \\
;

const Options = struct {
  device: []const u8,
  baudrate: u32 = 115200,
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
      options.baudrate = std.fmt.parseInt(u32, args[i], 10) catch return null;
      if (serial.speed(options.baudrate) == null) return null;
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

  const fd = serial.open(options.device, options.baudrate, options.rtscts) catch |e| {
    try err.print("ezsp-probe: {s}: {t}\n", .{ options.device, e });
    return 1;
  };
  defer serial.close(fd);

  var driver: Driver = .init(.{ .software_flow_control = !options.rtscts });
  const start = milliseconds(io);
  driver.start();
  const result = while (true) {
    if (try nextResult(&driver, out)) |event| break event;
    try write(fd, &driver, io, if (options.trace) err else null, start);

    const now = milliseconds(io);
    var timeout: i32 = -1;
    if (driver.nextDeadline()) |deadline| {
      timeout = if (deadline <= now) 0 else @intCast(@min(deadline - now, std.math.maxInt(i32)));
    }
    const events: i16 = if (driver.output().len > 0)
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
          driver.input(buffer[0..rc], milliseconds(io));
        },
        .AGAIN, .INTR => {},
        else => |e| {
          try err.print("ezsp-probe: {s}: read: {t}\n", .{ options.device, e });
          return 1;
        },
      }
    }
    driver.advance(milliseconds(io));
  };

  try out.print("device: {s}\n", .{ options.device });
  try out.print("XON/XOFF received: {d}\n", .{ driver.startup.link.flow_control_bytes });
  switch (result) {
    .ready => |ready| {
      try printVersion(out, ready.version);
      const f = ready.firmware;
      try out.print("firmware: {d}.{d}.{d}.{d}, build {d}, {s}\n", .{
        f.major,
        f.minor,
        f.patch,
        f.special,
        f.build,
        if (f.type == 0xaa) "general availability" else "pre-release",
      });
      try out.print("IEEE address: {x:0>16}\n", .{ ready.ieee });
      if (ready.network) |network| {
        const p = network.parameters;
        try out.print(
          "network: {t}, PAN ID 0x{x:0>4}, extended PAN ID 0x{x:0>16}, channel {d}, ",
          .{
            network.node_type,
            p.pan_id,
            p.extended_pan_id,
            p.channel,
          },
        );
        try out.print("transmit power {d} dBm, update id {d}\n", .{ p.tx_power, p.update_id });
      } else {
        try out.writeAll("network: none\n");
      }
      return 0;
    },
    .failed => |failure| {
      switch (failure) {
        .startup => |startup| try printStartupFailure(out, startup),
        .link => |link| try out.print("failed: ASH link: {any}\n", .{ link }),
        .response_timeout => try out.writeAll(
          "failed: the NCP did not answer, or its network did not come up\n",
        ),
        .invalid_command => |status| try out.print(
          "failed: the NCP rejected a command, status {d}\n",
          .{ status },
        ),
        .refused => |refused| try out.print("failed: the NCP refused {t}, status 0x{x}\n", .{
          refused.command,
          refused.status.value,
        }),
        .bad_response => try out.writeAll("failed: an answer that cannot be decoded\n"),
      }
      return 1;
    },
    // The probe neither forms networks nor sends commands it can do without.
    .configuration_refused,
    .formed,
    .command_refused,
    .permit_join_done,
    .join_window,
    .device,
    .callback,
    => unreachable,
  }
}

/// The driver's final event, if it came. Refused configuration values are only reported.
fn nextResult(driver: *Driver, out: *Io.Writer) !?ezsp.driver.Event {
  while (driver.nextEvent()) |event| {
    switch (event) {
      .configuration_refused => |refused| try out.print(
        "warning: the firmware refused configuration value {t}, status 0x{x}\n",
        .{ refused.id, refused.status.value },
      ),
      .command_refused => |refused| try out.print("warning: the NCP refused {t}, status 0x{x}\n", .{
        refused.command,
        refused.status.value,
      }),
      // The probe opens no join window, so none of these comes before ready.
      .permit_join_done, .join_window, .device, .callback => {},
      .ready, .failed, .formed => return event,
    }
  }
  return null;
}

fn printStartupFailure(out: *Io.Writer, failure: ezsp.startup.Failure) !void {
  switch (failure) {
    .link => |link| try out.print("failed: ASH link: {any}\n", .{ link }),
    .unsupported_version => |version| {
      try printVersion(out, version);
      try out.print("failed: EZSP {d} is not supported, only {d} to {d}\n", .{
        version.protocol_version,
        ezsp.frame.min_version,
        ezsp.frame.max_version,
      });
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
    .get_value => |status| try out.print("failed: reading the firmware version, status {d}\n", .{
      status,
    }),
    .bad_response => try out.writeAll("failed: an answer that cannot be decoded\n"),
  }
}

fn printVersion(out: *Io.Writer, version: ezsp.command.Version) !void {
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

fn write(fd: posix.fd_t, driver: *Driver, io: Io, tracer: ?*Io.Writer, start: u64) !void {
  while (true) {
    const pending = driver.output();
    if (pending.len == 0) return;
    const rc = linux.write(fd, pending.ptr, pending.len);
    switch (linux.errno(rc)) {
      .SUCCESS => {
        if (tracer) |w| {
          try trace(w, ">", pending[0..rc], milliseconds(io) - start);
        }
        driver.outputDone(rc, milliseconds(io));
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
