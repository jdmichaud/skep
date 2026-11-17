//! skep-protocol(7)'s methods, one function each, named as the method: the request's parameters
//! checked, libskep asked, and the response sent, or the request left pending until libskep ends
//! it. protocol.zig dispatches to them by the method's name, so that a method without its
//! function does not build.

const std = @import("std");
const build_options = @import("build_options");
const c = @import("skep_h");
const Protocol = @import("protocol.zig");
const Names = @import("Names.zig");
const describe = @import("describe.zig");
const events = @import("events.zig");
const Server = @import("Server.zig");
const libskep = @import("libskep.zig");
const values = @import("values.zig");

const Error = Protocol.Error;
const Message = Protocol.Message;
const Method = Protocol.Method;
const Params = Protocol.Params;
const Stringify = std.json.Stringify;
const target_members = Protocol.target_members;

pub fn version(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{});
  const v = c.skep_version();
  var out: Message = undefined;
  out.init(p.gpa);
  defer out.deinit();
  try p.result(&out, id);
  try out.j.objectField("protocol");
  try out.j.write(Protocol.version);
  try out.j.objectField("skepd");
  try out.j.write(build_options.version);
  try out.j.objectField("libskep");
  try out.j.print("\"{d}.{d}.{d}\"", .{ v >> 16, v >> 8 & 0xff, v & 0xff });
  p.send(client, &out);
}

pub fn watch(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{});
  try p.watch(client);
  p.empty(client, id);
}

pub fn network(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{});
  try describe.network(p, client, id);
}

pub fn permit_join(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "seconds" });
  const seconds = values.unsignedOf(
    u8,
    ps.get("seconds") orelse return p.fail("EINVAL", "no seconds", .{}),
  ) orelse
    return p.fail("EINVAL", "seconds: 0 to {d}", .{ c.SKEP_MAX_PERMIT_JOIN });
  if (seconds > c.SKEP_MAX_PERMIT_JOIN) {
    return p.fail("EINVAL", "seconds: 0 to {d}", .{ c.SKEP_MAX_PERMIT_JOIN });
  }
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_permit_join(p.ctx, seconds, &req);
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .permit_join });
}

pub fn rotate_network_key(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "per_device" });
  const per_device = switch (ps.get("per_device") orelse std.json.Value{ .bool = false }) {
    .bool => |b| b,
    else => return p.fail("EINVAL", "per_device: true or false", .{}),
  };
  try p.room(client);
  var req: u32 = 0;
  const how: c_uint = if (per_device) c.SKEP_KEY_PER_DEVICE else c.SKEP_KEY_BROADCAST;
  const r = c.skep_rotate_network_key(p.ctx, how, &req);
  if (libskep.is(r, .NODEV)) return p.fail("ENODEV", "no device to send a new key to", .{});
  if (libskep.is(r, .NOBUFS)) return p.fail("ENOBUFS", "the key is already being changed", .{});
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .rotate_network_key });
}

pub fn devices(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{});
  var count: usize = 0;
  _ = c.skep_get_devices(p.ctx, null, 0, &count);
  const addresses = try a.alloc(u64, count);
  _ = c.skep_get_devices(p.ctx, addresses.ptr, addresses.len, &count);
  var out: Message = undefined;
  out.init(p.gpa);
  defer out.deinit();
  try p.result(&out, id);
  try out.j.objectField("devices");
  try out.j.beginArray();
  for (addresses[0..@min(count, addresses.len)]) |ieee| {
    try out.j.beginObject();
    try describe.deviceMembers(p, &out.j, a, ieee);
    try out.j.endObject();
  }
  try out.j.endArray();
  p.send(client, &out);
}

pub fn device(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device" });
  const ieee = try p.deviceOf(ps.get("device"));
  var setup_state: c.enum_skep_setup = undefined;
  if (c.skep_device_get_setup(p.ctx, ieee, &setup_state) != 0) {
    return p.fail("ENODEV", "no such device", .{});
  }
  var out: Message = undefined;
  out.init(p.gpa);
  defer out.deinit();
  try p.result(&out, id);
  try describe.deviceMembers(p, &out.j, a, ieee);
  p.send(client, &out);
}

pub fn rename(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device", "name" });
  const ieee = try p.deviceOf(ps.get("device"));
  var setup_state: c.enum_skep_setup = undefined;
  if (c.skep_device_get_setup(p.ctx, ieee, &setup_state) != 0) {
    return p.fail("ENODEV", "no such device", .{});
  }
  const new_name: ?[]const u8 = if (ps.get("name")) |n| switch (n) {
    .string => |s| s,
    else => return p.fail("EINVAL", "name: a string or null", .{}),
  } else null;
  if (new_name) |n| {
    if (!Names.valid(n)) {
      return p.fail(
        "EINVAL",
        "name: 1 to 64 bytes of UTF-8, no control characters, not an address",
        .{},
      );
    }
    if (p.names.find(n)) |other| {
      if (other != ieee) return p.fail("EEXIST", "name taken", .{});
    }
  }
  const old = try p.names.set(ieee, new_name);
  defer if (old) |o| p.gpa.free(o);
  if (p.names.save(p.names_path)) |failure| {
    return p.fail("EIO", "{s}: {s}: {t}", .{ p.names_path, failure.step, failure.errno });
  }
  p.empty(client, id);
  events.renamed(p, ieee, old);
}

pub fn setup(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device" });
  const ieee = try p.deviceOf(ps.get("device"));
  const r = c.skep_setup_device(p.ctx, ieee);
  if (r != 0) return p.failErrno(r);
  p.empty(client, id);
}

pub fn remove(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device", "timeout" });
  const ieee = try p.deviceOf(ps.get("device"));
  const deadline = try p.deadlineOf(ps.get("timeout"));
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_remove_device(p.ctx, ieee, deadline, &req);
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{
    .client = client.id,
    .id = id,
    .method = .remove,
    .device = ieee,
  });
}

pub fn read(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &(target_members ++ [_][]const u8{ "attributes" }));
  const target = try p.targetOf(ps);
  const list = try p.arrayOf(ps.get("attributes"), "attributes");
  const ids = try a.alloc(u16, list.len);
  for (list, ids) |item, *attribute| {
    attribute.* = values.unsignedOf(u16, item) orelse
      return p.fail("EINVAL", "attributes: ids", .{});
  }
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_read_attributes(
    p.ctx,
    &target.target,
    ids.ptr,
    ids.len,
    target.deadline,
    &req,
  );
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{
    .client = client.id,
    .id = id,
    .method = .read,
    .device = target.target.device,
    .endpoint = target.target.endpoint,
    .cluster = target.target.cluster,
  });
}

pub fn write(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &(target_members ++ [_][]const u8{ "attributes" }));
  const target = try p.targetOf(ps);
  const list = try p.arrayOf(ps.get("attributes"), "attributes");
  const attributes = try a.alloc(c.struct_skep_attribute, list.len);
  for (list, attributes) |item, *attribute| {
    const o = try p.objectOf(item, &.{ "id", "type", "value" }, "attributes");
    attribute.* = std.mem.zeroes(c.struct_skep_attribute);
    attribute.id = values.unsignedOf(u16, o.get("id") orelse .null) orelse
      return p.fail("EINVAL", "attributes: id", .{});
    attribute.value = try p.valueOf(a, o.get("type"), o.get("value"), "attributes");
  }
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_write_attributes(
    p.ctx,
    &target.target,
    attributes.ptr,
    attributes.len,
    target.deadline,
    &req,
  );
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .write });
}

pub fn configure_reporting(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &(target_members ++ [_][]const u8{ "reporting" }));
  const target = try p.targetOf(ps);
  const list = try p.arrayOf(ps.get("reporting"), "reporting");
  const reporting = try a.alloc(c.struct_skep_reporting, list.len);
  for (list, reporting) |item, *r| {
    const o = try p.objectOf(
      item,
      &.{ "id", "type", "min_interval", "max_interval", "change" },
      "reporting",
    );
    r.* = std.mem.zeroes(c.struct_skep_reporting);
    r.attribute = values.unsignedOf(u16, o.get("id") orelse .null) orelse
      return p.fail("EINVAL", "reporting: id", .{});
    const t = values.typeOf(o.get("type") orelse .null) orelse
      return p.fail("EINVAL", "reporting: type", .{});
    r.type = t.id;
    r.min_interval = values.unsignedOf(u16, o.get("min_interval") orelse .null) orelse
      return p.fail("EINVAL", "reporting: min_interval", .{});
    r.max_interval = values.unsignedOf(u16, o.get("max_interval") orelse .null) orelse
      return p.fail("EINVAL", "reporting: max_interval", .{});
    r.change = .{ .type = t.id, .v = .{ .u = 0 } };
    if (o.get("change")) |change| {
      r.change = values.valueOf(a, t, change) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail("EINVAL", "reporting: change", .{}),
      };
    }
  }
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_configure_reporting(
    p.ctx,
    &target.target,
    reporting.ptr,
    reporting.len,
    target.deadline,
    &req,
  );
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .configure_reporting });
}

fn bind_unbind(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
  method: Method,
) Error!void {
  try p.params(ps, &target_members);
  const target = try p.targetOf(ps);
  try p.room(client);
  var req: u32 = 0;
  const r = if (method == .bind)
    c.skep_bind(p.ctx, &target.target, target.deadline, &req)
  else
    c.skep_unbind(p.ctx, &target.target, target.deadline, &req);
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = method });
}

pub fn bind(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  return bind_unbind(p, a, client, id, ps, .bind);
}

pub fn unbind(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  return bind_unbind(p, a, client, id, ps, .unbind);
}

pub fn command(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &(target_members ++ [_][]const u8{ "command", "arguments" }));
  const target = try p.targetOf(ps);
  const command_id = values.unsignedOf(u8, ps.get("command") orelse .null) orelse
    return p.fail("EINVAL", "command: an id", .{});
  const list: []const std.json.Value = if (ps.get("arguments")) |list|
    try p.arrayOf(list, "arguments")
  else
    &.{};
  const arguments = try a.alloc(c.struct_skep_value, list.len);
  for (list, arguments) |item, *argument| {
    const o = try p.objectOf(item, &.{ "type", "value" }, "arguments");
    argument.* = try p.valueOf(a, o.get("type"), o.get("value"), "arguments");
  }
  try p.room(client);
  var req: u32 = 0;
  const r = c.skep_send_command(
    p.ctx,
    &target.target,
    command_id,
    arguments.ptr,
    arguments.len,
    target.deadline,
    &req,
  );
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .command });
}

pub fn set(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "device", "endpoint", "reading", "value", "transition", "timeout" });
  var setting = std.mem.zeroes(c.struct_skep_setting);
  setting.device = try p.deviceOf(ps.get("device"));
  const reading = switch (ps.get("reading") orelse .null) {
    .string => |s| s,
    else => return p.fail("EINVAL", "reading: a name", .{}),
  };
  // A colour is set on Color Control, whose endpoints have a color_x.
  const color = std.mem.eql(u8, reading, "color");
  setting.endpoint = if (ps.get("endpoint")) |e|
    values.unsignedOf(u8, e) orelse return p.fail("EINVAL", "endpoint: 0 to 255", .{})
  else
    try endpointWith(p, a, setting.device, if (color) "color_x" else reading, reading);
  if (ps.get("transition")) |t| {
    setting.transition = switch (t) {
      .integer => |i| @floatFromInt(i),
      .float => |f| f,
      else => return p.fail("EINVAL", "transition: seconds", .{}),
    };
    if (!(setting.transition >= 0 and setting.transition <= c.SKEP_MAX_TRANSITION)) {
      return p.fail("EINVAL", "transition: from 0 to {d} seconds", .{ c.SKEP_MAX_TRANSITION });
    }
  }
  const deadline = try p.deadlineOf(ps.get("timeout"));
  const given = ps.get("value") orelse return p.fail("EINVAL", "no value", .{});
  try p.room(client);
  var req: u32 = 0;
  const r = if (color) set: {
    const rgb = colorOf(given) orelse
      return p.fail("EINVAL", "value: a colour, as #rrggbb", .{});
    break :set c.skep_set_color(p.ctx, &setting, rgb, deadline, &req);
  } else set: {
    const number: f64 = switch (given) {
      .integer => |i| @floatFromInt(i),
      .float => |f| f,
      .bool => |b| if (b) 1 else 0,
      else => return p.fail("EINVAL", "value: a number", .{}),
    };
    break :set c.skep_set_reading(
      p.ctx,
      &setting,
      try a.dupeSentinel(u8, reading, 0),
      number,
      deadline,
      &req,
    );
  };
  if (libskep.is(r, .NOENT)) {
    return p.fail("ENOENT", "no {s} on endpoint {d}", .{ reading, setting.endpoint });
  }
  if (libskep.is(r, .OPNOTSUPP)) {
    const json = try settable(p, a, setting.device);
    return p.failWith("ENOTSUP", "settable", json, "{s} cannot be set", .{ reading });
  }
  if (libskep.is(r, .RANGE)) {
    const json = try rangeOf(p, a, setting.device, setting.endpoint, reading);
    return p.failWith("ERANGE", "range", json, "{s} out of range", .{ reading });
  }
  if (color and libskep.is(r, .INVAL)) {
    return p.fail("EINVAL", "black is no colour", .{});
  }
  if (r != 0) return p.failErrno(r);
  try p.wait(req, .{ .client = client.id, .id = id, .method = .set });
}

pub fn cancel(
  p: *Protocol,
  _: std.mem.Allocator,
  client: *Server.Client,
  id: i64,
  ps: Params,
) Error!void {
  try p.params(ps, &.{ "id" });
  const canceled = switch (ps.get("id") orelse return p.fail("EINVAL", "no id", .{})) {
    .integer => |i| i,
    else => return p.fail("EINVAL", "id: not an integer", .{}),
  };
  var it = p.pending.iterator();
  while (it.next()) |entry| {
    if (entry.value_ptr.client != client.id or entry.value_ptr.id != canceled) continue;
    // Its response, ECANCELED, comes with libskep's REQUEST_DONE.
    const r = c.skep_cancel(p.ctx, entry.key_ptr.*);
    if (r != 0) return p.failErrno(r);
    return p.empty(client, id);
  }
  return p.fail("ENOENT", "no request {d} pending", .{ canceled });
}

// What set needs.

/// The first endpoint of a device with a reading, `name`, for a setting of `what`.
pub fn endpointWith(
  p: *Protocol,
  a: std.mem.Allocator,
  ieee: u64,
  name: []const u8,
  what: []const u8,
) Error!u8 {
  const sources = libskep.readings(p.ctx, a, ieee) catch |e| return switch (e) {
    error.OutOfMemory => error.OutOfMemory,
    error.NotInterviewed => p.fail("EAGAIN", "not interviewed yet", .{}),
    error.NoDevice => p.fail("ENODEV", "no such device", .{}),
  };
  for (sources) |source| {
    if (std.mem.eql(u8, std.mem.span(source.name), name)) return source.endpoint;
  }
  return p.failWith("ENOENT", "settable", try settable(p, a, ieee), "no reading {s}", .{ what });
}

/// The values a settable reading takes, as the "range" of an error: {"reading", "min", "max",
/// "unit"}.
pub fn rangeOf(
  p: *Protocol,
  a: std.mem.Allocator,
  ieee: u64,
  endpoint: u8,
  name: []const u8,
) Error![]const u8 {
  var w: std.Io.Writer.Allocating = .init(a);
  var j: Stringify = .{ .writer = &w.writer };
  try j.beginObject();
  try j.objectField("reading");
  try j.write(name);
  for (try sourcesOf(p, a, ieee)) |source| {
    if (source.endpoint != endpoint or !std.mem.eql(u8, std.mem.span(source.name), name)) continue;
    try j.objectField("min");
    try j.write(source.min);
    try j.objectField("max");
    try j.write(source.max);
    try j.objectField("unit");
    try j.write(std.mem.span(source.unit));
    break;
  }
  try j.endObject();
  return w.written();
}

/// What can be set on a device, as the "settable" of an error: the names of its settable
/// readings, and "color" for a light with Color Control.
pub fn settable(p: *Protocol, a: std.mem.Allocator, ieee: u64) Error![]const u8 {
  var names: std.ArrayList([]const u8) = .empty;
  var color = false;
  for (try sourcesOf(p, a, ieee)) |source| {
    const name = std.mem.span(source.name);
    if (std.mem.eql(u8, name, "color_x")) {
      color = true;
    }
    if (source.settable == 0) continue;
    for (names.items) |known| {
      if (std.mem.eql(u8, known, name)) break;
    } else {
      try names.append(a, name);
    }
  }
  if (color) {
    try names.append(a, "color");
  }
  var w: std.Io.Writer.Allocating = .init(a);
  var j: Stringify = .{ .writer = &w.writer };
  try j.write(names.items);
  return w.written();
}

/// A device's readings, none if it is not interviewed.
pub fn sourcesOf(
  p: *Protocol,
  a: std.mem.Allocator,
  ieee: u64,
) Error![]const c.struct_skep_reading_source {
  return libskep.readings(p.ctx, a, ieee) catch |e| switch (e) {
    error.OutOfMemory => error.OutOfMemory,
    error.NoDevice, error.NotInterviewed => &.{},
  };
}

/// An sRGB colour, "#rrggbb", as 0xrrggbb.
pub fn colorOf(value: std.json.Value) ?u32 {
  const text = switch (value) {
    .string => |s| s,
    else => return null,
  };
  if (text.len != 7 or text[0] != '#') return null;
  return std.fmt.parseInt(u32, text[1..], 16) catch null;
}
