//! Reads of a device's readings by name, as one request: skepd sends a read per endpoint and
//! cluster the readings are on, and answers once they all ended, with each reading's fresh value,
//! or why it has none. Which attribute of which cluster a reading is, is skepd's to know, not its
//! clients'.

const std = @import("std");
const c = @import("skep_h");
const Protocol = @import("protocol.zig");
const Readings = @import("Readings.zig");
const Server = @import("Server.zig");
const describe = @import("describe.zig");
const libskep = @import("libskep.zig");
const time = @import("time.zig");
const values = @import("values.zig");

const Error = Protocol.Error;
const Params = Protocol.Params;

/// A reading asked for, and what became of it.
pub const Slot = struct {
  source: c.struct_skep_reading_source,
  outcome: union(enum) {
    pending,
    read,
    /// The ZCL status the device answered with, for the attribute or the whole read.
    status: u8,
    /// The error libskep ended the read with.
    failed: c_int,
  } = .pending,
};

/// The reads that answer one request of a client.
pub const Group = struct {
  client: u32,
  id: i64,
  device: u64,
  slots: []Slot,
  /// Reads not ended yet.
  left: usize = 0,
};

/// `read_readings`: reads the readings named, all of the device's without names.
pub fn start(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device", "readings", "timeout" });
  const ieee = try p.deviceOf(ps.get("device"));
  const deadline = try p.deadlineOf(ps.get("timeout"));
  const sources = libskep.readings(p.ctx, a, ieee) catch |e| switch (e) {
    error.OutOfMemory => return error.OutOfMemory,
    error.NoDevice => return p.fail("ENODEV", "no such device", .{}),
    error.NotInterviewed => return p.fail("EAGAIN", "the device is not interviewed yet", .{}),
  };
  var chosen: std.ArrayList(c.struct_skep_reading_source) = .empty;
  if (ps.get("readings")) |names| {
    for (try p.arrayOf(names, "readings")) |name| {
      const text = switch (name) {
        .string => |s| s,
        else => return p.fail("EINVAL", "readings: names", .{}),
      };
      const before = chosen.items.len;
      for (sources) |source| {
        if (std.mem.eql(u8, std.mem.span(source.name), text)) {
          try chosen.append(a, source);
        }
      }
      if (chosen.items.len == before) {
        return p.failWith("ENOENT", "readings", try namesOf(a, sources), "no reading {s}", .{
          text,
        });
      }
    }
  } else {
    try chosen.appendSlice(a, sources);
  }
  if (chosen.items.len == 0) return p.fail("ENOENT", "the device has no readings", .{});

  // A read per endpoint and cluster, each with room among the client's requests.
  var reads: std.ArrayList([2]u16) = .empty;
  for (chosen.items) |source| {
    const key: [2]u16 = .{ source.endpoint, source.cluster };
    for (reads.items) |r| {
      if (std.mem.eql(u16, &r, &key)) break;
    } else {
      try reads.append(a, key);
    }
  }
  if (p.pendingOf(client.id) + reads.items.len > Protocol.max_pending_per_client) {
    return p.fail("ENOBUFS", "{d} requests pending", .{ Protocol.max_pending_per_client });
  }

  const slots = try p.gpa.alloc(Slot, chosen.items.len);
  errdefer p.gpa.free(slots);
  for (slots, chosen.items) |*slot, source| {
    slot.* = .{ .source = source };
  }
  const group_id = p.next_group;
  p.next_group = if (p.next_group == std.math.maxInt(u32)) 1 else p.next_group + 1;
  try p.groups.put(p.gpa, group_id, .{
    .client = client.id,
    .id = id,
    .device = ieee,
    .slots = slots,
  });
  const group = p.groups.getPtr(group_id).?;
  for (reads.items) |r| {
    var ids: [c.SKEP_MAX_ATTRIBUTES]u16 = undefined;
    var count: usize = 0;
    for (slots) |slot| {
      if (slot.source.endpoint == r[0] and slot.source.cluster == r[1] and count < ids.len) {
        ids[count] = slot.source.attribute;
        count += 1;
      }
    }
    const target: c.struct_skep_target = .{
      .device = ieee,
      .endpoint = @intCast(r[0]),
      .cluster = r[1],
      .manufacturer_code = 0,
      .reserved = @splat(0),
    };
    var req: u32 = 0;
    const result = c.skep_read_attributes(p.ctx, &target, &ids, count, deadline, &req);
    if (result != 0) {
      ended(group, @intCast(r[0]), r[1], .{ .failed = result }, null);
      continue;
    }
    p.pending.put(p.gpa, req, .{
      .client = client.id,
      .id = id,
      .method = .read_readings,
      .device = ieee,
      .endpoint = @intCast(r[0]),
      .cluster = r[1],
      .group = group_id,
    }) catch {
      _ = c.skep_cancel(p.ctx, req);
      ended(
        group,
        @intCast(r[0]),
        r[1],
        .{ .failed = -@as(c_int, @backingInt(std.posix.E.NOMEM)) },
        null,
      );
      continue;
    };
    group.left += 1;
  }
  // None went out: the answer is now.
  if (group.left == 0) {
    finish(p, group_id);
  }
}

/// The names of a device's readings, as a JSON array.
fn namesOf(a: std.mem.Allocator, sources: []const c.struct_skep_reading_source) ![]const u8 {
  var out: std.Io.Writer.Allocating = .init(a);
  var j: std.json.Stringify = .{ .writer = &out.writer };
  try j.beginArray();
  for (sources) |source| {
    try j.write(std.mem.span(source.name));
  }
  try j.endArray();
  return out.written();
}

/// A read of a group ended: its readings' outcomes, and the answer once it was the last.
pub fn readEnded(p: *Protocol, pending: Protocol.Pending, e: *const c.skep_event) void {
  const group = p.groups.getPtr(pending.group) orelse return;
  const error_code = c.skep_event_get_error(e);
  const status = c.skep_event_get_status(e);
  if (error_code != 0) {
    ended(group, pending.endpoint, pending.cluster, .{ .failed = error_code }, null);
  } else if (status != 0) {
    ended(group, pending.endpoint, pending.cluster, .{ .status = status }, null);
  } else {
    p.readings.remember(pending.device, pending.endpoint, pending.cluster, e, time.now(p.io));
    ended(group, pending.endpoint, pending.cluster, .read, e);
  }
  group.left -= 1;
  if (group.left == 0) {
    finish(p, pending.group);
  }
}

/// Sets the outcome of the readings of an endpoint's cluster: each attribute's own status, when
/// the read reached the device.
fn ended(
  group: *Group,
  endpoint: u8,
  cluster: u16,
  outcome: @FieldType(Slot, "outcome"),
  e: ?*const c.skep_event,
) void {
  for (group.slots) |*slot| {
    if (slot.source.endpoint != endpoint or slot.source.cluster != cluster) continue;
    slot.outcome = outcome;
    const event = e orelse continue;
    // An attribute the device did not answer for.
    slot.outcome = .{ .status = 0x86 };
    for (0..c.skep_event_get_attribute_count(event)) |i| {
      var attribute: c.struct_skep_attribute = undefined;
      if (c.skep_event_get_attribute(event, i, &attribute) != 0) continue;
      if (attribute.id != slot.source.attribute) continue;
      slot.outcome = if (attribute.status == 0) .read else .{ .status = attribute.status };
    }
  }
}

/// Answers the group's request, if its client is still there, and forgets the group.
fn finish(p: *Protocol, group_id: u32) void {
  const entry = p.groups.fetchRemove(group_id) orelse return;
  const group = entry.value;
  defer p.gpa.free(group.slots);
  const client = p.clientOf(group.client) orelse return;
  p.request_id = group.id;
  // Every read failed alike, canceled or out of time for one: the request did, as a read does.
  if (sameFailure(group.slots)) |code| {
    var buffer: [24]u8 = undefined;
    return p.sendError(client, Protocol.errnoCode(&buffer, code), Protocol.errnoText(code));
  }
  var m: Protocol.Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  answer(p, &m, &group) catch return p.sendError(client, "ENOMEM", "out of memory");
  p.send(client, &m);
}

/// The error every reading failed with, if they all failed with one.
fn sameFailure(slots: []const Slot) ?c_int {
  var code: ?c_int = null;
  for (slots) |slot| {
    const failed = switch (slot.outcome) {
      .failed => |f| f,
      else => return null,
    };
    if (code != null and code.? != failed) return null;
    code = failed;
  }
  return code;
}

fn answer(p: *Protocol, m: *Protocol.Message, group: *const Group) !void {
  try p.result(m, group.id);
  const j = &m.j;
  try j.objectField("readings");
  try j.beginArray();
  for (group.slots) |slot| {
    const source = slot.source;
    try j.beginObject();
    try j.objectField("endpoint");
    try j.write(source.endpoint);
    try j.objectField("cluster");
    try j.write(source.cluster);
    try j.objectField("id");
    try j.write(source.attribute);
    const last = p.readings.get(.{
      .device = group.device,
      .endpoint = source.endpoint,
      .cluster = source.cluster,
      .attribute = source.attribute,
    });
    if (slot.outcome == .read and last != null) {
      try values.write(j, p.gpa, last.?.value);
      try describe.readingMembers(j, source.name, source.unit, last.?.scaled);
      var buffer: [32]u8 = undefined;
      try j.objectField("time");
      try j.write(time.format(&buffer, last.?.time));
    } else {
      try j.objectField("reading");
      try j.write(std.mem.span(source.name));
      try j.objectField("unit");
      try j.write(std.mem.span(source.unit));
      switch (slot.outcome) {
        .status => |s| {
          try j.objectField("status");
          try j.write(s);
        },
        .failed => |code| {
          var buffer: [24]u8 = undefined;
          try j.objectField("error");
          try j.write(Protocol.errnoCode(&buffer, code));
        },
        .read, .pending => {},
      }
    }
    try j.endObject();
  }
  try j.endArray();
}

/// Forgets the groups, as skepd stops.
pub fn deinit(p: *Protocol) void {
  var it = p.groups.valueIterator();
  while (it.next()) |group| {
    p.gpa.free(group.slots);
  }
  p.groups.deinit(p.gpa);
}
