//! What a context reports to the application, which holds it as the opaque `skep_event`.
//!
//! An event holds copies of what it reports, and a copy of the allocator it came from, so that it
//! stays valid, and can be freed, after its context is gone.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;
const readings = @import("readings.zig");
const zcl = @import("zcl.zig");

const Event = @This();

/// `enum skep_event_type`.
pub const Type = enum(c_int) {
  started = 1,
  stopped = 2,
  permit_join = 3,
  device_joined = 4,
  device_ready = 5,
  device_left = 6,
  attributes = 7,
  command = 8,
  request_done = 9,
  log = 10,
  state_changed = 11,
  device_setup_failed = 12,
};

/// `enum skep_network_origin`, 0 for events of other types.
pub const Origin = enum(c_int) { none = 0, resumed = 1, restored = 2, formed = 3 };

/// Longest log message, without its terminating NUL.
pub const max_log_len = 160;
/// Longest ZCL payload an event keeps: more than a Zigbee frame holds.
pub const max_payload_len = 127;
/// Most attributes an event holds: as many as fit a payload, of one byte each.
pub const max_attributes = max_payload_len / 4 + 1;

type: Type = .log,
/// The next event in a queue.
next: ?*Event = null,
/// The allocator the event came from, or null for the C library's.
allocator: ?CAllocator,
error_code: c_int = 0,
/// For REQUEST_DONE: the request's id, and the device's status.
request: u32 = 0,
status: u8 = 0,
/// For PERMIT_JOIN: how long the join window stays open, 0 when it closed.
duration: c_uint = 0,
origin: Origin = .none,
device: u64 = 0,
log_level: c_int = 0,
log_buffer: [max_log_len + 1]u8 = @splat(0),
/// For ATTRIBUTES and COMMAND: where the frame came from.
endpoint: u8 = 0,
cluster: u16 = 0,
manufacturer_code: u16 = 0,
/// For COMMAND: the command, and its arguments in their ZCL encoding.
command: u8 = 0,
/// The ZCL payload the event's attributes and arguments point into.
payload: [max_payload_len]u8 = undefined,
payload_len: u8 = 0,
attributes: [max_attributes]Attribute = undefined,
attribute_count: u8 = 0,
/// What each attribute reads as, for those libskep names.
attribute_readings: [max_attributes]?readings.Reading = undefined,

/// `struct skep_attribute`.
pub const Attribute = extern struct {
  id: u16,
  status: u8,
  value: zcl.Value,
  reserved: [2]u64 = @splat(0),
};

/// How the attributes of a payload are laid out.
pub const Records = enum { report, read_response };

/// Copies a ZCL payload into the event, and decodes its attributes from the copy, so that their
/// values point into the event. Attributes after one that cannot be decoded are left out.
pub fn setAttributes(event: *Event, records: Records, payload: []const u8) void {
  event.setPayload(payload);
  event.attribute_count = 0;
  const bytes = event.payload[0..event.payload_len];
  switch (records) {
    .report => {
      var it: zcl.ReportIterator = .{ .bytes = bytes };
      while (it.next() catch null) |a| {
        if (!event.addAttribute(a)) break;
      }
    },
    .read_response => {
      var it: zcl.ReadResponseIterator = .{ .bytes = bytes };
      while (it.next() catch null) |a| {
        if (!event.addAttribute(a)) break;
      }
    },
  }
}

/// Adds an attribute, without a value; returns false if the event holds as many as it can.
pub fn addAttribute(event: *Event, a: zcl.Attribute) bool {
  if (event.attribute_count == max_attributes) return false;
  event.attributes[event.attribute_count] = .{ .id = a.id, .status = a.status, .value = a.value };
  event.attribute_readings[event.attribute_count] = null;
  event.attribute_count += 1;
  return true;
}

/// Names the event's attributes that have a reading, those of the device's `definitions` first.
pub fn addReadings(event: *Event, definitions: []const readings.Definition, cluster: u16) void {
  for (event.attributes[0..event.attribute_count], 0..) |a, i| {
    if (a.status != zcl.Status.success) continue;
    const definition = readings.find(definitions, cluster, a.id) orelse continue;
    event.attribute_readings[i] = readings.read(definition, a.value);
  }
}

/// `struct skep_reading`.
pub const CReading = extern struct {
  name: [*:0]const u8,
  unit: [*:0]const u8,
  value: f64,
  reserved: [2]u64 = @splat(0),
};

/// Copies a payload into the event, cut short if it is too long.
pub fn setPayload(event: *Event, payload: []const u8) void {
  const len = @min(payload.len, max_payload_len);
  @memcpy(event.payload[0..len], payload[0..len]);
  event.payload_len = @intCast(len);
}

pub fn create(allocator: ?CAllocator) error{ OutOfMemory }!*Event {
  var copy = allocator;
  const event = try gpaOf(&copy).create(Event);
  event.* = .{ .allocator = allocator };
  return event;
}

pub fn destroy(event: *Event) void {
  // The allocator is read from the event before the event is freed.
  var copy = event.allocator;
  gpaOf(&copy).destroy(event);
}

/// Empties the event for reuse, keeping its allocator.
pub fn clear(event: *Event) void {
  event.* = .{ .allocator = event.allocator };
}

/// Sets the log message, cut short if it is too long.
pub fn setLog(event: *Event, level: c_int, message: []const u8) void {
  const len = @min(message.len, max_log_len);
  event.log_level = level;
  @memcpy(event.log_buffer[0..len], message[0..len]);
  event.log_buffer[len] = 0;
}

pub fn log(event: *const Event) [*:0]const u8 {
  return @ptrCast(&event.log_buffer);
}

fn gpaOf(allocator: *?CAllocator) std.mem.Allocator {
  return if (allocator.*) |*c| c.allocator() else std.heap.c_allocator;
}

/// A queue of events, linked through the events themselves, so that queueing never allocates.
pub const Queue = struct {
  head: ?*Event = null,
  tail: ?*Event = null,
  len: usize = 0,

  pub fn push(q: *Queue, event: *Event) void {
    event.next = null;
    if (q.tail) |tail| {
      tail.next = event;
    } else {
      q.head = event;
    }
    q.tail = event;
    q.len += 1;
  }

  pub fn pop(q: *Queue) ?*Event {
    const event = q.head orelse return null;
    q.head = event.next;
    if (q.head == null) {
      q.tail = null;
    }
    event.next = null;
    q.len -= 1;
    return event;
  }

  pub fn destroyAll(q: *Queue) void {
    while (q.pop()) |event| {
      event.destroy();
    }
  }
};

test "events free themselves with the allocator they came from" {
  const c: CAllocator = .wrap(&std.testing.allocator);
  const event = try create(c);
  event.setLog(1, "a message");
  try std.testing.expectEqualStrings("a message", std.mem.span(event.log()));
  event.destroy();
}

test "log messages are cut short" {
  const c: CAllocator = .wrap(&std.testing.allocator);
  const event = try create(c);
  defer event.destroy();
  const long: [400]u8 = @splat('x');
  event.setLog(0, &long);
  try std.testing.expectEqual(max_log_len, std.mem.span(event.log()).len);
}

test "attributes point into the event, which outlives the frame" {
  const c: CAllocator = .wrap(&std.testing.allocator);
  const event = try create(c);
  defer event.destroy();
  {
    // The sensor's model and an unknown attribute, in a read response.
    var frame = [_]u8{ 0x05, 0x00, 0x00, 0x42, 0x03, 'a', 'b', 'c', 0x04, 0x00, 0x86 };
    event.setAttributes(.read_response, &frame);
    @memset(&frame, 0);
  }
  try std.testing.expectEqual(2, event.attribute_count);
  try std.testing.expectEqualStrings("abc", event.attributes[0].value.bytesOf());
  try std.testing.expectEqual(0x86, event.attributes[1].status);
}

test "a queue keeps events in order" {
  const c: CAllocator = .wrap(&std.testing.allocator);
  var q: Queue = .{};
  defer q.destroyAll();
  for (0..3) |i| {
    const event = try create(c);
    event.device = i;
    q.push(event);
  }
  const first = q.pop().?;
  defer first.destroy();
  try std.testing.expectEqual(0, first.device);
  try std.testing.expectEqual(2, q.len);
}
