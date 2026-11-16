//! What a context reports to the application, which holds it as the opaque `skep_event`.
//!
//! An event holds copies of what it reports, and a copy of the allocator it came from, so that it
//! stays valid, and can be freed, after its context is gone.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;

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
  serial_lines = 13,
};

/// `enum skep_network_origin`, 0 for events of other types.
pub const Origin = enum(c_int) { none = 0, resumed = 1, restored = 2, formed = 3 };

/// Longest log message, without its terminating NUL.
pub const max_log_len = 160;

type: Type = .log,
/// The next event in a queue.
next: ?*Event = null,
/// The allocator the event came from, or null for the C library's.
allocator: ?CAllocator,
error_code: c_int = 0,
origin: Origin = .none,
device: u64 = 0,
log_level: c_int = 0,
log_buffer: [max_log_len + 1]u8 = @splat(0),

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
