//! Exchanges with devices: a frame that asks a device something, sent when the device can hear
//! it, and the answer it waits for. Interviews, setups and the application's requests are made of
//! them.
//!
//! A device has one exchange under way at a time, so that what is asked of it goes out in the
//! order it was asked. A sleepy end device hears only what its parent holds for it when it polls,
//! which it does while awake: what is for it waits until it is heard from. A device that does not
//! pick an exchange up, or does not answer, is silent: nothing more goes to it until it is heard
//! from, and its exchanges wait, except the application's requests to a device that does not
//! sleep, which fail at once.

const std = @import("std");
const Context = @import("Context.zig");
const State = @import("State.zig");
const driver_layer = @import("driver/driver.zig");
const setup = @import("setup.zig");
const requests = @import("requests.zig");
const zcl = @import("zcl.zig");
const zdo = @import("zdo.zig");

const E = std.posix.E;

pub const never = std.math.maxInt(u64);

/// How long a device that sleeps stays awake after it is heard from, as far as libskep counts on,
/// in milliseconds.
pub const awake_time = 10 * 1000;
/// How long an answer may take once the frame is delivered, in milliseconds.
pub const answer_time = 10 * 1000;
/// How long a frame for a device that is not delivered may take, in milliseconds: the parent of
/// a sleepy device holds it 7.68 s, and the delivery report comes once it gave up.
pub const delivery_time = 30 * 1000;

/// The endpoint of the coordinator that talks to devices.
pub const coordinator_endpoint = 1;

pub const Exchange = struct {
  id: u32,
  device: u64,
  purpose: Purpose,
  /// The frame, its address left for the device's when it is sent.
  frame: driver_layer.Frame,
  /// What answers it: a ZDO response, or a ZCL frame, with this sequence number.
  is_zdo: bool,
  sequence: u8,
  phase: Phase = .waiting,
  tag: u8 = 0,
  /// Once sent: when the delivery report, then the answer, is due.
  due: u64 = never,
  /// When it is given up, wherever it is: the request's deadline.
  deadline: u64 = never,
};

pub const Phase = enum {
  /// For the device to be able to hear it.
  waiting,
  /// With the driver.
  sending,
  /// Sent: waiting for its delivery report.
  sent,
  /// Delivered: waiting for its answer.
  delivered,
};

pub const Purpose = union(enum) {
  /// A step of the device's interview or setup.
  setup,
  request: requests.Request,
};

/// How an exchange ended.
pub const Outcome = union(enum) {
  /// The payload of a ZDO response.
  zdo: []const u8,
  zcl: zcl.Frame,
  /// A negative errno value: -EHOSTUNREACH, -ETIMEDOUT, -EIO or -ECANCELED.
  failed: c_int,
};

/// A frame and the sequence number its answer carries.
pub const Built = struct {
  frame: driver_layer.Frame,
  sequence: u8,
};

/// A ZDO request for a device, encoded by one of zdo.zig's functions: its sequence number, the
/// first byte, is replaced with a new one.
pub fn zdoFrame(ctx: *Context, cluster: u16, encoded: []const u8) Built {
  ctx.zdo_sequence +%= 1;
  var frame: driver_layer.Frame = .{
    .address = 0,
    .profile = zdo.profile,
    .cluster = cluster,
    .source_endpoint = zdo.endpoint,
    .destination_endpoint = zdo.endpoint,
  };
  frame.setPayload(encoded);
  frame.payload[0] = ctx.zdo_sequence;
  return .{ .frame = frame, .sequence = ctx.zdo_sequence };
}

/// A ZCL frame for a device's endpoint, from the client side, with a new sequence number. It holds
/// the header only: callers write the rest with `payloadWriter` and `payloadWritten`.
pub fn zclFrame(
  ctx: *Context,
  d: *const State.Device,
  endpoint: u8,
  cluster: u16,
  header: zcl.Header,
) Built {
  ctx.zcl_sequence +%= 1;
  var frame: driver_layer.Frame = .{
    .address = 0,
    .profile = profileOf(d, endpoint),
    .cluster = cluster,
    .source_endpoint = coordinator_endpoint,
    .destination_endpoint = endpoint,
  };
  var h = header;
  h.sequence = ctx.zcl_sequence;
  var w: std.Io.Writer = .fixed(&frame.payload);
  h.write(&w) catch unreachable;
  frame.len = @intCast(w.end);
  return .{ .frame = frame, .sequence = ctx.zcl_sequence };
}

/// A writer for what follows the header of a frame.
pub fn payloadWriter(frame: *driver_layer.Frame) std.Io.Writer {
  return .fixed(frame.payload[frame.len..]);
}

/// Adds what `w`, from `payloadWriter`, wrote to the frame.
pub fn payloadWritten(frame: *driver_layer.Frame, w: *const std.Io.Writer) void {
  frame.len += @intCast(w.end);
}

/// The profile of a device's endpoint: Home Automation unless it said otherwise.
fn profileOf(d: *const State.Device, endpoint: u8) u16 {
  if (d.endpoint(endpoint)) |e| {
    if (e.profile != 0) return e.profile;
  }
  return 0x0104;
}

/// Queues an exchange for a device.
pub fn add(ctx: *Context, exchange: Exchange) error{ OutOfMemory }!void {
  var e = exchange;
  ctx.next_exchange +%= 1;
  e.id = ctx.next_exchange;
  try ctx.exchanges.append(ctx.gpa, e);
}

/// Whether a device can be sent something now.
fn canHear(ctx: *const Context, d: *const State.Device) bool {
  if (d.nwk == null or d.silent) return false;
  if (!d.sleepy()) return true;
  const heard_at = d.heard_at orelse return false;
  return ctx.now < heard_at + awake_time;
}

/// Hands the driver the next frame a device can hear. Returns its tag, or null if there is none.
pub fn sendNext(ctx: *Context) ?u8 {
  const s = if (ctx.state) |*s| s else return null;
  for (ctx.exchanges.items, 0..) |*e, i| {
    if (e.phase != .waiting) continue;
    // One at a time for each device.
    if (busy(ctx, e.device, i)) continue;
    const d = s.device(e.device) orelse continue;
    if (!canHear(ctx, d)) continue;
    ctx.next_tag +%= 1;
    e.tag = ctx.next_tag;
    e.phase = .sending;
    e.frame.address = d.nwk.?;
    e.frame.tag = e.tag;
    ctx.driver.?.send(&e.frame);
    return e.tag;
  }
  return null;
}

/// Whether an exchange before `before` for the device is under way.
fn busy(ctx: *const Context, device: u64, before: usize) bool {
  for (ctx.exchanges.items[0..before]) |e| {
    if (e.device == device and e.phase != .waiting) return true;
  }
  return false;
}

fn find(ctx: *Context, tag: u8) ?usize {
  for (ctx.exchanges.items, 0..) |e, i| {
    if (e.phase != .waiting and e.tag == tag) return i;
  }
  return null;
}

/// The driver took the frame, or refused it.
pub fn sendDone(ctx: *Context, tag: u8, refused: bool) void {
  const i = find(ctx, tag) orelse return;
  const e = &ctx.exchanges.items[i];
  if (refused) return miss(ctx, i, err(.IO));
  e.phase = .sent;
  e.due = ctx.now + delivery_time;
}

/// The frame was delivered, or given up on.
pub fn delivered(ctx: *Context, tag: u8, ok: bool) void {
  const i = find(ctx, tag) orelse return;
  const e = &ctx.exchanges.items[i];
  if (!ok) return miss(ctx, i, err(.HOSTUNREACH));
  // An answer may have come first.
  if (e.phase == .sent) {
    e.phase = .delivered;
    e.due = ctx.now + answer_time;
  }
}

/// A frame from a device: the answer to its exchange, if it is one. Returns whether it was.
pub fn answer(ctx: *Context, d: *const State.Device, frame: *const driver_layer.Frame) bool {
  for (ctx.exchanges.items, 0..) |e, i| {
    if (e.device != d.ieee or e.phase == .waiting or e.phase == .sending) continue;
    const payload = frame.bytes();
    if (e.is_zdo) {
      if (frame.profile != zdo.profile or frame.cluster != e.frame.cluster | zdo.Cluster.response) {
        continue;
      }
      if (payload.len == 0 or payload[0] != e.sequence) continue;
      end(ctx, i, .{ .zdo = payload });
      return true;
    }
    if (frame.profile == zdo.profile or frame.cluster != e.frame.cluster) continue;
    const parsed = zcl.Frame.parse(payload) catch continue;
    if (parsed.header.sequence != e.sequence or !parsed.header.from_server) continue;
    end(ctx, i, .{ .zcl = parsed });
    return true;
  }
  return false;
}

/// An exchange was not delivered or answered, or the driver refused it: the device is silent.
/// A sleepy device's exchanges and setups wait until it is heard from; a request to a device
/// that does not sleep fails.
fn miss(ctx: *Context, i: usize, error_code: c_int) void {
  const e = &ctx.exchanges.items[i];
  const d = ctx.state.?.device(e.device) orelse return end(ctx, i, .{ .failed = error_code });
  d.silent = true;
  if (e.purpose == .request and !d.sleepy()) return end(ctx, i, .{ .failed = error_code });
  e.phase = .waiting;
  e.due = never;
}

/// Removes an exchange, then tells what it was for how it ended.
fn end(ctx: *Context, i: usize, outcome: Outcome) void {
  const e = ctx.exchanges.orderedRemove(i);
  switch (e.purpose) {
    .setup => setup.ended(ctx, &e, outcome),
    .request => |r| requests.ended(ctx, &e, r, outcome),
  }
}

/// Gives up what is overdue. Ends one exchange at most, so that the caller can find the spare
/// events its end needs; returns whether there may be more.
pub fn checkTimes(ctx: *Context) bool {
  for (ctx.exchanges.items, 0..) |e, i| {
    if (e.phase != .sending and ctx.now >= e.deadline) {
      end(ctx, i, .{ .failed = err(.TIMEDOUT) });
      return true;
    }
    if ((e.phase == .sent or e.phase == .delivered) and ctx.now >= e.due) {
      miss(ctx, i, err(.TIMEDOUT));
      return true;
    }
  }
  return false;
}

/// The next time an exchange is overdue.
pub fn nextDeadline(ctx: *const Context) ?u64 {
  var next: u64 = never;
  for (ctx.exchanges.items) |e| {
    if (e.phase != .sending) {
      next = @min(next, e.deadline);
    }
    if (e.phase == .sent or e.phase == .delivered) {
      next = @min(next, e.due);
    }
  }
  // A sleepy device's awake time running out changes nothing to wake up for.
  return if (next == never) null else next;
}

/// A device was heard from: it is awake, and no longer silent.
pub fn heard(ctx: *Context, d: *State.Device) void {
  d.heard_at = ctx.now;
  d.silent = false;
}

/// Ends every exchange: requests with -ECANCELED, setups to be taken up again later.
pub fn cancelAll(ctx: *Context) void {
  while (ctx.exchanges.items.len > 0) {
    end(ctx, ctx.exchanges.items.len - 1, .{ .failed = err(.CANCELED) });
  }
}

fn err(e: E) c_int {
  return Context.err(e);
}
