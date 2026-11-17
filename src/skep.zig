//! libskep, a small Zigbee stack: the root of the library, which exports the C API declared in
//! `include/skep.h`. The functions here only translate between C and Context.zig and Event.zig.
//!
//! The API is implemented as milestones need it; functions skep.h declares and this file does not
//! export yet are still to come.

const std = @import("std");
const build_options = @import("build_options");
const CAllocator = @import("allocator.zig").CAllocator;
/// For skepd's tests, which give the sim driver its devices.
pub const Context = @import("Context.zig");
const Event = @import("Event.zig");
const State = @import("State.zig");
const requests = @import("requests.zig");
const setup = @import("setup.zig");
const readings = @import("readings.zig");
pub const zcl = @import("zcl.zig");
pub const sim = @import("driver/sim/sim.zig");
const driver_layer = @import("driver/driver.zig");

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

export fn skep_event_get_removed(event: *const Event) c_int {
  return @intFromBool(event.removed);
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

export fn skep_event_get_endpoint(event: *const Event) u8 {
  return event.endpoint;
}

export fn skep_event_get_cluster(event: *const Event) u16 {
  return event.cluster;
}

export fn skep_event_get_manufacturer_code(event: *const Event) u16 {
  return event.manufacturer_code;
}

export fn skep_event_get_attribute_count(event: *const Event) usize {
  return event.attribute_count;
}

export fn skep_event_get_attribute(
  event: *const Event,
  index: usize,
  attribute: *Event.Attribute,
) c_int {
  if (index >= event.attribute_count) return err(.INVAL);
  attribute.* = event.attributes[index];
  return 0;
}

export fn skep_event_get_reading(
  event: *const Event,
  index: usize,
  reading: *Event.CReading,
) c_int {
  if (index >= event.attribute_count) return err(.INVAL);
  const r = event.attribute_readings[index] orelse return err(.NOENT);
  reading.* = .{ .name = r.name, .unit = r.unit, .value = r.value };
  return 0;
}

const ReadingSource = readings.CSource;

export fn skep_device_get_readings(
  ctx: *const Context,
  ieee: u64,
  sources: ?[*]ReadingSource,
  capacity: usize,
  count: *usize,
) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  if (!interviewed(d)) return err(.AGAIN);
  if (capacity > 0 and sources == null) return err(.INVAL);
  const own = setup.entryOf(d).readings;
  var n: usize = 0;
  // The standard readings, as the device scales them if it does its own way, then its others:
  // in the tables' order, what matters most first.
  for ([_][]const readings.Definition{ &readings.standard, own }, 0..) |definitions, pass| {
    for (definitions) |*listed| {
      if (pass == 1 and readings.find(&.{}, listed.cluster, listed.attribute) != null) continue;
      const definition = readings.find(own, listed.cluster, listed.attribute).?;
      const settable_range = readings.range(definition, limitsOf(d, definition));
      for (d.endpoints) |e| {
        if (!e.hasInput(definition.cluster)) continue;
        if (n < capacity) {
          sources.?[n] = .{
            .endpoint = e.id,
            .cluster = definition.cluster,
            .attribute = definition.attribute,
            .settable = @intFromBool(definition.set != null),
            .min = settable_range[0],
            .max = settable_range[1],
            .name = definition.name.ptr,
            .unit = definition.unit.ptr,
          };
        }
        n += 1;
      }
    }
  }
  count.* = n;
  return 0;
}

export fn skep_event_get_command(event: *const Event) u8 {
  return event.command;
}

// libskep decodes the arguments of no command yet: the payload holds them.
export fn skep_event_get_argument_count(_: *const Event, _: *usize) c_int {
  return err(.OPNOTSUPP);
}

export fn skep_event_get_argument(_: *const Event, _: usize, _: *zcl.Value) c_int {
  return err(.OPNOTSUPP);
}

export fn skep_event_get_payload(event: *const Event, len: *usize) [*]const u8 {
  len.* = event.payload_len;
  return &event.payload;
}

export fn skep_get_devices(
  ctx: *const Context,
  devices: ?[*]u64,
  capacity: usize,
  count: *usize,
) c_int {
  const known = if (ctx.state) |*s| s.devices.items else &.{};
  count.* = known.len;
  if (capacity > 0) {
    const out = devices orelse return err(.INVAL);
    for (known[0..@min(capacity, known.len)], 0..) |d, i| {
      out[i] = d.ieee;
    }
  }
  return 0;
}

/// The device of IEEE address `ieee`, or a negative errno value.
fn deviceOf(ctx: *const Context, ieee: u64) union(enum) {
  device: *const State.Device,
  err: c_int,
} {
  const s = if (ctx.state) |*s| s else return .{ .err = err(.NODEV) };
  return .{ .device = s.device(ieee) orelse return .{ .err = err(.NODEV) } };
}

export fn skep_device_get_node(
  ctx: *const Context,
  ieee: u64,
  node_type: *c_int,
  manufacturer_code: *u16,
  rx_on_when_idle: *c_int,
) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  const node = d.node orelse return err(.AGAIN);
  node_type.* = @backingInt(node.type);
  manufacturer_code.* = node.manufacturer_code;
  rx_on_when_idle.* = @intFromBool(node.rx_on_when_idle);
  return 0;
}

export fn skep_device_get_short_address(ctx: *const Context, ieee: u64, address: *u16) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  address.* = d.nwk orelse return err(.AGAIN);
  return 0;
}

/// Copies a string of a device into `buf`, NUL-terminated and cut short if needed, and returns
/// its full length.
fn copyText(text: ?[]const u8, buf: ?[*]u8, size: usize) c_int {
  const t = text orelse return err(.AGAIN);
  if (size > 0) {
    const out = buf orelse return err(.INVAL);
    const len = @min(t.len, size - 1);
    @memcpy(out[0..len], t[0..len]);
    out[len] = 0;
  }
  return @intCast(t.len);
}

export fn skep_device_get_manufacturer(
  ctx: *const Context,
  ieee: u64,
  buf: ?[*]u8,
  size: usize,
) c_int {
  return switch (deviceOf(ctx, ieee)) {
    .device => |d| copyText(d.manufacturer, buf, size),
    .err => |e| e,
  };
}

export fn skep_device_get_model(ctx: *const Context, ieee: u64, buf: ?[*]u8, size: usize) c_int {
  return switch (deviceOf(ctx, ieee)) {
    .device => |d| copyText(d.model, buf, size),
    .err => |e| e,
  };
}

/// Whether the device's endpoints are known yet.
fn interviewed(d: *const State.Device) bool {
  return switch (d.progress.stage) {
    .node, .endpoints => d.endpoints.len > 0,
    else => true,
  };
}

export fn skep_device_get_endpoints(
  ctx: *const Context,
  ieee: u64,
  endpoints: ?[*]u8,
  capacity: usize,
  count: *usize,
) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  if (!interviewed(d)) return err(.AGAIN);
  count.* = d.endpoints.len;
  if (capacity > 0) {
    const out = endpoints orelse return err(.INVAL);
    for (d.endpoints[0..@min(capacity, d.endpoints.len)], 0..) |e, i| {
      out[i] = e.id;
    }
  }
  return 0;
}

export fn skep_device_get_endpoint(
  ctx: *const Context,
  ieee: u64,
  endpoint: u8,
  profile: *u16,
  device_type: *u16,
) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  if (!interviewed(d)) return err(.AGAIN);
  const e = d.endpoint(endpoint) orelse return err(.NOENT);
  profile.* = e.profile;
  device_type.* = e.device;
  return 0;
}

export fn skep_device_get_clusters(
  ctx: *const Context,
  ieee: u64,
  endpoint: u8,
  side: c_int,
  clusters: ?[*]u16,
  capacity: usize,
  count: *usize,
) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  if (!interviewed(d)) return err(.AGAIN);
  const e = d.endpoint(endpoint) orelse return err(.NOENT);
  const list = switch (std.enums.fromInt(ClusterSide, side) orelse return err(.INVAL)) {
    .input => e.input_clusters,
    .output => e.output_clusters,
  };
  count.* = list.len;
  if (capacity > 0) {
    const out = clusters orelse return err(.INVAL);
    @memcpy(out[0..@min(capacity, list.len)], list[0..@min(capacity, list.len)]);
  }
  return 0;
}

export fn skep_device_get_setup(ctx: *const Context, ieee: u64, setup_state: *c_int) c_int {
  const d = switch (deviceOf(ctx, ieee)) {
    .device => |d| d,
    .err => |e| return e,
  };
  const setup_state_of: Setup = switch (d.progress.stage) {
    .ready => .ready,
    .failed => .failed,
    else => .pending,
  };
  setup_state.* = @backingInt(setup_state_of);
  return 0;
}

/// The enums of skep.h that libskep has no type of its own for; abi_test.zig checks their values,
/// and those of the types libskep has, against the header.
pub const ClusterSide = enum(c_int) { input = 0, output = 1 };
pub const Setup = enum(c_int) { pending = 0, ready = 1, failed = 2 };

export fn skep_setup_device(ctx: *Context, ieee: u64) c_int {
  return ctx.setupDevice(ieee);
}

export fn skep_remove_device(ctx: *Context, ieee: u64, deadline: u64, request: *u32) c_int {
  return requests.remove(ctx, ieee, deadline, request);
}

export fn skep_read_attributes(
  ctx: *Context,
  target: *const requests.Target,
  ids: ?[*]const u16,
  count: usize,
  deadline: u64,
  request: *u32,
) c_int {
  const list = if (ids) |i| i[0..count] else return err(.INVAL);
  return requests.read(ctx, target, list, deadline, request);
}

export fn skep_write_attributes(
  ctx: *Context,
  target: *const requests.Target,
  attributes: ?[*]const Event.Attribute,
  count: usize,
  deadline: u64,
  request: *u32,
) c_int {
  const list = if (attributes) |a| a[0..count] else return err(.INVAL);
  return requests.write(ctx, target, list, deadline, request);
}

export fn skep_configure_reporting(
  ctx: *Context,
  target: *const requests.Target,
  reporting: ?[*]const requests.Reporting,
  count: usize,
  deadline: u64,
  request: *u32,
) c_int {
  const list = if (reporting) |r| r[0..count] else return err(.INVAL);
  return requests.configure(ctx, target, list, deadline, request);
}

export fn skep_bind(
  ctx: *Context,
  target: *const requests.Target,
  deadline: u64,
  request: *u32,
) c_int {
  return requests.bind(ctx, target, false, deadline, request);
}

export fn skep_unbind(
  ctx: *Context,
  target: *const requests.Target,
  deadline: u64,
  request: *u32,
) c_int {
  return requests.bind(ctx, target, true, deadline, request);
}

export fn skep_send_command(
  ctx: *Context,
  target: *const requests.Target,
  command: u8,
  arguments: ?[*]const zcl.Value,
  count: usize,
  deadline: u64,
  request: *u32,
) c_int {
  const list: []const zcl.Value = if (arguments) |a|
    a[0..count]
  else if (count == 0)
    &.{}
  else
    return err(.INVAL);
  return requests.command(ctx, target, command, list, deadline, request);
}

const Setting = readings.CSetting;

export fn skep_set_reading(
  ctx: *Context,
  setting: *const Setting,
  reading: [*:0]const u8,
  value: f64,
  deadline: u64,
  request: *u32,
) c_int {
  const e = switch (endpointOf(ctx, setting)) {
    .endpoint => |e| e,
    .err => |code| return code,
  };
  const definition = definitionOn(e.device, e.endpoint, std.mem.span(reading)) orelse
    return err(.NOENT);
  if (definition.set == null) return err(.OPNOTSUPP);
  const limits = limitsOf(e.device, definition);
  const command = readings.setting(definition, value, setting.transition, limits) catch |why|
    return settingErr(why);
  return sendSetting(ctx, setting, definition.cluster, command, deadline, request);
}

export fn skep_set_color(
  ctx: *Context,
  setting: *const Setting,
  rgb: u32,
  deadline: u64,
  request: *u32,
) c_int {
  const e = switch (endpointOf(ctx, setting)) {
    .endpoint => |e| e,
    .err => |code| return code,
  };
  if (!e.endpoint.hasInput(color_control)) return err(.NOENT);
  const command = readings.colorSetting(rgb, setting.transition) catch |why| return settingErr(why);
  return sendSetting(ctx, setting, color_control, command, deadline, request);
}

/// -ERANGE for a value out of the reading's range, -EINVAL for one that is not a value at all.
fn settingErr(e: readings.SettingError) c_int {
  return switch (e) {
    error.OutOfRange => err(.RANGE),
    error.Invalid => err(.INVAL),
  };
}

const color_control = zcl.Cluster.color_control;

/// The device's own limits of a reading's attribute: a light's range of colour temperatures.
fn limitsOf(d: *const State.Device, definition: *const readings.Definition) ?[2]u64 {
  if (definition.cluster != color_control or
    definition.attribute != zcl.AttributeId.color_control.color_temperature_mireds) {
    return null;
  }
  const r = d.color_temperature_range orelse return null;
  return .{ r.min, r.max };
}

const SettingEndpoint = struct {
  device: *const State.Device,
  endpoint: *const State.Endpoint,
};

/// The device and endpoint a setting goes to, once the device is interviewed.
fn endpointOf(ctx: *Context, setting: *const Setting) union(enum) {
  endpoint: SettingEndpoint,
  err: c_int,
} {
  if (!std.mem.allEqual(u32, &setting.reserved, 0)) return .{ .err = err(.INVAL) };
  const d = switch (deviceOf(ctx, setting.device)) {
    .device => |d| d,
    .err => |e| return .{ .err = e },
  };
  if (!interviewed(d)) return .{ .err = err(.AGAIN) };
  for (d.endpoints) |*e| {
    if (e.id == setting.endpoint) return .{ .endpoint = .{ .device = d, .endpoint = e } };
  }
  return .{ .err = err(.NOENT) };
}

/// The definition of a reading of an endpoint, by its name: the device's own, then the standard
/// ones it does not replace.
fn definitionOn(
  d: *const State.Device,
  e: *const State.Endpoint,
  name: []const u8,
) ?*const readings.Definition {
  const own = setup.entryOf(d).readings;
  for ([_][]const readings.Definition{ own, &readings.standard }) |definitions| {
    for (definitions) |*listed| {
      if (!std.mem.eql(u8, listed.name, name) or !e.hasInput(listed.cluster)) continue;
      return readings.find(own, listed.cluster, listed.attribute).?;
    }
  }
  return null;
}

fn sendSetting(
  ctx: *Context,
  setting: *const Setting,
  cluster: u16,
  command: readings.Command,
  deadline: u64,
  request: *u32,
) c_int {
  const target: requests.Target = .{
    .device = setting.device,
    .endpoint = setting.endpoint,
    .cluster = cluster,
    .manufacturer_code = 0,
    .reserved = @splat(0),
  };
  return requests.command(
    ctx,
    &target,
    command.id,
    command.arguments[0..command.count],
    deadline,
    request,
  );
}

export fn skep_cancel(ctx: *Context, request: u32) c_int {
  return ctx.cancel(request);
}

export fn skep_get_network(
  ctx: *const Context,
  channel: *u8,
  pan_id: *u16,
  extended_pan_id: *u64,
) c_int {
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

test "the port's flow control reaches the driver" {
  for ([_]struct { [:0]const u8, bool }{.{ "hardware", false }, .{ "software", true }}) |case| {
    const ctx = try testContext(&testing.allocator);
    defer skep_free(ctx);
    try testing.expectEqual(0, skep_set_option(ctx, "driver", "ezsp"));
    try testing.expectEqual(0, skep_set_option(ctx, "flow-control", case[0]));
    try testing.expectEqual(0, skep_start(ctx));
    try testing.expectEqual(
      case[1],
      ctx.driver.?.ezsp.driver.startup.link.options.software_flow_control,
    );
  }
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(err(.INVAL), skep_set_option(ctx, "flow-control", "xon"));
  try testing.expectEqual(0, skep_set_option(ctx, "tx-power", "-3"));
  try testing.expectEqual(-3, ctx.options.tx_power.?);
  try testing.expectEqual(err(.INVAL), skep_set_option(ctx, "tx-power", "200"));
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
  // The window opens, then the request ends once the routers are told.
  const window = skep_next_event(ctx).?;
  defer skep_event_free(window);
  try testing.expectEqual(@backingInt(Event.Type.permit_join), skep_event_get_type(window));
  try testing.expectEqual(60, skep_event_get_duration(window));
  const done = skep_next_event(ctx).?;
  defer skep_event_free(done);
  try testing.expectEqual(@backingInt(Event.Type.request_done), skep_event_get_type(done));
  try testing.expectEqual(request, skep_event_get_request(done));
  try testing.expectEqual(0, skep_event_get_error(done));
  // Told with a broadcast.
  const broadcast = ctx.driver.?.sim.sent[ctx.driver.?.sim.sent_len - 1];
  try testing.expect(broadcast.broadcast);
  try testing.expectEqual(0xfffc, broadcast.address);
  try testing.expectEqual(0x0036, broadcast.cluster);

  try openWindow(ctx);
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
  // Gone by itself: not removed.
  const gone = skep_next_event(ctx).?;
  defer skep_event_free(gone);
  try testing.expectEqual(@backingInt(Event.Type.device_left), skep_event_get_type(gone));
  try testing.expectEqual(0, skep_event_get_removed(gone));
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

test "devices libskep does not know are recorded only while the trust center admits them" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(0, skep_set_option(ctx, "log-level", "warning"));
  _ = try startedOrigin(ctx);
  const sim_driver = &ctx.driver.?.sim;
  // With no window open: a rejoin, a join, and an announcement, the last from the device itself.
  sim_driver.device(.{ .ieee = 0x00124b0000000001, .nwk = 0x1001, .kind = .rejoined });
  sim_driver.device(.{ .ieee = 0x00124b0000000002, .nwk = 0x1002, .kind = .joined });
  sim_driver.receive(announcement(0x1003, 0x1003, 0x00124b0000000003));
  for (0..3) |_| {
    const logged = (try nextOfType(ctx, .log)) orelse return error.TestExpectedLog;
    defer skep_event_free(logged);
    try testing.expect(
      std.mem.indexOf(u8, std.mem.span(logged.log()), "no join window open") != null,
    );
  }
  try testing.expectEqual(null, try nextEventType(ctx));
  try testing.expectEqual(0, ctx.state.?.devices.items.len);

  // A window open: an announcement from another address than the one it announces is not the
  // device's; the device's own is.
  try openWindow(ctx);
  sim_driver.receive(announcement(0x2222, 0x1003, 0x00124b0000000003));
  sim_driver.receive(announcement(0x1003, 0x0000, 0x00124b0000000003));
  try testing.expectEqual(null, try nextEventType(ctx));
  sim_driver.receive(announcement(0x1003, 0x1003, 0x00124b0000000003));
  skep_event_free((try nextOfType(ctx, .device_joined)).?);
  // An unknown device rejoining while the window is open is new: it is set up.
  sim_driver.device(.{ .ieee = 0x00124b0000000001, .nwk = 0x1001, .kind = .rejoined });
  const joined = (try nextOfType(ctx, .device_joined)).?;
  defer skep_event_free(joined);
  try testing.expectEqual(0x00124b0000000001, skep_event_get_device(joined));
  try testing.expectEqual(2, ctx.state.?.devices.items.len);

  // Once the window ends, known devices still rejoin, and move.
  sim_driver.windowEnds();
  skep_event_free((try nextOfType(ctx, .permit_join)).?);
  sim_driver.device(.{ .ieee = 0x00124b0000000001, .nwk = 0x1010, .kind = .rejoined });
  skep_event_free((try nextOfType(ctx, .state_changed)).?);
  try testing.expectEqual(0x1010, ctx.state.?.device(0x00124b0000000001).?.nwk);
}

test "libskep records so many devices, and no more" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(0, skep_set_option(ctx, "log-level", "warning"));
  _ = try startedOrigin(ctx);
  const s = &ctx.state.?;
  for (0..State.max_devices) |i| {
    _ = try s.noteDevice(testing.allocator, 0x00124b0000000000 + i, null);
  }
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b00ffffffff, .nwk = 0x1001, .kind = .joined });
  const logged = (try nextOfType(ctx, .log)).?;
  defer skep_event_free(logged);
  try testing.expect(
    std.mem.indexOf(u8, std.mem.span(logged.log()), "1024 devices at most") != null,
  );
  try testing.expectEqual(null, s.device(0x00124b00ffffffff));
  try testing.expectEqual(State.max_devices, s.devices.items.len);
}

test "a join window that ends on its own is closed on the trust center too" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  _ = try startedOrigin(ctx);
  try openWindow(ctx);
  const sim_driver = &ctx.driver.?.sim;
  try testing.expectEqual(Context.max_permit_join, sim_driver.permitted);
  sim_driver.windowEnds();
  const closed = (try nextOfType(ctx, .permit_join)).?;
  defer skep_event_free(closed);
  try testing.expectEqual(0, skep_event_get_duration(closed));
  // Closed by libskep, which tells the routers too, and reports nothing more.
  try testing.expectEqual(0, sim_driver.permitted);
  try testing.expectEqual(0x0036, sim_driver.sent[sim_driver.sent_len - 1].cluster);
  try testing.expectEqual(null, try nextEventType(ctx));
  try testing.expect(!ctx.admitting);
  // Stopping with no window open refreshes, and stops.
  try testing.expectEqual(0, skep_stop(ctx));
  skep_event_free((try nextOfType(ctx, .stopped)).?);
}

test "a device that rejoins before the network is known is not a crash" {
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  // A network forming: the state is made once it is formed.
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  try testing.expectEqual(0, skep_start(ctx));
  ctx.driver.?.sim.device(.{ .ieee = 0x00124b0000000001, .nwk = 0x1001, .kind = .rejoined });
  skep_event_free((try nextOfType(ctx, .started)).?);
  try testing.expectEqual(null, ctx.state.?.device(0x00124b0000000001));
}

/// A Device_annce from `from`, announcing `ieee` at `nwk`.
fn announcement(from: u16, nwk: u16, ieee: u64) driver_layer.Frame {
  var frame: driver_layer.Frame = .{
    .address = from,
    .profile = 0x0000,
    .cluster = 0x0013,
    .source_endpoint = 0,
    .destination_endpoint = 0,
  };
  var payload: [12]u8 = undefined;
  payload[0] = 1;
  std.mem.writeInt(u16, payload[1..3], nwk, .little);
  std.mem.writeInt(u64, payload[3..11], ieee, .little);
  payload[11] = 0x8e;
  frame.setPayload(&payload);
  return frame;
}

/// Opens the join window, as an application does before devices join.
fn openWindow(ctx: *Context) !void {
  var request: u32 = 0;
  try testing.expectEqual(0, skep_permit_join(ctx, Context.max_permit_join, &request));
  skep_event_free((try nextOfType(ctx, .request_done)) orelse return error.TestExpectedRequestDone);
}

/// The events up to the next of type `wanted`, which is returned: null if there is none.
fn nextOfType(ctx: *Context, wanted: Event.Type) !?*Event {
  for (0..100) |_| {
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
  skep_event_free((try nextOfType(ctx, .request_done)).?);
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

/// A context with the sim driver, whose network holds `devices`, started.
fn simContext(allocator: *const std.mem.Allocator, devices: []sim.Device) !*Context {
  const ctx = try testContext(allocator);
  errdefer skep_free(ctx);
  ctx.sim_dongle.devices = devices;
  if (skep_set_option(ctx, "driver", "sim") != 0) return error.TestUnexpectedResult;
  if (try startedOrigin(ctx) != @backingInt(Event.Origin.formed)) return error.TestUnexpectedResult;
  return ctx;
}

const sensor_ieee = 0xf44250000d350000;

const bulb_ieee = 0xc4d7fdba7b600000;

/// A ThirdReality ZL4 bulb, as it answers its interview.
fn simBulb() sim.Device {
  return .{
    .ieee = bulb_ieee,
    .nwk = 0x6442,
    .model = "3RCB02070Z",
    .input_clusters = &.{ 0x0000, 0x0003, 0x0004, 0x0005, 0x0006, 0x0008, 0x0300, 0xff04 },
    .color_temperature_range = .{ 142, 454 },
  };
}

test "with setup interview, a device is interviewed and set up no further" {
  var devices = [_]sim.Device{ simBulb() };
  const ctx = try testContext(&testing.allocator);
  defer skep_free(ctx);
  ctx.sim_dongle.devices = &devices;
  try testing.expectEqual(0, skep_set_option(ctx, "setup", "interview"));
  try testing.expectEqual(err(.INVAL), skep_set_option(ctx, "setup", "some"));
  try testing.expectEqual(0, skep_set_option(ctx, "driver", "sim"));
  _ = try startedOrigin(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = bulb_ieee, .nwk = 0x6442, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);
  try testing.expectEqualStrings("3RCB02070Z", ctx.state.?.device(bulb_ieee).?.model.?);
  try testing.expectEqual(0, devices[0].binds);
  try testing.expectEqual(0, devices[0].configurations);
}

test "a bulb is bound and configured to report its state" {
  var devices = [_]sim.Device{ simBulb() };
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = bulb_ieee, .nwk = 0x6442, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);
  try testing.expectEqual(3, devices[0].binds);
  try testing.expectEqual(7, devices[0].configurations);
}

/// Sets a reading of the bulb, and returns the ZCL frame it got, once it answered.
fn setBulb(ctx: *Context, reading: [*:0]const u8, value: f64, transition: f64) ![]const u8 {
  var request: u32 = 0;
  const setting: Setting = .{
    .device = bulb_ieee,
    .endpoint = 1,
    .transition = transition,
    .reserved = @splat(0),
  };
  const r = skep_set_reading(ctx, &setting, reading, value, std.math.maxInt(u64), &request);
  if (r != 0) return error.TestUnexpectedResult;
  return bulbAnswered(ctx);
}

fn bulbAnswered(ctx: *Context) ![]const u8 {
  const done = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(done);
  try testing.expectEqual(0, skep_event_get_error(done));
  try testing.expectEqual(0, skep_event_get_status(done));
  const sent = &ctx.driver.?.sim.sent[ctx.driver.?.sim.sent_len - 1];
  return sent.bytes();
}

test "a bulb's readings and colour are set by its clusters' commands" {
  var devices = [_]sim.Device{ simBulb() };
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = bulb_ieee, .nwk = 0x6442, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);

  // Listed as settable.
  var sources: [16]readings.CSource = undefined;
  var count: usize = 0;
  try testing.expectEqual(
    0,
    skep_device_get_readings(ctx, bulb_ieee, &sources, sources.len, &count),
  );
  try testing.expectEqualStrings("on", std.mem.span(sources[0].name));
  try testing.expectEqual(1, sources[0].settable);
  try testing.expectEqualStrings("color_x", std.mem.span(sources[5].name));
  try testing.expectEqual(0, sources[5].settable);

  // Off; 50 % over 1 s; 2700 K; red.
  var frame = try setBulb(ctx, "on", 0, 0);
  try testing.expectEqualSlices(u8, &.{ 0x01, frame[1], 0x00 }, frame);
  frame = try setBulb(ctx, "level", 50, 1);
  try testing.expectEqualSlices(u8, &.{ 0x01, frame[1], 0x04, 127, 10, 0 }, frame);
  frame = try setBulb(ctx, "color_temperature", 2700, 0);
  try testing.expectEqualSlices(u8, &.{ 0x01, frame[1], 0x0a, 0x72, 0x01, 0, 0 }, frame);
  var request: u32 = 0;
  var setting: Setting = .{
    .device = bulb_ieee,
    .endpoint = 1,
    .transition = 0,
    .reserved = @splat(0),
  };
  try testing.expectEqual(
    0,
    skep_set_color(ctx, &setting, 0xff0000, std.math.maxInt(u64), &request),
  );
  frame = try bulbAnswered(ctx);
  try testing.expectEqualSlices(
    u8,
    &.{ 0x01, frame[1], 0x07, 0xdc, 0xa3, 0x79, 0x54, 0, 0 },
    frame,
  );

  // What cannot be set is refused at once.
  const never = std.math.maxInt(u64);
  try testing.expectEqual(
    err(.RANGE),
    skep_set_reading(ctx, &setting, "level", 150, never, &request),
  );
  // Warmer than the bulb goes: its range, read at setup, is 2203 to 7042 K.
  try testing.expectEqual(
    err(.RANGE),
    skep_set_reading(ctx, &setting, "color_temperature", 1000, never, &request),
  );
  try testing.expectEqualStrings("color_temperature", std.mem.span(sources[2].name));
  try testing.expectEqual(2203, @round(sources[2].min));
  try testing.expectEqual(7042, @round(sources[2].max));
  try testing.expectEqual(
    err(.NOENT),
    skep_set_reading(ctx, &setting, "power", 1, never, &request),
  );
  try testing.expectEqual(
    err(.OPNOTSUPP),
    skep_set_reading(ctx, &setting, "color_x", 0.5, never, &request),
  );
  try testing.expectEqual(err(.INVAL), skep_set_color(ctx, &setting, 0x000000, never, &request));
  setting.transition = -1;
  try testing.expectEqual(
    err(.INVAL),
    skep_set_reading(ctx, &setting, "level", 50, never, &request),
  );
  setting.transition = 0;
  setting.endpoint = 2;
  try testing.expectEqual(
    err(.NOENT),
    skep_set_reading(ctx, &setting, "level", 50, never, &request),
  );
  setting.endpoint = 1;
  setting.reserved[0] = 1;
  try testing.expectEqual(
    err(.INVAL),
    skep_set_reading(ctx, &setting, "level", 50, never, &request),
  );
  setting.reserved[0] = 0;
  setting.device = 1;
  try testing.expectEqual(err(.NODEV), skep_set_color(ctx, &setting, 0xff0000, never, &request));
}

test "a device that joins is interviewed, set up, and reports" {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce, .rx_on_when_idle = false }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  const ready = (try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady;
  try testing.expectEqual(sensor_ieee, skep_event_get_device(ready));
  skep_event_free(ready);

  const d = ctx.state.?.device(sensor_ieee).?;
  try testing.expectEqual(State.Stage.ready, d.progress.stage);
  try testing.expectEqualStrings("3RTHS0224Z", d.model.?);
  try testing.expectEqualStrings("Third Reality, Inc", d.manufacturer.?);
  try testing.expectEqual(State.NodeType.end_device, d.node.?.type);
  try testing.expect(d.sleepy());
  try testing.expectEqual(1, d.endpoints.len);
  try testing.expect(d.endpoints[0].hasInput(0x0405));
  try testing.expectEqualSlices(u16, &.{ 0x0019 }, d.endpoints[0].output_clusters);
  // The steps of its entry: three bindings, three reporting configurations.
  try testing.expectEqual(3, devices[0].binds);
  try testing.expectEqual(3, devices[0].configurations);

  // MeasuredValue of the temperature: 22.43 °C.
  ctx.driver.?.sim.report(&devices[0], 0x0402, &.{ 0x00, 0x00, 0x29, 0xc3, 0x08 });
  const report = (try nextOfType(ctx, .attributes)) orelse return error.TestExpectedReport;
  defer skep_event_free(report);
  try testing.expectEqual(sensor_ieee, report.device);
  try testing.expectEqual(1, report.endpoint);
  try testing.expectEqual(0x0402, report.cluster);
  try testing.expectEqual(1, report.attribute_count);
  try testing.expectEqual(0x0000, report.attributes[0].id);
  try testing.expectEqual(2243, report.attributes[0].value.v.i);
  var reading: Event.CReading = undefined;
  try testing.expectEqual(0, skep_event_get_reading(report, 0, &reading));
  try testing.expectEqualStrings("temperature", std.mem.span(reading.name));
  try testing.expectEqualStrings("°C", std.mem.span(reading.unit));
  try testing.expectEqual(22.43, reading.value);
  try testing.expectEqual(err(.INVAL), skep_event_get_reading(report, 1, &reading));

  // What it can be read for: its clusters' readings.
  var sources: [8]ReadingSource = undefined;
  var count: usize = 0;
  try testing.expectEqual(
    0,
    skep_device_get_readings(ctx, sensor_ieee, &sources, sources.len, &count),
  );
  try testing.expectEqual(4, count);
  try testing.expectEqualStrings("temperature", std.mem.span(sources[0].name));
  try testing.expectEqualStrings("battery_voltage", std.mem.span(sources[3].name));
}

test "a device that falls silent is set up further when it is next heard from" {
  var devices = [_]sim.Device{.{
    .ieee = sensor_ieee,
    .nwk = 0x1bce,
    .rx_on_when_idle = false,
    .silent = true,
  }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  // Asleep: its interview waits, and nothing more is sent to it.
  try testing.expectEqual(null, try nextOfType(ctx, .device_ready));
  const sent = ctx.driver.?.sim.sent_len;
  try testing.expectEqual(null, try nextOfType(ctx, .device_ready));
  try testing.expectEqual(sent, ctx.driver.?.sim.sent_len);
  try testing.expectEqual(State.Stage.node, ctx.state.?.device(sensor_ieee).?.progress.stage);
  // It wakes up, and reports: the interview goes on.
  devices[0].silent = false;
  ctx.driver.?.sim.report(&devices[0], 0x0402, &.{ 0x00, 0x00, 0x29, 0xc3, 0x08 });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);
}

test "a device that refuses a step of its setup has failed" {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce, .bind_status = 0x8c }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  const failed = (try nextOfType(ctx, .device_setup_failed)) orelse
    return error.TestExpectedFailure;
  defer skep_event_free(failed);
  try testing.expectEqual(0, skep_event_get_error(failed));
  try testing.expectEqual(0x8c, skep_event_get_status(failed));
  try testing.expectEqual(State.Stage.failed, ctx.state.?.device(sensor_ieee).?.progress.stage);
  // And goes no further.
  try testing.expectEqual(null, try nextOfType(ctx, .device_ready));
}

test "devices are described, and requests reach them" {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);

  var count: usize = 0;
  try testing.expectEqual(0, skep_get_devices(ctx, null, 0, &count));
  try testing.expectEqual(1, count);
  var ieee: [1]u64 = undefined;
  try testing.expectEqual(0, skep_get_devices(ctx, &ieee, 1, &count));
  try testing.expectEqual(sensor_ieee, ieee[0]);
  var node_type: c_int = 0;
  var code: u16 = 0;
  var rx_on: c_int = 0;
  try testing.expectEqual(0, skep_device_get_node(ctx, sensor_ieee, &node_type, &code, &rx_on));
  try testing.expectEqual(1, node_type);
  try testing.expectEqual(0x1407, code);
  try testing.expectEqual(1, rx_on);
  try testing.expectEqual(err(.NODEV), skep_device_get_node(ctx, 1, &node_type, &code, &rx_on));
  var address: u16 = 0;
  try testing.expectEqual(0, skep_device_get_short_address(ctx, sensor_ieee, &address));
  try testing.expectEqual(0x1bce, address);
  // Cut short, and NUL-terminated.
  var model: [8]u8 = undefined;
  try testing.expectEqual(10, skep_device_get_model(ctx, sensor_ieee, &model, model.len));
  try testing.expectEqualStrings("3RTHS02", std.mem.sliceTo(&model, 0));
  var endpoints: [4]u8 = undefined;
  try testing.expectEqual(
    0,
    skep_device_get_endpoints(ctx, sensor_ieee, &endpoints, endpoints.len, &count),
  );
  try testing.expectEqualSlices(u8, &.{ 1 }, endpoints[0..count]);
  var clusters: [8]u16 = undefined;
  try testing.expectEqual(
    0,
    skep_device_get_clusters(ctx, sensor_ieee, 1, 0, &clusters, clusters.len, &count),
  );
  try testing.expectEqual(5, count);
  try testing.expectEqual(
    0,
    skep_device_get_clusters(ctx, sensor_ieee, 1, 1, &clusters, clusters.len, &count),
  );
  try testing.expectEqualSlices(u16, &.{ 0x0019 }, clusters[0..count]);
  try testing.expectEqual(
    err(.NOENT),
    skep_device_get_clusters(ctx, sensor_ieee, 2, 0, &clusters, 0, &count),
  );
  var profile: u16 = 0;
  var device_type: u16 = 0;
  try testing.expectEqual(0, skep_device_get_endpoint(ctx, sensor_ieee, 1, &profile, &device_type));
  try testing.expectEqual(0x0104, profile);
  try testing.expectEqual(0x0302, device_type);
  try testing.expectEqual(
    err(.NOENT),
    skep_device_get_endpoint(ctx, sensor_ieee, 2, &profile, &device_type),
  );
  var setup_state: c_int = -1;
  try testing.expectEqual(0, skep_device_get_setup(ctx, sensor_ieee, &setup_state));
  try testing.expectEqual(1, setup_state);
  try testing.expectEqual(err(.NODEV), skep_device_get_setup(ctx, 1, &setup_state));

  // Its model, its manufacturer, and an attribute it does not have.
  var target = std.mem.zeroes(requests.Target);
  target.device = sensor_ieee;
  target.endpoint = 1;
  target.cluster = 0x0000;
  var request: u32 = 0;
  const ids = [_]u16{ 0x0005, 0x0004, 0x0007 };
  try testing.expectEqual(
    0,
    skep_read_attributes(ctx, &target, &ids, ids.len, std.math.maxInt(u64), &request),
  );
  const read = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(read);
  try testing.expectEqual(request, skep_event_get_request(read));
  try testing.expectEqual(3, skep_event_get_attribute_count(read));
  var attribute: Event.Attribute = undefined;
  try testing.expectEqual(0, skep_event_get_attribute(read, 0, &attribute));
  try testing.expectEqualStrings("3RTHS0224Z", attribute.value.bytesOf());
  try testing.expectEqual(0, skep_event_get_attribute(read, 2, &attribute));
  try testing.expectEqual(0x86, attribute.status);
  try testing.expectEqual(err(.INVAL), skep_event_get_attribute(read, 3, &attribute));

  // Writes, reporting and bindings answer with a status for each attribute, or one for all.
  target.cluster = 0x0402;
  const writes = [_]Event.Attribute{.{ .id = 0x0010, .status = 0, .value = .unsigned(0x20, 5) }};
  try testing.expectEqual(
    0,
    skep_write_attributes(ctx, &target, &writes, writes.len, std.math.maxInt(u64), &request),
  );
  const written = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(written);
  try testing.expectEqual(1, skep_event_get_attribute_count(written));
  try testing.expectEqual(0, written.attributes[0].status);
  const reporting = [_]requests.Reporting{.{
    .attribute = 0x0000,
    .type = 0x29,
    .min_interval = 30,
    .max_interval = 600,
    .change = .signed(0x29, 50),
    .reserved = @splat(0),
  }};
  try testing.expectEqual(
    0,
    skep_configure_reporting(
      ctx,
      &target,
      &reporting,
      reporting.len,
      std.math.maxInt(u64),
      &request,
    ),
  );
  skep_event_free((try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone);
  try testing.expectEqual(4, devices[0].configurations);
  try testing.expectEqual(0, skep_bind(ctx, &target, std.math.maxInt(u64), &request));
  const bound = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(bound);
  try testing.expectEqual(0, skep_event_get_status(bound));
  try testing.expectEqual(4, devices[0].binds);
  // A command: Identify for 5 s.
  target.cluster = 0x0003;
  const arguments = [_]zcl.Value{ .unsigned(0x21, 5) };
  try testing.expectEqual(
    0,
    skep_send_command(
      ctx,
      &target,
      0x00,
      &arguments,
      arguments.len,
      std.math.maxInt(u64),
      &request,
    ),
  );
  const identified = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(identified);
  try testing.expectEqual(0, skep_event_get_status(identified));
  const sent = ctx.driver.?.sim.sent[ctx.driver.?.sim.sent_len - 1];
  try testing.expectEqualSlices(u8, &.{ 0x01, sent.payload[1], 0x00, 0x05, 0x00 }, sent.bytes());

  // Bad requests are refused at once.
  target.reserved[0] = 1;
  try testing.expectEqual(err(.INVAL), skep_bind(ctx, &target, std.math.maxInt(u64), &request));
  target.reserved[0] = 0;
  target.device = 1;
  try testing.expectEqual(err(.NODEV), skep_bind(ctx, &target, std.math.maxInt(u64), &request));
  target.device = sensor_ieee;
  const too_big = [_]zcl.Value{ .unsigned(0x20, 256) };
  try testing.expectEqual(
    err(.INVAL),
    skep_send_command(ctx, &target, 0x00, &too_big, 1, std.math.maxInt(u64), &request),
  );

  // Asleep: requests wait, until they are canceled or their deadline passes.
  devices[0].silent = true;
  ctx.state.?.device(sensor_ieee).?.node.?.rx_on_when_idle = false;
  try testing.expectEqual(0, skep_bind(ctx, &target, std.math.maxInt(u64), &request));
  var later: u32 = 0;
  try testing.expectEqual(0, skep_bind(ctx, &target, 5000, &later));
  try testing.expectEqual(null, try nextOfType(ctx, .request_done));
  try testing.expectEqual(0, skep_cancel(ctx, request));
  try testing.expectEqual(err(.NOENT), skep_cancel(ctx, request));
  const canceled = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(canceled);
  try testing.expectEqual(err(.CANCELED), skep_event_get_error(canceled));
  try testing.expectEqual(0, skep_advance(ctx, 5000));
  const late = skep_next_event(ctx) orelse return error.TestExpectedDone;
  defer skep_event_free(late);
  try testing.expectEqual(later, skep_event_get_request(late));
  try testing.expectEqual(err(.TIMEDOUT), skep_event_get_error(late));
  // A newer write of the same attributes replaces a waiting one.
  var first: u32 = 0;
  try testing.expectEqual(
    0,
    skep_write_attributes(ctx, &target, &writes, writes.len, std.math.maxInt(u64), &first),
  );
  try testing.expectEqual(
    0,
    skep_write_attributes(ctx, &target, &writes, writes.len, std.math.maxInt(u64), &request),
  );
  const replaced = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(replaced);
  try testing.expectEqual(first, skep_event_get_request(replaced));
  try testing.expectEqual(err(.CANCELED), skep_event_get_error(replaced));
  try testing.expectEqual(0, skep_cancel(ctx, request));
  skep_event_free((try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone);

  // Set up again from the start once awake.
  devices[0].silent = false;
  try testing.expectEqual(0, skep_setup_device(ctx, sensor_ieee));
  ctx.driver.?.sim.report(&devices[0], 0x0402, &.{ 0x00, 0x00, 0x29, 0xc3, 0x08 });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);

  // Removed: asked to leave, then forgotten.
  try testing.expectEqual(0, skep_remove_device(ctx, sensor_ieee, std.math.maxInt(u64), &request));
  const left = (try nextOfType(ctx, .device_left)) orelse return error.TestExpectedLeft;
  defer skep_event_free(left);
  try testing.expectEqual(sensor_ieee, skep_event_get_device(left));
  try testing.expectEqual(1, skep_event_get_removed(left));
  try testing.expectEqual(0, skep_get_devices(ctx, null, 0, &count));
  try testing.expectEqual(0, count);
}

test "a device asked to leave is forgotten even if it does not answer" {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);
  // Gone: it picks nothing up.
  devices[0].silent = true;
  var request: u32 = 0;
  try testing.expectEqual(0, skep_remove_device(ctx, sensor_ieee, std.math.maxInt(u64), &request));
  const done = (try nextOfType(ctx, .request_done)) orelse return error.TestExpectedDone;
  defer skep_event_free(done);
  try testing.expectEqual(err(.HOSTUNREACH), skep_event_get_error(done));
  skep_event_free((try nextOfType(ctx, .device_left)) orelse return error.TestExpectedLeft);
  var count: usize = 1;
  try testing.expectEqual(0, skep_get_devices(ctx, null, 0, &count));
  try testing.expectEqual(0, count);
}

test "libskep answers devices on the coordinator's behalf" {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce }};
  const ctx = try simContext(&testing.allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  skep_event_free((try nextOfType(ctx, .device_ready)) orelse return error.TestExpectedReady);
  // The state, which the setup changed, after the step that made the device ready.
  skep_event_free((try nextOfType(ctx, .state_changed)) orelse return error.TestExpectedState);
  const sim_driver = &ctx.driver.?.sim;

  // A firmware update query, as the plug asks: no image, and the query reported.
  var query: driver_layer.Frame = .{
    .address = 0x1bce,
    .profile = 0x0104,
    .cluster = 0x0019,
    .source_endpoint = 1,
    .destination_endpoint = 1,
  };
  query.setPayload(&.{ 0x01, 0xb8, 0x01, 0x00, 0x33, 0x12, 0xa6, 0xd3, 0x58, 0x30, 0x01, 0x10 });
  sim_driver.receive(query);
  const asked = (try nextOfType(ctx, .command)) orelse return error.TestExpectedCommand;
  try testing.expectEqual(0x0019, skep_event_get_cluster(asked));
  try testing.expectEqual(0x01, skep_event_get_command(asked));
  skep_event_free(asked);
  try testing.expectEqual(0, skep_advance(ctx, 0));
  var answer = sim_driver.sent[sim_driver.sent_len - 1];
  try testing.expectEqual(0x0019, answer.cluster);
  try testing.expectEqualSlices(u8, &.{ 0x19, 0xb8, 0x02, 0x98 }, answer.bytes());

  // A report that asks for a Default Response, as the plug's do: answered, and reported.
  var report: driver_layer.Frame = .{
    .address = 0x1bce,
    .profile = 0x0104,
    .cluster = 0x0006,
    .source_endpoint = 1,
    .destination_endpoint = 1,
  };
  report.setPayload(&.{ 0x08, 0xd9, 0x0a, 0x00, 0x00, 0x10, 0x01 });
  sim_driver.receive(report);
  const attributes = (try nextOfType(ctx, .attributes)) orelse return error.TestExpectedReport;
  defer skep_event_free(attributes);
  try testing.expectEqual(1, attributes.attributes[0].value.v.u);
  try testing.expectEqual(0, skep_advance(ctx, 0));
  answer = sim_driver.sent[sim_driver.sent_len - 1];
  try testing.expectEqualSlices(u8, &.{ 0x10, 0xd9, 0x0b, 0x0a, 0x00 }, answer.bytes());

  // The same, broadcast: reported, but not answered.
  const sent = sim_driver.sent_len;
  report.broadcast = true;
  sim_driver.receive(report);
  skep_event_free((try nextOfType(ctx, .attributes)) orelse return error.TestExpectedReport);
  try testing.expectEqual(0, skep_advance(ctx, 0));
  try testing.expectEqual(sent, sim_driver.sent_len);
}

/// A device joins and is interviewed, every allocation failing in turn.
fn interviewOnce(allocator: std.mem.Allocator) !void {
  var devices = [_]sim.Device{.{ .ieee = sensor_ieee, .nwk = 0x1bce }};
  const ctx = try simContext(&allocator, &devices);
  defer skep_free(ctx);
  try openWindow(ctx);
  ctx.driver.?.sim.device(.{ .ieee = sensor_ieee, .nwk = 0x1bce, .kind = .joined });
  for (0..60) |_| {
    _ = skep_advance(ctx, 0);
    while (skep_next_event(ctx)) |event| {
      skep_event_free(event);
    }
  }
}

test "running out of memory during an interview leaks nothing" {
  var i: usize = 0;
  while (true) : (i += 1) {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = i });
    interviewOnce(failing.allocator()) catch {};
    if (!failing.has_induced_failure) break;
  }
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
  try openWindow(ctx);
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
  _ = @import("devices.zig");
  _ = @import("exchange.zig");
  _ = @import("requests.zig");
  _ = @import("setup.zig");
  _ = @import("abi_test.zig");
  _ = @import("readings.zig");
  _ = @import("driver/driver.zig");
  _ = @import("driver/ezsp/ezsp.zig");
  std.testing.refAllDecls(@This());
}
