//! libskep's events, as skepd tells its clients: the end of a request, as its response, and news
//! of the network, as events for the clients that watch.

const std = @import("std");
const c = @import("skep_h");
const Protocol = @import("protocol.zig");
const libskep = @import("libskep.zig");
const time = @import("time.zig");
const values = @import("values.zig");

const Message = Protocol.Message;
const Stringify = std.json.Stringify;
const describe = @import("describe.zig");
const grouped = @import("grouped.zig");

pub fn handle(p: *Protocol, e: *const c.skep_event) bool {
  const t = c.skep_event_get_type(e);
  if (t == c.SKEP_EVENT_REQUEST_DONE) return p.readings.done(e, wallTime(p)) or requestDone(p, e);
  switch (t) {
    c.SKEP_EVENT_STARTED => {
      p.down_error = null;
      p.readings.readAll(p.ctx);
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      eventMessage(p, &m, "network_up") catch return false;
      describe.networkMembers(p, &m.j, c.skep_event_get_network_origin(e)) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_STOPPED => {
      const error_code = c.skep_event_get_error(e);
      p.down_error = if (error_code != 0) error_code else null;
      p.window_until = null;
      p.readings.stopped();
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      eventMessage(p, &m, "network_down") catch return false;
      if (error_code != 0) {
        var buffer: [24]u8 = undefined;
        m.j.objectField("error") catch return false;
        m.j.write(Protocol.errnoCode(&buffer, error_code)) catch return false;
      }
      p.broadcast(&m);
    },
    c.SKEP_EVENT_PERMIT_JOIN => {
      const seconds = c.skep_event_get_duration(e);
      p.window_until = if (seconds > 0) p.now + @as(u64, seconds) * 1000 else null;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      eventMessage(p, &m, "permit_join") catch return false;
      m.j.objectField("seconds") catch return false;
      m.j.write(seconds) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_DEVICE_JOINED, c.SKEP_EVENT_DEVICE_READY => {
      const device = c.skep_event_get_device(e);
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      deviceEvent(
        p,
        &m,
        if (t == c.SKEP_EVENT_DEVICE_JOINED) "device_joined" else "device_ready",
        device,
      ) catch return false;
      p.broadcast(&m);
      if (t == c.SKEP_EVENT_DEVICE_READY) {
        p.readings.readDevice(p.ctx, device);
      }
    },
    c.SKEP_EVENT_DEVICE_LEFT => {
      const device = c.skep_event_get_device(e);
      const removed = c.skep_event_get_removed(e) != 0;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      deviceEvent(p, &m, "device_left", device) catch return false;
      m.j.objectField("removed") catch return false;
      m.j.write(removed) catch return false;
      p.broadcast(&m);
      // Forgotten by libskep: by skepd too, its name after the event that gives it.
      if (removed) {
        p.readings.forget(device);
        if (p.names.set(device, null) catch null) |old| {
          p.gpa.free(old);
          _ = p.names.save(p.names_path);
        }
      }
    },
    c.SKEP_EVENT_DEVICE_SETUP_FAILED => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      deviceEvent(p, &m, "device_setup_failed", c.skep_event_get_device(e)) catch return false;
      const error_code = c.skep_event_get_error(e);
      if (error_code != 0) {
        var buffer: [24]u8 = undefined;
        m.j.objectField("error") catch return false;
        m.j.write(Protocol.errnoCode(&buffer, error_code)) catch return false;
      } else {
        m.j.objectField("status") catch return false;
        m.j.write(c.skep_event_get_status(e)) catch return false;
      }
      p.broadcast(&m);
    },
    c.SKEP_EVENT_ATTRIBUTES => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      const device = c.skep_event_get_device(e);
      remember(p, device, c.skep_event_get_endpoint(e), c.skep_event_get_cluster(e), e);
      deviceEvent(p, &m, "attributes", device) catch return false;
      frameMembers(p, &m.j, e) catch return false;
      writeAttributes(p, &m.j, e, false) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_COMMAND => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      deviceEvent(p, &m, "command", c.skep_event_get_device(e)) catch return false;
      commandMembers(p, &m.j, e) catch return false;
      p.broadcast(&m);
    },
    else => {},
  }
  return false;
}

/// Starts an event, whose members follow.
pub fn eventMessage(p: *Protocol, m: *Message, name: []const u8) !void {
  try m.open();
  try m.j.objectField("event");
  try m.j.write(name);
  var buffer: [32]u8 = undefined;
  try m.j.objectField("time");
  try m.j.write(p.timestamp(&buffer));
}

pub fn deviceEvent(p: *Protocol, m: *Message, name: []const u8, device: u64) !void {
  try eventMessage(p, m, name);
  try m.j.objectField("device");
  try m.j.print("\"{x:0>16}\"", .{ device });
  if (p.names.get(device)) |n| {
    try m.j.objectField("name");
    try m.j.write(n);
  }
}

/// device_renamed, for the clients that watch.
pub fn renamed(p: *Protocol, device: u64, old: ?[]const u8) void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  deviceEvent(p, &m, "device_renamed", device) catch return;
  if (old) |o| {
    m.j.objectField("old_name") catch return;
    m.j.write(o) catch return;
  }
  p.broadcast(&m);
}

pub fn frameMembers(_: *Protocol, j: *Stringify, e: *const c.skep_event) !void {
  try j.objectField("endpoint");
  try j.write(c.skep_event_get_endpoint(e));
  try j.objectField("cluster");
  try j.write(c.skep_event_get_cluster(e));
  const code = c.skep_event_get_manufacturer_code(e);
  if (code != 0) {
    try j.objectField("manufacturer_code");
    try j.write(code);
  }
}

/// "attributes": those of the event, with their statuses in results, and values where they have
/// them.
pub fn writeAttributes(
  p: *Protocol,
  j: *Stringify,
  e: *const c.skep_event,
  with_status: bool,
) !void {
  try j.objectField("attributes");
  try j.beginArray();
  for (0..c.skep_event_get_attribute_count(e)) |i| {
    var a: c.struct_skep_attribute = undefined;
    if (c.skep_event_get_attribute(e, i, &a) != 0) continue;
    try j.beginObject();
    try j.objectField("id");
    try j.write(a.id);
    if (with_status) {
      try j.objectField("status");
      try j.write(a.status);
    }
    if (a.status == 0 and a.value.type != 0) {
      try values.write(j, p.gpa, a.value);
    }
    var reading: c.struct_skep_reading = undefined;
    if (c.skep_event_get_reading(e, i, &reading) == 0) {
      try describe.readingMembers(j, reading.name, reading.unit, reading.value);
    }
    try j.endObject();
  }
  try j.endArray();
}

pub fn commandMembers(p: *Protocol, j: *Stringify, e: *const c.skep_event) !void {
  try frameMembers(p, j, e);
  try j.objectField("command");
  try j.write(c.skep_event_get_command(e));
  var len: usize = 0;
  const payload = c.skep_event_get_payload(e, &len);
  try j.objectField("payload");
  try j.print("\"{x}\"", .{ payload[0..len] });
  var count: usize = 0;
  if (c.skep_event_get_argument_count(e, &count) == 0) {
    try j.objectField("arguments");
    try j.beginArray();
    for (0..count) |i| {
      var v: c.struct_skep_value = undefined;
      if (c.skep_event_get_argument(e, i, &v) != 0) continue;
      try j.beginObject();
      try values.write(j, p.gpa, v);
      try j.endObject();
    }
    try j.endArray();
  }
}

/// Remembers the readings of an event's attributes, from a device's endpoint and cluster.
pub fn remember(
  p: *Protocol,
  device: u64,
  endpoint: u8,
  cluster: u16,
  e: *const c.skep_event,
) void {
  p.readings.remember(device, endpoint, cluster, e, wallTime(p));
}

/// The time in milliseconds since the epoch.
pub fn wallTime(p: *Protocol) i64 {
  return time.now(p.io);
}

/// The end of a client's request: its response.
pub fn requestDone(p: *Protocol, e: *const c.skep_event) bool {
  const entry = p.pending.fetchRemove(c.skep_event_get_request(e)) orelse return false;
  const pending = entry.value;
  if (pending.method == .read_readings) {
    grouped.readEnded(p, pending, e);
    return true;
  }
  // A client that went away.
  const client = p.clientOf(pending.client) orelse return true;
  p.request_id = pending.id;
  const error_code = c.skep_event_get_error(e);
  const status = c.skep_event_get_status(e);
  if (pending.method == .remove) {
    // Forgotten unless canceled, answered or not: done, which SKEP_EVENT_DEVICE_LEFT follows.
    if (error_code == 0 or libskep.is(error_code, .TIMEDOUT) or
      libskep.is(error_code, .HOSTUNREACH)) {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.result(&m, pending.id) catch return true;
      if (error_code == 0) {
        m.j.objectField("status") catch return true;
        m.j.write(status) catch return true;
      }
      p.send(client, &m);
      return true;
    }
  }
  if (error_code != 0) {
    var buffer: [24]u8 = undefined;
    const text = if (pending.method == .rotate_network_key) switch (libskep.errno(error_code)) {
      .HOSTUNREACH => "no device took the new key: the network keeps its own",
      .IO => "the dongle did not switch to the new key",
      else => Protocol.errnoText(error_code),
    } else Protocol.errnoText(error_code);
    p.sendError(client, Protocol.errnoCode(&buffer, error_code), text);
    return true;
  }
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  p.result(&m, pending.id) catch return true;
  switch (pending.method) {
    .permit_join, .rotate_network_key => {},
    .read, .write, .configure_reporting => {
      if (pending.method == .read) {
        remember(p, pending.device, pending.endpoint, pending.cluster, e);
      }
      m.j.objectField("status") catch return true;
      m.j.write(status) catch return true;
      if (pending.method != .read or status == 0) {
        writeAttributes(p, &m.j, e, true) catch return true;
      }
    },
    else => {
      m.j.objectField("status") catch return true;
      m.j.write(status) catch return true;
    },
  }
  p.send(client, &m);
  return true;
}
