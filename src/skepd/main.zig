//! skepd: the daemon that runs a Zigbee network with libskep. It owns the dongle and does all of
//! libskep's I/O: it opens the serial port, runs the poll loop, keeps time, and reopens the dongle
//! when it disappears. It uses libskep only through skep.h, like any other program would.
//!
//! Its options come from the command line until the configuration file format is settled.

const std = @import("std");
const c = @import("skep_h");
const serial = @import("serial");

const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

const usage =
  \\usage: skepd --device <path> [--driver <name>] [--log-level <level>] [--replace-network]
  \\             [--baud <rate>] [--rtscts]
  \\
  \\Runs the Zigbee network of the dongle on <path>. Stops cleanly on SIGTERM or SIGINT.
  \\
  \\  --device <path>     the dongle's serial device, best under /dev/serial/by-id/
  \\  --driver <name>     ezsp (default) for Silicon Labs EmberZNet dongles
  \\  --log-level <level> error, warning, info (default) or debug
  \\  --replace-network   replace the network the dongle holds with a new one; its devices
  \\                      must then be paired again
  \\  --baud <rate>       the serial speed, if not the driver's usual one
  \\  --rtscts            hardware flow control, if not the driver's usual one
  \\
;

/// How long to wait before opening the dongle again, in milliseconds.
const reopen_delay = 5000;

const Options = struct {
  device: [:0]const u8,
  driver: [:0]const u8 = "ezsp",
  log_level: [:0]const u8 = "info",
  replace_network: bool = false,
  baudrate: ?u32 = null,
  rtscts: ?bool = null,
};

fn parseOptions(args: []const [:0]const u8) ?Options {
  var device: ?[:0]const u8 = null;
  var options: Options = .{ .device = undefined };
  var i: usize = 1;
  while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "--rtscts")) {
      options.rtscts = true;
      continue;
    }
    if (std.mem.eql(u8, arg, "--replace-network")) {
      options.replace_network = true;
      continue;
    }
    i += 1;
    if (i == args.len) return null;
    const value = args[i];
    if (std.mem.eql(u8, arg, "--device")) {
      device = value;
    } else if (std.mem.eql(u8, arg, "--driver")) {
      options.driver = value;
    } else if (std.mem.eql(u8, arg, "--log-level")) {
      options.log_level = value;
    } else if (std.mem.eql(u8, arg, "--baud")) {
      options.baudrate = std.fmt.parseInt(u32, value, 10) catch return null;
    } else {
      return null;
    }
  }
  options.device = device orelse return null;
  return options;
}

const Daemon = struct {
  io: Io,
  log: *Io.Writer,
  ctx: *c.skep_ctx,
  device: [:0]const u8,
  baudrate: u32,
  rtscts: bool,
  /// The dongle, while it is open.
  fd: ?posix.fd_t = null,
  /// When to try opening the dongle again.
  reopen_at: ?u64 = null,
  /// A signal asked to stop: exit once libskep has.
  stopping: bool = false,
  exit_code: ?u8 = null,

  fn now(d: *const Daemon) u64 {
    const timestamp = Io.Clock.awake.now(d.io);
    return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
  }

  fn print(d: *Daemon, comptime format: []const u8, args: anytype) void {
    d.log.print("skepd: " ++ format ++ "\n", args) catch {};
    d.log.flush() catch {};
  }

  /// Opens the dongle and starts libskep, or tries again later.
  fn open(d: *Daemon) void {
    d.reopen_at = null;
    const fd = serial.open(d.device, d.baudrate, d.rtscts) catch |e| {
      d.print("{s}: {t}, trying again in {d} s", .{ d.device, e, reopen_delay / 1000 });
      d.reopen_at = d.now() + reopen_delay;
      return;
    };
    d.fd = fd;
    const r = c.skep_start(d.ctx);
    if (r != 0) {
      d.print("cannot start: {t}", .{ errnoName(r) });
      d.exit_code = 1;
    }
  }

  /// The dongle failed: libskep reports it with STOPPED, and the dongle is opened again.
  fn lose(d: *Daemon) void {
    if (d.fd) |fd| {
      serial.close(fd);
    }
    d.fd = null;
    c.skep_link_lost(d.ctx);
  }

  fn writeOutput(d: *Daemon) void {
    const fd = d.fd orelse return;
    while (true) {
      var data: [*c]const u8 = undefined;
      const len = c.skep_output(d.ctx, &data);
      if (len == 0) return;
      const rc = linux.write(fd, data, len);
      switch (linux.errno(rc)) {
        .SUCCESS => c.skep_output_done(d.ctx, rc, d.now()),
        .AGAIN => return,
        .INTR => {},
        else => |e| {
          d.print("{s}: write: {t}", .{ d.device, e });
          return d.lose();
        },
      }
    }
  }

  fn readInput(d: *Daemon) void {
    const fd = d.fd orelse return;
    var buffer: [512]u8 = undefined;
    const rc = linux.read(fd, &buffer, buffer.len);
    switch (linux.errno(rc)) {
      .SUCCESS => {
        if (rc == 0) {
          d.print("{s}: closed", .{ d.device });
          return d.lose();
        }
        d.check(c.skep_input(d.ctx, &buffer, rc, d.now()));
      },
      .AGAIN, .INTR => {},
      else => |e| {
        d.print("{s}: read: {t}", .{ d.device, e });
        d.lose();
      },
    }
  }

  fn check(d: *Daemon, r: c_int) void {
    // Nothing is lost when memory runs out: the next call goes on.
    if (r != 0) {
      d.print("libskep: {t}", .{ errnoName(r) });
    }
  }

  fn handleEvents(d: *Daemon) void {
    while (c.skep_next_event(d.ctx)) |event| {
      defer c.skep_event_free(event);
      switch (c.skep_event_get_type(event)) {
        c.SKEP_EVENT_LOG => {
          var message: [*c]const u8 = undefined;
          const level = c.skep_event_get_log(event, &message);
          const names = [_][]const u8{ "error", "warning", "info", "debug" };
          const name = if (level >= 0 and level < names.len) names[@intCast(level)] else "log";
          d.print("{s}: {s}", .{ name, std.mem.span(message) });
        },
        c.SKEP_EVENT_STARTED => {
          var channel: u8 = 0;
          var pan_id: u16 = 0;
          var extended_pan_id: u64 = 0;
          _ = c.skep_get_network(d.ctx, &channel, &pan_id, &extended_pan_id);
          const origins = [_][]const u8{ "?", "resumed", "restored", "formed" };
          const origin: usize = @intCast(c.skep_event_get_network_origin(event));
          d.print("network up ({s}): channel {d}, PAN ID 0x{x:0>4}, extended PAN ID 0x{x:0>16}", .{
            if (origin < origins.len) origins[origin] else "?",
            channel,
            pan_id,
            extended_pan_id,
          });
        },
        c.SKEP_EVENT_STOPPED => d.stopped(c.skep_event_get_error(event)),
        // Events of types skepd does not know are ignored, as skep.h asks.
        else => {},
      }
    }
  }

  fn stopped(d: *Daemon, error_code: c_int) void {
    if (d.fd) |fd| {
      serial.close(fd);
    }
    d.fd = null;
    if (d.stopping) {
      d.print("stopped", .{});
      d.exit_code = 0;
    } else if (error_code == -@as(c_int, @backingInt(posix.E.NOTCONN))) {
      d.print("{s}: lost, opening it again in {d} s", .{ d.device, reopen_delay / 1000 });
      d.reopen_at = d.now() + reopen_delay;
    } else {
      d.print("stopped: {t}", .{ errnoName(error_code) });
      d.exit_code = 1;
    }
  }

  /// SIGTERM or SIGINT: stop libskep cleanly, or exit if it is not running.
  fn stop(d: *Daemon) void {
    if (d.stopping) return;
    d.stopping = true;
    d.print("stopping", .{});
    const r = c.skep_stop(d.ctx);
    // Not started: nothing to stop.
    if (r == -@as(c_int, @backingInt(posix.E.NETDOWN))) {
      d.exit_code = 0;
    } else {
      d.check(r);
    }
  }

  fn run(d: *Daemon, signals: posix.fd_t) !u8 {
    d.open();
    while (true) {
      d.handleEvents();
      if (d.exit_code) |code| return code;
      d.writeOutput();

      const time = d.now();
      var deadline: ?u64 = d.reopen_at;
      var libskep_deadline: u64 = 0;
      if (c.skep_next_deadline(d.ctx, &libskep_deadline) != 0) {
        deadline = if (deadline) |t| @min(t, libskep_deadline) else libskep_deadline;
      }
      const timeout: i32 = if (deadline) |t|
        (if (t <= time) 0 else @intCast(@min(t - time, std.math.maxInt(i32))))
      else
        -1;
      var output: [*c]const u8 = undefined;
      const writing = c.skep_output(d.ctx, &output) > 0;
      var fds = [_]posix.pollfd{
        .{ .fd = signals, .events = posix.POLL.IN, .revents = 0 },
        .{
          .fd = d.fd orelse -1,
          .events = if (writing) posix.POLL.IN | posix.POLL.OUT else posix.POLL.IN,
          .revents = 0,
        },
      };
      _ = try posix.poll(&fds, timeout);

      if (fds[0].revents & posix.POLL.IN != 0) {
        var info: linux.signalfd_siginfo = undefined;
        _ = linux.read(signals, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        d.stop();
      }
      if (fds[1].revents & posix.POLL.IN != 0) {
        d.readInput();
      }
      if (fds[1].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0 and
        d.fd != null) {
        d.print("{s}: went away", .{ d.device });
        d.lose();
      }
      d.check(c.skep_advance(d.ctx, d.now()));
      if (d.reopen_at) |t| {
        if (d.now() >= t and !d.stopping) {
          d.open();
        }
      }
    }
  }
};

fn errnoName(r: c_int) posix.E {
  return @fromBackingInt(@intCast(@as(u16, @intCast(-r))));
}

pub fn main(init: std.process.Init) !u8 {
  const io = init.io;
  var stderr_buffer: [1024]u8 = undefined;
  var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
  const log = &stderr_writer.interface;
  defer log.flush() catch {};

  const args = try init.minimal.args.toSlice(init.arena.allocator());
  const options = parseOptions(args) orelse {
    try log.writeAll(usage);
    return 2;
  };

  var seed: [c.SKEP_SEED_SIZE]u8 = undefined;
  try io.randomSecure(&seed);
  var ctx: ?*c.skep_ctx = null;
  if (c.skep_new(null, &seed, &ctx) != 0) {
    try log.writeAll("skepd: out of memory\n");
    return 1;
  }
  defer c.skep_free(ctx);

  for ([_][2][:0]const u8{
    .{ "driver", options.driver },
    .{ "log-level", options.log_level },
    .{ "replace-network", if (options.replace_network) "yes" else "no" },
  }) |option| {
    const r = c.skep_set_option(ctx, option[0].ptr, option[1].ptr);
    if (r != 0) {
      try log.print("skepd: --{s} {s}: {t}\n", .{ option[0], option[1], errnoName(r) });
      return 2;
    }
  }
  var baudrate: c_uint = 0;
  var flow_control: c.enum_skep_flow_control = c.SKEP_FLOW_CONTROL_NONE;
  const r = c.skep_get_serial_defaults(ctx, &baudrate, &flow_control);
  if (r != 0) {
    try log.print("skepd: the {s} driver talks to no serial device\n", .{ options.driver });
    return 2;
  }

  // Signals arrive through a file descriptor, polled with the dongle.
  var mask = posix.sigemptyset();
  posix.sigaddset(&mask, .INT);
  posix.sigaddset(&mask, .TERM);
  posix.sigprocmask(linux.SIG.BLOCK, &mask, null);
  const signals = try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC);

  var daemon: Daemon = .{
    .io = io,
    .log = log,
    .ctx = ctx.?,
    .device = options.device,
    .baudrate = options.baudrate orelse baudrate,
    .rtscts = options.rtscts orelse (flow_control == c.SKEP_FLOW_CONTROL_HARDWARE),
  };
  return daemon.run(signals);
}
