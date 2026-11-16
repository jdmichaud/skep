//! skep: the command-line client of skepd. It turns its arguments into a request of
//! skep-protocol(7), sends it on skepd's socket, and prints the answer, or the events it watches.
//! It holds no Zigbee logic of its own: skepd, and libskep behind it, do the work.

const std = @import("std");
const build_options = @import("build_options");

const linux = std.os.linux;
const Io = std.Io;

const usage =
  \\usage: skep [--socket <path>] [--json] [--timeout <seconds>] <command> [<arguments>]
  \\
  \\Asks skepd about the Zigbee network, and tells it what to do.
  \\
  \\  version                         the versions of skepd and of its protocol
  \\  network                         the network
  \\  permit [<seconds>]              let new devices join, 60 s by default, 0 to stop
  \\  devices                         the devices
  \\  device <device>                 one device, in detail
  \\  rename <device> [<name>]        name a device, or forget its name
  \\  setup <device>                  interview and set a device up again
  \\  remove <device>                 make a device leave the network, and forget it
  \\  read <device> <endpoint> <cluster> <attribute>...
  \\  write <device> <endpoint> <cluster> <attribute> <type> <value>
  \\  report <device> <endpoint> <cluster> <attribute> <type> <min> <max> [<change>]
  \\  bind <device> <endpoint> <cluster>
  \\  unbind <device> <endpoint> <cluster>
  \\  command <device> <endpoint> <cluster> <command> [<type>:<value>...]
  \\  on|off|toggle <device> [<endpoint>]
  \\  watch                           print events until interrupted
  \\
  \\A device is its IEEE address or its name. Clusters, attributes and commands are numbers,
  \\in hexadecimal after 0x. --json prints skepd's answers as they are. skep(1) tells more.
  \\
;

const Options = struct {
  socket: ?[]const u8 = null,
  json: bool = false,
  timeout: ?[]const u8 = null,
};

/// Exit statuses.
const ok = 0;
const failed = 1;
const misused = 2;

pub fn main(init: std.process.Init) !u8 {
  const io = init.io;
  var stdout_buffer: [4096]u8 = undefined;
  var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
  const out = &stdout_writer.interface;
  defer out.flush() catch {};
  var stderr_buffer: [1024]u8 = undefined;
  var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
  const err = &stderr_writer.interface;
  defer err.flush() catch {};

  const arena = init.arena.allocator();
  const args = try init.minimal.args.toSlice(arena);
  var options: Options = .{};
  var i: usize = 1;
  while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "--help")) {
      try out.writeAll(usage);
      return ok;
    } else if (std.mem.eql(u8, arg, "--version")) {
      try out.writeAll("skep " ++ build_options.version ++ "\n");
      return ok;
    } else if (std.mem.eql(u8, arg, "--json")) {
      options.json = true;
    } else if (std.mem.eql(u8, arg, "--socket") and i + 1 < args.len) {
      i += 1;
      options.socket = args[i];
    } else if (std.mem.eql(u8, arg, "--timeout") and i + 1 < args.len) {
      i += 1;
      options.timeout = args[i];
    } else {
      try err.writeAll(usage);
      return misused;
    }
  }
  if (i == args.len) {
    try err.writeAll(usage);
    return misused;
  }
  const command = args[i];
  const rest = args[i + 1..];

  var request: Io.Writer.Allocating = .init(arena);
  const method = build(&request, command, rest, options) catch |e| switch (e) {
    error.Usage => {
      try err.writeAll(usage);
      return misused;
    },
    else => return e,
  };

  const fd = connect(arena, init.environ_map, options.socket) catch |e| {
    try err.print("skep: cannot reach skepd: {t}\n", .{ e });
    return failed;
  };
  defer _ = linux.close(fd);
  try sendAll(fd, request.written());

  var client: Client = .{ .fd = fd, .arena = arena };
  if (std.mem.eql(u8, method, "watch")) return watch(&client, out, err, options);
  // The request is all: skepd answers, then closes.
  _ = linux.shutdown(fd, linux.SHUT.WR);
  const line = (try client.nextLine()) orelse {
    try err.writeAll("skep: skepd closed the connection without answering\n");
    return failed;
  };
  if (options.json) {
    try out.print("{s}\n", .{ line });
  }
  const response = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
    try err.writeAll("skep: an answer that is not JSON\n");
    return failed;
  };
  if (field(response, "error")) |e| {
    try err.print("skep: {s}: {s}\n", .{ text(field(e, "code")), text(field(e, "message")) });
    return failed;
  }
  const result = field(response, "result") orelse {
    try err.writeAll("skep: an answer without a result\n");
    return failed;
  };
  if (options.json) return statusOf(result);
  return show(out, err, command, rest, result);
}

// Building requests.

/// Writes the request for `command`, and returns its method.
fn build(
  w: *Io.Writer.Allocating,
  command: []const u8,
  args: []const [:0]const u8,
  options: Options,
) ![]const u8 {
  var j: std.json.Stringify = .{ .writer = &w.writer };
  try j.beginObject();
  try j.objectField("id");
  try j.write(1);
  const method: []const u8 = method: {
    if (eq(command, "version") or
      eq(command, "network") or
      eq(command, "devices") or
      eq(command, "watch")) {
      if (args.len != 0) return error.Usage;
      break :method command;
    }
    if (eq(command, "on") or eq(command, "off") or eq(command, "toggle")) break :method "command";
    if (eq(command, "permit")) break :method "permit_join";
    if (eq(command, "report")) break :method "configure_reporting";
    for ([_][]const u8{
      "device",
      "rename",
      "setup",
      "remove",
      "read",
      "write",
      "bind",
      "unbind",
      "command",
    }) |m| {
      if (eq(command, m)) break :method m;
    }
    return error.Usage;
  };
  try j.objectField("method");
  try j.write(method);
  try j.objectField("params");
  try j.beginObject();
  if (eq(command, "permit")) {
    if (args.len > 1) return error.Usage;
    try j.objectField("seconds");
    try number(&j, if (args.len == 1) args[0] else "60");
  } else if (eq(command, "device") or eq(command, "setup") or eq(command, "remove")) {
    if (args.len != 1) return error.Usage;
    try j.objectField("device");
    try j.write(args[0]);
    if (eq(command, "remove")) {
      // A device that is gone never answers: give up after a minute, unless told otherwise.
      try j.objectField("timeout");
      try number(&j, options.timeout orelse "60");
    }
  } else if (eq(command, "rename")) {
    if (args.len < 1 or args.len > 2) return error.Usage;
    try j.objectField("device");
    try j.write(args[0]);
    try j.objectField("name");
    try j.write(if (args.len == 2) args[1] else null);
  } else if (eq(command, "on") or eq(command, "off") or eq(command, "toggle")) {
    if (args.len < 1 or args.len > 2) return error.Usage;
    try target(&j, args[0], if (args.len == 2) args[1] else "1", "0x0006", options);
    try j.objectField("command");
    try j.write(@as(u8, if (eq(command, "off")) 0 else if (eq(command, "on")) 1 else 2));
  } else if (eq(command, "read")) {
    if (args.len < 4) return error.Usage;
    try target(&j, args[0], args[1], args[2], options);
    try j.objectField("attributes");
    try j.beginArray();
    for (args[3..]) |a| {
      try number(&j, a);
    }
    try j.endArray();
  } else if (eq(command, "write")) {
    if (args.len != 6) return error.Usage;
    try target(&j, args[0], args[1], args[2], options);
    try j.objectField("attributes");
    try j.beginArray();
    try j.beginObject();
    try j.objectField("id");
    try number(&j, args[3]);
    try typedValue(&j, args[4], args[5]);
    try j.endObject();
    try j.endArray();
  } else if (eq(command, "report")) {
    if (args.len < 7 or args.len > 8) return error.Usage;
    try target(&j, args[0], args[1], args[2], options);
    try j.objectField("reporting");
    try j.beginArray();
    try j.beginObject();
    try j.objectField("id");
    try number(&j, args[3]);
    try j.objectField("type");
    try j.write(args[4]);
    try j.objectField("min_interval");
    try number(&j, args[5]);
    try j.objectField("max_interval");
    try number(&j, args[6]);
    if (args.len == 8) {
      try j.objectField("change");
      try value(&j, args[7]);
    }
    try j.endObject();
    try j.endArray();
  } else if (eq(command, "bind") or eq(command, "unbind")) {
    if (args.len != 3) return error.Usage;
    try target(&j, args[0], args[1], args[2], options);
  } else if (eq(command, "command")) {
    if (args.len < 4) return error.Usage;
    try target(&j, args[0], args[1], args[2], options);
    try j.objectField("command");
    try number(&j, args[3]);
    if (args.len > 4) {
      try j.objectField("arguments");
      try j.beginArray();
      for (args[4..]) |a| {
        const colon = std.mem.indexOfScalar(u8, a, ':') orelse return error.Usage;
        try j.beginObject();
        try typedValue(&j, a[0..colon], a[colon + 1..]);
        try j.endObject();
      }
      try j.endArray();
    }
  }
  try j.endObject();
  try j.endObject();
  try w.writer.writeByte('\n');
  return method;
}

fn eq(a: []const u8, b: []const u8) bool {
  return std.mem.eql(u8, a, b);
}

fn target(
  j: *std.json.Stringify,
  device: []const u8,
  endpoint: []const u8,
  cluster: []const u8,
  options: Options,
) !void {
  try j.objectField("device");
  try j.write(device);
  try j.objectField("endpoint");
  try number(j, endpoint);
  try j.objectField("cluster");
  try number(j, cluster);
  if (options.timeout) |t| {
    try j.objectField("timeout");
    try number(j, t);
  }
}

/// A number as typed: hexadecimal after 0x is left for skepd to read, as a string.
fn number(j: *std.json.Stringify, arg: []const u8) !void {
  if (std.mem.startsWith(u8, arg, "0x")) return j.write(arg);
  const n = std.fmt.parseFloat(f64, arg) catch return error.Usage;
  if (@floor(n) == n and @abs(n) < 1e15) return j.write(@as(i64, @intFromFloat(n)));
  try j.write(n);
}

/// A value as typed: a number, true or false, or text.
fn value(j: *std.json.Stringify, arg: []const u8) !void {
  if (eq(arg, "true")) return j.write(true);
  if (eq(arg, "false")) return j.write(false);
  if (std.fmt.parseInt(i64, arg, 10)) |n| return j.write(n) else |_| {}
  if (std.fmt.parseFloat(f64, arg)) |f| return j.write(f) else |_| {}
  try j.write(arg);
}

fn typedValue(j: *std.json.Stringify, type_name: []const u8, arg: []const u8) !void {
  try j.objectField("type");
  try j.write(type_name);
  try j.objectField("value");
  // Text and hexadecimal digits stay strings, whatever they look like.
  if (std.mem.endsWith(u8, type_name, "_string") or
    eq(type_name, "array") or
    eq(type_name, "struct") or
    eq(type_name, "set") or
    eq(type_name, "bag") or
    eq(type_name, "key128") or
    eq(type_name, "ieee_address")) {
    try j.write(arg);
  } else {
    try value(j, arg);
  }
}

// Talking to skepd.

/// Connects to skepd's socket: the one given, $SKEP_SOCKET, or the usual places.
fn connect(
  arena: std.mem.Allocator,
  environ: *const std.process.Environ.Map,
  given: ?[]const u8,
) !linux.fd_t {
  var paths: std.ArrayList([]const u8) = .empty;
  if (given) |path| {
    try paths.append(arena, path);
  } else {
    if (environ.get("SKEP_SOCKET")) |path| {
      try paths.append(arena, path);
    }
    if (environ.get("XDG_RUNTIME_DIR")) |dir| {
      try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/skep/skepd.sock", .{ dir }));
    }
    try paths.append(arena, "/run/skep/skepd.sock");
  }
  var last: anyerror = error.FileNotFound;
  for (paths.items) |path| {
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= address.path.len) continue;
    @memcpy(address.path[0..path.len], path);
    const fd: linux.fd_t = @intCast(
      linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0),
    );
    const e = linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)));
    if (e == .SUCCESS) return fd;
    _ = linux.close(fd);
    last = switch (e) {
      .NOENT => error.FileNotFound,
      .ACCES, .PERM => error.AccessDenied,
      .CONNREFUSED => error.ConnectionRefused,
      else => error.Unexpected,
    };
  }
  return last;
}

fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
  var sent: usize = 0;
  while (sent < bytes.len) {
    const n = linux.sendto(fd, bytes[sent..].ptr, bytes.len - sent, linux.MSG.NOSIGNAL, null, 0);
    switch (linux.errno(n)) {
      .SUCCESS => sent += n,
      .INTR => {},
      else => return error.BrokenPipe,
    }
  }
}

/// Lines from skepd.
const Client = struct {
  fd: linux.fd_t,
  arena: std.mem.Allocator,
  buffer: std.ArrayList(u8) = .empty,
  start: usize = 0,

  /// The next line, or null once skepd closed the connection.
  fn nextLine(c: *Client) !?[]const u8 {
    while (true) {
      if (std.mem.indexOfScalarPos(u8, c.buffer.items, c.start, '\n')) |end| {
        const line = c.buffer.items[c.start..end];
        c.start = end + 1;
        return line;
      }
      var chunk: [4096]u8 = undefined;
      const n = linux.read(c.fd, &chunk, chunk.len);
      switch (linux.errno(n)) {
        .SUCCESS => {},
        .INTR => continue,
        else => return error.ReadFailed,
      }
      if (n == 0) return null;
      try c.buffer.appendSlice(c.arena, chunk[0..n]);
    }
  }
};

fn watch(client: *Client, out: *Io.Writer, err: *Io.Writer, options: Options) !u8 {
  while (try client.nextLine()) |line| {
    if (options.json) {
      try out.print("{s}\n", .{ line });
    } else {
      const message = std.json.parseFromSliceLeaky(std.json.Value, client.arena, line, .{}) catch
        continue;
      if (field(message, "error")) |e| {
        try err.print("skep: {s}: {s}\n", .{ text(field(e, "code")), text(field(e, "message")) });
        return failed;
      }
      if (field(message, "event") != null) {
        try showEvent(out, message);
      }
    }
    try out.flush();
  }
  try err.writeAll("skep: skepd closed the connection\n");
  return failed;
}

// Printing.

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
  return switch (v) {
    .object => |o| o.get(name),
    else => null,
  };
}

fn text(v: ?std.json.Value) []const u8 {
  return switch (v orelse return "") {
    .string => |s| s,
    else => "",
  };
}

fn integer(v: ?std.json.Value) ?i64 {
  return switch (v orelse return null) {
    .integer => |i| i,
    else => null,
  };
}

/// The exit status of a result: a device that refused is a failure.
fn statusOf(result: std.json.Value) u8 {
  const status = integer(field(result, "status")) orelse return ok;
  if (status != 0) return failed;
  if (field(result, "attributes")) |attributes| {
    for (attributes.array.items) |a| {
      if ((integer(field(a, "status")) orelse 0) != 0) return failed;
    }
  }
  return ok;
}

fn show(
  out: *Io.Writer,
  err: *Io.Writer,
  command: []const u8,
  args: []const [:0]const u8,
  result: std.json.Value,
) !u8 {
  if (eq(command, "version")) {
    try out.print("skepd {s}, protocol {d}\n", .{
      text(field(result, "skepd")),
      integer(field(result, "protocol")) orelse 0,
    });
  } else if (eq(command, "network")) {
    if (field(result, "up").?.bool) {
      try out.print("up: channel {d}, PAN ID 0x{x:0>4}, extended PAN ID {s}", .{
        integer(field(result, "channel")) orelse 0,
        @as(u64, @intCast(integer(field(result, "pan_id")) orelse 0)),
        text(field(result, "extended_pan_id")),
      });
      const left = integer(field(result, "permit_join")) orelse 0;
      if (left > 0) {
        try out.print(", devices may join for {d} s", .{ left });
      }
      try out.writeByte('\n');
    } else {
      try out.writeAll("down");
      if (field(result, "error")) |e| {
        try out.print(": {s}", .{ text(e) });
      }
      try out.writeByte('\n');
    }
  } else if (eq(command, "permit")) {
    const seconds = if (args.len == 1) args[0] else "60";
    if (eq(seconds, "0")) {
      try out.writeAll("devices may no longer join\n");
    } else {
      try out.print("devices may join for {s} s\n", .{ seconds });
    }
  } else if (eq(command, "devices")) {
    for (field(result, "devices").?.array.items) |d| {
      try out.print("{s}  {s:<16}  {s:<14}  {s:<10}  {s}\n", .{
        text(field(d, "device")),
        if (field(d, "name")) |n| text(n) else "-",
        if (field(d, "model")) |m| text(m) else "?",
        typeName(text(field(d, "type"))),
        text(field(d, "setup")),
      });
    }
  } else if (eq(command, "device")) {
    try showDevice(out, result);
  } else if (eq(command, "read")) {
    if (field(result, "attributes")) |attributes| {
      for (attributes.array.items) |a| {
        try showAttribute(out, a);
      }
    }
  } else if (eq(command, "write") or eq(command, "report")) {
    for (field(result, "attributes").?.array.items) |a| {
      const status = integer(field(a, "status")) orelse 0;
      if (status != 0) {
        try out.print("0x{x:0>4}: refused, status 0x{x:0>2}\n", .{
          @as(u64, @intCast(integer(field(a, "id")) orelse 0)),
          @as(u64, @intCast(status)),
        });
      }
    }
  }
  const status = statusOf(result);
  if (status != ok) {
    if (integer(field(result, "status"))) |s| {
      if (s != 0) {
        try err.print("skep: the device refused, status 0x{x:0>2}\n", .{ @as(u64, @intCast(s)) });
      }
    }
  }
  return status;
}

fn typeName(t: []const u8) []const u8 {
  if (eq(t, "end_device")) return "end device";
  return if (t.len == 0) "?" else t;
}

fn showDevice(out: *Io.Writer, d: std.json.Value) !void {
  try out.print("device            {s}\n", .{ text(field(d, "device")) });
  if (field(d, "name")) |n| {
    try out.print("name              {s}\n", .{ text(n) });
  }
  if (integer(field(d, "network_address"))) |a| {
    try out.print("network address   0x{x:0>4}\n", .{ @as(u64, @intCast(a)) });
  }
  if (field(d, "type")) |t| {
    try out.print("type              {s}\n", .{ typeName(text(t)) });
  }
  if (field(d, "manufacturer")) |m| {
    try out.print("manufacturer      {s}\n", .{ text(m) });
  }
  if (integer(field(d, "manufacturer_code"))) |m| {
    try out.print("manufacturer code 0x{x:0>4}\n", .{ @as(u64, @intCast(m)) });
  }
  if (field(d, "model")) |m| {
    try out.print("model             {s}\n", .{ text(m) });
  }
  if (field(d, "rx_on_when_idle")) |r| {
    try out.print("sleeps            {s}\n", .{ if (r.bool) "no" else "yes" });
  }
  try out.print("setup             {s}\n", .{ text(field(d, "setup")) });
  if (field(d, "endpoints")) |endpoints| {
    for (endpoints.array.items) |e| {
      try out.print("endpoint {d}: profile 0x{x:0>4}, device type 0x{x:0>4}\n", .{
        integer(field(e, "endpoint")) orelse 0,
        @as(u64, @intCast(integer(field(e, "profile")) orelse 0)),
        @as(u64, @intCast(integer(field(e, "device_type")) orelse 0)),
      });
      inline for (.{.{ "input_clusters", "in " }, .{ "output_clusters", "out" }}) |side| {
        try out.writeAll("  " ++ side[1] ++ ":");
        if (field(e, side[0])) |clusters| {
          for (clusters.array.items) |cl| {
            try out.print(" 0x{x:0>4}", .{ @as(u64, @intCast(integer(cl) orelse 0)) });
          }
        }
        try out.writeByte('\n');
      }
    }
  }
}

fn showAttribute(out: *Io.Writer, a: std.json.Value) !void {
  const id: u64 = @intCast(integer(field(a, "id")) orelse 0);
  const status = integer(field(a, "status")) orelse 0;
  if (status != 0) {
    return out.print("0x{x:0>4}: status 0x{x:0>2}\n", .{ id, @as(u64, @intCast(status)) });
  }
  try out.print("0x{x:0>4} = ", .{ id });
  try showValue(out, a);
  try out.writeByte('\n');
}

/// A value and its type: `2154 (int16)`.
fn showValue(out: *Io.Writer, a: std.json.Value) !void {
  if (field(a, "value")) |v| {
    switch (v) {
      .integer => |i| try out.print("{d}", .{ i }),
      .float => |f| try out.print("{d}", .{ f }),
      .bool => |b| try out.writeAll(if (b) "true" else "false"),
      .string => |s| try out.print("\"{s}\"", .{ s }),
      .null => try out.writeAll("null"),
      else => try out.writeAll("?"),
    }
    try out.writeByte(' ');
  }
  switch (field(a, "type") orelse .null) {
    .string => |t| try out.print("({s})", .{ t }),
    .integer => |t| try out.print("(type 0x{x:0>2})", .{ @as(u64, @intCast(t)) }),
    else => {},
  }
}

fn showEvent(out: *Io.Writer, e: std.json.Value) !void {
  const event = text(field(e, "event"));
  try out.print("{s} {s}", .{ text(field(e, "time")), event });
  if (field(e, "device")) |d| {
    try out.print(" {s}", .{ text(d) });
    if (field(e, "name")) |n| {
      try out.print(" ({s})", .{ text(n) });
    }
  }
  if (eq(event, "attributes")) {
    try out.print(" {d}/0x{x:0>4}:", .{
      integer(field(e, "endpoint")) orelse 0,
      @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
    });
    for (field(e, "attributes").?.array.items) |a| {
      try out.print(" 0x{x:0>4} = ", .{ @as(u64, @intCast(integer(field(a, "id")) orelse 0)) });
      try showValue(out, a);
    }
  } else if (eq(event, "command")) {
    try out.print(" {d}/0x{x:0>4}: command 0x{x:0>2} {s}", .{
      integer(field(e, "endpoint")) orelse 0,
      @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
      @as(u64, @intCast(integer(field(e, "command")) orelse 0)),
      text(field(e, "payload")),
    });
  } else if (eq(event, "permit_join")) {
    try out.print(" {d} s", .{ integer(field(e, "seconds")) orelse 0 });
  } else if (eq(event, "network_up")) {
    try out.print(" ({s}): channel {d}", .{
      text(field(e, "origin")),
      integer(field(e, "channel")) orelse 0,
    });
  } else if (eq(event, "network_down") or eq(event, "device_setup_failed")) {
    if (field(e, "error")) |x| {
      try out.print(": {s}", .{ text(x) });
    }
    if (integer(field(e, "status"))) |s| {
      try out.print(": status 0x{x:0>2}", .{ @as(u64, @intCast(s)) });
    }
  } else if (eq(event, "device_left")) {
    if (field(e, "removed")) |r| {
      if (r.bool) {
        try out.writeAll(", removed");
      }
    }
  } else if (eq(event, "device_renamed")) {
    if (field(e, "old_name")) |o| {
      try out.print(", was {s}", .{ text(o) });
    }
  }
  try out.writeByte('\n');
}
