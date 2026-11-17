//! The structs of skep.h, as libskep lays them out: checked against the header's translation, so
//! that the two cannot drift apart.

const std = @import("std");
const c = @import("skep_h");
const CAllocator = @import("allocator.zig").CAllocator;
const Event = @import("Event.zig");
const readings = @import("readings.zig");
const requests = @import("requests.zig");
const zcl = @import("zcl.zig");

fn expectSameLayout(comptime Ours: type, comptime Theirs: type) !void {
  try std.testing.expectEqual(@sizeOf(Theirs), @sizeOf(Ours));
  try std.testing.expectEqual(@alignOf(Theirs), @alignOf(Ours));
  const ours = @typeInfo(Ours).@"struct";
  const theirs = @typeInfo(Theirs).@"struct";
  try std.testing.expectEqual(theirs.field_names.len, ours.field_names.len);
  inline for (
    ours.field_names,
    ours.field_types,
    theirs.field_names,
    theirs.field_types,
  ) |a, a_type, b, b_type| {
    try std.testing.expectEqual(@offsetOf(Theirs, b), @offsetOf(Ours, a));
    try std.testing.expectEqual(@sizeOf(b_type), @sizeOf(a_type));
  }
}

test "the structs of skep.h are laid out as libskep's" {
  try expectSameLayout(zcl.Value, c.struct_skep_value);
  try expectSameLayout(Event.Attribute, c.struct_skep_attribute);
  try expectSameLayout(requests.Target, c.struct_skep_target);
  try expectSameLayout(requests.Reporting, c.struct_skep_reporting);
  try expectSameLayout(CAllocator, c.struct_skep_allocator);
  try expectSameLayout(Event.CReading, c.struct_skep_reading);
  try expectSameLayout(readings.CSource, c.struct_skep_reading_source);
  try expectSameLayout(readings.CSetting, c.struct_skep_setting);
}
