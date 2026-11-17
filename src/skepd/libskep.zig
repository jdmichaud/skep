//! skep.h as skepd uses it, beyond its declarations: its errors, negative errno values, in Zig's
//! terms, and its lists, which take two calls.

const std = @import("std");
const c = @import("skep_h");

pub const E = std.posix.E;

/// The errno value of a negative return.
pub fn errno(r: c_int) E {
  return @fromBackingInt(@intCast(@as(u16, @intCast(-r))));
}

/// Whether a return is that error.
pub fn is(r: c_int, e: E) bool {
  return r == -@as(c_int, @backingInt(e));
}

pub const ReadingsError = error{ OutOfMemory, NoDevice, NotInterviewed };

/// A device's readings, in memory from `a`.
pub fn readings(
  ctx: *c.skep_ctx,
  a: std.mem.Allocator,
  device: u64,
) ReadingsError![]c.struct_skep_reading_source {
  var count: usize = 0;
  const r = c.skep_device_get_readings(ctx, device, null, 0, &count);
  if (is(r, .AGAIN)) return error.NotInterviewed;
  if (r != 0) return error.NoDevice;
  const sources = try a.alloc(c.struct_skep_reading_source, count);
  errdefer a.free(sources);
  // They cannot change in between: libskep is not called meanwhile.
  if (c.skep_device_get_readings(ctx, device, sources.ptr, sources.len, &count) != 0) {
    return error.NoDevice;
  }
  return sources;
}
