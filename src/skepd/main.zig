//! skepd: the daemon that runs a Zigbee network with libskep. It owns the dongle and does all of
//! libskep's I/O: it opens the serial port, runs the poll loop, keeps time, reopens the dongle
//! when it disappears, and keeps libskep's state in a file. It uses libskep only through skep.h,
//! like any other program would.
//!
//! Its options come from the command line until the configuration file format is settled.

const std = @import("std");
const c = @import("skep_h");
const serial = @import("serial");
const Names = @import("Names.zig");
const Protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const StateFile = @import("StateFile.zig");
const libskep = @import("libskep.zig");
const time = @import("time.zig");
const Notifier = @import("notify.zig").Notifier;

const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

const usage =
  \\usage: skepd --device <path> [--state <path>] [--socket <path>] [--driver <name>]
  \\             [--log-level <level>] [--replace-network] [--baud <rate>] [--rtscts]
  \\             [--tx-power <dBm>]
  \\
  \\Runs the Zigbee network of the dongle on <path>. Stops cleanly on SIGTERM or SIGINT.
  \\
  \\  --device <path>     the dongle's serial device, best under /dev/serial/by-id/
  \\  --state <path>      the file keeping the network, its keys and its devices, which skepd
  \\                      reads at start and replaces on each change; by default state.json in
  \\                      $STATE_DIRECTORY under systemd, in $XDG_DATA_HOME/skep otherwise
  \\  --socket <path>     the socket clients connect to, as skep-protocol(7) says; by default
  \\                      skepd.sock in $RUNTIME_DIRECTORY under systemd, in
  \\                      $XDG_RUNTIME_DIR/skep otherwise
  \\  --driver <name>     ezsp (default) for Silicon Labs EmberZNet dongles, or sim, a
  \\                      simulated network for tests, with no --device
  \\  --log-level <level> error, warning, info (default) or debug
  \\  --replace-network   replace the network the dongle holds with the saved one, or with a
  \\                      new one if no state is saved; its devices must then be paired again
  \\  --baud <rate>       the serial speed, if not the driver's usual one
  \\  --rtscts            hardware flow control, if not the driver's usual one
  \\  --tx-power <dBm>    the radio's transmit power, set at every start; the dongle's own
  \\                      by default
  \\  --help              print this, and exit
  \\
  \\skepd(8) tells more.
  \\
;

/// How long to wait before opening the dongle again, in milliseconds.
const reopen_delay = 5000;

/// How often to read the frame counters from the dongle into the state, in milliseconds: a dongle
/// that dies takes at most this long of them with it.
const refresh_interval = 3600 * 1000;

const Options = struct {
  /// Required by the drivers that talk to a serial device.
  device: ?[:0]const u8 = null,
  state: ?[:0]const u8 = null,
  socket: ?[:0]const u8 = null,
  driver: [:0]const u8 = "ezsp",
  log_level: [:0]const u8 = "info",
  replace_network: bool = false,
  baudrate: ?u32 = null,
  rtscts: ?bool = null,
  tx_power: ?[:0]const u8 = null,
};

fn parseOptions(args: []const [:0]const u8) ?Options {
  var options: Options = .{};
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
      options.device = value;
    } else if (std.mem.eql(u8, arg, "--socket")) {
      options.socket = value;
    } else if (std.mem.eql(u8, arg, "--state")) {
      options.state = value;
    } else if (std.mem.eql(u8, arg, "--driver")) {
      options.driver = value;
    } else if (std.mem.eql(u8, arg, "--log-level")) {
      options.log_level = value;
    } else if (std.mem.eql(u8, arg, "--tx-power")) {
      options.tx_power = value;
    } else if (std.mem.eql(u8, arg, "--baud")) {
      options.baudrate = std.fmt.parseInt(u32, value, 10) catch return null;
    } else {
      return null;
    }
  }
  return options;
}

const Daemon = struct {
  io: Io,
  log: *Io.Writer,
  /// Start log lines with the time, unless journald, which adds its own.
  timestamps: bool,
  gpa: std.mem.Allocator,
  ctx: *c.skep_ctx,
  /// The dongle's serial device, or null for a driver that talks to none: sim, for tests.
  device: ?[:0]const u8,
  state_path: [:0]const u8,
  /// Clients, and what they asked.
  protocol: Protocol,
  /// When to refresh the state from the dongle next, while the network is up.
  refresh_at: ?u64 = null,
  baudrate: u32,
  rtscts: bool,
  /// The dongle, while it is open.
  fd: ?posix.fd_t = null,
  /// When to try opening the dongle again.
  reopen_at: ?u64 = null,
  /// A signal asked to stop: exit once libskep has.
  stopping: bool = false,
  exit_code: ?u8 = null,
  /// systemd, when it runs skepd as a Type=notify service.
  notifier: Notifier,

  fn now(d: *const Daemon) u64 {
    const timestamp = Io.Clock.awake.now(d.io);
    return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
  }

  fn print(d: *Daemon, comptime format: []const u8, args: anytype) void {
    if (d.timestamps) {
      writeTimestamp(d.log, d.io) catch {};
    }
    d.log.print("skepd: " ++ format ++ "\n", args) catch {};
    d.log.flush() catch {};
  }

  /// Loads the saved state, if there is one. Returns an exit code if skepd cannot go on.
  fn loadState(d: *Daemon) ?u8 {
    const data = switch (StateFile.read(d.gpa, d.state_path)) {
      .none => {
        d.print("no state in {s} yet: it comes from the dongle's network", .{ d.state_path });
        return null;
      },
      .data => |data| data,
      .failed => |failure| {
        d.print("{s}: {s}: {t}", .{ d.state_path, failure.step, failure.errno });
        return 1;
      },
    };
    defer d.gpa.free(data);
    const r = c.skep_import_state(d.ctx, data.ptr, data.len);
    if (r == 0) {
      d.print("state read from {s}", .{ d.state_path });
      return null;
    }
    // The state is kept as it is: what it holds would be lost if it were replaced.
    const why = switch (libskep.errno(r)) {
      .INVAL => "not a state libskep can read; move it away to start without it",
      .OPNOTSUPP => "written by a newer skep",
      else => "cannot be read",
    };
    d.print("{s}: {s} ({t})", .{ d.state_path, why, libskep.errno(r) });
    return 1;
  }

  /// Replaces the state file with libskep's state.
  fn saveState(d: *Daemon) void {
    var len: usize = 0;
    _ = c.skep_export_state(d.ctx, null, 0, &len);
    const buffer = d.gpa.alloc(u8, len) catch {
      d.print("error: cannot save the state: out of memory", .{});
      return;
    };
    defer d.gpa.free(buffer);
    const r = c.skep_export_state(d.ctx, buffer.ptr, buffer.len, &len);
    if (r != 0) {
      d.print("error: cannot save the state: {t}", .{ libskep.errno(r) });
      return;
    }
    if (StateFile.write(d.state_path, buffer[0..len])) |failure| {
      d.print("error: cannot save the state in {s}: {s}: {t}", .{
        d.state_path,
        failure.step,
        failure.errno,
      });
    }
  }

  fn refresh(d: *Daemon) void {
    d.refresh_at = d.now() + refresh_interval;
    var request: u32 = 0;
    const r = c.skep_refresh_state(d.ctx, &request);
    // -ENOBUFS: one is already under way.
    if (r != 0 and !libskep.is(r, .NOBUFS)) {
      d.print("cannot refresh the state: {t}", .{ libskep.errno(r) });
    }
  }

  /// Tells systemd how skepd is doing, in a line `systemctl status` shows.
  fn status(d: *Daemon, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    d.notifier.send(std.fmt.bufPrint(&buffer, "STATUS=" ++ format, args) catch return);
  }

  /// Opens the dongle and starts libskep, or tries again later.
  fn open(d: *Daemon) void {
    d.reopen_at = null;
    const device = d.device orelse return d.start();
    const fd = serial.open(device, d.baudrate, d.rtscts) catch |e| {
      d.print("{s}: {t}, trying again in {d} s", .{ d.dongle(), e, reopen_delay / 1000 });
      d.status("{s}: {t}, trying again", .{ d.dongle(), e });
      d.reopen_at = d.now() + reopen_delay;
      return;
    };
    d.fd = fd;
    d.start();
  }

  /// What the log calls the dongle: its device, or the driver's name if it has none.
  fn dongle(d: *const Daemon) []const u8 {
    return d.device orelse "the simulated dongle";
  }

  fn start(d: *Daemon) void {
    const r = c.skep_start(d.ctx);
    if (r != 0) {
      d.print("cannot start: {t}", .{ libskep.errno(r) });
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
          d.print("{s}: write: {t}", .{ d.dongle(), e });
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
          d.print("{s}: closed", .{ d.dongle() });
          return d.lose();
        }
        d.check(c.skep_input(d.ctx, &buffer, rc, d.now()));
      },
      .AGAIN, .INTR => {},
      else => |e| {
        d.print("{s}: read: {t}", .{ d.dongle(), e });
        d.lose();
      },
    }
  }

  fn check(d: *Daemon, r: c_int) void {
    // Nothing is lost when memory runs out: the next call goes on.
    if (r != 0) {
      d.print("libskep: {t}", .{ libskep.errno(r) });
    }
  }

  fn handleEvents(d: *Daemon) void {
    d.protocol.now = d.now();
    while (c.skep_next_event(d.ctx)) |event| {
      defer c.skep_event_free(event);
      // A client's request ended: its response says how.
      if (d.protocol.event(event)) continue;
      switch (c.skep_event_get_type(event)) {
        c.SKEP_EVENT_LOG => {
          var message: [*c]const u8 = undefined;
          const name = switch (c.skep_event_get_log(event, &message)) {
            c.SKEP_LOG_ERROR => "error",
            c.SKEP_LOG_WARNING => "warning",
            c.SKEP_LOG_INFO => "info",
            c.SKEP_LOG_DEBUG => "debug",
            else => "log",
          };
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
          d.status("network up: channel {d}, PAN ID 0x{x:0>4}", .{ channel, pan_id });
          d.refresh_at = d.now() + refresh_interval;
        },
        c.SKEP_EVENT_STOPPED => d.stopped(c.skep_event_get_error(event)),
        c.SKEP_EVENT_STATE_CHANGED => d.saveState(),
        c.SKEP_EVENT_PERMIT_JOIN => {
          const duration = c.skep_event_get_duration(event);
          if (duration > 0) {
            d.print("join window open for {d} s", .{ duration });
          } else {
            d.print("join window closed", .{});
          }
        },
        c.SKEP_EVENT_DEVICE_JOINED => d.print("device joined: {x:0>16}", .{
          c.skep_event_get_device(event),
        }),
        c.SKEP_EVENT_DEVICE_LEFT => d.print("device left: {x:0>16}", .{
          c.skep_event_get_device(event),
        }),
        c.SKEP_EVENT_DEVICE_READY => {
          const device = c.skep_event_get_device(event);
          var manufacturer: [64]u8 = @splat(0);
          var model: [64]u8 = @splat(0);
          _ = c.skep_device_get_manufacturer(d.ctx, device, &manufacturer, manufacturer.len);
          _ = c.skep_device_get_model(d.ctx, device, &model, model.len);
          d.print("device ready: {x:0>16} ({s}, {s})", .{
            device,
            std.mem.sliceTo(&manufacturer, 0),
            std.mem.sliceTo(&model, 0),
          });
        },
        c.SKEP_EVENT_DEVICE_SETUP_FAILED => d.print(
          "device {x:0>16}: setup failed: error {d}, status 0x{x:0>2}",
          .{
            c.skep_event_get_device(event),
            c.skep_event_get_error(event),
            c.skep_event_get_status(event),
          },
        ),
        c.SKEP_EVENT_ATTRIBUTES => d.printAttributes(event),
        c.SKEP_EVENT_COMMAND => {
          var len: usize = 0;
          _ = c.skep_event_get_payload(event, &len);
          d.print("{x:0>16} {d}/0x{x:0>4}: command 0x{x:0>2}, {d} bytes", .{
            c.skep_event_get_device(event),
            c.skep_event_get_endpoint(event),
            c.skep_event_get_cluster(event),
            c.skep_event_get_command(event),
            len,
          });
        },
        c.SKEP_EVENT_REQUEST_DONE => {
          const error_code = c.skep_event_get_error(event);
          if (error_code != 0) {
            d.print("request {d} failed: {t}", .{
              c.skep_event_get_request(event),
              libskep.errno(error_code),
            });
          }
        },
        // Events of types skepd does not know are ignored, as skep.h asks.
        else => {},
      }
    }
  }

  /// One line per attribute reported: device, endpoint and cluster, attribute, value.
  fn printAttributes(d: *Daemon, event: *const c.skep_event) void {
    const device = c.skep_event_get_device(event);
    const endpoint = c.skep_event_get_endpoint(event);
    const cluster = c.skep_event_get_cluster(event);
    for (0..c.skep_event_get_attribute_count(event)) |i| {
      var a: c.struct_skep_attribute = undefined;
      if (c.skep_event_get_attribute(event, i, &a) != 0) continue;
      var buffer: [96]u8 = undefined;
      var w: Io.Writer = .fixed(&buffer);
      writeValue(&w, a.value) catch {};
      d.print("{x:0>16} {d}/0x{x:0>4}: 0x{x:0>4} = {s}", .{
        device,
        endpoint,
        cluster,
        a.id,
        w.buffered(),
      });
    }
  }

  fn stopped(d: *Daemon, error_code: c_int) void {
    if (d.fd) |fd| {
      serial.close(fd);
    }
    d.fd = null;
    d.refresh_at = null;
    if (d.stopping) {
      d.print("stopped", .{});
      d.exit_code = 0;
    } else if (libskep.is(error_code, .NOTCONN)) {
      d.print("{s}: lost, opening it again in {d} s", .{ d.dongle(), reopen_delay / 1000 });
      d.status("{s}: lost, opening it again", .{ d.dongle() });
      d.reopen_at = d.now() + reopen_delay;
    } else {
      d.print("stopped: {t}", .{ libskep.errno(error_code) });
      d.exit_code = 1;
    }
  }

  /// SIGTERM or SIGINT: stop libskep cleanly, or exit if it is not running.
  fn stop(d: *Daemon) void {
    if (d.stopping) return;
    d.stopping = true;
    d.print("stopping", .{});
    d.notifier.send("STOPPING=1");
    const r = c.skep_stop(d.ctx);
    // Not started: nothing to stop.
    if (libskep.is(r, .NETDOWN)) {
      d.exit_code = 0;
    } else {
      d.check(r);
    }
  }

  fn run(d: *Daemon, signals: posix.fd_t) !u8 {
    var fds: std.ArrayList(posix.pollfd) = .empty;
    defer fds.deinit(d.gpa);
    d.open();
    while (true) {
      d.handleEvents();
      if (d.exit_code) |code| return code;
      d.writeOutput();
      const server = &d.protocol.server;
      for (server.clients.items) |client| {
        Server.flush(client);
      }
      d.protocol.dropFinished();

      const current = d.now();
      var deadline: ?u64 = d.reopen_at;
      if (d.refresh_at) |t| {
        deadline = if (deadline) |other| @min(other, t) else t;
      }
      var libskep_deadline: u64 = 0;
      if (c.skep_next_deadline(d.ctx, &libskep_deadline) != 0) {
        deadline = if (deadline) |t| @min(t, libskep_deadline) else libskep_deadline;
      }
      const timeout: i32 = if (deadline) |t|
        (if (t <= current) 0 else @intCast(@min(t - current, std.math.maxInt(i32))))
      else
        -1;
      var output: [*c]const u8 = undefined;
      const writing = c.skep_output(d.ctx, &output) > 0;
      // Signals, the dongle, the listening socket, then the clients.
      fds.clearRetainingCapacity();
      try fds.appendSlice(
        d.gpa,
        &.{
          .{ .fd = signals, .events = posix.POLL.IN, .revents = 0 },
          .{
            .fd = d.fd orelse -1,
            .events = if (writing) posix.POLL.IN | posix.POLL.OUT else posix.POLL.IN,
            .revents = 0,
          },
          .{ .fd = server.fd, .events = posix.POLL.IN, .revents = 0 },
        },
      );
      for (server.clients.items) |client| {
        var events: i16 = 0;
        if (!client.input_closed and !client.overflowed) {
          events |= posix.POLL.IN;
        }
        if (client.output.items.len > 0) {
          events |= posix.POLL.OUT;
        }
        try fds.append(d.gpa, .{ .fd = client.fd, .events = events, .revents = 0 });
      }
      _ = try posix.poll(fds.items, timeout);

      if (fds.items[0].revents & posix.POLL.IN != 0) {
        var info: linux.signalfd_siginfo = undefined;
        _ = linux.read(signals, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        d.stop();
      }
      if (fds.items[1].revents & posix.POLL.IN != 0) {
        d.readInput();
      }
      if (fds.items[1].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0 and
        d.fd != null) {
        d.print("{s}: went away", .{ d.dongle() });
        d.lose();
      }
      // The clients polled are the first ones of the list, which accepting only adds to.
      for (fds.items[3..], 0..) |fd, i| {
        const client = server.clients.items[i];
        // Gone altogether, not only done sending: what it asked is canceled.
        if (fd.revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
          client.closing = true;
        } else if (fd.revents & posix.POLL.IN != 0) {
          server.read(client);
        }
      }
      if (fds.items[2].revents & posix.POLL.IN != 0) {
        server.accept() catch d.print("error: accepting a client: out of memory", .{});
      }
      d.protocol.now = d.now();
      d.protocol.serve();
      d.check(c.skep_advance(d.ctx, d.now()));
      if (d.refresh_at) |t| {
        if (d.now() >= t and !d.stopping) {
          d.refresh();
        }
      }
      if (d.reopen_at) |t| {
        if (d.now() >= t and !d.stopping) {
          d.open();
        }
      }
    }
  }
};

/// A ZCL value, as its type says, followed by its type.
fn writeValue(w: *Io.Writer, v: c.struct_skep_value) !void {
  switch (v.type) {
    c.SKEP_TYPE_INT8,
    c.SKEP_TYPE_INT16,
    c.SKEP_TYPE_INT24,
    c.SKEP_TYPE_INT32,
    c.SKEP_TYPE_INT64,
    => try w.print("{d}", .{ v.v.i }),
    c.SKEP_TYPE_SEMI, c.SKEP_TYPE_SINGLE, c.SKEP_TYPE_DOUBLE => try w.print("{d}", .{ v.v.f }),
    c.SKEP_TYPE_CHAR_STRING => {
      const bytes = if (v.v.bytes.data) |data| data[0..v.v.bytes.len] else "";
      try w.print("\"{s}\"", .{ bytes });
    },
    c.SKEP_TYPE_OCTET_STRING, c.SKEP_TYPE_ARRAY, c.SKEP_TYPE_STRUCT, c.SKEP_TYPE_KEY128 => {
      const bytes = if (v.v.bytes.data) |data| data[0..v.v.bytes.len] else "";
      try w.print("{x}", .{ bytes });
    },
    else => try w.print("{d}", .{ v.v.u }),
  }
  try w.print(" (type 0x{x:0>2})", .{ v.type });
}

/// The current time in UTC, as ISO 8601 with milliseconds, and a space.
fn writeTimestamp(w: *Io.Writer, io: Io) !void {
  var buffer: [32]u8 = undefined;
  try w.print("{s} ", .{ time.format(&buffer, time.now(io)) });
}

/// Whether stderr goes to journald, as systemd says in JOURNAL_STREAM ("device:inode" of the
/// stream it connected). The variable is inherited, so stderr must still be that stream.
fn toJournald(environ: *const std.process.Environ.Map) bool {
  const stream = environ.get("JOURNAL_STREAM") orelse return false;
  var fields = std.mem.splitScalar(u8, stream, ':');
  const device = std.fmt.parseInt(u64, fields.next() orelse return false, 10) catch return false;
  const inode = std.fmt.parseInt(u64, fields.next() orelse return false, 10) catch return false;
  var st: linux.Statx = undefined;
  const empty_path = 0x1000;
  if (linux.errno(linux.statx(2, "", empty_path, .{ .INO = true }, &st)) != .SUCCESS) return false;
  // st_dev as fstat(2) gives it, encoded as glibc's makedev does.
  const major: u64 = st.dev_major;
  const minor: u64 = st.dev_minor;
  const dev = (major & 0xfffff000) << 32 |
    (major & 0xfff) << 8 |
    (minor & 0xffffff00) << 12 |
    (minor & 0xff);
  return dev == device and st.ino == inode;
}

pub fn main(init: std.process.Init) !u8 {
  const io = init.io;
  var stderr_buffer: [1024]u8 = undefined;
  var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
  const log = &stderr_writer.interface;
  defer log.flush() catch {};

  const args = try init.minimal.args.toSlice(init.arena.allocator());
  for (args[1..]) |arg| {
    if (!std.mem.eql(u8, arg, "--help")) continue;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &.{});
    try stdout_writer.interface.writeAll(usage);
    return 0;
  }
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
      try log.print("skepd: --{s} {s}: {t}\n", .{ option[0], option[1], libskep.errno(r) });
      return 2;
    }
  }
  var baudrate: c_uint = 0;
  var flow_control: c.enum_skep_flow_control = c.SKEP_FLOW_CONTROL_NONE;
  const serial_port = c.skep_get_serial_defaults(ctx, &baudrate, &flow_control) == 0;
  if (serial_port and options.device == null) {
    try log.print("skepd: the {s} driver needs --device\n", .{ options.driver });
    try log.writeAll(usage);
    return 2;
  }
  if (!serial_port and options.device != null) {
    try log.print("skepd: the {s} driver talks to no serial device: no --device\n", .{
      options.driver,
    });
    return 2;
  }
  if (options.tx_power) |power| {
    if (c.skep_set_option(ctx, "tx-power", power.ptr) != 0) {
      try log.print("skepd: --tx-power {s}: dBm, from -128 to 127\n", .{ power });
      return 2;
    }
  }

  const rtscts = options.rtscts orelse (flow_control == c.SKEP_FLOW_CONTROL_HARDWARE);
  // XON and XOFF are libskep's to handle, and to warn of when the port uses RTS/CTS instead.
  if (rtscts and c.skep_set_option(ctx, "flow-control", "hardware") != 0) {
    try log.writeAll("skepd: --rtscts: libskep takes no flow control\n");
    return 2;
  }

  const state_path = options.state orelse
    StateFile.defaultPath(init.arena.allocator(), init.environ_map) orelse {
    try log.writeAll(
      "skepd: no --state, and no STATE_DIRECTORY, XDG_DATA_HOME or HOME to put it in\n",
    );
    return 2;
  };

  const socket_path = options.socket orelse
    defaultSocket(init.arena.allocator(), init.environ_map) orelse {
    try log.writeAll(
      "skepd: no --socket, and no RUNTIME_DIRECTORY or XDG_RUNTIME_DIR to put it in\n",
    );
    return 2;
  };
  var errno: linux.E = .SUCCESS;
  var server = Server.open(init.gpa, socket_path, &errno) catch |e| {
    switch (e) {
      error.InUse => try log.print("skepd: {s}: another skepd answers on it\n", .{ socket_path }),
      error.System => try log.print("skepd: {s}: {t}\n", .{ socket_path, errno }),
      else => try log.print("skepd: {s}: {t}\n", .{ socket_path, e }),
    }
    return 1;
  };
  errdefer server.deinit();
  const names_path = try std.fmt.allocPrintSentinel(
    init.arena.allocator(),
    "{s}/names.json",
    .{ std.fs.path.dirname(state_path) orelse "." },
    0,
  );
  const names = Names.load(init.gpa, names_path) catch |e| {
    try log.print("skepd: {s}: {t}\n", .{ names_path, e });
    return 1;
  };

  // Signals arrive through a file descriptor, polled with the dongle.
  var mask = posix.sigemptyset();
  posix.sigaddset(&mask, .INT);
  posix.sigaddset(&mask, .TERM);
  posix.sigprocmask(linux.SIG.BLOCK, &mask, null);
  const signals = try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC);

  var daemon: Daemon = .{
    .io = io,
    .log = log,
    .timestamps = !toJournald(init.environ_map),
    .gpa = init.gpa,
    .ctx = ctx.?,
    .device = options.device,
    .state_path = state_path,
    .protocol = .{
      .gpa = init.gpa,
      .io = io,
      .ctx = ctx.?,
      .server = server,
      .names = names,
      .names_path = names_path,
      .readings = .{ .gpa = init.gpa },
    },
    .baudrate = options.baudrate orelse baudrate,
    .rtscts = rtscts,
    .notifier = .init(init.environ_map),
  };
  defer daemon.protocol.deinit();
  defer daemon.notifier.deinit();
  daemon.print("listening on {s}", .{ socket_path });
  if (daemon.loadState()) |code| return code;
  // Ready once clients can connect: the network comes up when the dongle answers, which may
  // take a while, or wait for it to be plugged in.
  daemon.notifier.send("READY=1\nSTATUS=opening the dongle");
  return daemon.run(signals);
}

/// Where the socket goes by default: the runtime directory systemd gives the service, or the
/// XDG runtime directory. Null if neither is set.
fn defaultSocket(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[:0]const u8 {
  if (environ.get("RUNTIME_DIRECTORY")) |directories| {
    var it = std.mem.splitScalar(u8, directories, ':');
    const first = it.first();
    if (first.len > 0) {
      return std.fmt.allocPrintSentinel(arena, "{s}/skepd.sock", .{ first }, 0) catch null;
    }
  }
  const runtime = environ.get("XDG_RUNTIME_DIR") orelse return null;
  if (!std.fs.path.isAbsolute(runtime)) return null;
  return std.fmt.allocPrintSentinel(arena, "{s}/skep/skepd.sock", .{ runtime }, 0) catch null;
}

test {
  _ = @import("Names.zig");
  _ = @import("Server.zig");
  _ = @import("StateFile.zig");
  _ = @import("values.zig");
  _ = @import("protocol.zig");
  _ = @import("notify.zig");
  _ = @import("Readings.zig");
  _ = @import("libskep.zig");
  _ = @import("time.zig");
  // libskep's sources, whose exports the tests call: the test build has no library to link.
  _ = @import("libskep");
}
