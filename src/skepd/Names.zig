//! The names clients give devices: skepd's, not libskep's, kept in names.json next to the state,
//! as a JSON object from IEEE addresses to names.

const std = @import("std");
const StateFile = @import("StateFile.zig");
const printable = @import("printable");
const values = @import("values.zig");

const Names = @This();

gpa: std.mem.Allocator,
/// Owned names, by IEEE address.
map: std.AutoArrayHashMapUnmanaged(u64, []u8) = .empty,

pub const max_len = 64;

pub fn deinit(n: *Names) void {
  for (n.map.values()) |name| {
    n.gpa.free(name);
  }
  n.map.deinit(n.gpa);
}

pub fn get(n: *const Names, ieee: u64) ?[]const u8 {
  return n.map.get(ieee);
}

/// The device of a name.
pub fn find(n: *const Names, name: []const u8) ?u64 {
  var it = n.map.iterator();
  while (it.next()) |entry| {
    if (std.mem.eql(u8, entry.value_ptr.*, name)) return entry.key_ptr.*;
  }
  return null;
}

/// Whether a name can be given: 1 to 64 bytes of UTF-8, without control characters nor
/// characters that reorder text, and not 16 hexadecimal digits, with or without "0x", which
/// would be taken for an address.
pub fn valid(name: []const u8) bool {
  if (name.len == 0 or name.len > max_len) return false;
  // Printed as it is: no controls, nor characters that reorder text.
  if (!printable.is(name)) return false;
  return values.parseIeee(name) == null;
}

/// Names a device, or forgets its name with null. Returns the name it had, which the caller
/// frees.
pub fn set(n: *Names, ieee: u64, name: ?[]const u8) error{ OutOfMemory }!?[]u8 {
  const copy = if (name) |new| try n.gpa.dupe(u8, new) else null;
  errdefer if (copy) |new| n.gpa.free(new);
  const old = if (n.map.fetchSwapRemove(ieee)) |entry| entry.value else null;
  if (copy) |new| {
    n.map.put(n.gpa, ieee, new) catch |e| {
      if (old) |o| {
        n.map.putAssumeCapacity(ieee, o);
      }
      return e;
    };
  }
  return old;
}

/// Reads names.json. A file that is not there is no names; one that cannot be read is an error.
pub fn load(gpa: std.mem.Allocator, path: [:0]const u8) error{
  Invalid,
  OutOfMemory,
  System,
}!Names {
  var n: Names = .{ .gpa = gpa };
  errdefer n.deinit();
  const data = switch (StateFile.read(gpa, path)) {
    .none => return n,
    .data => |data| data,
    .failed => return error.System,
  };
  defer gpa.free(data);
  const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |e|
    return if (e == error.OutOfMemory) error.OutOfMemory else error.Invalid;
  defer parsed.deinit();
  const object = switch (parsed.value) {
    .object => |o| o,
    else => return error.Invalid,
  };
  var it = object.iterator();
  while (it.next()) |entry| {
    const ieee = values.parseIeee(entry.key_ptr.*) orelse return error.Invalid;
    const name = switch (entry.value_ptr.*) {
      .string => |s| s,
      else => return error.Invalid,
    };
    if (!valid(name) or n.find(name) != null) return error.Invalid;
    if (try n.set(ieee, name)) |old| {
      gpa.free(old);
    }
  }
  return n;
}

/// Writes names.json, replacing it as a whole.
pub fn save(n: *const Names, path: [:0]const u8) ?StateFile.Failure {
  var out: std.Io.Writer.Allocating = .init(n.gpa);
  defer out.deinit();
  var j: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
  j.beginObject() catch return .{ .step = "write", .errno = .NOMEM };
  var it = n.map.iterator();
  while (it.next()) |entry| {
    var key: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&key, "{x:0>16}", .{ entry.key_ptr.* }) catch unreachable;
    j.objectField(&key) catch return .{ .step = "write", .errno = .NOMEM };
    j.write(entry.value_ptr.*) catch return .{ .step = "write", .errno = .NOMEM };
  }
  j.endObject() catch return .{ .step = "write", .errno = .NOMEM };
  out.writer.writeByte('\n') catch return .{ .step = "write", .errno = .NOMEM };
  return StateFile.write(path, out.written());
}

const testing = std.testing;

test "names are checked, kept and read back" {
  try testing.expect(valid("living room"));
  try testing.expect(valid("salon é"));
  try testing.expect(!valid(""));
  try testing.expect(!valid("a\tb"));
  try testing.expect(!valid("\xff"));
  // Neither C1 controls nor characters that reorder text.
  try testing.expect(!valid("a\u{9b}b"));
  try testing.expect(!valid("lamp\u{202e}"));
  try testing.expect(!valid("f44250000d350000"));
  try testing.expect(!valid("0xF44250000D350000"));
  try testing.expect(valid("f44250000d35000"));

  var tmp = testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [128]u8 = undefined;
  const path = try std.fmt.bufPrintSentinel(
    &buffer,
    ".zig-cache/tmp/{s}/names.json",
    .{ &tmp.sub_path },
    0,
  );
  var names: Names = .{ .gpa = testing.allocator };
  defer names.deinit();
  try testing.expectEqual(null, try names.set(0xf44250000d350000, "living room"));
  const old = (try names.set(0xf44250000d350000, "salon")).?;
  testing.allocator.free(old);
  try testing.expectEqual(null, try names.set(0xffffb40e06001797, "plug"));
  try testing.expectEqual(0xffffb40e06001797, names.find("plug"));
  try testing.expectEqual(null, names.save(path));

  var again = try load(testing.allocator, path);
  defer again.deinit();
  try testing.expectEqualStrings("salon", again.get(0xf44250000d350000).?);
  try testing.expectEqualStrings("plug", again.get(0xffffb40e06001797).?);
  const gone = (try again.set(0xffffb40e06001797, null)).?;
  testing.allocator.free(gone);
  try testing.expectEqual(null, again.get(0xffffb40e06001797));
}
