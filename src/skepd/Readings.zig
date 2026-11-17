//! The last readings of devices' attributes, as they were reported or read, which skepd gives
//! with the devices: a sleepy device cannot be read on the spot, and its last report is often
//! what a client wants. In memory only: the devices send them again within the hour.
//!
//! So that there is something to give from the start, skepd reads devices for the readings it
//! has no value for: all devices once the network is up, and a device once it is set up. A few
//! at a time, so that clients' requests always find room in libskep.

const std = @import("std");
const c = @import("skep_h");

const Readings = @This();

gpa: std.mem.Allocator,
last: std.AutoHashMapUnmanaged(Source, Last) = .empty,
/// The reads to make, one cluster of a device's endpoint each, in order.
queue: std.ArrayList(Read) = .empty,
/// The reads libskep is making, by request id.
reading: std.AutoHashMapUnmanaged(u32, Read) = .empty,

/// Most reads made at once. libskep makes at most 32 requests at once, the clients' included.
const max_reads = 4;
/// How long a read may wait for a sleepy device to wake up: it reports within the hour anyway.
const read_timeout = 3600 * std.time.ms_per_s;

/// A read of the readings of one cluster of a device's endpoint that have no value.
const Read = struct {
  device: u64,
  endpoint: u8,
  cluster: u16,
};

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
  r.reading.deinit(r.gpa);
  r.queue.deinit(r.gpa);
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

/// Forgets the readings of a device that left the network for good, and the reads to make of it.
pub fn forget(r: *Readings, device: u64) void {
  var it = r.last.iterator();
  while (it.next()) |entry| {
    if (entry.key_ptr.device != device) continue;
    r.last.removeByPtr(entry.key_ptr);
    it = r.last.iterator();
  }
  var i: usize = 0;
  while (i < r.queue.items.len) {
    if (r.queue.items[i].device == device) {
      _ = r.queue.orderedRemove(i);
    } else {
      i += 1;
    }
  }
}

/// Plans reads of every device for the readings it has no value for, once the network is up:
/// those that do not sleep first, since they answer at once.
pub fn readAll(r: *Readings, ctx: *c.skep_ctx) void {
  var count: usize = 0;
  _ = c.skep_get_devices(ctx, null, 0, &count);
  const devices = r.gpa.alloc(u64, count) catch return;
  defer r.gpa.free(devices);
  _ = c.skep_get_devices(ctx, devices.ptr, devices.len, &count);
  for ([_]bool{ false, true }) |sleepy| {
    for (devices[0..@min(count, devices.len)]) |device| {
      if (sleeps(ctx, device) == sleepy) {
        r.readDevice(ctx, device);
      }
    }
  }
}

/// Plans reads of a device for the readings it has no value for: once it is set up, or the
/// network is up.
pub fn readDevice(r: *Readings, ctx: *c.skep_ctx, device: u64) void {
  const sources = r.sourcesOf(ctx, device) orelse return;
  defer r.gpa.free(sources);
  for (sources) |s| {
    if (r.get(.{
      .device = device,
      .endpoint = s.endpoint,
      .cluster = s.cluster,
      .attribute = s.attribute,
    }) != null) {
      continue;
    }
    const read: Read = .{ .device = device, .endpoint = s.endpoint, .cluster = s.cluster };
    if (r.planned(read)) continue;
    // Out of memory: a reading without a value until the device reports it.
    r.queue.append(r.gpa, read) catch return;
  }
}

/// The network went down: the reads planned are dropped, and those being made end with it.
pub fn stopped(r: *Readings) void {
  r.queue.clearRetainingCapacity();
  r.reading.clearRetainingCapacity();
}

/// Makes the reads planned, as many as it may: one per device at a time, since libskep talks to
/// a device one exchange at a time, so that a sleepy device does not hold up the others.
pub fn advance(r: *Readings, ctx: *c.skep_ctx, now: u64) void {
  var i: usize = 0;
  while (i < r.queue.items.len and r.reading.count() < max_reads) {
    const read = r.queue.items[i];
    if (r.busy(read.device)) {
      i += 1;
      continue;
    }
    // Those still without a value: a report may have brought them since.
    var ids: [c.SKEP_MAX_ATTRIBUTES]u16 = undefined;
    const count = r.missing(ctx, read, &ids);
    var request: u32 = 0;
    if (count > 0) {
      var target = std.mem.zeroes(c.struct_skep_target);
      target.device = read.device;
      target.endpoint = read.endpoint;
      target.cluster = read.cluster;
      const result = c.skep_read_attributes(
        ctx,
        &target,
        &ids,
        count,
        now + read_timeout,
        &request,
      );
      // libskep is full: later, when a request ends.
      if (result == -@as(c_int, @backingInt(std.posix.E.NOBUFS))) return;
      if (result != 0) {
        request = 0;
      }
    }
    _ = r.queue.orderedRemove(i);
    if (request != 0) {
      // Out of memory: the read goes on, and ends unnoticed.
      r.reading.put(r.gpa, request, read) catch {};
    }
  }
}

/// The end of a request: if it is one of these reads, remembers what it read, and returns true.
pub fn done(r: *Readings, e: *const c.skep_event, time: i64) bool {
  const entry = r.reading.fetchRemove(c.skep_event_get_request(e)) orelse return false;
  const read = entry.value;
  if (c.skep_event_get_error(e) == 0 and c.skep_event_get_status(e) == 0) {
    r.remember(read.device, read.endpoint, read.cluster, e, time);
  }
  return true;
}

fn planned(r: *const Readings, read: Read) bool {
  for (r.queue.items) |other| {
    if (std.meta.eql(other, read)) return true;
  }
  return false;
}

/// Whether one of these reads of the device is being made.
fn busy(r: *const Readings, device: u64) bool {
  var it = r.reading.valueIterator();
  while (it.next()) |read| {
    if (read.device == device) return true;
  }
  return false;
}

/// The attributes of a read's cluster whose readings have no value, 16 at most.
fn missing(r: *Readings, ctx: *c.skep_ctx, read: Read, ids: *[c.SKEP_MAX_ATTRIBUTES]u16) usize {
  const sources = r.sourcesOf(ctx, read.device) orelse return 0;
  defer r.gpa.free(sources);
  var count: usize = 0;
  for (sources) |s| {
    if (s.endpoint != read.endpoint or s.cluster != read.cluster or count == ids.len) continue;
    if (r.get(.{
      .device = read.device,
      .endpoint = s.endpoint,
      .cluster = s.cluster,
      .attribute = s.attribute,
    }) != null) {
      continue;
    }
    ids[count] = s.attribute;
    count += 1;
  }
  return count;
}

/// The readings a device has, which the caller frees; null for a device not interviewed yet.
fn sourcesOf(r: *Readings, ctx: *c.skep_ctx, device: u64) ?[]c.struct_skep_reading_source {
  var count: usize = 0;
  if (c.skep_device_get_readings(ctx, device, null, 0, &count) != 0) return null;
  const sources = r.gpa.alloc(c.struct_skep_reading_source, count) catch return null;
  if (c.skep_device_get_readings(ctx, device, sources.ptr, sources.len, &count) != 0 or
    count != sources.len) {
    r.gpa.free(sources);
    return null;
  }
  return sources;
}

fn sleeps(ctx: *c.skep_ctx, device: u64) bool {
  var node_type: c.enum_skep_node_type = undefined;
  var manufacturer_code: u16 = 0;
  var rx_on_when_idle: c_int = 0;
  if (c.skep_device_get_node(ctx, device, &node_type, &manufacturer_code, &rx_on_when_idle) != 0) {
    return true;
  }
  return rx_on_when_idle == 0;
}
