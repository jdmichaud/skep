//! The structs of skep.h, as libskep lays them out: checked against the header's translation, so
//! that the two cannot drift apart.

const std = @import("std");
const c = @import("skep_h");
const CAllocator = @import("allocator.zig").CAllocator;
const Context = @import("Context.zig");
const Event = @import("Event.zig");
const State = @import("State.zig");
const driver_layer = @import("driver/driver.zig");
const skep = @import("skep.zig");
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

test "every function skep.h declares is exported" {
  // Taking each one's address links it: a function the header declares and libskep does not
  // export fails the build.
  @setEvalBranchQuota(100_000);
  comptime var count = 0;
  inline for (@typeInfo(c).@"struct".decl_names) |name| {
    if (comptime !std.mem.startsWith(u8, name, "skep_")) continue;
    const Declared = @TypeOf(@field(c, name));
    if (@typeInfo(Declared) != .@"fn") continue;
    std.mem.doNotOptimizeAway(&@field(c, name));
    count += 1;
  }
  try std.testing.expect(count > 50);
}

test "skep.h's limits are libskep's" {
  try std.testing.expectEqual(c.SKEP_MAX_PERMIT_JOIN, Context.max_permit_join);
  try std.testing.expectEqual(c.SKEP_MAX_ATTRIBUTES, requests.max_attributes);
  try std.testing.expectEqual(c.SKEP_MAX_REQUESTS, requests.max_pending);
  try std.testing.expectEqual(c.SKEP_MAX_TRANSITION, readings.max_transition);
}

/// Each value of a Zig enum, by name, against the header's constant of that name.
fn expectSameValues(
  comptime Ours: type,
  comptime prefix: []const u8,
  comptime names: anytype,
) !void {
  inline for (names) |pair| {
    const ours = @field(Ours, pair[0]);
    const theirs = @field(c, prefix ++ pair[1]);
    try std.testing.expectEqual(@as(c_int, theirs), @as(c_int, @intCast(@backingInt(ours))));
  }
}

test "skep.h's enums are libskep's" {
  try expectSameValues(skep.Setup, "SKEP_SETUP_", .{
    .{ "pending", "PENDING" },
    .{ "ready", "READY" },
    .{ "failed", "FAILED" },
  });
  try expectSameValues(skep.ClusterSide, "SKEP_CLUSTER_", .{
    .{ "input", "INPUT" },
    .{ "output", "OUTPUT" },
  });
  try expectSameValues(State.NodeType, "SKEP_NODE_", .{
    .{ "coordinator", "COORDINATOR" },
    .{ "router", "ROUTER" },
    .{ "end_device", "END_DEVICE" },
  });
  try expectSameValues(driver_layer.Level, "SKEP_LOG_", .{
    .{ "err", "ERROR" },
    .{ "warning", "WARNING" },
    .{ "info", "INFO" },
    .{ "debug", "DEBUG" },
  });
  try expectSameValues(driver_layer.FlowControl, "SKEP_FLOW_CONTROL_", .{
    .{ "none", "NONE" },
    .{ "software", "SOFTWARE" },
    .{ "hardware", "HARDWARE" },
  });
  try expectSameValues(Event.Origin, "SKEP_NETWORK_", .{
    .{ "resumed", "RESUMED" },
    .{ "restored", "RESTORED" },
    .{ "formed", "FORMED" },
  });
  inline for (@typeInfo(Event.Type).@"enum".field_names) |name| {
    comptime var upper: [name.len]u8 = undefined;
    inline for (name, 0..) |ch, i| {
      upper[i] = comptime std.ascii.toUpper(ch);
    }
    const theirs = @field(c, "SKEP_EVENT_" ++ upper);
    try std.testing.expectEqual(
      @as(c_int, theirs),
      @as(c_int, @backingInt(@field(Event.Type, name))),
    );
  }
}
