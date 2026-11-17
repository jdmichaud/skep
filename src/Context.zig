//! A context: everything libskep knows about one dongle and the network it coordinates. Applications
//! hold it as the opaque `skep_ctx`; skep.zig turns the C API into calls on it.
//!
//! There is no global state: two contexts share nothing, so a program can drive several dongles.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;
const Event = @import("Event.zig");
const State = @import("State.zig");
const driver_layer = @import("driver/driver.zig");
const sim = @import("driver/sim/sim.zig");
const exchange = @import("exchange.zig");
const requests = @import("requests.zig");
const setup = @import("setup.zig");
const zdo = @import("zdo.zig");
const zcl = @import("zcl.zig");

const Context = @This();

const E = std.posix.E;

/// The application's allocator, or null for the C library's. `gpa` points at it.
c_allocator: ?CAllocator,
gpa: std.mem.Allocator,
random: std.Random.DefaultCsprng,
options: Options = .{},
status: Status = .idle,
driver: ?driver_layer.Driver = null,
/// The simulated dongle the sim driver starts with. Tests change it before `start`.
sim_dongle: sim.Driver = .{},
ieee: u64 = 0,
network: ?driver_layer.Network = null,
/// What must survive a restart: imported, or taken from the network once up. Kept across stops,
/// so that the next start comes back to the same network.
state: ?State = null,
/// The network being formed is the state's, put back onto the dongle.
restoring: bool = false,
events: Event.Queue = .{},
/// Events allocated ahead, so that taking an event from the driver never loses it to a failed
/// allocation, and `linkLost` can report without allocating.
spares: Event.Queue = .{},
/// The state changed since SKEP_EVENT_STATE_CHANGED last said so. One event says it, after the
/// step that changed it, however many changes the step made: an interview moving through
/// several stages at once among them.
state_changed_pending: bool = false,
/// The id of the next request.
next_request: u32 = 1,
/// What the driver was asked to do and has not done, in order: one thing at a time, the first
/// being under way when the driver is busy with an operation.
ops: [max_ops]Op = undefined,
ops_len: usize = 0,
busy: Busy = .idle,
/// The time last given, on the application's clock.
now: u64 = 0,
/// What is asked of devices, and waits for their answers.
exchanges: std.ArrayList(exchange.Exchange) = .empty,
next_exchange: u32 = 0,
/// Sequence numbers of ZDO and ZCL frames, and tags of the frames given to the driver.
zdo_sequence: u8 = 0,
zcl_sequence: u8 = 0,
next_tag: u8 = 0,
/// `stop` was called: once the driver is idle, the state is refreshed, then the context stops.
stopping: bool = false,
/// The join window last asked for, in seconds, reported when the dongle opens it.
window_seconds: u8 = 0,
/// Requests ended without a spare event to report them, by `linkLost`: still to be queued.
canceled_pending: [max_ops + requests.max_pending]u32 = undefined,
canceled_len: usize = 0,
/// The error of a STOPPED event still to be queued, after the canceled requests.
stopped_pending: ?c_int = null,

pub const Status = enum { idle, starting, running, stopped };

/// What the driver is busy with.
const Busy = union(enum) {
  idle,
  /// The first of `ops`.
  op,
  /// The first of `ops`, a join window, whose broadcast to the routers is this frame.
  routers: u8,
  /// A frame of an exchange.
  frame: u8,
};

/// Something the driver is asked to do.
const Op = struct {
  kind: enum { permit_join, refresh },
  /// The request it ends; null once canceled, and for the refresh `stop` makes.
  request: ?u32,
  seconds: u8 = 0,
};

/// One join window and one refresh at a time.
const max_ops = 2;

pub const Options = struct {
  driver: ?driver_layer.Name = null,
  log_level: driver_layer.Level = .warning,
  frame_counter_margin: u32 = 100000,
  replace_network: bool = false,
  channel: u8 = 15,
  pan_id: ?u16 = null,
  extended_pan_id: ?u64 = null,
  network_key: ?[16]u8 = null,
};

/// The names of `driver_layer.Level`, in its order.
const LogLevelName = enum { @"error", warning, info, debug };

/// Spare events kept ready, as many as a driver event can lead to, besides the state change,
/// which takes one after, and log messages, which take none: a failure ends both requests and
/// stops the context; a device that leaves on request ends the request and is reported gone.
const spare_count = 2 + max_ops;

/// Creates a context. With `allocator` null, memory comes from the C library.
pub fn create(allocator: ?CAllocator, seed: [32]u8) error{ OutOfMemory }!*Context {
  var copy = allocator;
  const gpa = if (copy) |*c| c.allocator() else std.heap.c_allocator;
  const ctx = try gpa.create(Context);
  ctx.* = .{ .c_allocator = allocator, .gpa = undefined, .random = .init(seed) };
  ctx.gpa = if (ctx.c_allocator) |*c| c.allocator() else std.heap.c_allocator;
  ctx.fillSpares() catch {
    ctx.spares.destroyAll();
    gpa.destroy(ctx);
    return error.OutOfMemory;
  };
  return ctx;
}

pub fn destroy(ctx: *Context) void {
  if (ctx.state) |*s| {
    s.deinit(ctx.gpa);
  }
  ctx.exchanges.deinit(ctx.gpa);
  ctx.events.destroyAll();
  ctx.spares.destroyAll();
  var copy = ctx.c_allocator;
  const gpa = if (copy) |*c| c.allocator() else std.heap.c_allocator;
  gpa.destroy(ctx);
}

/// Sets an option, as `skep_set_option`. Returns 0 or a negative errno value.
pub fn setOption(ctx: *Context, name: []const u8, value: []const u8) c_int {
  const running = ctx.status == .starting or ctx.status == .running;
  if (std.mem.eql(u8, name, "log-level")) {
    const level = std.meta.stringToEnum(LogLevelName, value) orelse return err(.INVAL);
    ctx.options.log_level = @fromBackingInt(@intCast(@backingInt(level)));
    return 0;
  }
  const field = std.meta.stringToEnum(OptionName, name) orelse return err(.NOENT);
  if (running) return err(.BUSY);
  const o = &ctx.options;
  switch (field) {
    .driver => o.driver = std.meta.stringToEnum(driver_layer.Name, value) orelse return err(.INVAL),
    .@"frame-counter-margin" => o.frame_counter_margin = std.fmt.parseInt(u32, value, 10) catch
      return err(.INVAL),
    .@"replace-network" => o.replace_network = parseYesNo(value) orelse return err(.INVAL),
    .channel => {
      const channel = std.fmt.parseInt(u8, value, 10) catch return err(.INVAL);
      if (channel < 11 or channel > 26) return err(.INVAL);
      o.channel = channel;
    },
    .@"pan-id" => {
      const pan_id = parseHex(u16, value) orelse return err(.INVAL);
      // 0xffff addresses every PAN.
      if (pan_id == 0xffff) return err(.INVAL);
      o.pan_id = pan_id;
    },
    .@"extended-pan-id" => {
      const extended = parseHex(u64, value) orelse return err(.INVAL);
      if (extended == 0 or extended == std.math.maxInt(u64)) return err(.INVAL);
      o.extended_pan_id = extended;
    },
    .@"network-key" => {
      // All 32 digits, so that a key cut short is not taken for one with leading zeros.
      const digits = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
      if (digits.len != 32) return err(.INVAL);
      const key = parseHex(u128, value) orelse return err(.INVAL);
      var bytes: [16]u8 = undefined;
      std.mem.writeInt(u128, &bytes, key, .big);
      o.network_key = bytes;
    },
  }
  return 0;
}

const OptionName = enum {
  driver,
  @"frame-counter-margin",
  @"replace-network",
  channel,
  @"pan-id",
  @"extended-pan-id",
  @"network-key",
};

fn parseYesNo(value: []const u8) ?bool {
  if (std.mem.eql(u8, value, "yes")) return true;
  if (std.mem.eql(u8, value, "no")) return false;
  return null;
}

/// Hexadecimal digits, with or without 0x, as many as the type holds at most.
fn parseHex(comptime T: type, value: []const u8) ?T {
  const digits = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
  if (digits.len == 0 or digits.len > @typeInfo(T).int.bits / 4) return null;
  return std.fmt.parseInt(T, digits, 16) catch null;
}

pub fn serialDefaults(ctx: *const Context) error{
  NoDriver,
  NotSerial,
}!driver_layer.SerialDefaults {
  const name = ctx.options.driver orelse return error.NoDriver;
  return driver_layer.Driver.serialDefaults(name) orelse error.NotSerial;
}

/// Starts the driver, as `skep_start`.
pub fn start(ctx: *Context) c_int {
  const name = ctx.options.driver orelse return err(.INVAL);
  if (ctx.status == .starting or ctx.status == .running) return err(.BUSY);
  ctx.driver = switch (name) {
    .sim => .{ .sim = ctx.sim_dongle },
    else => .init(name),
  };
  ctx.driver.?.start();
  ctx.status = .starting;
  ctx.network = null;
  return 0;
}

/// Opens the network to new devices, as `skep_permit_join`.
pub fn permitJoin(ctx: *Context, seconds: c_uint, request: *u32) c_int {
  if (ctx.status != .running or ctx.stopping) return err(.NETDOWN);
  if (seconds > 254) return err(.INVAL);
  // One at a time: a second would race the first.
  if (ctx.pending(.permit_join)) return err(.NOBUFS);
  const id = ctx.newRequest();
  ctx.push(.{ .kind = .permit_join, .request = id, .seconds = @intCast(seconds) });
  request.* = id;
  return 0;
}

/// Reads the security counters from the dongle again, as `skep_refresh_state`.
pub fn refreshState(ctx: *Context, request: *u32) c_int {
  if (ctx.status != .running or ctx.stopping) return err(.NETDOWN);
  if (ctx.pending(.refresh)) return err(.NOBUFS);
  const id = ctx.newRequest();
  ctx.push(.{ .kind = .refresh, .request = id });
  request.* = id;
  return 0;
}

/// Sets a device up again from the start, as `skep_setup_device`.
pub fn setupDevice(ctx: *Context, ieee: u64) c_int {
  if (ctx.status != .running or ctx.stopping) return err(.NETDOWN);
  const d = ctx.state.?.device(ieee) orelse return err(.NODEV);
  // For the state changing.
  ctx.fillSpares() catch return err(.NOMEM);
  setup.restart(ctx, d);
  ctx.kick();
  return 0;
}

/// Gives up a pending request, as `skep_cancel`.
pub fn cancel(ctx: *Context, id: u32) c_int {
  if (ctx.spares.len == 0) {
    ctx.fillSpares() catch return err(.NOMEM);
  }
  for (ctx.ops[0..ctx.ops_len], 0..) |*op, i| {
    if (op.request != id) continue;
    // The driver finishes what it started, for no one.
    if (i == 0 and ctx.busy != .idle) {
      op.request = null;
    } else {
      std.mem.copyForwards(Op, ctx.ops[i..ctx.ops_len - 1], ctx.ops[i + 1..ctx.ops_len]);
      ctx.ops_len -= 1;
    }
    ctx.cancelRequest(id);
    return 0;
  }
  const result = requests.cancel(ctx, id);
  // The device's next exchange may go now.
  ctx.kick();
  return result;
}

/// Copies the state as JSON into `buf`, as `skep_export_state`.
pub fn exportState(ctx: *const Context, buf: []u8, len: *usize) c_int {
  const s = if (ctx.state) |*s| s else return err(.NODATA);
  len.* = s.writtenLen();
  if (buf.len < len.*) return err(.NOBUFS);
  var w: std.Io.Writer = .fixed(buf);
  s.write(&w) catch unreachable;
  return 0;
}

/// Loads a state, as `skep_import_state`.
pub fn importState(ctx: *Context, bytes: []const u8) c_int {
  if (ctx.status == .starting or ctx.status == .running) return err(.BUSY);
  const s = State.parse(ctx.gpa, bytes) catch |e| return switch (e) {
    error.Invalid => err(.INVAL),
    error.NotSupported => err(.OPNOTSUPP),
    error.OutOfMemory => err(.NOMEM),
  };
  if (ctx.state) |*old| {
    old.deinit(ctx.gpa);
  }
  ctx.state = s;
  return 0;
}

pub fn newRequest(ctx: *Context) u32 {
  const id = ctx.next_request;
  ctx.next_request +%= 1;
  if (ctx.next_request == 0) {
    ctx.next_request = 1;
  }
  return id;
}

/// Whether the driver has been asked to do `kind` and has not done it.
fn pending(ctx: *const Context, kind: @FieldType(Op, "kind")) bool {
  for (ctx.ops[0..ctx.ops_len]) |op| {
    if (op.kind == kind) return true;
  }
  return false;
}

fn push(ctx: *Context, op: Op) void {
  ctx.ops[ctx.ops_len] = op;
  ctx.ops_len += 1;
  ctx.kick();
}

/// Starts the next thing for the driver to do, if it is idle: what was asked for, the refresh
/// before stopping, or a frame for a device that can hear it.
pub fn kick(ctx: *Context) void {
  if (ctx.busy != .idle or ctx.status != .running) return;
  if (ctx.ops_len == 0) {
    if (!ctx.stopping) {
      if (exchange.sendNext(ctx)) |tag| {
        ctx.busy = .{ .frame = tag };
      }
      return;
    }
    ctx.ops[0] = .{ .kind = .refresh, .request = null };
    ctx.ops_len = 1;
  }
  const op = ctx.ops[0];
  ctx.busy = .op;
  const d = &ctx.driver.?;
  switch (op.kind) {
    .permit_join => {
      ctx.window_seconds = op.seconds;
      d.permitJoin(op.seconds);
    },
    .refresh => d.refresh(),
  }
}

/// The driver did the first thing asked of it.
fn done(ctx: *Context) Op {
  const op = ctx.ops[0];
  std.mem.copyForwards(Op, ctx.ops[0..ctx.ops_len - 1], ctx.ops[1..ctx.ops_len]);
  ctx.ops_len -= 1;
  ctx.busy = .idle;
  return op;
}

/// Stops cleanly, as `skep_stop`: once the driver is idle, the state is refreshed, then the
/// context stops.
pub fn stop(ctx: *Context) c_int {
  if (ctx.status != .starting and ctx.status != .running) return err(.NETDOWN);
  if (ctx.stopping) return 0;
  // Enough for the canceled requests and STOPPED.
  ctx.fillSpares() catch return err(.NOMEM);
  // A network still starting has no state to refresh.
  if (ctx.status == .starting) {
    ctx.finish(0);
    return 0;
  }
  ctx.cancelRequests();
  exchange.cancelAll(ctx);
  // What the driver has not started is dropped; what it has started, it finishes.
  ctx.ops_len = if (ctx.busy == .op or ctx.busy == .routers) 1 else 0;
  ctx.stopping = true;
  ctx.kick();
  return 0;
}

/// The dongle is gone, as `skep_link_lost`. Never fails: spare events report it, or are queued
/// by the next call that can allocate them.
pub fn linkLost(ctx: *Context) void {
  if (ctx.status != .starting and ctx.status != .running) return;
  ctx.finish(err(.NOTCONN));
}

/// Ends pending requests, queues STOPPED with `error_code`, and lets the driver go.
fn finish(ctx: *Context, error_code: c_int) void {
  ctx.cancelRequests();
  exchange.cancelAll(ctx);
  // After the canceled requests, which may still wait for events, and the state's last change,
  // which an application stopping on the event must have saved.
  if (ctx.canceled_len == 0) {
    ctx.flushStateChanged();
    if (ctx.spares.pop()) |event| {
      event.type = .stopped;
      event.error_code = error_code;
      ctx.events.push(event);
    } else {
      ctx.stopped_pending = error_code;
    }
  } else {
    ctx.stopped_pending = error_code;
  }
  ctx.ops_len = 0;
  ctx.busy = .idle;
  ctx.stopping = false;
  ctx.restoring = false;
  ctx.driver = null;
  ctx.status = .stopped;
  ctx.network = null;
}

/// Ends with -ECANCELED the requests the driver has not done, which it then does for no one.
fn cancelRequests(ctx: *Context) void {
  for (ctx.ops[0..ctx.ops_len]) |*op| {
    const id = op.request orelse continue;
    op.request = null;
    ctx.cancelRequest(id);
  }
}

/// Ends a request with -ECANCELED, now if a spare event is left, otherwise at the next call that
/// can allocate one.
pub fn cancelRequest(ctx: *Context, id: u32) void {
  if (ctx.spares.pop()) |event| {
    requestDone(event, id, err(.CANCELED));
    ctx.events.push(event);
  } else {
    ctx.canceled_pending[ctx.canceled_len] = id;
    ctx.canceled_len += 1;
  }
}

/// SKEP_EVENT_REQUEST_DONE, to fill in and push. Takes a spare event, of which the caller made
/// sure one was left.
pub fn requestEvent(ctx: *Context, id: u32, error_code: c_int, status: u8) *Event {
  // What the request changed comes first.
  ctx.flushStateChanged();
  const event = ctx.spares.pop().?;
  requestDone(event, id, error_code);
  event.status = status;
  return event;
}

pub fn requestEnded(ctx: *Context, id: u32, error_code: c_int, status: u8) void {
  ctx.events.push(ctx.requestEvent(id, error_code, status));
}

/// An event about a device, without more to it.
pub fn deviceEvent(ctx: *Context, t: Event.Type, ieee: u64) void {
  const event = ctx.spares.pop().?;
  event.type = t;
  event.device = ieee;
  ctx.events.push(event);
}

/// A device refused a step of its setup: logged, and reported.
pub fn setupFailed(
  ctx: *Context,
  ieee: u64,
  error_code: c_int,
  status: u8,
  progress: State.Progress,
) void {
  const message: driver_layer.Message = .init(
    "device {x:0>16}: setup failed at {t} {d} (error {d}, status 0x{x:0>2})",
    .{
      ieee,
      progress.stage,
      progress.step,
      error_code,
      status,
    },
  );
  ctx.logMessage(.warning, message.text());
  const event = ctx.spares.pop().?;
  event.type = .device_setup_failed;
  event.device = ieee;
  event.error_code = error_code;
  event.status = status;
  ctx.events.push(event);
}

/// Forgets a device that left on request: its exchanges go, and so does it.
pub fn forgetDevice(ctx: *Context, ieee: u64) void {
  var i: usize = 0;
  while (i < ctx.exchanges.items.len) {
    const e = ctx.exchanges.items[i];
    // Its requests are ended as canceled; it has no other exchange left.
    if (e.device == ieee and e.phase == .waiting) {
      _ = ctx.exchanges.orderedRemove(i);
      if (e.purpose == .request) {
        ctx.cancelRequest(e.purpose.request.id);
      }
    } else {
      i += 1;
    }
  }
  const s = &ctx.state.?;
  for (s.devices.items, 0..) |*d, j| {
    if (d.ieee != ieee) continue;
    d.deinit(ctx.gpa);
    _ = s.devices.orderedRemove(j);
    break;
  }
  ctx.deviceEvent(.device_left, ieee);
  ctx.stateChanged();
}

pub fn input(ctx: *Context, bytes: []const u8, now: u64) c_int {
  ctx.now = now;
  const d = if (ctx.driver) |*d| d else return 0;
  d.input(bytes, now);
  return ctx.process();
}

pub fn output(ctx: *const Context) []const u8 {
  const d = if (ctx.driver) |*d| d else return &.{};
  return d.output();
}

pub fn outputDone(ctx: *Context, len: usize, now: u64) void {
  ctx.now = now;
  // The driver's events wait for the next call that can report a failed allocation.
  if (ctx.driver) |*d| {
    d.outputDone(len, now);
  }
}

pub fn nextDeadline(ctx: *const Context) ?u64 {
  const d = if (ctx.driver) |*d| d else return null;
  const driver_deadline = d.nextDeadline();
  const exchange_deadline = exchange.nextDeadline(ctx);
  if (driver_deadline == null) return exchange_deadline;
  if (exchange_deadline == null) return driver_deadline;
  return @min(driver_deadline.?, exchange_deadline.?);
}

pub fn advance(ctx: *Context, now: u64) c_int {
  ctx.now = now;
  if (ctx.driver) |*d| {
    d.advance(now);
  }
  return ctx.process();
}

pub fn nextEvent(ctx: *Context) ?*Event {
  return ctx.events.pop();
}

/// Turns the driver's events into the application's. Returns 0 or -ENOMEM; on -ENOMEM nothing
/// is lost, and the next call goes on.
fn process(ctx: *Context) c_int {
  // One at a time, each with a spare event.
  while (ctx.canceled_len > 0) {
    ctx.fillSpares() catch return err(.NOMEM);
    ctx.canceled_len -= 1;
    const event = ctx.spares.pop().?;
    requestDone(event, ctx.canceled_pending[ctx.canceled_len], err(.CANCELED));
    ctx.events.push(event);
  }
  ctx.fillSpares() catch return err(.NOMEM);
  ctx.flushStateChanged();
  ctx.fillSpares() catch return err(.NOMEM);
  if (ctx.stopped_pending) |error_code| {
    ctx.stopped_pending = null;
    const event = ctx.spares.pop().?;
    event.type = .stopped;
    event.error_code = error_code;
    ctx.events.push(event);
  }
  ctx.fillSpares() catch return err(.NOMEM);
  while (ctx.driver) |*d| {
    // Room for a device that joins, so that recording it cannot fail once its event is taken.
    if (ctx.state) |*s| {
      s.devices.ensureUnusedCapacity(ctx.gpa, 1) catch return err(.NOMEM);
    }
    const driver_event = d.nextEvent() orelse break;
    switch (driver_event) {
      .ready => |ready| ctx.onReady(ready),
      .formed => |held| ctx.onFormed(held),
      .refreshed => |held| {
        const op = ctx.done();
        ctx.network = held.network;
        if (ctx.state.?.update(ctx.ieee, held)) {
          ctx.stateChanged();
        }
        if (op.request) |id| {
          ctx.flushStateChanged();
          const event = ctx.spares.pop().?;
          requestDone(event, id, 0);
          ctx.events.push(event);
        }
        // Any refresh will do for stopping.
        if (ctx.stopping) {
          ctx.finish(0);
        } else {
          ctx.kick();
        }
      },
      .permit_join_done => |failure| {
        if (failure) |f| {
          ctx.logMessage(.err, f.message.text());
          const op = ctx.done();
          if (op.request) |id| {
            ctx.requestEnded(id, err(errnoOf(f.kind)), 0);
          }
        } else {
          ctx.tellRouters(ctx.ops[0].seconds);
        }
        ctx.kick();
      },
      .send_done => |sent| {
        switch (ctx.busy) {
          .routers => |tag| if (tag == sent.tag) {
            const op = ctx.done();
            if (sent.failure) |f| {
              ctx.logMessage(.warning, f.message.text());
            }
            if (op.request) |id| {
              ctx.requestEnded(id, if (sent.failure) |f| err(errnoOf(f.kind)) else 0, 0);
            }
          },
          .frame => |tag| if (tag == sent.tag) {
            ctx.busy = .idle;
            exchange.sendDone(ctx, sent.tag, sent.failure != null);
          },
          .idle, .op => {},
        }
        ctx.kick();
      },
      .delivered => |delivered| exchange.delivered(ctx, delivered.tag, delivered.ok),
      .message => |frame| ctx.onFrame(&frame),
      .join_window => |open| {
        const event = ctx.spares.pop().?;
        event.type = .permit_join;
        event.duration = if (open) ctx.window_seconds else 0;
        ctx.events.push(event);
      },
      .device => |device| switch (device.kind) {
        .joined, .rejoined => {
          const s = &ctx.state.?;
          const changed = s.noteDeviceAssumeCapacity(device.ieee, device.nwk);
          const known = s.device(device.ieee).?;
          exchange.heard(ctx, known);
          if (device.kind == .joined) {
            // New, or joining afresh after a factory reset: set up from the start.
            ctx.deviceEvent(.device_joined, device.ieee);
            setup.restart(ctx, known);
          } else {
            // A known device keeps its setup: nothing to report.
            const message: driver_layer.Message = .init("device {x:0>16} rejoined", .{
              device.ieee,
            });
            ctx.logMessage(.debug, message.text());
            if (changed) {
              ctx.stateChanged();
            }
            setup.next(ctx, known);
          }
        },
        // libskep keeps a device that left: it may come back.
        .left => {
          const event = ctx.spares.pop().?;
          event.type = .device_left;
          event.device = device.ieee;
          ctx.events.push(event);
        },
      },
      .failed => |failure| {
        ctx.logMessage(.err, failure.message.text());
        ctx.finish(err(errnoOf(failure.kind)));
      },
      .log => |entry| ctx.logMessage(entry.level, entry.message.text()),
    }
    ctx.fillSpares() catch return err(.NOMEM);
    ctx.flushStateChanged();
    ctx.fillSpares() catch return err(.NOMEM);
  }
  // Exchanges overdue, one at a time, each with its spare events.
  if (ctx.status == .running) {
    while (exchange.checkTimes(ctx)) {
      ctx.fillSpares() catch return err(.NOMEM);
      ctx.flushStateChanged();
      ctx.fillSpares() catch return err(.NOMEM);
    }
  }
  ctx.kick();
  ctx.flushStateChanged();
  return 0;
}

/// After the dongle opened or closed the join window, the routers are told, with a broadcast.
fn tellRouters(ctx: *Context, seconds: u8) void {
  var out: [3]u8 = undefined;
  const built = exchange.zdoFrame(
    ctx,
    zdo.Cluster.permit_joining_request,
    zdo.permitJoiningRequest(&out, 0, seconds),
  );
  var frame = built.frame;
  frame.address = 0xfffc;
  frame.broadcast = true;
  ctx.next_tag +%= 1;
  frame.tag = ctx.next_tag;
  ctx.busy = .{ .routers = frame.tag };
  ctx.driver.?.send(&frame);
}

/// A frame from a device: an announcement, the answer to an exchange, a report, or a command.
fn onFrame(ctx: *Context, frame: *const driver_layer.Frame) void {
  const s = if (ctx.state) |*s| s else return;
  if (frame.profile == zdo.profile and frame.cluster == zdo.Cluster.device_announce) {
    const announce = zdo.DeviceAnnounce.parse(frame.bytes()) catch return;
    const known = s.device(announce.ieee) != null;
    if (s.noteDeviceAssumeCapacity(announce.ieee, announce.nwk)) {
      ctx.stateChanged();
    }
    const d = s.device(announce.ieee).?;
    exchange.heard(ctx, d);
    if (!known) {
      ctx.deviceEvent(.device_joined, d.ieee);
    }
    setup.next(ctx, d);
    return;
  }
  const d = s.deviceAt(frame.address) orelse return;
  const ieee = d.ieee;
  exchange.heard(ctx, d);
  if (!exchange.answer(ctx, d, frame)) {
    ctx.unsolicited(d, frame);
  }
  // Looked up again: the answer to a removal forgets the device.
  setup.next(ctx, s.device(ieee) orelse return);
}

/// The OTA Upgrade cluster, and its commands libskep answers.
const ota_cluster: u16 = 0x0019;
const ota_query_next_image: u8 = 0x01;
const ota_query_next_image_response: u8 = 0x02;
const ota_no_image_available: u8 = 0x98;

/// What a device sent by itself: attribute reports, and cluster commands. libskep answers on the
/// coordinator's behalf: "no image available" to firmware update queries, since updates are not
/// supported, and a Default Response wherever the frame asks for one.
fn unsolicited(ctx: *Context, d: *const State.Device, frame: *const driver_layer.Frame) void {
  if (frame.profile == zdo.profile) return;
  const parsed = zcl.Frame.parse(frame.bytes()) catch return;
  const h = parsed.header;
  var answer: zcl.Header = .{
    .cluster_specific = false,
    .manufacturer_code = h.manufacturer_code,
    .from_server = !h.from_server,
    .disable_default_response = true,
    .sequence = h.sequence,
    .command = zcl.Command.default_response,
  };
  if (h.cluster_specific and frame.cluster == ota_cluster and h.command == ota_query_next_image) {
    answer.cluster_specific = true;
    answer.command = ota_query_next_image_response;
    return exchange.reply(ctx, d, frame, answer, &.{ ota_no_image_available });
  }
  if (!h.disable_default_response and
    !(!h.cluster_specific and h.command == zcl.Command.default_response)) {
    exchange.reply(ctx, d, frame, answer, &.{ h.command, zcl.Status.success });
  }
  const report = !h.cluster_specific and h.command == zcl.Command.report_attributes;
  if (!report and !h.cluster_specific) return;
  const event = ctx.spares.pop().?;
  event.type = if (report) .attributes else .command;
  event.device = d.ieee;
  event.endpoint = frame.source_endpoint;
  event.cluster = frame.cluster;
  event.manufacturer_code = h.manufacturer_code orelse 0;
  if (report) {
    event.setAttributes(.report, parsed.payload);
    event.addReadings(setup.entryOf(d).readings, frame.cluster);
  } else {
    event.command = h.command;
    event.setPayload(parsed.payload);
  }
  ctx.events.push(event);
}

fn onReady(ctx: *Context, r: driver_layer.Ready) void {
  ctx.ieee = r.ieee;
  if (ctx.state) |*s| return ctx.readyWithState(s, r);
  if (r.network) |held| {
    const network = held.network;
    if (!ctx.options.replace_network) {
      const message: driver_layer.Message = .init(
        "resumed the dongle's network: channel {d}, PAN ID 0x{x:0>4} ({s})",
        .{ network.channel, network.pan_id, r.firmware.text() },
      );
      ctx.logMessage(.info, message.text());
      return ctx.started(held, .resumed);
    }
  }
  const f = ctx.newNetwork();
  const message: driver_layer.Message = if (r.network) |old|
    .init(
      "replacing the dongle's network (PAN ID 0x{x:0>4}) with a new one on channel {d} ({s})",
      .{ old.network.pan_id, f.network.channel, r.firmware.text() },
    )
  else
    .init("forming a new network on channel {d} ({s})", .{ f.network.channel, r.firmware.text() });
  ctx.logMessage(.info, message.text());
  ctx.driver.?.form(f);
}

/// The dongle is ready, and a state says which network to run: the dongle's if it is the same,
/// the state's put back otherwise, but only over another network if replace-network allows.
fn readyWithState(ctx: *Context, s: *State, r: driver_layer.Ready) void {
  if (r.network) |held| {
    const same_network = held.network.extended_pan_id == s.network.extended_pan_id;
    if (same_network and std.mem.eql(u8, &held.security.network_key, &s.network_key)) {
      const message: driver_layer.Message = .init(
        "resumed the dongle's network: channel {d}, PAN ID 0x{x:0>4} ({s})",
        .{ held.network.channel, held.network.pan_id, r.firmware.text() },
      );
      ctx.logMessage(.info, message.text());
      return ctx.started(held, .resumed);
    }
    if (!ctx.options.replace_network) {
      const message: driver_layer.Message = if (same_network)
        .init(
          "the dongle's network has the saved extended PAN ID but another network key; " ++
            "replace-network lets the saved network replace it",
          .{},
        )
      else
        .init(
          "the dongle holds another network (extended PAN ID 0x{x:0>16}) than the saved " ++
            "one (0x{x:0>16}); replace-network lets the saved network replace it",
          .{ held.network.extended_pan_id, s.network.extended_pan_id },
        );
      ctx.logMessage(.err, message.text());
      return ctx.finish(err(.EXIST));
    }
  }
  var trust_center_link_key: [16]u8 = undefined;
  if (s.trust_center_link_key) |key| {
    trust_center_link_key = key;
  } else {
    ctx.random.random().bytes(&trust_center_link_key);
    ctx.logMessage(
      .warning,
      "the state holds no trust center link key: the dongle gets a new one, which devices " ++
        "paired before do not share",
    );
  }
  var held = s.held(trust_center_link_key);
  // Ahead of the frames sent since the state was last refreshed.
  const margin = ctx.options.frame_counter_margin;
  held.security.network_frame_counter +|= margin;
  held.security.trust_center_frame_counter = s.trust_center_frame_counter +| margin;
  const message: driver_layer.Message = if (r.network) |old|
    .init(
      "replacing the dongle's network (PAN ID 0x{x:0>4}) with the saved one: channel {d}, " ++
        "PAN ID 0x{x:0>4} ({s})",
      .{ old.network.pan_id, s.network.channel, s.network.pan_id, r.firmware.text() },
    )
  else
    .init("putting the saved network back onto the dongle: channel {d}, PAN ID 0x{x:0>4} ({s})", .{
      s.network.channel,
      s.network.pan_id,
      r.firmware.text(),
    });
  ctx.logMessage(.info, message.text());
  if (s.coordinator_ieee != r.ieee) {
    const warning: driver_layer.Message = .init(
      "the dongle's IEEE address {x:0>16} is not the saved coordinator's {x:0>16}: devices " ++
        "that check it may have to be paired again",
      .{ r.ieee, s.coordinator_ieee },
    );
    ctx.logMessage(.warning, warning.text());
  }
  ctx.restoring = true;
  ctx.driver.?.form(.{ .network = held.network, .security = held.security, .restore = true });
}

fn onFormed(ctx: *Context, held: driver_layer.Held) void {
  const network = held.network;
  const message: driver_layer.Message = .init(
    "{s}: channel {d}, PAN ID 0x{x:0>4}, extended PAN ID 0x{x:0>16}",
    .{
      if (ctx.restoring) "put the saved network back" else "formed a new network",
      network.channel,
      network.pan_id,
      network.extended_pan_id,
    },
  );
  ctx.logMessage(.info, message.text());
  ctx.started(held, if (ctx.restoring) .restored else .formed);
}

/// The network is up: reports it, and takes it into the state.
fn started(ctx: *Context, held: driver_layer.Held, origin: Event.Origin) void {
  ctx.network = held.network;
  ctx.status = .running;
  ctx.restoring = false;
  const changed = if (ctx.state) |*s| s.update(ctx.ieee, held) else blk: {
    ctx.state = .init(ctx.ieee, held);
    break :blk true;
  };
  const event = ctx.spares.pop().?;
  event.type = .started;
  event.origin = origin;
  ctx.events.push(event);
  if (changed) {
    ctx.stateChanged();
  }
}

pub fn stateChanged(ctx: *Context) void {
  ctx.state_changed_pending = true;
}

/// Says that the state changed, if it did, with a spare event, which the caller refills. Without
/// one, it says it after the next step.
fn flushStateChanged(ctx: *Context) void {
  if (!ctx.state_changed_pending) return;
  const event = ctx.spares.pop() orelse return;
  ctx.state_changed_pending = false;
  event.type = .state_changed;
  ctx.events.push(event);
}

/// The parameters of a new network: the options, or values drawn from the seeded generator.
fn newNetwork(ctx: *Context) driver_layer.Form {
  const random = ctx.random.random();
  const o = ctx.options;
  var f: driver_layer.Form = .{
    .network = .{
      .channel = o.channel,
      // 0xffff addresses every PAN.
      .pan_id = o.pan_id orelse while (true) {
        const pan_id = random.int(u16);
        if (pan_id != 0xffff) break pan_id;
      },
      // 0 and all ones are reserved.
      .extended_pan_id = o.extended_pan_id orelse while (true) {
        const extended = random.int(u64);
        if (extended != 0 and extended != std.math.maxInt(u64)) break extended;
      },
    },
    .security = .{ .network_key = undefined, .trust_center_link_key = undefined },
  };
  if (o.network_key) |key| {
    f.security.network_key = key;
  } else {
    random.bytes(&f.security.network_key);
  }
  random.bytes(&f.security.trust_center_link_key);
  return f;
}

/// Queues a log message if the log level lets it through. Its event is its own, not a spare one,
/// so that a message never takes an event something else must have; out of memory, the message
/// is lost.
fn logMessage(ctx: *Context, level: driver_layer.Level, message: []const u8) void {
  if (@backingInt(level) > @backingInt(ctx.options.log_level)) return;
  const event = Event.create(ctx.c_allocator) catch return;
  event.type = .log;
  event.setLog(@backingInt(level), message);
  ctx.events.push(event);
}

fn fillSpares(ctx: *Context) error{ OutOfMemory }!void {
  while (ctx.spares.len < spare_count) {
    const event = try Event.create(ctx.c_allocator);
    ctx.spares.push(event);
  }
}

fn errnoOf(kind: driver_layer.Failure.Kind) E {
  return switch (kind) {
    .timeout => .TIMEDOUT,
    .protocol => .PROTO,
    .unsupported => .PROTONOSUPPORT,
    .refused => .IO,
  };
}

fn requestDone(event: *Event, id: u32, error_code: c_int) void {
  event.type = .request_done;
  event.request = id;
  event.error_code = error_code;
}

pub fn err(e: E) c_int {
  return -@as(c_int, @intCast(@backingInt(e)));
}

test "options are checked" {
  var ctx = try create(.wrap(&std.testing.allocator), @splat(0));
  defer ctx.destroy();
  try std.testing.expectEqual(0, ctx.setOption("driver", "sim"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("driver", "zstack"));
  try std.testing.expectEqual(err(.NOENT), ctx.setOption("colour", "blue"));
  try std.testing.expectEqual(0, ctx.setOption("channel", "20"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("channel", "27"));
  try std.testing.expectEqual(0, ctx.setOption("pan-id", "0x1a62"));
  try std.testing.expectEqual(0x1a62, ctx.options.pan_id);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("pan-id", "ffff"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("pan-id", "12345"));
  try std.testing.expectEqual(0, ctx.setOption("network-key", "000102030405060708090a0b0c0d0e0f"));
  try std.testing.expectEqual(0x0f, ctx.options.network_key.?[15]);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("extended-pan-id", "0"));
  try std.testing.expectEqual(0, ctx.setOption("replace-network", "yes"));
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("log-level", "loud"));
  try std.testing.expectEqual(0, ctx.setOption("log-level", "debug"));
  try std.testing.expectEqual(driver_layer.Level.debug, ctx.options.log_level);
  try std.testing.expectEqual(err(.INVAL), ctx.setOption("network-key", "0f"));
}
