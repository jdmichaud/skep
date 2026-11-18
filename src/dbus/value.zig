//! D-Bus values, in no library's terms but the bus's own types: what is published is made of
//! these, and another D-Bus library would take them through an adapter.

const std = @import("std");
const signature = @import("signature.zig");
const names = @import("names.zig");

const Io = std.Io;

pub const Value = union(enum) {
  byte: u8,
  boolean: bool,
  int16: i16,
  uint16: u16,
  int32: i32,
  uint32: u32,
  int64: i64,
  uint64: u64,
  double: f64,
  /// UTF-8, without NUL.
  string: []const u8,
  object_path: []const u8,
  signature: []const u8,
  variant: *const Value,
  array: Array,
  dict: Dict,
  structure: []const Value,

  /// Values of one type, whose signature is `element`: an empty array has none to tell it.
  pub const Array = struct {
    element: []const u8,
    items: []const Value,
  };

  /// Values by keys of a basic type.
  pub const Dict = struct {
    key: []const u8,
    value: []const u8,
    entries: []const Entry,
  };

  pub const Entry = struct {
    key: Value,
    value: Value,
  };

  /// Writes the signature of the value's type.
  pub fn writeSignature(v: Value, w: *Io.Writer) Io.Writer.Error!void {
    switch (v) {
      .byte => try w.writeByte('y'),
      .boolean => try w.writeByte('b'),
      .int16 => try w.writeByte('n'),
      .uint16 => try w.writeByte('q'),
      .int32 => try w.writeByte('i'),
      .uint32 => try w.writeByte('u'),
      .int64 => try w.writeByte('x'),
      .uint64 => try w.writeByte('t'),
      .double => try w.writeByte('d'),
      .string => try w.writeByte('s'),
      .object_path => try w.writeByte('o'),
      .signature => try w.writeByte('g'),
      .variant => try w.writeByte('v'),
      .array => |a| {
        try w.writeByte('a');
        try w.writeAll(a.element);
      },
      .dict => |d| {
        try w.writeAll("a{");
        try w.writeAll(d.key);
        try w.writeAll(d.value);
        try w.writeByte('}');
      },
      .structure => |fields| {
        try w.writeByte('(');
        for (fields) |field| {
          try field.writeSignature(w);
        }
        try w.writeByte(')');
      },
    }
  }

  /// Whether the value is of the type `sig`.
  pub fn is(v: Value, sig: []const u8) bool {
    var buffer: [signature.max_len]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    v.writeSignature(&w) catch return false;
    return std.mem.eql(u8, w.buffered(), sig);
  }

  /// Whether the value can be sent: strings, paths and signatures as the bus takes them, arrays
  /// and dictionaries of the types they say, nested within bounds.
  pub fn isValid(v: Value) bool {
    var buffer: [signature.max_len]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    v.writeSignature(&w) catch return false;
    return signature.isSingle(w.buffered()) and v.contentsValid();
  }

  fn contentsValid(v: Value) bool {
    return switch (v) {
      .string => |s| names.isString(s),
      .object_path => |p| names.isObjectPath(p),
      .signature => |s| signature.isValid(s),
      .variant => |inner| inner.isValid(),
      .array => |a| for (a.items) |item| {
        if (!item.is(a.element) or !item.contentsValid()) break false;
      } else true,
      .dict => |d| for (d.entries) |entry| {
        if (!entry.key.is(d.key) or !entry.value.is(d.value)) break false;
        if (!entry.key.contentsValid() or !entry.value.contentsValid()) break false;
      } else true,
      .structure => |fields| for (fields) |field| {
        if (!field.contentsValid()) break false;
      } else true,
      else => true,
    };
  }

  /// Whether two values are the same, as a client would see them: doubles by their bits.
  pub fn eql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
      .double => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.double)),
      .string => |s| std.mem.eql(u8, s, b.string),
      .object_path => |s| std.mem.eql(u8, s, b.object_path),
      .signature => |s| std.mem.eql(u8, s, b.signature),
      .variant => |inner| inner.eql(b.variant.*),
      .array => |x| std.mem.eql(u8, x.element, b.array.element) and
        x.items.len == b.array.items.len and
        for (x.items, b.array.items) |i, j| {
          if (!i.eql(j)) break false;
        } else true,
      .dict => |x| std.mem.eql(u8, x.key, b.dict.key) and
        std.mem.eql(u8, x.value, b.dict.value) and
        x.entries.len == b.dict.entries.len and
        for (x.entries, b.dict.entries) |i, j| {
          if (!i.key.eql(j.key) or !i.value.eql(j.value)) break false;
        } else true,
      .structure => |x| x.len == b.structure.len and for (x, b.structure) |i, j| {
        if (!i.eql(j)) break false;
      } else true,
      inline else => |x, tag| x == @field(b, @tagName(tag)),
    };
  }

  /// A copy of the value, and of all it refers to, which `deinit` frees.
  pub fn clone(v: Value, gpa: std.mem.Allocator) error{ OutOfMemory }!Value {
    return switch (v) {
      .string => |s| .{ .string = try gpa.dupe(u8, s) },
      .object_path => |s| .{ .object_path = try gpa.dupe(u8, s) },
      .signature => |s| .{ .signature = try gpa.dupe(u8, s) },
      .variant => |inner| {
        const copy = try gpa.create(Value);
        errdefer gpa.destroy(copy);
        copy.* = try inner.clone(gpa);
        return .{ .variant = copy };
      },
      .array => |a| {
        const element = try gpa.dupe(u8, a.element);
        errdefer gpa.free(element);
        return .{ .array = .{ .element = element, .items = try cloneAll(gpa, a.items) } };
      },
      .dict => |d| {
        const key = try gpa.dupe(u8, d.key);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, d.value);
        errdefer gpa.free(value);
        const entries = try gpa.alloc(Entry, d.entries.len);
        var done: usize = 0;
        errdefer {
          for (entries[0..done]) |entry| {
            entry.key.deinit(gpa);
            entry.value.deinit(gpa);
          }
          gpa.free(entries);
        }
        for (d.entries, entries) |from, *to| {
          const k = try from.key.clone(gpa);
          errdefer k.deinit(gpa);
          to.* = .{ .key = k, .value = try from.value.clone(gpa) };
          done += 1;
        }
        return .{ .dict = .{ .key = key, .value = value, .entries = entries } };
      },
      .structure => |fields| .{ .structure = try cloneAll(gpa, fields) },
      else => v,
    };
  }

  fn cloneAll(gpa: std.mem.Allocator, items: []const Value) error{ OutOfMemory }![]Value {
    const copies = try gpa.alloc(Value, items.len);
    var done: usize = 0;
    errdefer {
      for (copies[0..done]) |copy| {
        copy.deinit(gpa);
      }
      gpa.free(copies);
    }
    for (items, copies) |item, *copy| {
      copy.* = try item.clone(gpa);
      done += 1;
    }
    return copies;
  }

  /// Frees a value made by `clone`.
  pub fn deinit(v: Value, gpa: std.mem.Allocator) void {
    switch (v) {
      .string, .object_path, .signature => |s| gpa.free(s),
      .variant => |inner| {
        inner.deinit(gpa);
        gpa.destroy(inner);
      },
      .array => |a| {
        for (a.items) |item| {
          item.deinit(gpa);
        }
        gpa.free(a.items);
        gpa.free(a.element);
      },
      .dict => |d| {
        for (d.entries) |entry| {
          entry.key.deinit(gpa);
          entry.value.deinit(gpa);
        }
        gpa.free(d.entries);
        gpa.free(d.key);
        gpa.free(d.value);
      },
      .structure => |fields| {
        for (fields) |field| {
          field.deinit(gpa);
        }
        gpa.free(fields);
      },
      else => {},
    }
  }
};

const testing = std.testing;

test "values tell their signatures, and whether they can be sent" {
  const inner: Value = .{ .double = 21.5 };
  const entries = [_]Value.Entry{.{
    .key = .{ .string = "temperature" },
    .value = .{ .variant = &inner },
  }};
  const readings: Value = .{ .dict = .{ .key = "s", .value = "v", .entries = &entries } };
  try testing.expect(readings.is("a{sv}"));
  try testing.expect(readings.isValid());

  const wrong = [_]Value.Entry{.{ .key = .{ .uint32 = 1 }, .value = .{ .variant = &inner } }};
  try testing.expect(
    !(Value{ .dict = .{ .key = "s", .value = "v", .entries = &wrong } }).isValid(),
  );
  try testing.expect(!(Value{ .string = "a\x00b" }).isValid());
  try testing.expect(!(Value{ .string = "\xff" }).isValid());
  try testing.expect(!(Value{ .object_path = "/a//b" }).isValid());
  const items = [_]Value{.{ .int32 = 1 }, .{ .uint32 = 2 }};
  try testing.expect(!(Value{ .array = .{ .element = "i", .items = &items } }).isValid());
  try testing.expect((Value{ .array = .{ .element = "s", .items = &.{} } }).isValid());
}

test "a cloned value is equal to its original, and frees all it holds" {
  const inner: Value = .{ .string = "living room" };
  const fields = [_]Value{.{ .object_path = "/a" }, .{ .variant = &inner }, .{ .boolean = true }};
  const items = [_]Value{.{ .structure = &fields }};
  const entries = [_]Value.Entry{.{
    .key = .{ .string = "x" },
    .value = .{ .array = .{ .element = "(ovb)", .items = &items } },
  }};
  const original: Value = .{ .dict = .{ .key = "s", .value = "a(ovb)", .entries = &entries } };
  const copy = try original.clone(testing.allocator);
  defer copy.deinit(testing.allocator);
  try testing.expect(copy.eql(original));
  try testing.expect(!copy.eql(.{ .dict = .{ .key = "s", .value = "a(ovb)", .entries = &.{} } }));
  try testing.expect(!(Value{ .double = 0.0 }).eql(.{ .double = -0.0 }));

  // Running out of memory at any allocation leaks nothing.
  try testing.checkAllAllocationFailures(
    testing.allocator,
    struct {
      fn clone(gpa: std.mem.Allocator, v: Value) !void {
        const c = try v.clone(gpa);
        c.deinit(gpa);
      }
    }.clone,
    .{ original },
  );
}
