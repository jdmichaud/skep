//! The last readings of devices' attributes, as they were reported or read, which skepd gives
//! with the devices: a sleepy device cannot be read on the spot, and its last report is often
//! what a client wants. In memory only: the devices send them again within the hour.

const std = @import("std");
const c = @import("skep_h");

const Readings = @This();

gpa: std.mem.Allocator,
last: std.AutoHashMapUnmanaged(Source, Last) = .empty,

/// An attribute of a device's endpoint.
pub const Source = struct {
  device: u64,
  endpoint: u8,
  cluster: u16,
  attribute: u16,
};

/// The last reading of an attribute.
pub const Last = struct {
  value: c.struct_skep_value,
  scaled: f64,
  /// When it came, in milliseconds since the epoch.
  time: i64,
};

pub fn deinit(r: *Readings) void {
  r.last.deinit(r.gpa);
}

/// Remembers the readings of an event's attributes, from a device's endpoint and cluster: a
/// report, or the end of a read.
pub fn remember(
  r: *Readings,
  device: u64,
  endpoint: u8,
  cluster: u16,
  e: *const c.skep_event,
  time: i64,
) void {
  for (0..c.skep_event_get_attribute_count(e)) |i| {
    var a: c.struct_skep_attribute = undefined;
    var reading: c.struct_skep_reading = undefined;
    if (c.skep_event_get_attribute(e, i, &a) != 0 or
      c.skep_event_get_reading(e, i, &reading) != 0) {
      continue;
    }
    const source: Source = .{
      .device = device,
      .endpoint = endpoint,
      .cluster = cluster,
      .attribute = a.id,
    };
    // Out of memory: a value not remembered, which the next report brings again.
    r.last.put(r.gpa, source, .{
      .value = a.value,
      .scaled = reading.value,
      .time = time,
    }) catch {};
  }
}

pub fn get(r: *const Readings, source: Source) ?Last {
  return r.last.get(source);
}

/// Forgets the readings of a device that left the network for good.
pub fn forget(r: *Readings, device: u64) void {
  var it = r.last.iterator();
  while (it.next()) |entry| {
    if (entry.key_ptr.device != device) continue;
    r.last.removeByPtr(entry.key_ptr);
    it = r.last.iterator();
  }
}
