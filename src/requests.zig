//! The application's requests to devices: reading and writing attributes, configuring their
//! reporting, binding, cluster commands, and removing a device. Each is an exchange; how it ends
//! becomes its SKEP_EVENT_REQUEST_DONE.

const std = @import("std");
const Context = @import("Context.zig");
const Event = @import("Event.zig");
const State = @import("State.zig");
const driver_layer = @import("driver/driver.zig");
const exchange = @import("exchange.zig");
const setup = @import("setup.zig");
const zcl = @import("zcl.zig");
const zdo = @import("zdo.zig");

pub const Kind = enum { read, write, configure, bind, unbind, command, remove };

/// Most attributes in a request.
pub const max_attributes = 16;
/// Most requests pending at once.
pub const max_pending = 32;

pub const Request = struct {
  id: u32,
  kind: Kind,
  /// For writes and reporting configurations: their attributes, in order, whose statuses the
  /// result lists.
  attributes: [max_attributes]u16 = undefined,
  count: u8 = 0,
};

/// Where a request goes, as `struct skep_target` says.
pub const Target = extern struct {
  device: u64,
  endpoint: u8,
  cluster: u16,
  manufacturer_code: u16,
  reserved: [4]u32,
};

/// `struct skep_reporting`.
pub const Reporting = extern struct {
  attribute: u16,
  type: u8,
  min_interval: u16,
  max_interval: u16,
  change: zcl.Value,
  reserved: [2]u64,
};

/// How many of the application's requests are pending.
pub fn pending(ctx: *const Context) usize {
  var n: usize = 0;
  for (ctx.exchanges.items) |e| {
    if (e.purpose == .request) {
      n += 1;
    }
  }
  return n;
}

/// Checks a request and finds its device. Returns 0 and the device, or a negative errno value.
fn check(ctx: *Context, target: *const Target) union(enum) { device: *State.Device, err: c_int } {
  if (ctx.status != .running or ctx.stopping) return .{ .err = Context.err(.NETDOWN) };
  for (target.reserved) |r| {
    if (r != 0) return .{ .err = Context.err(.INVAL) };
  }
  const d = ctx.state.?.device(target.device) orelse return .{ .err = Context.err(.NODEV) };
  if (pending(ctx) >= max_pending) return .{ .err = Context.err(.NOBUFS) };
  return .{ .device = d };
}

/// Starts a ZCL request: its header, for the payload `write` writes.
fn zclRequest(
  ctx: *Context,
  target: *const Target,
  request: Request,
  cluster_specific: bool,
  command_id: u8,
  deadline: u64,
  id: *u32,
  writePayload: anytype,
) c_int {
  const d = switch (check(ctx, target)) {
    .device => |d| d,
    .err => |e| return e,
  };
  var built = exchange.zclFrame(ctx, d, target.endpoint, target.cluster, .{
    .cluster_specific = cluster_specific,
    .manufacturer_code = if (target.manufacturer_code != 0) target.manufacturer_code else null,
    .from_server = false,
    .sequence = 0,
    .command = command_id,
  });
  var w = exchange.payloadWriter(&built.frame);
  writePayload.write(&w) catch |e| return switch (e) {
    error.WriteFailed => Context.err(.NOBUFS),
    error.BadValue => Context.err(.INVAL),
  };
  exchange.payloadWritten(&built.frame, &w);
  return add(ctx, d, request, built, false, deadline, id);
}

fn add(
  ctx: *Context,
  d: *const State.Device,
  request: Request,
  built: exchange.Built,
  is_zdo: bool,
  deadline: u64,
  id: *u32,
) c_int {
  if (request.kind == .write or request.kind == .configure) {
    replaceWaiting(ctx, d.ieee, request, &built.frame);
  }
  var r = request;
  r.id = ctx.newRequest();
  exchange.add(ctx, .{
    .id = 0,
    .device = d.ieee,
    .purpose = .{ .request = r },
    .frame = built.frame,
    .is_zdo = is_zdo,
    .sequence = built.sequence,
    .deadline = deadline,
  }) catch return Context.err(.NOMEM);
  id.* = r.id;
  ctx.kick();
  return 0;
}

pub fn read(ctx: *Context, target: *const Target, ids: []const u16, deadline: u64, id: *u32) c_int {
  if (ids.len == 0 or ids.len > max_attributes) return Context.err(.INVAL);
  const Payload = struct {
    ids: []const u16,
    fn write(p: @This(), w: *std.Io.Writer) error{ WriteFailed, BadValue }!void {
      for (p.ids) |a| {
        try w.writeInt(u16, a, .little);
      }
    }
  };
  return zclRequest(
    ctx,
    target,
    .{ .id = 0, .kind = .read },
    false,
    zcl.Command.read_attributes,
    deadline,
    id,
    Payload{ .ids = ids },
  );
}

pub fn write(
  ctx: *Context,
  target: *const Target,
  attributes: []const Event.Attribute,
  deadline: u64,
  id: *u32,
) c_int {
  if (attributes.len == 0 or attributes.len > max_attributes) return Context.err(.INVAL);
  var r: Request = .{ .id = 0, .kind = .write, .count = @intCast(attributes.len) };
  for (attributes, 0..) |a, i| {
    if (a.reserved[0] != 0 or a.reserved[1] != 0) return Context.err(.INVAL);
    r.attributes[i] = a.id;
  }
  const Payload = struct {
    attributes: []const Event.Attribute,
    fn write(p: @This(), w: *std.Io.Writer) error{ WriteFailed, BadValue }!void {
      for (p.attributes) |a| {
        try w.writeInt(u16, a.id, .little);
        try w.writeByte(a.value.type);
        try zcl.writeValue(w, a.value);
      }
    }
  };
  return zclRequest(ctx, target, r, false, zcl.Command.write_attributes, deadline, id, Payload{
    .attributes = attributes,
  });
}

pub fn configure(
  ctx: *Context,
  target: *const Target,
  reporting: []const Reporting,
  deadline: u64,
  id: *u32,
) c_int {
  if (reporting.len == 0 or reporting.len > max_attributes) return Context.err(.INVAL);
  var r: Request = .{ .id = 0, .kind = .configure, .count = @intCast(reporting.len) };
  for (reporting, 0..) |c, i| {
    if (c.reserved[0] != 0 or c.reserved[1] != 0) return Context.err(.INVAL);
    r.attributes[i] = c.attribute;
  }
  const Payload = struct {
    reporting: []const Reporting,
    fn write(p: @This(), w: *std.Io.Writer) error{ WriteFailed, BadValue }!void {
      for (p.reporting) |c| {
        const entry: zcl.Reporting = .{
          .attribute = c.attribute,
          .type = c.type,
          .min_interval = c.min_interval,
          .max_interval = c.max_interval,
          .change = c.change,
        };
        try entry.write(w);
      }
    }
  };
  return zclRequest(ctx, target, r, false, zcl.Command.configure_reporting, deadline, id, Payload{
    .reporting = reporting,
  });
}

pub fn command(
  ctx: *Context,
  target: *const Target,
  id_of_command: u8,
  arguments: []const zcl.Value,
  deadline: u64,
  id: *u32,
) c_int {
  const Payload = struct {
    arguments: []const zcl.Value,
    fn write(p: @This(), w: *std.Io.Writer) error{ WriteFailed, BadValue }!void {
      for (p.arguments) |a| {
        try zcl.writeValue(w, a);
      }
    }
  };
  return zclRequest(
    ctx,
    target,
    .{ .id = 0, .kind = .command },
    true,
    id_of_command,
    deadline,
    id,
    Payload{ .arguments = arguments },
  );
}

pub fn bind(ctx: *Context, target: *const Target, unbinding: bool, deadline: u64, id: *u32) c_int {
  const d = switch (check(ctx, target)) {
    .device => |d| d,
    .err => |e| return e,
  };
  var out: [22]u8 = undefined;
  const encoded = zdo.bindRequest(
    &out,
    0,
    d.ieee,
    target.endpoint,
    target.cluster,
    ctx.ieee,
    exchange.coordinator_endpoint,
  );
  const cluster = if (unbinding) zdo.Cluster.unbind_request else zdo.Cluster.bind_request;
  const built = exchange.zdoFrame(ctx, cluster, encoded);
  return add(
    ctx,
    d,
    .{ .id = 0, .kind = if (unbinding) .unbind else .bind },
    built,
    true,
    deadline,
    id,
  );
}

pub fn remove(ctx: *Context, ieee: u64, deadline: u64, id: *u32) c_int {
  const target: Target = .{
    .device = ieee,
    .endpoint = 0,
    .cluster = 0,
    .manufacturer_code = 0,
    .reserved = @splat(0),
  };
  const d = switch (check(ctx, &target)) {
    .device => |d| d,
    .err => |e| return e,
  };
  var out: [10]u8 = undefined;
  const built = exchange.zdoFrame(
    ctx,
    zdo.Cluster.leave_request,
    zdo.leaveRequest(&out, 0, d.ieee),
  );
  return add(ctx, d, .{ .id = 0, .kind = .remove }, built, true, deadline, id);
}

/// A write or reporting configuration still waiting for its device is replaced by a newer one for
/// the same attributes of the same target: it ends with -ECANCELED.
fn replaceWaiting(ctx: *Context, ieee: u64, newer: Request, frame: *const driver_layer.Frame) void {
  var i: usize = 0;
  while (i < ctx.exchanges.items.len) {
    const e = ctx.exchanges.items[i];
    const same = e.device == ieee and
      e.phase == .waiting and
      e.purpose == .request and
      e.purpose.request.kind == newer.kind and
      e.frame.destination_endpoint == frame.destination_endpoint and
      e.frame.cluster == frame.cluster and
      manufacturerOf(&e.frame) == manufacturerOf(frame) and
      std.mem.eql(
        u16,
        e.purpose.request.attributes[0..e.purpose.request.count],
        newer.attributes[0..newer.count],
      );
    if (same) {
      _ = ctx.exchanges.orderedRemove(i);
      ctx.cancelRequest(e.purpose.request.id);
    } else {
      i += 1;
    }
  }
}

/// The manufacturer code of a ZCL frame, or null for a standard one.
fn manufacturerOf(frame: *const driver_layer.Frame) ?u16 {
  const parsed = zcl.Frame.parse(frame.bytes()) catch return null;
  return parsed.header.manufacturer_code;
}

/// Ends a pending request with -ECANCELED. Returns -ENOENT if there is none of that id.
pub fn cancel(ctx: *Context, id: u32) c_int {
  for (ctx.exchanges.items, 0..) |e, i| {
    if (e.purpose != .request or e.purpose.request.id != id) continue;
    _ = ctx.exchanges.orderedRemove(i);
    ctx.cancelRequest(id);
    return 0;
  }
  return Context.err(.NOENT);
}

/// An exchange for a request ended: SKEP_EVENT_REQUEST_DONE tells how.
pub fn ended(
  ctx: *Context,
  e: *const exchange.Exchange,
  r: Request,
  outcome: exchange.Outcome,
) void {
  const frame = switch (outcome) {
    .failed => |code| {
      if (code == Context.err(.CANCELED)) return ctx.cancelRequest(r.id);
      ctx.requestEnded(r.id, code, 0);
      // A device asked to leave is forgotten even if it did not answer: one that is broken or
      // gone never will, as skep.h says.
      if (r.kind == .remove) {
        ctx.forgetDevice(e.device);
      }
      return;
    },
    .zdo => |payload| {
      const response = zdo.parseResponse(payload) catch
        return ctx.requestEnded(r.id, Context.err(.PROTO), 0);
      ctx.requestEnded(r.id, 0, response.status);
      // Asked to leave: forgotten, whether it agreed or not.
      if (r.kind == .remove) {
        ctx.forgetDevice(e.device);
      }
      return;
    },
    .zcl => |f| f,
  };
  const event = ctx.requestEvent(r.id, 0, 0);
  const h = frame.header;
  if (!h.cluster_specific and h.command == zcl.Command.default_response) {
    if (zcl.parseDefaultResponse(frame.payload)) |response| {
      event.status = response.status;
    } else |_| {
      event.error_code = Context.err(.PROTO);
    }
  } else switch (r.kind) {
    .read => if (h.command == zcl.Command.read_attributes_response) {
      event.setAttributes(.read_response, frame.payload);
      if (ctx.state.?.device(e.device)) |d| {
        event.addReadings(setup.entryOf(d).readings, e.frame.cluster);
      }
    },
    .write, .configure => {
      for (r.attributes[0..r.count]) |a| {
        const status = zcl.statusOf(frame.payload, h.command, a) catch zcl.Status.failure;
        _ = event.addAttribute(.{ .id = a, .status = status });
      }
    },
    // Whatever the device answered, it did not refuse.
    else => {},
  }
  ctx.events.push(event);
}
