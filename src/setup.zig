//! Interviewing a device, then setting it up: libskep asks its node descriptor, its endpoints and
//! their simple descriptors, its manufacturer and model, a light's range of colour temperatures,
//! then takes the steps its entry in devices.zig lists, binding clusters and configuring their
//! reporting.
//!
//! Each step is an exchange, and what it learns is kept in the state with the device's progress,
//! so that a device that falls asleep half-way, or a restart, takes the setup up where it was. A
//! device that refuses a step has failed: libskep reports it, and goes no further until
//! `skep_setup_device` starts again.

const std = @import("std");
const Context = @import("Context.zig");
const State = @import("State.zig");
const devices = @import("devices.zig");
const exchange = @import("exchange.zig");
const zcl = @import("zcl.zig");
const zdo = @import("zdo.zig");

/// Queues the next step of a device's interview or setup, unless one is queued, or it is done.
pub fn next(ctx: *Context, d: *State.Device) void {
  if (d.progress.stage == .ready or d.progress.stage == .failed) return;
  for (ctx.exchanges.items) |e| {
    if (e.device == d.ieee and e.purpose == .setup) return;
  }
  // Out of memory: taken up again when the device is next heard from.
  queue(ctx, d) catch {};
}

/// Starts a device's interview and setup again from the start, forgetting what it learnt.
pub fn restart(ctx: *Context, d: *State.Device) void {
  var i: usize = 0;
  while (i < ctx.exchanges.items.len) {
    const e = ctx.exchanges.items[i];
    if (e.device == d.ieee and e.purpose == .setup) {
      _ = ctx.exchanges.orderedRemove(i);
    } else {
      i += 1;
    }
  }
  d.deinit(ctx.gpa);
  ctx.stateChanged();
  next(ctx, d);
}

fn queue(ctx: *Context, d: *State.Device) error{ OutOfMemory }!void {
  const nwk = d.nwk orelse return;
  const step = d.progress.step;
  const built: exchange.Built, const is_zdo = switch (d.progress.stage) {
    .node => blk: {
      var out: [3]u8 = undefined;
      break :blk .{
        exchange.zdoFrame(
          ctx,
          zdo.Cluster.node_descriptor_request,
          zdo.addressRequest(&out, 0, nwk),
        ),
        true,
      };
    },
    .endpoints => blk: {
      var out: [3]u8 = undefined;
      break :blk .{
        exchange.zdoFrame(
          ctx,
          zdo.Cluster.active_endpoints_request,
          zdo.addressRequest(&out, 0, nwk),
        ),
        true,
      };
    },
    .descriptors => blk: {
      if (step >= d.endpoints.len) {
        moveTo(ctx, d, .{ .stage = .basic });
        return queue(ctx, d);
      }
      var out: [4]u8 = undefined;
      const request = zdo.simpleDescriptorRequest(&out, 0, nwk, d.endpoints[step].id);
      break :blk .{ exchange.zdoFrame(ctx, zdo.Cluster.simple_descriptor_request, request), true };
    },
    .basic => blk: {
      var built = exchange.zclFrame(ctx, d, basicEndpoint(d), devices.Cluster.basic, .{
        .cluster_specific = false,
        .from_server = false,
        .sequence = 0,
        .command = zcl.Command.read_attributes,
      });
      var w = exchange.payloadWriter(&built.frame);
      for ([_]u16{ attribute_manufacturer, attribute_model }) |id| {
        w.writeInt(u16, id, .little) catch unreachable;
      }
      exchange.payloadWritten(&built.frame, &w);
      break :blk .{ built, false };
    },
    .light => blk: {
      const e = colorEndpoint(d) orelse {
        moveTo(ctx, d, .{ .stage = .setup });
        return queue(ctx, d);
      };
      var built = exchange.zclFrame(ctx, d, e, devices.Cluster.color_control, .{
        .cluster_specific = false,
        .from_server = false,
        .sequence = 0,
        .command = zcl.Command.read_attributes,
      });
      var w = exchange.payloadWriter(&built.frame);
      for ([_]u16{ attribute_physical_min_mireds, attribute_physical_max_mireds }) |id| {
        w.writeInt(u16, id, .little) catch unreachable;
      }
      exchange.payloadWritten(&built.frame, &w);
      break :blk .{ built, false };
    },
    .setup => blk: {
      const steps = entryOf(d).steps;
      if (step >= steps.len) return moveTo(ctx, d, .{ .stage = .ready });
      switch (steps[step]) {
        .bind => |b| {
          var out: [22]u8 = undefined;
          const request = zdo.bindRequest(
            &out,
            0,
            d.ieee,
            b.endpoint,
            b.cluster,
            ctx.ieee,
            exchange.coordinator_endpoint,
          );
          break :blk .{ exchange.zdoFrame(ctx, zdo.Cluster.bind_request, request), true };
        },
        .report => |r| {
          var built = exchange.zclFrame(ctx, d, r.endpoint, r.cluster, .{
            .cluster_specific = false,
            .from_server = false,
            .sequence = 0,
            .command = zcl.Command.configure_reporting,
          });
          var w = exchange.payloadWriter(&built.frame);
          r.reporting.write(&w) catch unreachable;
          exchange.payloadWritten(&built.frame, &w);
          break :blk .{ built, false };
        },
      }
    },
    .ready, .failed => return,
  };
  try exchange.add(ctx, .{
    .id = 0,
    .device = d.ieee,
    .purpose = .setup,
    .frame = built.frame,
    .is_zdo = is_zdo,
    .sequence = built.sequence,
  });
}

const attribute_manufacturer: u16 = 0x0004;
const attribute_model: u16 = 0x0005;
/// ColorTempPhysicalMinMireds and ColorTempPhysicalMaxMireds, of Color Control.
const attribute_physical_min_mireds: u16 = 0x400b;
const attribute_physical_max_mireds: u16 = 0x400c;

/// The first endpoint with Color Control, a light's.
fn colorEndpoint(d: *const State.Device) ?u8 {
  for (d.endpoints) |e| {
    if (e.hasInput(devices.Cluster.color_control)) return e.id;
  }
  return null;
}

/// The endpoint to read the Basic cluster from: the first that has it, or the first.
fn basicEndpoint(d: *const State.Device) u8 {
  for (d.endpoints) |e| {
    if (e.hasInput(devices.Cluster.basic)) return e.id;
  }
  return if (d.endpoints.len > 0) d.endpoints[0].id else 1;
}

/// The device's entry; one without steps for a model libskep does not know.
pub fn entryOf(d: *const State.Device) *const devices.Entry {
  const none: devices.Entry = .{ .model = "", .steps = &.{} };
  return devices.find(d.model orelse return &none) orelse &none;
}

/// An exchange of the setup ended. Takes in the answer, then queues the next step.
pub fn ended(ctx: *Context, e: *const exchange.Exchange, outcome: exchange.Outcome) void {
  const d = ctx.state.?.device(e.device) orelse return;
  switch (outcome) {
    // Canceled: taken up again later.
    .failed => return,
    .zdo => |payload| zdoAnswer(ctx, d, payload),
    .zcl => |frame| zclAnswer(ctx, d, frame),
  }
  next(ctx, d);
}

fn zdoAnswer(ctx: *Context, d: *State.Device, payload: []const u8) void {
  const response = zdo.parseResponse(payload) catch return fail(ctx, d, Context.err(.PROTO), 0);
  if (response.status != zdo.Status.success) return fail(ctx, d, 0, response.status);
  const step = d.progress.step;
  switch (d.progress.stage) {
    .node => {
      const node = zdo.NodeDescriptor.parse(payload) catch
        return fail(ctx, d, Context.err(.PROTO), 0);
      d.node = .{
        .type = switch (node.logical_type) {
          .coordinator => .coordinator,
          .router => .router,
          else => .end_device,
        },
        .manufacturer_code = node.manufacturer_code,
        .rx_on_when_idle = node.rx_on_when_idle,
      };
      moveTo(ctx, d, .{ .stage = .endpoints });
    },
    .endpoints => {
      const ids = zdo.parseActiveEndpoints(payload) catch
        return fail(ctx, d, Context.err(.PROTO), 0);
      const endpoints = ctx.gpa.alloc(State.Endpoint, ids.len) catch return;
      for (endpoints, ids) |*e, id| {
        e.* = .{ .id = id };
      }
      State.freeEndpoints(ctx.gpa, d.endpoints);
      d.endpoints = endpoints;
      moveTo(ctx, d, .{ .stage = .descriptors });
    },
    .descriptors => {
      const descriptor = zdo.SimpleDescriptor.parse(payload) catch
        return fail(ctx, d, Context.err(.PROTO), 0);
      if (step >= d.endpoints.len) return;
      const e = &d.endpoints[step];
      if (descriptor.endpoint != e.id) return;
      const input = clusters(ctx, descriptor.input_clusters) catch return;
      const output = clusters(ctx, descriptor.output_clusters) catch {
        ctx.gpa.free(input);
        return;
      };
      ctx.gpa.free(e.input_clusters);
      ctx.gpa.free(e.output_clusters);
      e.* = .{
        .id = e.id,
        .profile = descriptor.profile,
        .device = descriptor.device,
        .input_clusters = input,
        .output_clusters = output,
      };
      moveTo(ctx, d, .{ .stage = .descriptors, .step = step + 1 });
    },
    // A binding.
    .setup => moveTo(ctx, d, .{ .stage = .setup, .step = step + 1 }),
    else => {},
  }
}

fn clusters(ctx: *Context, list: []const u8) error{ OutOfMemory }![]u16 {
  const out = try ctx.gpa.alloc(u16, list.len / 2);
  for (out, 0..) |*c, i| {
    c.* = zdo.clusterAt(list, i);
  }
  return out;
}

fn zclAnswer(ctx: *Context, d: *State.Device, frame: zcl.Frame) void {
  const command = frame.header.command;
  switch (d.progress.stage) {
    .basic => {
      // A device that does not say who made it, or what it is, is set up without an entry.
      if (command == zcl.Command.read_attributes_response) {
        var it: zcl.ReadResponseIterator = .{ .bytes = frame.payload };
        while (it.next() catch null) |a| {
          if (a.status != zcl.Status.success or a.value.type != zcl.Type.char_string) continue;
          const field = switch (a.id) {
            attribute_manufacturer => &d.manufacturer,
            attribute_model => &d.model,
            else => continue,
          };
          State.Device.setText(ctx.gpa, field, a.value.bytesOf()) catch return;
        }
      }
      moveTo(ctx, d, .{ .stage = .light });
    },
    .light => {
      // A light without colour temperatures, or that does not say, has no range.
      if (command == zcl.Command.read_attributes_response) {
        var min: ?u16 = null;
        var max: ?u16 = null;
        var it: zcl.ReadResponseIterator = .{ .bytes = frame.payload };
        while (it.next() catch null) |a| {
          if (a.status != zcl.Status.success or a.value.type != zcl.Type.uint16) continue;
          const end = switch (a.id) {
            attribute_physical_min_mireds => &min,
            attribute_physical_max_mireds => &max,
            else => continue,
          };
          end.* = @intCast(a.value.v.u);
        }
        if (min != null and max != null and min.? > 0 and min.? <= max.? and max.? < 0xffff) {
          d.color_temperature_range = .{ .min = min.?, .max = max.? };
        }
      }
      moveTo(ctx, d, .{ .stage = .setup });
    },
    .setup => {
      const steps = entryOf(d).steps;
      const step = d.progress.step;
      if (step >= steps.len or steps[step] != .report) return;
      const status = if (command == zcl.Command.configure_reporting_response)
        zcl.statusOf(frame.payload, command, steps[step].report.reporting.attribute) catch
          return fail(ctx, d, Context.err(.PROTO), 0)
      else if (command == zcl.Command.default_response)
        (zcl.parseDefaultResponse(frame.payload) catch
          return fail(ctx, d, Context.err(.PROTO), 0)).status
      else
        return;
      if (status != zcl.Status.success) return fail(ctx, d, 0, status);
      moveTo(ctx, d, .{ .stage = .setup, .step = step + 1 });
    },
    else => {},
  }
}

/// Moves a device on, which is worth saving, and reports it ready when it is.
fn moveTo(ctx: *Context, d: *State.Device, progress: State.Progress) void {
  var p = progress;
  if (p.stage == .setup and p.step >= entryOf(d).steps.len) {
    p = .{ .stage = .ready };
  }
  d.progress = p;
  ctx.stateChanged();
  if (p.stage == .ready) {
    ctx.deviceEvent(.device_ready, d.ieee);
  }
}

/// The device refused a step, or answered what cannot be read.
fn fail(ctx: *Context, d: *State.Device, error_code: c_int, status: u8) void {
  const step = d.progress;
  d.progress = .{ .stage = .failed, .step = step.step };
  ctx.stateChanged();
  ctx.setupFailed(d.ieee, error_code, status, step);
}
