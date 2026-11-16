//! skepd uses libskep through skep.h, translated by the build: check that the translation works
//! and keeps the declarations.

const std = @import("std");
const c = @import("skep_h");
const build_options = @import("build_options");

test "skep.h translates to Zig" {
  const functions = .{
    "skep_version",         "skep_new",                      "skep_free",                     "skep_set_option",         "skep_get_serial_defaults",
    "skep_start",           "skep_stop",                     "skep_link_lost",                "skep_input",              "skep_output",
    "skep_output_done",     "skep_next_deadline",            "skep_advance",                  "skep_next_event",         "skep_event_free",
    "skep_event_get_type",  "skep_event_get_network_origin", "skep_event_get_lines",          "skep_export_state",       "skep_refresh_state",
    "skep_import_state",    "skep_get_network",              "skep_permit_join",              "skep_get_devices",        "skep_setup_device",
    "skep_read_attributes", "skep_write_attributes",         "skep_configure_reporting",      "skep_bind",               "skep_unbind",
    "skep_send_command",    "skep_cancel",                   "skep_event_get_argument_count", "skep_event_get_argument",
  };
  inline for (functions) |name| {
    if (!@hasDecl(c, name)) @compileError("skep.h lost " ++ name);
  }
  try std.testing.expectEqual(1, c.SKEP_EVENT_STARTED);
  try std.testing.expectEqual(12, c.SKEP_EVENT_DEVICE_SETUP_FAILED);
  try std.testing.expectEqual(32, c.SKEP_SEED_SIZE);
  try std.testing.expectEqual(0x29, c.SKEP_TYPE_INT16);
  try std.testing.expectEqual(0x0b04, c.SKEP_CLUSTER_ELECTRICAL);
  try std.testing.expectEqual(0x0a, c.SKEP_CMD_COLOR_MOVE_TO_COLOR_TEMPERATURE);
  try std.testing.expectEqual(0x4003, c.SKEP_ATTR_ON_OFF_START_UP_ON_OFF);
  var target = std.mem.zeroes(c.struct_skep_target);
  target.device = 1;
  target.endpoint = 1;
  target.cluster = 6;
  try std.testing.expectEqual(6, target.cluster);
  try std.testing.expectEqual(4, target.reserved.len);
}

test "struct skep_allocator translates to Zig" {
  const functions = struct {
    fn alloc(_: ?*anyopaque, _: usize, _: usize) callconv(.c) ?*anyopaque {
      return null;
    }

    fn free(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize) callconv(.c) void {}
  };
  var allocator = std.mem.zeroes(c.struct_skep_allocator);
  allocator.alloc = functions.alloc;
  allocator.free = functions.free;
  try std.testing.expectEqual(null, allocator.realloc);
  try std.testing.expectEqual(4, allocator.reserved.len);
}

test "skep.h version matches build.zig.zon" {
  const version = try std.SemanticVersion.parse(build_options.version);
  try std.testing.expectEqual(version.major, c.SKEP_VERSION_MAJOR);
  try std.testing.expectEqual(version.minor, c.SKEP_VERSION_MINOR);
  try std.testing.expectEqual(version.patch, c.SKEP_VERSION_PATCH);
}
