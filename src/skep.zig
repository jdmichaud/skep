//! libskep, a small Zigbee stack: the root of the library, which exports the C API declared in
//! `include/skep.h`. The functions here only translate between C and Context.zig and Event.zig.
//!
//! The API is implemented as milestones need it; functions skep.h declares and this file does not
//! export yet are still to come.

const std = @import("std");
const build_options = @import("build_options");
const CAllocator = @import("allocator.zig").CAllocator;
const Context = @import("Context.zig");
const Event = @import("Event.zig");
const sim = @import("driver/sim/sim.zig");

/// Version of libskep, taken from `.version` in `build.zig.zon`.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(build_options.version) catch
  @compileError("invalid version in build.zig.zon");

const err = Context.err;

export fn skep_version() u32 {
  return @intCast(version.major << 16 | version.minor << 8 | version.patch);
}

export fn skep_new(allocator: ?*const CAllocator, seed: ?*const [32]u8, ctx: ?*?*Context) c_int {
  const out = ctx orelse return err(.INVAL);
  const s = seed orelse return err(.INVAL);
  if (allocator) |a| {
    if (!a.valid()) return err(.INVAL);
  }
  out.* = Context.create(if (allocator) |a| a.* else null, s.*) catch return err(.NOMEM);
  return 0;
}

export fn skep_free(ctx: ?*Context) void {
  if (ctx) |c| {
    c.destroy();
  }
}

export fn skep_set_option(ctx: *Context, name: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
  return ctx.setOption(
    std.mem.span(name orelse return err(.INVAL)),
    std.mem.span(value orelse return err(.INVAL)),
  );
}

export fn skep_get_serial_defaults(
  ctx: *const Context,
  baudrate: *c_uint,
  flow_control: *c_int,
) c_int {
  const defaults = ctx.serialDefaults() catch |e| return switch (e) {
    error.NoDriver => err(.INVAL),
    error.NotSerial => err(.OPNOTSUPP),
  };
  baudrate.* = defaults.baudrate;
  flow_control.* = @backingInt(defaults.flow_control);
  return 0;
}

export fn skep_start(ctx: *Context) c_int {
  return ctx.start();
}

export fn skep_stop(ctx: *Context) c_int {
  return ctx.stop();
}

export fn skep_link_lost(ctx: *Context) void {
  ctx.linkLost();
}

export fn skep_input(ctx: *Context, data: [*]const u8, len: usize, now: u64) c_int {
  return ctx.input(data[0..len], now);
}

export fn skep_output(ctx: *Context, data: *[*]const u8) usize {
  const bytes = ctx.output();
  data.* = bytes.ptr;
  return bytes.len;
}

export fn skep_output_done(ctx: *Context, len: usize, now: u64) void {
  ctx.outputDone(len, now);
}

export fn skep_next_deadline(ctx: *const Context, deadline: *u64) c_int {
  deadline.* = ctx.nextDeadline() orelse return 0;
  return 1;
}

export fn skep_advance(ctx: *Context, now: u64) c_int {
  return ctx.advance(now);
}

export fn skep_next_event(ctx: *Context) ?*Event {
  return ctx.nextEvent();
}

export fn skep_event_free(event: ?*Event) void {
  if (event) |e| {
    e.destroy();
  }
}

export fn skep_event_get_type(event: *const Event) c_int {
  return @backingInt(event.type);
}

export fn skep_event_get_device(event: *const Event) u64 {
  return event.device;
}

export fn skep_event_get_error(event: *const Event) c_int {
  return event.error_code;
}

export fn skep_event_get_network_origin(event: *const Event) c_int {
  return @backingInt(event.origin);
}

export fn skep_event_get_log(event: *const Event, message: *[*:0]const u8) c_int {
  message.* = event.log();
  return event.log_level;
}

export fn skep_permit_join(ctx: *Context, seconds: c_uint, request: *u32) c_int {
  return ctx.permitJoin(seconds, request);
}

export fn skep_event_get_request(event: *const Event) u32 {
  return event.request;
}

export fn skep_event_get_status(event: *const Event) u8 {
  return event.status;
}

export fn skep_event_get_duration(event: *const Event) c_uint {
  return event.duration;
}

export fn skep_export_state(ctx: *const Context, buf: ?[*]u8, size: usize, len: *usize) c_int {
  const out: []u8 = if (buf) |b| b[0..size] else if (size == 0) &.{} else return err(.INVAL);
  return ctx.exportState(out, len);
}

export fn skep_refresh_state(ctx: *Context, request: *u32) c_int {
  return ctx.refreshState(request);
}

export fn skep_import_state(ctx: *Context, data: ?[*]const u8, len: usize) c_int {
  const bytes: []const u8 = if (data) |d| d[0..len] else if (len == 0) &.{} else return err(.INVAL);
  return ctx.importState(bytes);
}

export fn skep_get_network(ctx: *Context, channel: *u8, pan_id: *u16, extended_pan_id: *u64) c_int {
  const network = ctx.network orelse return err(.NETDOWN);
  channel.* = network.channel;
  pan_id.* = network.pan_id;
  extended_pan_id.* = network.extended_pan_id;
  return 0;
}

// Tests: the C API as an application uses it, with the sim driver.

const testing = std.testing;

/// A context on the testing allocator, with a fixed seed.
fn testContext(allocator: *const std.mem.Allocator) !*Context {
  const c: CAllocator = .wrap(allocator);
  var ctx: ?*Context = null;
  if (skep_new(&c, &@splat(7), &ctx) != 0) return error.OutOfMemory;
  return ctx.?;
}

/// Runs the loop once, as an application would, and returns the type of the next event.
fn nextEventType(ctx: *Context) !?c_int {
  if (skep_advance(ctx, 0) != 0) return error.OutOfMemory;
  const event = skep_next_event(ctx) orelse return null;
  defer skep_event_free(event);
  return skep_event_get_type(event);
}

test "the version is build.zig.zon's" {
  try testing.expectEqual(version.minor, skep_version() >> 8 & 0xff);
}

test "a context needs a seed, and a valid allocator" {
  var ctx: ?*Context = null;
  const c: CAllocator = .wrap(&testing.allocator);
  try testing.expectEqual(err(.INVAL), skep_new(&c, null, &ctx));
  var incomplete = c;
  incomplete.alloc = null;
  try testing.expectEqual(err(.INVAL), skep_new(&incomplete, &@splat(0), &ctx));
  try testing.expectEqual(null, ctx);
}

test "the sim driver resumes the network of the simulated dongle" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(err(.INVAL), skep_start(ctx));
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  var baudrate: c_uint = 0;
  var flow_control: c_int = 0;
  try testing.expectEqual(err(.OPNOTSUPP), skep_get_serial_defaults(ctx, &baudrate, &flow_control));
  ctx.sim_dongle.network = sim.testNetwork(.{
    .channel = 20,
    .pan_id = 0x1a62,
    .extended_pan_id = 0xdddddddddddddddd,
  });

  try testing.expectEqual(0, skep_start(ctx));
  try testing.expectEqual(err(.BUSY), skep_start(ctx));
  try testing.expectEqual(err(.BUSY), skep_set_option(ctx, "channel", "11"));
  try testing.expectEqual(0, skep_set_option(ctx, "log-level", "info"));

  try testing.expectEqual(0, skep_advance(ctx, 0));
  const log = skep_next_event(ctx).?;
  var message: [*:0]const u8 = undefined;
  try testing.expectEqual(@backingInt(Event.Type.log), skep_event_get_type(log));
  try testing.expectEqual(2, skep_event_get_log(log, &message));
  try testing.expectEqualStrings(
    "resumed the dongle's network: channel 20, PAN ID 0x1a62 (simulated dongle)",
    std.mem.span(message),
  );
  skep_event_free(log);
  const started = skep_next_event(ctx).?;
  defer skep_event_free(started);
  try testing.expectEqual(@backingInt(Event.Type.started), skep_event_get_type(started));
  try testing.expectEqual(
    @backingInt(Event.Origin.resumed),
    skep_event_get_network_origin(started),
  );

  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  try testing.expectEqual(0, skep_get_network(ctx, &channel, &pan_id, &extended_pan_id));
  try testing.expectEqual(20, channel);
  // The state comes from the dongle's network.
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));

  // Stopping refreshes the state first: the dongle's counters moved.
  ctx.driver.?.sim.network.?.security.network_frame_counter = 1234;
  try testing.expectEqual(0, skep_stop(ctx));
  try testing.expectEqual(0, skep_stop(ctx));
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));
  try testing.expectEqual(@backingInt(Event.Type.stopped), try nextEventType(ctx));
  try testing.expectEqual(1234, ctx.state.?.network_frame_counter);
  try testing.expectEqual(
    err(.NETDOWN),
    skep_get_network(ctx, &channel, &pan_id, &extended_pan_id),
  );
  try testing.expectEqual(err(.NETDOWN), skep_stop(ctx));
}

/// Starts the context and returns how the network came up.
fn startedOrigin(ctx: *Context) !c_int {
  try testing.expectEqual(0, skep_start(ctx));
  for (0..10) |_| {
    if (skep_advance(ctx, 0) != 0) return error.OutOfMemory;
    const event = skep_next_event(ctx) orelse continue;
    defer skep_event_free(event);
    if (skep_event_get_type(event) == @backingInt(Event.Type.started)) {
      return skep_event_get_network_origin(event);
    }
  }
  return error.TestExpectedStarted;
}

test "a dongle without a network forms one, as the options say" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(0, skep_set_option(ctx, "channel", "25"));
  try testing.expectEqual(0, skep_set_option(ctx, "pan-id", "1a62"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  try testing.expectEqual(0, skep_get_network(ctx, &channel, &pan_id, &extended_pan_id));
  try testing.expectEqual(25, channel);
  try testing.expectEqual(0x1a62, pan_id);
  try testing.expect(extended_pan_id != 0);
  // The seed chose the extended PAN ID: the same seed chooses it again.
  const again = try testContext(&testing.allocator);
  defer skep_free(again);
  try testing.expectEqual(0, skep_set_option(again, "driver", "sim"));
  try testing.expectEqual(0, skep_set_option(again, "pan-id", "1a62"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(again));
  try testing.expectEqual(extended_pan_id, again.network.?.extended_pan_id);
}

test "replace-network replaces the dongle's network with a new one" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(0, skep_set_option(ctx, "replace-network", "yes"));
  ctx.sim_dongle.network = sim.testNetwork(.{
    .channel = 20,
    .pan_id = 0x1a62,
    .extended_pan_id = 1,
  });
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  try testing.expectEqual(15, ctx.network.?.channel);
  try testing.expect(ctx.network.?.extended_pan_id != 1);
}

test "a lost link stops at once, and events outlive their context" {
  const ctx = try testContext(&testing.allocator);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  ctx.sim_dongle.network = sim.testNetwork(.{ .channel = 15, .pan_id = 1, .extended_pan_id = 1 });
  try testing.expectEqual(0, skep_start(ctx));
  try testing.expectEqual(@backingInt(Event.Type.started), try nextEventType(ctx));
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));
  skep_link_lost(ctx);
  const stopped = skep_next_event(ctx).?;
  skep_free(ctx);
  try testing.expectEqual(err(.NOTCONN), skep_event_get_error(stopped));
  skep_event_free(stopped);
}

test "the ezsp driver suggests the dongle's serial settings" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "ezsp"));
  var baudrate: c_uint = 0;
  var flow_control: c_int = 0;
  try testing.expectEqual(0, skep_get_serial_defaults(ctx, &baudrate, &flow_control));
  try testing.expectEqual(115200, baudrate);
  try testing.expectEqual(1, flow_control);
  try testing.expectEqual(0, skep_start(ctx));
  var out: [*]const u8 = undefined;
  // A cancel byte and RST, for the dongle.
  try testing.expectEqual(5, skep_output(ctx, &out));
}

test "devices join while the window is open" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  var request: u32 = 0;
  try testing.expectEqual(err(.NETDOWN), skep_permit_join(ctx, 60, &request));
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));

  try testing.expectEqual(err(.INVAL), skep_permit_join(ctx, 255, &request));
  try testing.expectEqual(0, skep_permit_join(ctx, 60, &request));
  try testing.expect(request != 0);
  var second: u32 = 0;
  try testing.expectEqual(err(.NOBUFS), skep_permit_join(ctx, 60, &second));
  try testing.expectEqual(0, skep_advance(ctx, 0));
  const done = skep_next_event(ctx).?;
  defer skep_event_free(done);
  try testing.expectEqual(@backingInt(Event.Type.request_done), skep_event_get_type(done));
  try testing.expectEqual(request, skep_event_get_request(done));
  try testing.expectEqual(0, skep_event_get_error(done));
  const window = skep_next_event(ctx).?;
  defer skep_event_free(window);
  try testing.expectEqual(@backingInt(Event.Type.permit_join), skep_event_get_type(window));
  try testing.expectEqual(60, skep_event_get_duration(window));

  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0012345678, .nwk = 0x1234, .kind = .joined });
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0012345678, .nwk = 0x1234, .kind = .rejoined });
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0012345678, .nwk = 0x1234, .kind = .left });
  try testing.expectEqual(0, skep_advance(ctx, 0));
  const joined = skep_next_event(ctx).?;
  defer skep_event_free(joined);
  try testing.expectEqual(@backingInt(Event.Type.device_joined), skep_event_get_type(joined));
  try testing.expectEqual(0x00124b0012345678, skep_event_get_device(joined));
  // The new device is in the state; the rejoin, with the same address, is only logged.
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));
  try testing.expectEqual(@backingInt(Event.Type.device_left), try nextEventType(ctx));
}

/// Exports the state into a buffer of the testing allocator.
fn exportState(ctx: *Context) ![]u8 {
  var len: usize = 0;
  try testing.expectEqual(err(.NOBUFS), skep_export_state(ctx, null, 0, &len));
  const buf = try testing.allocator.alloc(u8, len);
  errdefer testing.allocator.free(buf);
  try testing.expectEqual(0, skep_export_state(ctx, buf.ptr, buf.len, &len));
  try testing.expectEqual(buf.len, len);
  return buf;
}

/// The events up to the next of type `wanted`, which is returned: null if there is none.
fn nextOfType(ctx: *Context, wanted: Event.Type) !?*Event {
  for (0..10) |_| {
    if (skep_advance(ctx, 0) != 0) return error.OutOfMemory;
    const event = skep_next_event(ctx) orelse return null;
    if (skep_event_get_type(event) == @backingInt(wanted)) return event;
    skep_event_free(event);
  }
  return null;
}

test "the state is exported, and brings the network back onto a new dongle" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  var len: usize = 0;
  try testing.expectEqual(err(.NODATA), skep_export_state(ctx, null, 0, &len));
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));
  var request: u32 = 0;
  try testing.expectEqual(0, skep_permit_join(ctx, 60, &request));
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0012345678, .nwk = 0x1234, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .state_changed)).?);
  try testing.expectEqual(null, try nextEventType(ctx));
  // A refresh reports the counters that moved, then ends.
  ctx.driver.?.sim.network.?.security.network_frame_counter = 5000;
  ctx.driver.?.sim.network.?.security.trust_center_frame_counter = 70;
  try testing.expectEqual(0, skep_refresh_state(ctx, &request));
  var second: u32 = 0;
  try testing.expectEqual(err(.NOBUFS), skep_refresh_state(ctx, &second));
  try testing.expectEqual(@backingInt(Event.Type.state_changed), try nextEventType(ctx));
  const done = skep_next_event(ctx).?;
  try testing.expectEqual(request, skep_event_get_request(done));
  skep_event_free(done);
  const saved = try exportState(ctx);
  defer testing.allocator.free(saved);
  try testing.expect(std.mem.indexOf(u8, saved, "\"frame_counter\": 5000") != null);
  try testing.expect(std.mem.indexOf(u8, saved, "\"ieee_address\": \"00124b0012345678\"") != null);

  // A new dongle, of another IEEE address and without a network.
  const new = try testContext(&testing.allocator);
  defer skep_free(new);
  try testing.expectEqual(0, skep_set_option(new, "driver", "sim"));
  try testing.expectEqual(err(.INVAL), skep_import_state(new, saved.ptr, saved.len - 10));
  try testing.expectEqual(0, skep_import_state(new, saved.ptr, saved.len));
  new.sim_dongle.ieee = 0x0200_0000_0000_0002;
  try testing.expectEqual(@backingInt(Event.Origin.restored), try startedOrigin(new));
  try testing.expectEqual(err(.BUSY), skep_import_state(new, saved.ptr, saved.len));
  const network = new.driver.?.sim.network.?;
  try testing.expectEqual(ctx.network.?, network.network);
  try testing.expectEqual(ctx.state.?.network_key, network.security.network_key);
  // The counters, with the margin for frames sent since the state was saved.
  try testing.expectEqual(5000 + 100000, network.security.network_frame_counter);
  try testing.expectEqual(70 + 100000, network.security.trust_center_frame_counter);
  try testing.expectEqual(0x00124b0012345678, new.state.?.devices.items[0].ieee);
  try testing.expectEqual(0x0200_0000_0000_0002, new.state.?.coordinator_ieee);
}

test "a dongle holding another network is not overwritten without replace-network" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  const saved = try exportState(ctx);
  defer testing.allocator.free(saved);

  const other = try testContext(&testing.allocator);
  defer skep_free(other);
  try testing.expectEqual(0, skep_set_option(other, "driver", "sim"));
  try testing.expectEqual(0, skep_import_state(other, saved.ptr, saved.len));
  other.sim_dongle.network = sim.testNetwork(.{
    .channel = 20,
    .pan_id = 0x1a62,
    .extended_pan_id = 1,
  });
  try testing.expectEqual(0, skep_start(other));
  const stopped = (try nextOfType(other, .stopped)).?;
  defer skep_event_free(stopped);
  try testing.expectEqual(err(.EXIST), skep_event_get_error(stopped));

  try testing.expectEqual(0, skep_set_option(other, "replace-network", "yes"));
  try testing.expectEqual(@backingInt(Event.Origin.restored), try startedOrigin(other));
  try testing.expectEqual(ctx.network.?, other.network.?);
}

test "stopping ends pending requests" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(@backingInt(Event.Origin.formed), try startedOrigin(ctx));
  var request: u32 = 0;
  try testing.expectEqual(0, skep_permit_join(ctx, 60, &request));
  var refresh: u32 = 0;
  try testing.expectEqual(0, skep_refresh_state(ctx, &refresh));
  // Gone before the driver reported anything.
  while (skep_next_event(ctx)) |event| {
    skep_event_free(event);
  }
  skep_link_lost(ctx);
  for ([_]u32{ request, refresh }) |id| {
    const done = skep_next_event(ctx).?;
    defer skep_event_free(done);
    try testing.expectEqual(id, skep_event_get_request(done));
    try testing.expectEqual(err(.CANCELED), skep_event_get_error(done));
  }
  const stopped = skep_next_event(ctx).?;
  defer skep_event_free(stopped);
  try testing.expectEqual(err(.NOTCONN), skep_event_get_error(stopped));
}

/// Starting, running and stopping with the sim driver, then moving the network to another
/// simulated dongle, every allocation failing in turn.
fn startAndStop(allocator: std.mem.Allocator) !void {
  const ctx = try testContext(&allocator);
  defer skep_free(ctx);
  if (skep_set_option(ctx, "driver", "sim") != 0) return error.TestUnexpectedResult;
  ctx.sim_dongle.network = sim.testNetwork(.{ .channel = 15, .pan_id = 1, .extended_pan_id = 1 });
  if (skep_start(ctx) != 0) return error.TestUnexpectedResult;
  try waitFor(ctx, .started);
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0012345678, .nwk = 0x1234, .kind = .joined });
  try waitFor(ctx, .device_joined);
  if (skep_stop(ctx) != 0) return error.OutOfMemory;
  try waitFor(ctx, .stopped);

  var len: usize = 0;
  _ = skep_export_state(ctx, null, 0, &len);
  const saved = try allocator.alloc(u8, len);
  defer allocator.free(saved);
  if (skep_export_state(ctx, saved.ptr, saved.len, &len) != 0) return error.TestUnexpectedResult;
  const new = try testContext(&allocator);
  defer skep_free(new);
  if (skep_set_option(new, "driver", "sim") != 0) return error.TestUnexpectedResult;
  const imported = skep_import_state(new, saved.ptr, saved.len);
  if (imported == err(.NOMEM)) return error.OutOfMemory;
  if (imported != 0) return error.TestUnexpectedResult;
  if (skep_start(new) != 0) return error.TestUnexpectedResult;
  try waitFor(new, .started);
  if (new.state.?.devices.items.len != 1) return error.TestUnexpectedResult;
}

/// Runs the loop until an event of type `wanted`.
fn waitFor(ctx: *Context, wanted: Event.Type) !void {
  for (0..10) |_| {
    const event_type = try nextEventType(ctx) orelse continue;
    if (event_type == @backingInt(wanted)) return;
  }
  return error.TestExpectedEvent;
}

test "running out of memory loses nothing" {
  try testing.checkAllAllocationFailures(testing.allocator, startAndStop, .{});
}

test {
  _ = @import("allocator.zig");
  _ = @import("Context.zig");
  _ = @import("Event.zig");
  _ = @import("State.zig");
  _ = @import("zcl.zig");
  _ = @import("zdo.zig");
  _ = @import("driver/driver.zig");
  _ = @import("driver/ezsp/ezsp.zig");
  std.testing.refAllDecls(@This());
}
