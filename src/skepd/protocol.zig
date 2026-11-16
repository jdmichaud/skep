//! skep-protocol(7), skepd's side: requests read from clients' lines and made to libskep through
//! skep.h, their responses, and events for the clients that watch.

const std = @import("std");
const c = @import("skep_h");
const Names = @import("Names.zig");
const Readings = @import("Readings.zig");
const Server = @import("Server.zig");
const values = @import("values.zig");

const Io = std.Io;
const Stringify = std.json.Stringify;
const E = std.posix.E;

const Protocol = @This();

/// The protocol's version: raised only by changes that break clients.
pub const version = 1;
/// Most requests of one client pending at once, so that one client cannot take all of libskep's.
pub const max_pending_per_client = 16;
/// Most attributes in a request, as libskep takes.
const max_attributes = 16;

gpa: std.mem.Allocator,
io: Io,
ctx: *c.skep_ctx,
server: Server,
names: Names,
names_path: [:0]const u8,
/// The clients' requests that libskep is doing, by libskep's request id.
pending: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
/// The error that took the network down, while it is down because of one.
down_error: ?c_int = null,
/// When the join window closes, on the monotonic clock, while it is open.
window_until: ?u64 = null,
/// The monotonic time in milliseconds, as last given: libskep's clock.
now: u64 = 0,
/// The last readings of devices' attributes, which `device` and `devices` give.
readings: Readings,
/// The id of the request being handled, once known, for its error response.
request_id: ?i64 = null,
failure: Failure = .{},

pub const Method = enum {
  version,
  watch,
  network,
  permit_join,
  devices,
  device,
  rename,
  setup,
  remove,
  read,
  write,
  configure_reporting,
  bind,
  unbind,
  command,
  cancel,
};

const Pending = struct {
  client: u32,
  id: i64,
  method: Method,
  device: u64 = 0,
  /// For reads: what was read, whose readings skepd remembers.
  endpoint: u8 = 0,
  cluster: u16 = 0,
};

/// Why the request being handled fails.
const Failure = struct {
  code: [24]u8 = undefined,
  code_len: usize = 0,
  message: [200]u8 = undefined,
  message_len: usize = 0,
};

/// WriteFailed is what writing JSON into memory fails with: out of memory too.
const Error = error{ Fail, OutOfMemory, WriteFailed };

pub fn deinit(p: *Protocol) void {
  p.readings.deinit();
  p.pending.deinit(p.gpa);
  p.names.deinit();
  p.server.deinit();
}

/// Fails the request being handled with an errno name and a message.
fn fail(p: *Protocol, code: []const u8, comptime format: []const u8, args: anytype) Error {
  const n = @min(code.len, p.failure.code.len);
  @memcpy(p.failure.code[0..n], code[0..n]);
  p.failure.code_len = n;
  const message = std.fmt.bufPrint(&p.failure.message, format, args) catch &p.failure.message;
  p.failure.message_len = message.len;
  return error.Fail;
}

/// Fails with the error a function of skep.h returned.
fn failErrno(p: *Protocol, r: c_int, comptime what: []const u8) Error {
  var buffer: [24]u8 = undefined;
  return p.fail(errnoCode(&buffer, r), what ++ ": {t}", .{ errnoOf(r) });
}

fn errnoOf(r: c_int) E {
  return @fromBackingInt(@intCast(@as(u16, @intCast(-r))));
}

/// The errno name of a negative errno value: "E" and its name, ENOTSUP for EOPNOTSUPP.
fn errnoCode(buffer: *[24]u8, r: c_int) []const u8 {
  const e = errnoOf(r);
  if (e == .OPNOTSUPP) return "ENOTSUP";
  return std.fmt.bufPrint(buffer, "E{t}", .{ e }) catch "EIO";
}

// Reading clients.

/// Handles the lines clients sent.
pub fn serve(p: *Protocol) void {
  for (p.server.clients.items) |client| {
    while (!client.closing and !client.close_when_written) {
      const line = client.nextLine() orelse break;
      if (std.mem.trim(u8, line, " \t\r").len > 0) {
        p.handle(client, line);
      }
      client.consumeLine();
    }
    if (client.overflowed and !client.close_when_written) {
      p.request_id = null;
      p.sendError(client, "EMSGSIZE", "a line longer than 65536 bytes");
      client.close_when_written = true;
    }
  }
}

fn handle(p: *Protocol, client: *Server.Client, line: []const u8) void {
  var arena: std.heap.ArenaAllocator = .init(p.gpa);
  defer arena.deinit();
  p.request_id = null;
  p.request(arena.allocator(), client, line) catch |e| switch (e) {
    error.Fail => p.sendError(
      client,
      p.failure.code[0..p.failure.code_len],
      p.failure.message[0..p.failure.message_len],
    ),
    error.OutOfMemory, error.WriteFailed => p.sendError(client, "ENOMEM", "out of memory"),
  };
}

/// The parameters of a request: what is not taken is refused.
const Params = struct {
  object: ?std.json.ObjectMap,

  fn get(ps: Params, name: []const u8) ?std.json.Value {
    const o = ps.object orelse return null;
    const v = o.get(name) orelse return null;
    return if (v == .null) null else v;
  }
};

fn request(
  p: *Protocol,
  a: std.mem.Allocator,
  client: *Server.Client,
  line: []const u8,
) Error!void {
  const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch |e| {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return p.fail("EINVAL", "not JSON", .{});
  };
  const object = switch (value) {
    .object => |o| o,
    else => return p.fail("EINVAL", "not a JSON object", .{}),
  };
  const id = switch (object.get("id") orelse return p.fail("EINVAL", "no id", .{})) {
    .integer => |i| i,
    else => return p.fail("EINVAL", "id: not an integer", .{}),
  };
  p.request_id = id;
  try p.only(object, &.{ "id", "method", "params" }, "");
  const name = switch (object.get("method") orelse return p.fail("EINVAL", "no method", .{})) {
    .string => |s| s,
    else => return p.fail("EINVAL", "method: not a string", .{}),
  };
  const method = std.meta.stringToEnum(Method, name) orelse
    return p.fail("ENOSYS", "unknown method: {s}", .{ name });
  const ps: Params = .{
    .object = switch (object.get("params") orelse .null) {
      .null => null,
      .object => |o| o,
      else => return p.fail("EINVAL", "params: not an object", .{}),
    },
  };
  var pending_requests = p.pending.valueIterator();
  while (pending_requests.next()) |pending| {
    if (pending.client == client.id and pending.id == id) {
      return p.fail("EEXIST", "id {d} is pending", .{ id });
    }
  }
  switch (method) {
    .version => {
      try p.params(ps, &.{});
      const v = c.skep_version();
      var out: Message = undefined;
      out.init(p.gpa);
      defer out.deinit();
      try p.result(&out, id);
      try out.j.objectField("protocol");
      try out.j.write(version);
      try out.j.objectField("skepd");
      try out.j.print("\"{d}.{d}.{d}\"", .{ v >> 16, v >> 8 & 0xff, v & 0xff });
      p.send(client, &out);
    },
    .watch => {
      try p.params(ps, &.{});
      client.watching = true;
      p.empty(client, id);
    },
    .network => {
      try p.params(ps, &.{});
      try p.network(client, id);
    },
    .permit_join => {
      try p.params(ps, &.{ "seconds" });
      const seconds = values.unsignedOf(
        u8,
        ps.get("seconds") orelse return p.fail("EINVAL", "no seconds", .{}),
      ) orelse
        return p.fail("EINVAL", "seconds: 0 to 254", .{});
      if (seconds > 254) return p.fail("EINVAL", "seconds: 0 to 254", .{});
      try p.room(client);
      var req: u32 = 0;
      const r = c.skep_permit_join(p.ctx, seconds, &req);
      if (r != 0) return p.failErrno(r, "permit_join");
      try p.wait(client, req, .{ .client = client.id, .id = id, .method = .permit_join });
    },
    .devices => {
      try p.params(ps, &.{});
      var count: usize = 0;
      _ = c.skep_get_devices(p.ctx, null, 0, &count);
      const devices = try a.alloc(u64, count);
      _ = c.skep_get_devices(p.ctx, devices.ptr, devices.len, &count);
      var out: Message = undefined;
      out.init(p.gpa);
      defer out.deinit();
      try p.result(&out, id);
      try out.j.objectField("devices");
      try out.j.beginArray();
      for (devices[0..@min(count, devices.len)]) |device| {
        try out.j.beginObject();
        try p.describe(&out.j, a, device);
        try out.j.endObject();
      }
      try out.j.endArray();
      p.send(client, &out);
    },
    .device => {
      try p.params(ps, &.{ "device" });
      const device = try p.deviceOf(ps.get("device"));
      var setup: c.enum_skep_setup = undefined;
      if (c.skep_device_get_setup(p.ctx, device, &setup) != 0) {
        return p.fail("ENODEV", "no such device", .{});
      }
      var out: Message = undefined;
      out.init(p.gpa);
      defer out.deinit();
      try p.result(&out, id);
      try p.describe(&out.j, a, device);
      p.send(client, &out);
    },
    .rename => {
      try p.params(ps, &.{ "device", "name" });
      const device = try p.deviceOf(ps.get("device"));
      var setup: c.enum_skep_setup = undefined;
      if (c.skep_device_get_setup(p.ctx, device, &setup) != 0) {
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
          if (other != device) return p.fail("EEXIST", "name taken", .{});
        }
      }
      const old = try p.names.set(device, new_name);
      defer if (old) |o| p.gpa.free(o);
      if (p.names.save(p.names_path)) |failure| {
        return p.fail("EIO", "{s}: {s}: {t}", .{ p.names_path, failure.step, failure.errno });
      }
      p.empty(client, id);
      p.renamed(device, old);
    },
    .setup => {
      try p.params(ps, &.{ "device" });
      const device = try p.deviceOf(ps.get("device"));
      const r = c.skep_setup_device(p.ctx, device);
      if (r != 0) return p.failErrno(r, "setup");
      p.empty(client, id);
    },
    .remove => {
      try p.params(ps, &.{ "device", "timeout" });
      const device = try p.deviceOf(ps.get("device"));
      const deadline = try p.deadlineOf(ps.get("timeout"));
      try p.room(client);
      var req: u32 = 0;
      const r = c.skep_remove_device(p.ctx, device, deadline, &req);
      if (r != 0) return p.failErrno(r, "remove");
      try p.wait(client, req, .{
        .client = client.id,
        .id = id,
        .method = .remove,
        .device = device,
      });
    },
    .read => {
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
      if (r != 0) return p.failErrno(r, "read");
      try p.wait(client, req, .{
        .client = client.id,
        .id = id,
        .method = .read,
        .device = target.target.device,
        .endpoint = target.target.endpoint,
        .cluster = target.target.cluster,
      });
    },
    .write => {
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
      if (r != 0) return p.failErrno(r, "write");
      try p.wait(client, req, .{ .client = client.id, .id = id, .method = .write });
    },
    .configure_reporting => {
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
      if (r != 0) return p.failErrno(r, "configure_reporting");
      try p.wait(client, req, .{ .client = client.id, .id = id, .method = .configure_reporting });
    },
    .bind, .unbind => {
      try p.params(ps, &target_members);
      const target = try p.targetOf(ps);
      try p.room(client);
      var req: u32 = 0;
      const r = if (method == .bind)
        c.skep_bind(p.ctx, &target.target, target.deadline, &req)
      else
        c.skep_unbind(p.ctx, &target.target, target.deadline, &req);
      if (r != 0) return p.failErrno(r, "bind");
      try p.wait(client, req, .{ .client = client.id, .id = id, .method = method });
    },
    .command => {
      try p.params(ps, &(target_members ++ [_][]const u8{ "command", "arguments" }));
      const target = try p.targetOf(ps);
      const command = values.unsignedOf(u8, ps.get("command") orelse .null) orelse
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
        command,
        arguments.ptr,
        arguments.len,
        target.deadline,
        &req,
      );
      if (r != 0) return p.failErrno(r, "command");
      try p.wait(client, req, .{ .client = client.id, .id = id, .method = .command });
    },
    .cancel => {
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
        if (r != 0) return p.failErrno(r, "cancel");
        return p.empty(client, id);
      }
      return p.fail("ENOENT", "no request {d} pending", .{ canceled });
    },
  }
}

const target_members = [_][]const u8{
  "device",
  "endpoint",
  "cluster",
  "manufacturer_code",
  "timeout",
};

/// Refuses members other than `allowed`.
fn only(
  p: *Protocol,
  object: std.json.ObjectMap,
  allowed: []const []const u8,
  comptime where: []const u8,
) Error!void {
  outer: for (object.keys()) |key| {
    for (allowed) |name| {
      if (std.mem.eql(u8, key, name)) continue :outer;
    }
    return p.fail("ENOTSUP", "unknown member: " ++ where ++ "{s}", .{ key });
  }
}

fn params(p: *Protocol, ps: Params, allowed: []const []const u8) Error!void {
  if (ps.object) |o| {
    try p.only(o, allowed, "params.");
  }
}

fn arrayOf(
  p: *Protocol,
  value: ?std.json.Value,
  comptime name: []const u8,
) Error![]const std.json.Value {
  const list = switch (value orelse return p.fail("EINVAL", "no " ++ name, .{})) {
    .array => |list| list.items,
    else => return p.fail("EINVAL", name ++ ": not an array", .{}),
  };
  if (list.len == 0 or list.len > max_attributes) return p.fail("EINVAL", name ++ ": 1 to 16", .{});
  return list;
}

fn objectOf(
  p: *Protocol,
  value: std.json.Value,
  allowed: []const []const u8,
  comptime name: []const u8,
) Error!std.json.ObjectMap {
  const o = switch (value) {
    .object => |o| o,
    else => return p.fail("EINVAL", name ++ ": objects", .{}),
  };
  try p.only(o, allowed, name ++ ".");
  return o;
}

/// A value given as its type and its value.
fn valueOf(
  p: *Protocol,
  a: std.mem.Allocator,
  type_value: ?std.json.Value,
  value: ?std.json.Value,
  comptime name: []const u8,
) Error!c.struct_skep_value {
  const t = values.typeOf(type_value orelse .null) orelse
    return p.fail("EINVAL", name ++ ": type", .{});
  if (t.kind == .none) return .{ .type = t.id, .v = .{ .u = 0 } };
  return values.valueOf(
    a,
    t,
    value orelse return p.fail("EINVAL", name ++ ": no value", .{}),
  ) catch |e| switch (e) {
    error.OutOfMemory => error.OutOfMemory,
    else => p.fail("EINVAL", name ++ ": value of type {s}", .{ t.name }),
  };
}

/// A device given by its IEEE address or its name.
fn deviceOf(p: *Protocol, value: ?std.json.Value) Error!u64 {
  const text = switch (value orelse return p.fail("EINVAL", "no device", .{})) {
    .string => |s| s,
    else => return p.fail("EINVAL", "device: an address or a name", .{}),
  };
  if (values.parseIeee(text)) |ieee| return ieee;
  return p.names.find(text) orelse p.fail("ENODEV", "no device named {s}", .{ text });
}

const Target = struct {
  target: c.struct_skep_target,
  deadline: u64,
};

fn targetOf(p: *Protocol, ps: Params) Error!Target {
  var t = std.mem.zeroes(c.struct_skep_target);
  t.device = try p.deviceOf(ps.get("device"));
  t.endpoint = values.unsignedOf(u8, ps.get("endpoint") orelse .null) orelse
    return p.fail("EINVAL", "endpoint: 0 to 255", .{});
  t.cluster = values.unsignedOf(u16, ps.get("cluster") orelse .null) orelse
    return p.fail("EINVAL", "cluster: an id", .{});
  if (ps.get("manufacturer_code")) |code| {
    t.manufacturer_code = values.unsignedOf(u16, code) orelse
      return p.fail("EINVAL", "manufacturer_code: an id", .{});
  }
  return .{ .target = t, .deadline = try p.deadlineOf(ps.get("timeout")) };
}

/// The deadline of a timeout in seconds, on libskep's clock; none without one.
fn deadlineOf(p: *Protocol, value: ?std.json.Value) Error!u64 {
  const seconds: f64 = switch (value orelse return std.math.maxInt(u64)) {
    .integer => |i| @floatFromInt(i),
    .float => |f| f,
    else => return p.fail("EINVAL", "timeout: seconds", .{}),
  };
  if (!(seconds > 0) or seconds > 1e9) return p.fail("EINVAL", "timeout: more than 0 seconds", .{});
  return p.now + @as(u64, @intFromFloat(seconds * 1000));
}

/// Whether the client may have one more request pending.
fn room(p: *Protocol, client: *const Server.Client) Error!void {
  if (client.pending >= max_pending_per_client) {
    return p.fail("ENOBUFS", "16 requests pending", .{});
  }
}

/// Waits for libskep's request `req`, which answers a client's.
fn wait(p: *Protocol, client: *Server.Client, req: u32, pending: Pending) Error!void {
  try p.pending.put(p.gpa, req, pending);
  client.pending += 1;
}

// Responses.

/// A message being written, in place: its writer points into it.
const Message = struct {
  out: Io.Writer.Allocating,
  j: Stringify,
  /// Objects open, which `finish` closes.
  depth: u8,

  fn init(m: *Message, gpa: std.mem.Allocator) void {
    m.out = .init(gpa);
    m.j = .{ .writer = &m.out.writer };
    m.depth = 0;
  }

  fn deinit(m: *Message) void {
    m.out.deinit();
  }

  fn open(m: *Message) !void {
    try m.j.beginObject();
    m.depth += 1;
  }

  /// Closes what is open, and returns the line.
  fn finish(m: *Message) ![]const u8 {
    while (m.depth > 0) : (m.depth -= 1) {
      try m.j.endObject();
    }
    return m.out.written();
  }
};

/// Starts a response with a result, whose members follow; `send` ends it.
fn result(_: *Protocol, m: *Message, id: i64) !void {
  try m.open();
  try m.j.objectField("id");
  try m.j.write(id);
  try m.j.objectField("result");
  try m.open();
}

/// Ends a message, and queues it for a client.
fn send(p: *Protocol, client: *Server.Client, m: *Message) void {
  const line = m.finish() catch return;
  p.server.send(client, line);
}

fn empty(p: *Protocol, client: *Server.Client, id: i64) void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  p.result(&m, id) catch return;
  p.send(client, &m);
}

fn sendError(p: *Protocol, client: *Server.Client, code: []const u8, message: []const u8) void {
  var out: Io.Writer.Allocating = .init(p.gpa);
  defer out.deinit();
  var j: Stringify = .{ .writer = &out.writer };
  j.beginObject() catch return;
  j.objectField("id") catch return;
  j.write(p.request_id) catch return;
  j.objectField("error") catch return;
  j.beginObject() catch return;
  j.objectField("code") catch return;
  j.write(code) catch return;
  j.objectField("message") catch return;
  j.write(message) catch return;
  j.endObject() catch return;
  j.endObject() catch return;
  p.server.send(client, out.written());
}

fn network(p: *Protocol, client: *Server.Client, id: i64) Error!void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  try p.result(&m, id);
  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  const up = c.skep_get_network(p.ctx, &channel, &pan_id, &extended_pan_id) == 0;
  try m.j.objectField("up");
  try m.j.write(up);
  if (up) {
    try m.j.objectField("channel");
    try m.j.write(channel);
    try m.j.objectField("pan_id");
    try m.j.write(pan_id);
    try m.j.objectField("extended_pan_id");
    try m.j.print("\"{x:0>16}\"", .{ extended_pan_id });
    try m.j.objectField("permit_join");
    const left = if (p.window_until) |until|
      (if (until > p.now) (until - p.now + 999) / 1000 else 0)
    else
      0;
    try m.j.write(left);
  } else if (p.down_error) |e| {
    var buffer: [24]u8 = undefined;
    try m.j.objectField("error");
    try m.j.write(errnoCode(&buffer, e));
  }
  p.send(client, &m);
}

/// The members of a device object: what is known of it so far.
fn describe(p: *Protocol, j: *Stringify, a: std.mem.Allocator, device: u64) Error!void {
  try j.objectField("device");
  try j.print("\"{x:0>16}\"", .{ device });
  if (p.names.get(device)) |name| {
    try j.objectField("name");
    try j.write(name);
  }
  var address: u16 = 0;
  if (c.skep_device_get_short_address(p.ctx, device, &address) == 0) {
    try j.objectField("network_address");
    try j.write(address);
  }
  var node_type: c.enum_skep_node_type = undefined;
  var manufacturer_code: u16 = 0;
  var rx_on_when_idle: c_int = 0;
  if (c.skep_device_get_node(p.ctx, device, &node_type, &manufacturer_code, &rx_on_when_idle) ==
    0) {
    try j.objectField("type");
    try j.write(
      switch (node_type) {
        c.SKEP_NODE_COORDINATOR => "coordinator",
        c.SKEP_NODE_ROUTER => "router",
        else => "end_device",
      },
    );
    try j.objectField("manufacturer_code");
    try j.write(manufacturer_code);
    try j.objectField("rx_on_when_idle");
    try j.write(rx_on_when_idle != 0);
  }
  var text: [256]u8 = undefined;
  inline for (.{
    .{ "manufacturer", c.skep_device_get_manufacturer },
    .{ "model", c.skep_device_get_model },
  }) |field| {
    if (field[1](p.ctx, device, &text, text.len) >= 0) {
      const valid = try values.validUtf8(a, std.mem.sliceTo(&text, 0));
      try j.objectField(field[0]);
      try j.write(valid);
    }
  }
  var count: usize = 0;
  if (c.skep_device_get_endpoints(p.ctx, device, null, 0, &count) == 0) {
    const endpoints = try a.alloc(u8, count);
    _ = c.skep_device_get_endpoints(p.ctx, device, endpoints.ptr, endpoints.len, &count);
    try j.objectField("endpoints");
    try j.beginArray();
    for (endpoints) |endpoint| {
      try j.beginObject();
      try j.objectField("endpoint");
      try j.write(endpoint);
      var profile: u16 = 0;
      var device_type: u16 = 0;
      if (c.skep_device_get_endpoint(p.ctx, device, endpoint, &profile, &device_type) == 0) {
        try j.objectField("profile");
        try j.write(profile);
        try j.objectField("device_type");
        try j.write(device_type);
      }
      inline for (.{
        .{ "input_clusters", c.SKEP_CLUSTER_INPUT },
        .{ "output_clusters", c.SKEP_CLUSTER_OUTPUT },
      }) |side| {
        var n: usize = 0;
        if (c.skep_device_get_clusters(p.ctx, device, endpoint, side[1], null, 0, &n) == 0) {
          const clusters = try a.alloc(u16, n);
          _ = c.skep_device_get_clusters(
            p.ctx,
            device,
            endpoint,
            side[1],
            clusters.ptr,
            clusters.len,
            &n,
          );
          try j.objectField(side[0]);
          try j.write(clusters);
        }
      }
      try j.endObject();
    }
    try j.endArray();
  }
  var setup: c.enum_skep_setup = undefined;
  if (c.skep_device_get_setup(p.ctx, device, &setup) == 0) {
    try j.objectField("setup");
    try j.write(
      switch (setup) {
        c.SKEP_SETUP_READY => "ready",
        c.SKEP_SETUP_FAILED => "failed",
        else => "pending",
      },
    );
  }
  try p.describeReadings(j, a, device);
}

// libskep's events.

/// Takes an event of libskep: the end of a client's request, or news for the clients that watch.
/// Returns whether it was the end of a client's request.
pub fn event(p: *Protocol, e: *const c.skep_event) bool {
  const t = c.skep_event_get_type(e);
  if (t == c.SKEP_EVENT_REQUEST_DONE) return p.requestDone(e);
  switch (t) {
    c.SKEP_EVENT_STARTED => {
      p.down_error = null;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.eventMessage(&m, "network_up") catch return false;
      p.networkMembers(&m.j, c.skep_event_get_network_origin(e)) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_STOPPED => {
      const error_code = c.skep_event_get_error(e);
      p.down_error = if (error_code != 0) error_code else null;
      p.window_until = null;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.eventMessage(&m, "network_down") catch return false;
      if (error_code != 0) {
        var buffer: [24]u8 = undefined;
        m.j.objectField("error") catch return false;
        m.j.write(errnoCode(&buffer, error_code)) catch return false;
      }
      p.broadcast(&m);
    },
    c.SKEP_EVENT_PERMIT_JOIN => {
      const seconds = c.skep_event_get_duration(e);
      p.window_until = if (seconds > 0) p.now + @as(u64, seconds) * 1000 else null;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.eventMessage(&m, "permit_join") catch return false;
      m.j.objectField("seconds") catch return false;
      m.j.write(seconds) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_DEVICE_JOINED, c.SKEP_EVENT_DEVICE_READY => {
      const device = c.skep_event_get_device(e);
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.deviceEvent(
        &m,
        if (t == c.SKEP_EVENT_DEVICE_JOINED) "device_joined" else "device_ready",
        device,
      ) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_DEVICE_LEFT => {
      const device = c.skep_event_get_device(e);
      var setup: c.enum_skep_setup = undefined;
      // Forgotten by libskep: removed, not gone by itself.
      const removed = c.skep_device_get_setup(p.ctx, device, &setup) != 0;
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.deviceEvent(&m, "device_left", device) catch return false;
      m.j.objectField("removed") catch return false;
      m.j.write(removed) catch return false;
      if (removed) {
        p.readings.forget(device);
      }
      p.broadcast(&m);
    },
    c.SKEP_EVENT_DEVICE_SETUP_FAILED => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.deviceEvent(&m, "device_setup_failed", c.skep_event_get_device(e)) catch return false;
      const error_code = c.skep_event_get_error(e);
      if (error_code != 0) {
        var buffer: [24]u8 = undefined;
        m.j.objectField("error") catch return false;
        m.j.write(errnoCode(&buffer, error_code)) catch return false;
      } else {
        m.j.objectField("status") catch return false;
        m.j.write(c.skep_event_get_status(e)) catch return false;
      }
      p.broadcast(&m);
    },
    c.SKEP_EVENT_ATTRIBUTES => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      const device = c.skep_event_get_device(e);
      p.remember(device, c.skep_event_get_endpoint(e), c.skep_event_get_cluster(e), e);
      p.deviceEvent(&m, "attributes", device) catch return false;
      p.frameMembers(&m.j, e) catch return false;
      p.writeAttributes(&m.j, e, false) catch return false;
      p.broadcast(&m);
    },
    c.SKEP_EVENT_COMMAND => {
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.deviceEvent(&m, "command", c.skep_event_get_device(e)) catch return false;
      p.commandMembers(&m.j, e) catch return false;
      p.broadcast(&m);
    },
    else => {},
  }
  return false;
}

/// Starts an event, whose members follow.
fn eventMessage(p: *Protocol, m: *Message, name: []const u8) !void {
  try m.open();
  try m.j.objectField("event");
  try m.j.write(name);
  var buffer: [32]u8 = undefined;
  try m.j.objectField("time");
  try m.j.write(p.timestamp(&buffer));
}

fn deviceEvent(p: *Protocol, m: *Message, name: []const u8, device: u64) !void {
  try p.eventMessage(m, name);
  try m.j.objectField("device");
  try m.j.print("\"{x:0>16}\"", .{ device });
  if (p.names.get(device)) |n| {
    try m.j.objectField("name");
    try m.j.write(n);
  }
}

/// device_renamed, for the clients that watch.
fn renamed(p: *Protocol, device: u64, old: ?[]const u8) void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  p.deviceEvent(&m, "device_renamed", device) catch return;
  if (old) |o| {
    m.j.objectField("old_name") catch return;
    m.j.write(o) catch return;
  }
  p.broadcast(&m);
}

fn networkMembers(p: *Protocol, j: *Stringify, origin: c.enum_skep_network_origin) !void {
  try j.objectField("origin");
  try j.write(
    switch (origin) {
      c.SKEP_NETWORK_RESTORED => "restored",
      c.SKEP_NETWORK_FORMED => "formed",
      else => "resumed",
    },
  );
  var channel: u8 = 0;
  var pan_id: u16 = 0;
  var extended_pan_id: u64 = 0;
  if (c.skep_get_network(p.ctx, &channel, &pan_id, &extended_pan_id) != 0) return;
  try j.objectField("channel");
  try j.write(channel);
  try j.objectField("pan_id");
  try j.write(pan_id);
  try j.objectField("extended_pan_id");
  try j.print("\"{x:0>16}\"", .{ extended_pan_id });
}

fn frameMembers(_: *Protocol, j: *Stringify, e: *const c.skep_event) !void {
  try j.objectField("endpoint");
  try j.write(c.skep_event_get_endpoint(e));
  try j.objectField("cluster");
  try j.write(c.skep_event_get_cluster(e));
  const code = c.skep_event_get_manufacturer_code(e);
  if (code != 0) {
    try j.objectField("manufacturer_code");
    try j.write(code);
  }
}

/// The members of an attribute's reading: its name, its value in its unit, and its unit.
fn readingMembers(
  j: *Stringify,
  name: [*c]const u8,
  unit: [*c]const u8,
  scaled: f64,
) !void {
  try j.objectField("reading");
  try j.write(std.mem.span(name));
  try j.objectField("scaled");
  if (std.math.isFinite(scaled)) {
    try j.write(scaled);
  } else {
    try j.write(null);
  }
  try j.objectField("unit");
  try j.write(std.mem.span(unit));
}

/// Remembers the readings of an event's attributes, from a device's endpoint and cluster.
fn remember(p: *Protocol, device: u64, endpoint: u8, cluster: u16, e: *const c.skep_event) void {
  const time: i64 = @intCast(@divTrunc(Io.Clock.real.now(p.io).nanoseconds, std.time.ns_per_ms));
  p.readings.remember(device, endpoint, cluster, e, time);
}

/// "readings": what the device can be read for, with what it last reported or was read, and
/// when.
fn describeReadings(p: *Protocol, j: *Stringify, a: std.mem.Allocator, device: u64) !void {
  var count: usize = 0;
  if (c.skep_device_get_readings(p.ctx, device, null, 0, &count) != 0) return;
  const sources = try a.alloc(c.struct_skep_reading_source, count);
  _ = c.skep_device_get_readings(p.ctx, device, sources.ptr, sources.len, &count);
  try j.objectField("readings");
  try j.beginArray();
  for (sources[0..@min(count, sources.len)]) |source| {
    try j.beginObject();
    try j.objectField("endpoint");
    try j.write(source.endpoint);
    try j.objectField("cluster");
    try j.write(source.cluster);
    try j.objectField("id");
    try j.write(source.attribute);
    const key: Readings.Source = .{
      .device = device,
      .endpoint = source.endpoint,
      .cluster = source.cluster,
      .attribute = source.attribute,
    };
    if (p.readings.get(key)) |last| {
      try values.write(j, p.gpa, last.value);
      try readingMembers(j, source.name, source.unit, last.scaled);
      var buffer: [32]u8 = undefined;
      try j.objectField("time");
      try j.write(formatTime(&buffer, last.time));
    } else {
      try j.objectField("reading");
      try j.write(std.mem.span(source.name));
      try j.objectField("unit");
      try j.write(std.mem.span(source.unit));
    }
    try j.endObject();
  }
  try j.endArray();
}

/// "attributes": those of the event, with their statuses in results, and values where they have
/// them.
fn writeAttributes(p: *Protocol, j: *Stringify, e: *const c.skep_event, with_status: bool) !void {
  try j.objectField("attributes");
  try j.beginArray();
  for (0..c.skep_event_get_attribute_count(e)) |i| {
    var a: c.struct_skep_attribute = undefined;
    if (c.skep_event_get_attribute(e, i, &a) != 0) continue;
    try j.beginObject();
    try j.objectField("id");
    try j.write(a.id);
    if (with_status) {
      try j.objectField("status");
      try j.write(a.status);
    }
    if (a.status == 0 and a.value.type != 0) {
      try values.write(j, p.gpa, a.value);
    }
    var reading: c.struct_skep_reading = undefined;
    if (c.skep_event_get_reading(e, i, &reading) == 0) {
      try readingMembers(j, reading.name, reading.unit, reading.value);
    }
    try j.endObject();
  }
  try j.endArray();
}

fn commandMembers(p: *Protocol, j: *Stringify, e: *const c.skep_event) !void {
  try p.frameMembers(j, e);
  try j.objectField("command");
  try j.write(c.skep_event_get_command(e));
  var len: usize = 0;
  const payload = c.skep_event_get_payload(e, &len);
  try j.objectField("payload");
  try j.print("\"{x}\"", .{ payload[0..len] });
  var count: usize = 0;
  if (c.skep_event_get_argument_count(e, &count) == 0) {
    try j.objectField("arguments");
    try j.beginArray();
    for (0..count) |i| {
      var v: c.struct_skep_value = undefined;
      if (c.skep_event_get_argument(e, i, &v) != 0) continue;
      try j.beginObject();
      try values.write(j, p.gpa, v);
      try j.endObject();
    }
    try j.endArray();
  }
}

/// The end of a client's request: its response.
fn requestDone(p: *Protocol, e: *const c.skep_event) bool {
  const entry = p.pending.fetchRemove(c.skep_event_get_request(e)) orelse return false;
  const pending = entry.value;
  // A client that went away.
  const client = p.clientOf(pending.client) orelse return true;
  client.pending -|= 1;
  p.request_id = pending.id;
  const error_code = c.skep_event_get_error(e);
  const status = c.skep_event_get_status(e);
  if (pending.method == .remove) {
    // Forgotten unless canceled: answered, or not.
    if (error_code == 0 or error_code == -@as(c_int, @backingInt(E.TIMEDOUT)) or
      error_code == -@as(c_int, @backingInt(E.HOSTUNREACH))) {
      if (p.names.set(pending.device, null) catch null) |old| {
        p.gpa.free(old);
        _ = p.names.save(p.names_path);
      }
      var m: Message = undefined;
      m.init(p.gpa);
      defer m.deinit();
      p.result(&m, pending.id) catch return true;
      if (error_code == 0) {
        m.j.objectField("status") catch return true;
        m.j.write(status) catch return true;
      }
      p.send(client, &m);
      return true;
    }
  }
  if (error_code != 0) {
    var buffer: [24]u8 = undefined;
    var message: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "{t}", .{ errnoOf(error_code) }) catch "";
    p.sendError(client, errnoCode(&buffer, error_code), text);
    return true;
  }
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  p.result(&m, pending.id) catch return true;
  switch (pending.method) {
    .permit_join => {},
    .read, .write, .configure_reporting => {
      if (pending.method == .read) {
        p.remember(pending.device, pending.endpoint, pending.cluster, e);
      }
      m.j.objectField("status") catch return true;
      m.j.write(status) catch return true;
      if (pending.method != .read or status == 0) {
        p.writeAttributes(&m.j, e, true) catch return true;
      }
    },
    else => {
      m.j.objectField("status") catch return true;
      m.j.write(status) catch return true;
    },
  }
  p.send(client, &m);
  return true;
}

fn clientOf(p: *Protocol, id: u32) ?*Server.Client {
  for (p.server.clients.items) |client| {
    if (client.id == id) return client;
  }
  return null;
}

fn broadcast(p: *Protocol, m: *Message) void {
  const line = m.finish() catch return;
  for (p.server.clients.items) |client| {
    if (client.watching) {
      p.server.send(client, line);
    }
  }
}

/// Drops the clients that are done with, and cancels what they had pending.
pub fn dropFinished(p: *Protocol) void {
  var i: usize = 0;
  while (i < p.server.clients.items.len) {
    const client = p.server.clients.items[i];
    if (!Server.finished(client)) {
      i += 1;
      continue;
    }
    var it = p.pending.iterator();
    while (it.next()) |entry| {
      if (entry.value_ptr.client == client.id) {
        _ = c.skep_cancel(p.ctx, entry.key_ptr.*);
      }
    }
    p.server.drop(client);
  }
}

/// The current time in UTC, as ISO 8601 with milliseconds.
fn timestamp(p: *Protocol, buffer: *[32]u8) []const u8 {
  return formatTime(
    buffer,
    @intCast(@divTrunc(Io.Clock.real.now(p.io).nanoseconds, std.time.ns_per_ms)),
  );
}

/// A time in milliseconds since the epoch, in UTC, as ISO 8601 with milliseconds.
fn formatTime(buffer: *[32]u8, time: i64) []const u8 {
  const ms: u64 = @intCast(@max(time, 0));
  const epoch: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
  const year_day = epoch.getEpochDay().calculateYearDay();
  const month_day = year_day.calculateMonthDay();
  const day = epoch.getDaySeconds();
  return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
    year_day.year,
    @backingInt(month_day.month),
    month_day.day_index + 1,
    day.getHoursIntoDay(),
    day.getMinutesIntoHour(),
    day.getSecondsIntoMinute(),
    ms % 1000,
  }) catch "";
}

const testing = std.testing;
const linux = std.os.linux;

/// libskep with the sim driver, its network up, and skepd's protocol on a socket in /tmp.
const TestBench = struct {
  dir: [64]u8 = undefined,
  dir_len: usize = 0,
  protocol: Protocol,
  client: linux.fd_t,

  fn init(b: *TestBench) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.bufPrint(&b.dir, "/tmp/skep-test-{s}", .{ &tmp.sub_path });
    b.dir_len = dir.len;
    var ctx: ?*c.skep_ctx = null;
    const seed: [c.SKEP_SEED_SIZE]u8 = @splat(3);
    if (c.skep_new(null, &seed, &ctx) != 0) return error.OutOfMemory;
    errdefer c.skep_free(ctx);
    if (c.skep_set_option(ctx, "driver", "sim") != 0) return error.TestUnexpectedResult;
    if (c.skep_start(ctx) != 0) return error.TestUnexpectedResult;
    var socket_path: [96]u8 = undefined;
    var errno: std.os.linux.E = .SUCCESS;
    const server = try Server.open(
      testing.allocator,
      try std.fmt.bufPrint(&socket_path, "{s}/skepd.sock", .{ dir }),
      &errno,
    );
    b.protocol = .{
      .gpa = testing.allocator,
      .io = testing.io,
      .ctx = ctx.?,
      .server = server,
      .names = .{ .gpa = testing.allocator },
      .readings = .{ .gpa = testing.allocator },
      .names_path = try testing.allocator.dupeSentinel(
        u8,
        try std.fmt.bufPrint(&socket_path, "{s}/names.json", .{ dir }),
        0,
      ),
    };
    b.client = try connect(b.protocol.server.path);
    try b.protocol.server.accept();
    b.pump();
  }

  fn deinit(b: *TestBench) void {
    _ = linux.close(b.client);
    const ctx = b.protocol.ctx;
    testing.allocator.free(b.protocol.names_path);
    var names_path: [96]u8 = undefined;
    _ = linux.unlink(
      std.fmt.bufPrintSentinel(&names_path, "{s}/names.json", .{ b.dir[0..b.dir_len] }, 0) catch
        unreachable,
    );
    b.protocol.deinit();
    c.skep_free(ctx);
    var dir: [64]u8 = undefined;
    _ = linux.rmdir(
      std.fmt.bufPrintSentinel(&dir, "{s}", .{ b.dir[0..b.dir_len] }, 0) catch unreachable,
    );
  }

  /// skepd's loop, once: libskep, its events, the clients' lines, and what goes back.
  fn pump(b: *TestBench) void {
    const p = &b.protocol;
    for (0..4) |_| {
      _ = c.skep_advance(p.ctx, p.now);
      while (c.skep_next_event(p.ctx)) |e| {
        _ = p.event(e);
        c.skep_event_free(e);
      }
      for (p.server.clients.items) |client| {
        p.server.read(client);
      }
      p.serve();
      for (p.server.clients.items) |client| {
        Server.flush(client);
      }
    }
  }

  fn ask(b: *TestBench, line: []const u8) void {
    _ = linux.write(b.client, line.ptr, line.len);
    b.pump();
  }

  /// What the client has received since it last looked.
  fn received(b: *TestBench, buffer: []u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
      var poll = [_]linux.pollfd{.{ .fd = b.client, .events = linux.POLL.IN, .revents = 0 }};
      if (linux.poll(&poll, 1, 0) == 0) break;
      const n = linux.read(b.client, buffer[len..].ptr, buffer.len - len);
      if (linux.errno(n) != .SUCCESS or n == 0) break;
      len += n;
    }
    return buffer[0..len];
  }
};

fn connect(path: []const u8) !linux.fd_t {
  var address: linux.sockaddr.un = .{ .path = @splat(0) };
  @memcpy(address.path[0..path.len], path);
  const fd: linux.fd_t = @intCast(
    linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0),
  );
  if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
    return error.ConnectFailed;
  }
  return fd;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
  if (std.mem.indexOf(u8, haystack, needle) == null) {
    std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedContains;
  }
}

test "clients ask skepd, and watch the network" {
  var bench: TestBench = undefined;
  try bench.init();
  defer bench.deinit();
  var buffer: [8192]u8 = undefined;

  bench.ask(
    "{\"id\": 1, \"method\": \"version\"}\n\n{\"id\": 2, \"method\": \"network\"}\n{\"id\": 3, \"method\": \"devices\"}\n",
  );
  var got = bench.received(&buffer);
  try expectContains(got, "{\"id\":1,\"result\":{\"protocol\":1,\"skepd\":\"");
  try expectContains(got, "{\"id\":2,\"result\":{\"up\":true,\"channel\":15,");
  try expectContains(got, "\"permit_join\":0}}");
  try expectContains(got, "{\"id\":3,\"result\":{\"devices\":[]}}");

  bench.ask(
    "{\"id\": 4, \"method\": \"nope\"}\n{\"id\": 5, \"method\": \"network\", \"extra\": 1}\nnot JSON\n",
  );
  got = bench.received(&buffer);
  try expectContains(got, "{\"id\":4,\"error\":{\"code\":\"ENOSYS\"");
  try expectContains(got, "{\"id\":5,\"error\":{\"code\":\"ENOTSUP\"");
  try expectContains(got, "{\"id\":null,\"error\":{\"code\":\"EINVAL\"");

  bench.ask(
    "{\"id\": 6, \"method\": \"permit_join\", \"params\": {\"seconds\": 300}}\n{\"id\": 7, \"method\": \"device\", \"params\": {\"device\": \"living room\"}}\n{\"id\": 8, \"method\": \"cancel\", \"params\": {\"id\": 99}}\n",
  );
  got = bench.received(&buffer);
  try expectContains(got, "{\"id\":6,\"error\":{\"code\":\"EINVAL\"");
  try expectContains(got, "{\"id\":7,\"error\":{\"code\":\"ENODEV\"");
  try expectContains(got, "{\"id\":8,\"error\":{\"code\":\"ENOENT\"");

  // Watching: the join window opens, as an event, then the request ends.
  bench.ask(
    "{\"id\": 9, \"method\": \"watch\"}\n{\"id\": 10, \"method\": \"permit_join\", \"params\": {\"seconds\": \"0x3c\"}}\n",
  );
  got = bench.received(&buffer);
  try expectContains(got, "{\"id\":9,\"result\":{}}");
  try expectContains(got, "{\"event\":\"permit_join\",\"time\":\"");
  try expectContains(got, "\"seconds\":60}");
  try expectContains(got, "{\"id\":10,\"result\":{}}");
  bench.ask("{\"id\": 11, \"method\": \"network\"}\n");
  try expectContains(bench.received(&buffer), "\"permit_join\":60}}");
}

test "a client done sending still gets its answers" {
  var bench: TestBench = undefined;
  try bench.init();
  defer bench.deinit();
  var buffer: [4096]u8 = undefined;
  const line = "{\"id\": 1, \"method\": \"permit_join\", \"params\": {\"seconds\": 30}}\n";
  _ = linux.write(bench.client, line.ptr, line.len);
  _ = linux.shutdown(bench.client, linux.SHUT.WR);
  bench.pump();
  try expectContains(bench.received(&buffer), "{\"id\":1,\"result\":{}}");
  bench.protocol.dropFinished();
  try testing.expectEqual(0, bench.protocol.server.clients.items.len);
}

test "fuzz: whatever a client sends, skepd answers in JSON" {
  var bench: TestBench = undefined;
  try bench.init();
  defer bench.deinit();
  try testing.fuzz(&bench, fuzzRequest, .{
    .corpus = &.{
      "{\"id\": 1, \"method\": \"version\"}",
      "{\"id\": 2, \"method\": \"write\", \"params\": {\"device\": \"f44250000d350000\", \"endpoint\": 1, \"cluster\": 6, \"timeout\": 1.5, \"attributes\": [{\"id\": 0, \"type\": \"bool\", \"value\": true}]}}",
      "{\"id\": 3, \"method\": \"configure_reporting\", \"params\": {\"device\": \"plug\", \"endpoint\": 1, \"cluster\": \"0x0b04\", \"reporting\": [{\"id\": 1291, \"type\": \"int16\", \"min_interval\": 5, \"max_interval\": 3600, \"change\": 10}]}}",
      "{\"id\": 4, \"method\": \"command\", \"params\": {\"device\": \"0xF44250000D350000\", \"endpoint\": 1, \"cluster\": 3, \"command\": 0, \"arguments\": [{\"type\": \"uint16\", \"value\": 5}, {\"type\": \"octet_string\", \"value\": \"01ab\"}]}}",
      "{\"id\": 5, \"method\": \"rename\", \"params\": {\"device\": \"f44250000d350000\", \"name\": null}}",
    },
  });
}

fn fuzzRequest(bench: *TestBench, smith: *testing.Smith) !void {
  var line: [512]u8 = undefined;
  const len = smith.slice(&line);
  if (std.mem.indexOfScalar(u8, line[0..len], '\n') != null) return;
  const client = bench.protocol.server.clients.items[0];
  bench.protocol.handle(client, line[0..len]);
  var answers = std.mem.splitScalar(u8, client.output.items, '\n');
  while (answers.next()) |answer| {
    if (answer.len == 0) continue;
    try testing.expect(try std.json.validate(testing.allocator, answer));
  }
  // Each input from scratch, leaving nothing allocated behind it: the fuzzer counts that as a leak.
  const p = &bench.protocol;
  client.output.deinit(p.gpa);
  client.output = .empty;
  var it = p.pending.iterator();
  while (it.next()) |entry| {
    _ = c.skep_cancel(p.ctx, entry.key_ptr.*);
  }
  p.pending.clearAndFree(p.gpa);
  client.pending = 0;
  client.watching = false;
  p.names.deinit();
  p.names = .{ .gpa = p.gpa };
  while (c.skep_next_event(p.ctx)) |e| {
    c.skep_event_free(e);
  }
}
