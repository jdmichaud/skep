//! skep-protocol(7), skepd's side: requests read from clients' lines and made to libskep through
//! skep.h, their responses, and events for the clients that watch.

const std = @import("std");
const c = @import("skep_h");
const Names = @import("Names.zig");
const libskep = @import("libskep.zig");
const time = @import("time.zig");
const Readings = @import("Readings.zig");
const Server = @import("Server.zig");
const events = @import("events.zig");
const methods = @import("methods.zig");
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
pub const max_attributes = c.SKEP_MAX_ATTRIBUTES;

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
  set,
  cancel,
};

pub const Pending = struct {
  client: u32,
  id: i64,
  method: Method,
  device: u64 = 0,
  /// For reads: what was read, whose readings skepd remembers.
  endpoint: u8 = 0,
  cluster: u16 = 0,
};

/// Why the request being handled fails.
pub const Failure = struct {
  code: [24]u8 = undefined,
  code_len: usize = 0,
  message: [200]u8 = undefined,
  message_len: usize = 0,
  /// A member the error has besides its code and message, for clients to word, its value as
  /// JSON: "range" or "settable"; none if the name is empty.
  data_name: []const u8 = "",
  data: [1024]u8 = undefined,
  data_len: usize = 0,
};

/// WriteFailed is what writing JSON into memory fails with: out of memory too.
pub const Error = error{ Fail, OutOfMemory, WriteFailed };

pub fn deinit(p: *Protocol) void {
  p.readings.deinit();
  p.pending.deinit(p.gpa);
  p.names.deinit();
  p.server.deinit();
}

/// Fails the request being handled with an errno name and a message.
pub fn fail(p: *Protocol, code: []const u8, comptime format: []const u8, args: anytype) Error {
  p.failure.data_name = "";
  const n = @min(code.len, p.failure.code.len);
  @memcpy(p.failure.code[0..n], code[0..n]);
  p.failure.code_len = n;
  const message = std.fmt.bufPrint(&p.failure.message, format, args) catch &p.failure.message;
  p.failure.message_len = message.len;
  return error.Fail;
}

/// Fails, with a member for clients besides the message: its name and its value as JSON.
pub fn failWith(
  p: *Protocol,
  code: []const u8,
  name: []const u8,
  json: []const u8,
  comptime format: []const u8,
  args: anytype,
) Error {
  const failure = p.fail(code, format, args);
  if (json.len <= p.failure.data.len) {
    @memcpy(p.failure.data[0..json.len], json);
    p.failure.data_len = json.len;
    p.failure.data_name = name;
  }
  return failure;
}

/// Fails with the error a function of skep.h returned.
pub fn failErrno(p: *Protocol, r: c_int) Error {
  var buffer: [24]u8 = undefined;
  return p.fail(errnoCode(&buffer, r), "{s}", .{ errnoText(r) });
}

/// What a negative errno value from libskep means, in words, for error messages.
pub fn errnoText(r: c_int) []const u8 {
  return switch (libskep.errno(r)) {
    .NODEV => "no such device",
    .NETDOWN => "the network is down",
    .AGAIN => "the device is not interviewed yet",
    .NOBUFS => "too many requests are pending",
    .INVAL => "a value it cannot take",
    .NOENT => "no such thing on the device",
    .OPNOTSUPP => "not supported",
    .NOMEM => "out of memory",
    .TIMEDOUT => "the device did not answer in time",
    .HOSTUNREACH => "the device could not be reached",
    .CANCELED => "canceled",
    .MSGSIZE => "too long for a frame",
    else => "failed",
  };
}

/// The errno name of a negative errno value: "E" and its name, ENOTSUP for EOPNOTSUPP.
pub fn errnoCode(buffer: *[24]u8, r: c_int) []const u8 {
  const e = libskep.errno(r);
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

pub fn handle(p: *Protocol, client: *Server.Client, line: []const u8) void {
  var arena: std.heap.ArenaAllocator = .init(p.gpa);
  defer arena.deinit();
  p.request_id = null;
  p.request(arena.allocator(), client, line) catch |e| switch (e) {
    error.Fail => p.sendErrorWith(
      client,
      p.failure.code[0..p.failure.code_len],
      p.failure.message[0..p.failure.message_len],
      p.failure.data_name,
      p.failure.data[0..p.failure.data_len],
    ),
    error.OutOfMemory, error.WriteFailed => p.sendError(client, "ENOMEM", "out of memory"),
  };
}

/// The parameters of a request: what is not taken is refused.
pub const Params = struct {
  object: ?std.json.ObjectMap,

  pub fn get(ps: Params, name: []const u8) ?std.json.Value {
    const o = ps.object orelse return null;
    const v = o.get(name) orelse return null;
    return if (v == .null) null else v;
  }
};

pub fn request(
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
    inline else => |m| try @field(methods, @tagName(m))(p, a, client, id, ps),
  }
}

pub const target_members = [_][]const u8{
  "device",
  "endpoint",
  "cluster",
  "manufacturer_code",
  "timeout",
};

/// Refuses members other than `allowed`.
pub fn only(
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

pub fn params(p: *Protocol, ps: Params, allowed: []const []const u8) Error!void {
  if (ps.object) |o| {
    try p.only(o, allowed, "params.");
  }
}

pub fn arrayOf(
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

pub fn objectOf(
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
pub fn valueOf(
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
pub fn deviceOf(p: *Protocol, value: ?std.json.Value) Error!u64 {
  const text = switch (value orelse return p.fail("EINVAL", "no device", .{})) {
    .string => |s| s,
    else => return p.fail("EINVAL", "device: an address or a name", .{}),
  };
  if (values.parseIeee(text)) |ieee| return ieee;
  return p.names.find(text) orelse p.fail("ENODEV", "no device named {s}", .{ text });
}

pub const Target = struct {
  target: c.struct_skep_target,
  deadline: u64,
};

pub fn targetOf(p: *Protocol, ps: Params) Error!Target {
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
pub fn deadlineOf(p: *Protocol, value: ?std.json.Value) Error!u64 {
  const seconds: f64 = switch (value orelse return std.math.maxInt(u64)) {
    .integer => |i| @floatFromInt(i),
    .float => |f| f,
    else => return p.fail("EINVAL", "timeout: seconds", .{}),
  };
  if (!(seconds > 0) or seconds > 1e9) return p.fail("EINVAL", "timeout: more than 0 seconds", .{});
  return p.now + @as(u64, @intFromFloat(seconds * 1000));
}

/// Whether the client may have one more request pending.
pub fn room(p: *Protocol, client: *const Server.Client) Error!void {
  if (client.pending >= max_pending_per_client) {
    return p.fail("ENOBUFS", "16 requests pending", .{});
  }
}

/// Waits for libskep's request `req`, which answers a client's.
pub fn wait(p: *Protocol, client: *Server.Client, req: u32, pending: Pending) Error!void {
  try p.pending.put(p.gpa, req, pending);
  client.pending += 1;
}

// Responses.

/// A message being written, in place: its writer points into it.
pub const Message = struct {
  out: Io.Writer.Allocating,
  j: Stringify,
  /// Objects open, which `finish` closes.
  depth: u8,

  pub fn init(m: *Message, gpa: std.mem.Allocator) void {
    m.out = .init(gpa);
    m.j = .{ .writer = &m.out.writer };
    m.depth = 0;
  }

  pub fn deinit(m: *Message) void {
    m.out.deinit();
  }

  pub fn open(m: *Message) !void {
    try m.j.beginObject();
    m.depth += 1;
  }

  /// Closes what is open, and returns the line.
  pub fn finish(m: *Message) ![]const u8 {
    while (m.depth > 0) : (m.depth -= 1) {
      try m.j.endObject();
    }
    return m.out.written();
  }
};

/// Starts a response with a result, whose members follow; `send` ends it.
pub fn result(_: *Protocol, m: *Message, id: i64) !void {
  try m.open();
  try m.j.objectField("id");
  try m.j.write(id);
  try m.j.objectField("result");
  try m.open();
}

/// Ends a message, and queues it for a client.
pub fn send(p: *Protocol, client: *Server.Client, m: *Message) void {
  const line = m.finish() catch return;
  p.server.send(client, line);
}

pub fn empty(p: *Protocol, client: *Server.Client, id: i64) void {
  var m: Message = undefined;
  m.init(p.gpa);
  defer m.deinit();
  p.result(&m, id) catch return;
  p.send(client, &m);
}

pub fn sendError(p: *Protocol, client: *Server.Client, code: []const u8, message: []const u8) void {
  p.sendErrorWith(client, code, message, "", "");
}

/// An error with a member besides its code and message, its value already JSON.
pub fn sendErrorWith(
  p: *Protocol,
  client: *Server.Client,
  code: []const u8,
  message: []const u8,
  data_name: []const u8,
  data: []const u8,
) void {
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
  if (data_name.len > 0) {
    j.objectField(data_name) catch return;
    j.print("{s}", .{ data }) catch return;
  }
  j.endObject() catch return;
  j.endObject() catch return;
  p.server.send(client, out.written());
}

// libskep's events.

/// Takes an event of libskep: the end of a client's request or of skepd's own read, or news for
/// the clients that watch. Returns whether it was the end of a request.
pub fn event(p: *Protocol, e: *const c.skep_event) bool {
  const handled = events.handle(p, e);
  // What the event may have made possible: a read, once the network is up, a device set up, or
  // another read done.
  p.readings.advance(p.ctx, p.now);
  return handled;
}

pub fn clientOf(p: *Protocol, id: u32) ?*Server.Client {
  for (p.server.clients.items) |client| {
    if (client.id == id) return client;
  }
  return null;
}

pub fn broadcast(p: *Protocol, m: *Message) void {
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
pub fn timestamp(p: *Protocol, buffer: *[32]u8) []const u8 {
  return time.format(buffer, time.now(p.io));
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

pub fn connect(path: []const u8) !linux.fd_t {
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

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
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

test "settings skepd cannot make are refused" {
  var bench: TestBench = undefined;
  try bench.init();
  defer bench.deinit();
  var buffer: [4096]u8 = undefined;
  bench.ask(
    "{\"id\": 1, \"method\": \"set\", \"params\": {\"device\": \"0011223344556677\", \"reading\": \"level\", \"value\": 50}}\n" ++
      "{\"id\": 2, \"method\": \"set\", \"params\": {\"device\": \"0011223344556677\", \"endpoint\": 1, \"reading\": \"level\"}}\n" ++
      "{\"id\": 3, \"method\": \"set\", \"params\": {\"device\": \"0011223344556677\", \"endpoint\": 1, \"reading\": \"color\", \"value\": \"red\"}}\n" ++
      "{\"id\": 4, \"method\": \"set\", \"params\": {\"device\": \"0011223344556677\", \"endpoint\": 1, \"reading\": \"level\", \"value\": 50, \"speed\": 1}}\n",
  );
  const got = bench.received(&buffer);
  // No such device, no value, no colour, a member set does not take.
  try expectContains(got, "{\"id\":1,\"error\":{\"code\":\"ENODEV\"");
  try expectContains(got, "{\"id\":2,\"error\":{\"code\":\"EINVAL\"");
  try expectContains(got, "{\"id\":3,\"error\":{\"code\":\"EINVAL\"");
  try expectContains(got, "{\"id\":4,\"error\":{\"code\":\"ENOTSUP\"");
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

pub fn fuzzRequest(bench: *TestBench, smith: *testing.Smith) !void {
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
