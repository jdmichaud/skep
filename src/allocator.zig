//! The allocator an application gives a context, `struct skep_allocator` in skep.h, and how the
//! rest of libskep sees it: as a `std.mem.Allocator`.
//!
//! The mapping loses nothing: `alloc` and `free` map directly, `realloc` serves `remap`, and
//! resizing in place is refused, since the C interface has no way to ask for it. libskep then
//! always passes back the size and alignment a block was allocated with.

const std = @import("std");

const Alignment = std.mem.Alignment;

/// `struct skep_allocator`.
pub const CAllocator = extern struct {
  ctx: ?*anyopaque = null,
  alloc: ?*const fn (
    ctx: ?*anyopaque,
    size: usize,
    alignment: usize,
  ) callconv(.c) ?*anyopaque = null,
  realloc: ?*const fn (
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
    new_size: usize,
    alignment: usize,
  ) callconv(.c) ?*anyopaque = null,
  free: ?*const fn (
    ctx: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
    alignment: usize,
  ) callconv(.c) void = null,
  reserved: [4]?*anyopaque = @splat(null),

  /// Whether the required functions are there and the reserved fields empty.
  pub fn valid(a: *const CAllocator) bool {
    for (a.reserved) |field| {
      if (field != null) return false;
    }
    return a.alloc != null and a.free != null;
  }

  /// A `std.mem.Allocator` that calls `a`, which must stay where it is while the result is used.
  pub fn allocator(a: *const CAllocator) std.mem.Allocator {
    return .{ .ptr = @constCast(a), .vtable = &vtable };
  }

  /// Wraps a Zig allocator, for tests: with `std.testing.allocator`, a block freed with another
  /// size than it was allocated with fails the test.
  pub fn wrap(zig: *const std.mem.Allocator) CAllocator {
    return .{ .ctx = @constCast(zig), .alloc = zigAlloc, .realloc = zigRealloc, .free = zigFree };
  }
};

const vtable: std.mem.Allocator.VTable = .{
  .alloc = alloc,
  .resize = resize,
  .remap = remap,
  .free = free,
};

fn from(ptr: *anyopaque) *const CAllocator {
  return @ptrCast(@alignCast(ptr));
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
  const a = from(ptr);
  return @ptrCast(a.alloc.?(a.ctx, len, alignment.toByteUnits()));
}

fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
  return false;
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
  const a = from(ptr);
  // Without `realloc`, Zig allocates a new block, copies and frees the old one.
  const realloc = a.realloc orelse return null;
  return @ptrCast(realloc(a.ctx, memory.ptr, memory.len, new_len, alignment.toByteUnits()));
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
  const a = from(ptr);
  a.free.?(a.ctx, memory.ptr, memory.len, alignment.toByteUnits());
}

fn wrapped(ctx: ?*anyopaque) *const std.mem.Allocator {
  return @ptrCast(@alignCast(ctx.?));
}

fn zigAlloc(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
  return wrapped(ctx).rawAlloc(size, .fromByteUnits(alignment), @returnAddress());
}

fn zigRealloc(
  ctx: ?*anyopaque,
  ptr: ?*anyopaque,
  size: usize,
  new_size: usize,
  alignment: usize,
) callconv(.c) ?*anyopaque {
  const memory = @as([*]u8, @ptrCast(ptr.?))[0..size];
  return wrapped(ctx).rawRemap(memory, .fromByteUnits(alignment), new_size, @returnAddress());
}

fn zigFree(ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
  const memory = @as([*]u8, @ptrCast(ptr.?))[0..size];
  wrapped(ctx).rawFree(memory, .fromByteUnits(alignment), @returnAddress());
}

const testing = std.testing;

test "allocations go through the application's functions" {
  const c: CAllocator = .wrap(&testing.allocator);
  try testing.expect(c.valid());
  const a = c.allocator();

  const block = try a.alignedAlloc(u8, .@"64", 100);
  try testing.expect(std.mem.isAligned(@intFromPtr(block.ptr), 64));
  const bigger = try a.realloc(block, 1000);
  @memset(bigger, 0xaa);
  const smaller = try a.realloc(bigger, 10);
  a.free(smaller);

  const items = try a.alloc(u64, 3);
  a.free(items);
}

test "without realloc, blocks are moved" {
  var c: CAllocator = .wrap(&testing.allocator);
  c.realloc = null;
  const a = c.allocator();
  const block = try a.alloc(u8, 16);
  @memcpy(block, "0123456789abcdef");
  const bigger = try a.realloc(block, 64);
  try testing.expectEqualStrings("0123456789abcdef", bigger[0..16]);
  a.free(bigger);
}

test "an allocator needs alloc and free, and empty reserved fields" {
  var c: CAllocator = .wrap(&testing.allocator);
  c.free = null;
  try testing.expect(!c.valid());
  c = .wrap(&testing.allocator);
  c.reserved[2] = @ptrCast(&c);
  try testing.expect(!c.valid());
}
