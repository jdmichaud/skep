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
  \\  devices                         the devices, and what they last reported
  \\  device <device>                 one device, in detail
  \\  get <device> [<reading>...]     what a device last reported, or was read for
  \\  read <device> <reading>...      ask a device for readings, such as temperature
  \\  set <device> <reading> <value> [--transition <seconds>]
  \\                                  set a reading, such as level 50, or a colour: color #ff8000
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
  \\in hexadecimal after 0x. A reading is a name such as temperature, which get lists.
  \\--json prints skepd's answers as they are. skep(1) tells more.
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
  // The request is all, except for reads of readings, which need the device first: skepd
  // answers, then closes.
  const by_reading = byReading(command, rest);
  if (!by_reading) {
    _ = linux.shutdown(fd, linux.SHUT.WR);
  }
  const line = (try client.nextLine()) orelse {
    try err.writeAll("skep: skepd closed the connection without answering\n");
    return failed;
  };
  if (options.json and !by_reading) {
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
  if (by_reading) return readReadings(&client, out, err, rest, result, options);
  if (options.json) return statusOf(result);
  const now: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
  return show(out, err, command, rest, result, now, arena);
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
    if (eq(command, "get") or byReading(command, args)) {
      if (args.len < 1) return error.Usage;
      break :method "device";
    }
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
      "set",
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
  } else if (eq(command, "get") or byReading(command, args)) {
    try j.objectField("device");
    try j.write(args[0]);
  } else if (eq(command, "device") or eq(command, "setup") or eq(command, "remove")) {
    if (args.len != 1) return error.Usage;
    try j.objectField("device");
    try j.write(args[0]);
    if (eq(command, "remove")) {
      // A device that is gone never answers: give up after a minute, unless told otherwise.
      try j.objectField("timeout");
      try number(&j, options.timeout orelse "60");
    }
  } else if (eq(command, "set")) {
    // <device> <reading> <value>, and --transition <seconds> anywhere after.
    var positional: [3][]const u8 = undefined;
    var count: usize = 0;
    var transition: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
      if (eq(args[i], "--transition")) {
        if (i + 1 == args.len) return error.Usage;
        i += 1;
        transition = args[i];
      } else {
        if (count == positional.len) return error.Usage;
        positional[count] = args[i];
        count += 1;
      }
    }
    if (count != positional.len) return error.Usage;
    try j.objectField("device");
    try j.write(positional[0]);
    try j.objectField("reading");
    try j.write(positional[1]);
    try j.objectField("value");
    try settingValue(&j, positional[1], positional[2]);
    if (transition) |t| {
      try j.objectField("transition");
      try number(&j, t);
    }
    if (options.timeout) |t| {
      try j.objectField("timeout");
      try number(&j, t);
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

/// Whether the command reads readings by name, `read plug power`, rather than attributes by
/// endpoint, cluster and id: readings are names, endpoints numbers.
fn byReading(command: []const u8, args: []const [:0]const u8) bool {
  return eq(command, "read") and args.len >= 2 and std.ascii.isAlphabetic(args[1][0]);
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

/// A setting's value as typed: a colour as #rrggbb, with or without its #; yes or no, on or off;
/// or a number, with its unit if typed, as in 50%, 2700K or 180°.
fn settingValue(j: *std.json.Stringify, reading: []const u8, arg: []const u8) !void {
  if (eq(reading, "color")) {
    if (std.mem.startsWith(u8, arg, "#")) return j.write(arg);
    var buffer: [64]u8 = undefined;
    return j.write(std.fmt.bufPrint(&buffer, "#{s}", .{ arg }) catch return error.Usage);
  }
  for ([_][]const u8{ "yes", "on", "true" }) |word| {
    if (std.ascii.eqlIgnoreCase(arg, word)) return j.write(true);
  }
  for ([_][]const u8{ "no", "off", "false" }) |word| {
    if (std.ascii.eqlIgnoreCase(arg, word)) return j.write(false);
  }
  var digits = arg;
  for ([_][]const u8{ "%", "K", "k", "°" }) |unit| {
    if (std.mem.endsWith(u8, digits, unit)) {
      digits = digits[0..digits.len - unit.len];
    }
  }
  try number(j, digits);
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

/// `read <device> <reading>...`: with the device's readings, which skepd gave, reads them from the
/// device, one request per cluster, and prints them as `get` does.
fn readReadings(
  client: *Client,
  out: *Io.Writer,
  err: *Io.Writer,
  args: []const [:0]const u8,
  device: std.json.Value,
  options: Options,
) !u8 {
  const a = client.arena;
  const wanted = try chosen(a, err, args[0], device, args[1..]) orelse return failed;
  // One request per endpoint and cluster, its id one more than its index.
  var groups: std.ArrayList(std.json.Value) = .empty;
  var group_of = try a.alloc(usize, wanted.len);
  for (wanted, 0..) |r, i| {
    group_of[i] = for (groups.items, 0..) |g, k| {
      if (integer(field(g, "endpoint")) == integer(field(r, "endpoint")) and
        integer(field(g, "cluster")) == integer(field(r, "cluster"))) {
        break k;
      }
    } else blk: {
      try groups.append(a, r);
      break :blk groups.items.len - 1;
    };
  }
  var request: Io.Writer.Allocating = .init(a);
  for (groups.items, 0..) |g, k| {
    var j: std.json.Stringify = .{ .writer = &request.writer };
    try j.beginObject();
    try j.objectField("id");
    try j.write(k + 2);
    try j.objectField("method");
    try j.write("read");
    try j.objectField("params");
    try j.beginObject();
    var endpoint: [8]u8 = undefined;
    var cluster: [8]u8 = undefined;
    try target(
      &j,
      args[0],
      try std.fmt.bufPrint(&endpoint, "{d}", .{ integer(field(g, "endpoint")) orelse 0 }),
      try std.fmt.bufPrint(&cluster, "{d}", .{ integer(field(g, "cluster")) orelse 0 }),
      options,
    );
    try j.objectField("attributes");
    try j.beginArray();
    for (wanted, group_of) |r, gi| {
      if (gi == k) {
        try j.write(integer(field(r, "id")) orelse 0);
      }
    }
    try j.endArray();
    try j.endObject();
    try j.endObject();
    try request.writer.writeByte('\n');
  }
  try sendAll(client.fd, request.written());
  _ = linux.shutdown(client.fd, linux.SHUT.WR);

  // The answers, in whatever order they come.
  const answers = try a.alloc(?std.json.Value, groups.items.len);
  @memset(answers, null);
  var status: u8 = ok;
  var left = groups.items.len;
  while (left > 0) {
    const line = (try client.nextLine()) orelse {
      try err.writeAll("skep: skepd closed the connection without answering\n");
      return failed;
    };
    if (options.json) {
      try out.print("{s}\n", .{ line });
    }
    const response = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
    const id = integer(field(response, "id")) orelse continue;
    if (id < 2 or id - 2 >= answers.len) continue;
    const k: usize = @intCast(id - 2);
    left -= 1;
    if (field(response, "error")) |e| {
      try err.print("skep: {s}: {s}\n", .{ text(field(e, "code")), text(field(e, "message")) });
      status = failed;
    } else if (field(response, "result")) |result| {
      answers[k] = result;
      if (statusOf(result) != ok) {
        status = failed;
      }
    }
  }
  if (options.json) return status;

  // As asked, from the attributes of the answers.
  var rows = try a.alloc(Row, wanted.len);
  for (wanted, group_of, 0..) |r, k, i| {
    rows[i] = .{ .label = try label(a, device, r) };
    const result = answers[k] orelse continue;
    const id = integer(field(r, "id"));
    if (integer(field(result, "status"))) |s| {
      if (s != 0) {
        rows[i].value = try std.fmt.allocPrint(a, "refused, status 0x{x:0>2}", .{
          @as(u64, @intCast(s)),
        });
        continue;
      }
    }
    const attributes = field(result, "attributes") orelse continue;
    for (attributes.array.items) |attribute| {
      if (integer(field(attribute, "id")) != id) continue;
      const s = integer(field(attribute, "status")) orelse 0;
      rows[i].value = if (s != 0)
        try std.fmt.allocPrint(a, "status 0x{x:0>2}", .{ @as(u64, @intCast(s)) })
      else
        try readingText(a, attribute, .table);
    }
  }
  try showRows(out, rows);
  return status;
}

/// The readings of a device that `names` ask for, all of them without names: null, after telling
/// why, for a device whose interview is not done, or a name it has no reading for.
fn chosen(
  a: std.mem.Allocator,
  err: *Io.Writer,
  device_name: []const u8,
  device: std.json.Value,
  names: []const [:0]const u8,
) !?[]std.json.Value {
  const readings = (field(device, "readings") orelse {
    if (field(device, "endpoints") != null) {
      try err.writeAll("skep: skepd gives no readings: it is older than skep\n");
    } else {
      try err.print("skep: {s}: not interviewed yet, its readings are not known\n", .{
        device_name,
      });
    }
    return null;
  }).array.items;
  if (names.len == 0) return readings;
  var list: std.ArrayList(std.json.Value) = .empty;
  for (names) |name| {
    const before = list.items.len;
    for (readings) |r| {
      if (eq(text(field(r, "reading")), name)) {
        try list.append(a, r);
      }
    }
    if (list.items.len == before) {
      try err.print("skep: {s} has no reading {s}; it has", .{ device_name, name });
      for (readings, 0..) |r, i| {
        try err.print("{s} {s}", .{ if (i == 0) "" else ",", text(field(r, "reading")) });
      }
      if (readings.len == 0) {
        try err.writeAll(" none");
      }
      try err.writeByte('\n');
      return null;
    }
  }
  return list.items;
}

/// A line of a table of readings.
const Row = struct {
  label: []const u8,
  value: []const u8 = "-",
  age: []const u8 = "",
};

/// Rows in aligned columns.
fn showRows(out: *Io.Writer, rows: []const Row) !void {
  var label_width: usize = 0;
  var value_width: usize = 0;
  for (rows) |r| {
    label_width = @max(label_width, width(r.label));
    value_width = @max(value_width, width(r.value));
  }
  for (rows) |r| {
    try out.writeAll(r.label);
    try out.splatByteAll(' ', label_width - width(r.label) + 2);
    try out.writeAll(r.value);
    if (r.age.len > 0) {
      try out.splatByteAll(' ', value_width - width(r.value) + 2);
      try out.writeAll(r.age);
    }
    try out.writeByte('\n');
  }
}

/// The rows of a device's readings, with their last values and how old they are.
fn readingRows(
  a: std.mem.Allocator,
  device: std.json.Value,
  readings: []const std.json.Value,
  now: i64,
) ![]Row {
  const rows = try a.alloc(Row, readings.len);
  for (readings, rows) |r, *row| {
    row.* = .{ .label = try label(a, device, r) };
    if (float(field(r, "scaled")) == null) continue;
    row.value = try readingText(a, r, .table);
    if (parseTime(text(field(r, "time")))) |time| {
      row.age = try ago(a, now - time);
    }
  }
  return rows;
}

/// A reading's name, and its endpoint when the device has it on several.
fn label(a: std.mem.Allocator, device: std.json.Value, r: std.json.Value) ![]const u8 {
  const name = text(field(r, "reading"));
  var count: usize = 0;
  if (field(device, "readings")) |all| {
    for (all.array.items) |other| {
      if (eq(text(field(other, "reading")), name)) {
        count += 1;
      }
    }
  }
  if (count < 2) return name;
  return std.fmt.allocPrint(a, "{s} ({d})", .{ name, integer(field(r, "endpoint")) orelse 0 });
}

/// How a reading is written: in a table, where "on" says yes or no next to its name, or in a
/// summary, where it says on or off on its own.
const Style = enum { table, summary };

/// A reading's value in its unit, `21.54 °C`, from its "scaled" and "unit" members.
fn writeReading(w: *Io.Writer, r: std.json.Value, style: Style) !void {
  const scaled = float(field(r, "scaled")) orelse return w.writeAll("-");
  const name = text(field(r, "reading"));
  if (eq(name, "on")) {
    return w.writeAll(
      switch (style) {
        .table => if (scaled != 0) "yes" else "no",
        .summary => if (scaled != 0) "on" else "off",
      },
    );
  }
  if (style == .summary) {
    try w.print("{s} ", .{ name });
  }
  try writeNumber(w, scaled);
  const unit = text(field(r, "unit"));
  if (unit.len > 0) {
    try w.print(" {s}", .{ unit });
  }
}

fn readingText(a: std.mem.Allocator, r: std.json.Value, style: Style) ![]const u8 {
  var w: Io.Writer.Allocating = .init(a);
  try writeReading(&w.writer, r, style);
  return w.written();
}

/// A number with four significant digits at most, without trailing zeros: 21.54, 237.9, 0.0012.
fn writeNumber(w: *Io.Writer, x: f64) !void {
  if (x == 0 or !std.math.isFinite(x)) return w.print("{d}", .{ x });
  const magnitude: i64 = @intFromFloat(@floor(std.math.log10(@abs(x))));
  const decimals: usize = @intCast(std.math.clamp(3 - magnitude, 0, 6));
  var buffer: [64]u8 = undefined;
  var s: []const u8 = std.fmt.bufPrint(&buffer, "{d:.[1]}", .{ x, decimals }) catch
    return w.print("{d}", .{ x });
  if (std.mem.indexOfScalar(u8, s, '.') != null) {
    s = std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
  }
  try w.writeAll(s);
}

/// How long ago, from milliseconds: `40 s ago`, `2 min ago`, `3 h ago`, `2 d ago`.
fn ago(a: std.mem.Allocator, ms: i64) ![]const u8 {
  const s: u64 = @intCast(@max(ms, 0) / 1000);
  if (s < 60) return std.fmt.allocPrint(a, "{d} s ago", .{ s });
  if (s < 3600) return std.fmt.allocPrint(a, "{d} min ago", .{ s / 60 });
  if (s < 86400) return std.fmt.allocPrint(a, "{d} h ago", .{ s / 3600 });
  return std.fmt.allocPrint(a, "{d} d ago", .{ s / 86400 });
}

/// Milliseconds since the epoch of a time skepd gives, `2026-11-16T21:39:12.250Z`.
fn parseTime(s: []const u8) ?i64 {
  if (s.len != 24 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or
    s[19] != '.' or s[23] != 'Z') {
    return null;
  }
  const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
  const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
  const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
  const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
  const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
  const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
  const ms = std.fmt.parseInt(i64, s[20..23], 10) catch return null;
  if (month < 1 or month > 12) return null;
  // Days since the epoch of a date: Howard Hinnant's days_from_civil.
  const y = if (month <= 2) year - 1 else year;
  const era = @divFloor(y, 400);
  const yoe = y - era * 400;
  const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
  const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
  const days = era * 146097 + doe - 719468;
  return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms;
}

/// Characters on screen, for alignment: UTF-8 code points.
fn width(s: []const u8) usize {
  return std.unicode.utf8CountCodepoints(s) catch s.len;
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

fn float(v: ?std.json.Value) ?f64 {
  return switch (v orelse return null) {
    .integer => |i| @floatFromInt(i),
    .float => |f| f,
    else => null,
  };
}

/// What a device is called: its name, or its address.
fn who(d: std.json.Value) []const u8 {
  if (field(d, "name")) |n| return text(n);
  return text(field(d, "device"));
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
  now: i64,
  a: std.mem.Allocator,
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
    try showDevices(out, field(result, "devices").?.array.items);
  } else if (eq(command, "device")) {
    try showDevice(out, result);
    if (field(result, "readings")) |readings| {
      if (readings.array.items.len > 0) {
        try out.writeAll("readings\n");
        const rows = try readingRows(a, result, readings.array.items, now);
        for (rows) |*r| {
          r.label = try std.fmt.allocPrint(a, "  {s}", .{ r.label });
        }
        try showRows(out, rows);
      }
    }
  } else if (eq(command, "get")) {
    const readings = try chosen(a, err, args[0], result, args[1..]) orelse return failed;
    try showRows(out, try readingRows(a, result, readings, now));
  } else if (eq(command, "read")) {
    if (field(result, "attributes")) |attributes| {
      for (attributes.array.items) |attribute| {
        try showAttribute(out, attribute);
      }
    }
  } else if (eq(command, "write") or eq(command, "report")) {
    for (field(result, "attributes").?.array.items) |attribute| {
      const status = integer(field(attribute, "status")) orelse 0;
      if (status != 0) {
        try out.print("0x{x:0>4}: refused, status 0x{x:0>2}\n", .{
          @as(u64, @intCast(integer(field(attribute, "id")) orelse 0)),
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

/// The devices, one per line, under a header: what they are called, their model, and what they
/// last reported, the first three readings, or how far their setup is.
fn showDevices(out: *Io.Writer, devices: []const std.json.Value) !void {
  var name_width: usize = "NAME".len;
  var model_width: usize = "MODEL".len;
  for (devices) |d| {
    name_width = @max(name_width, width(who(d)));
    model_width = @max(model_width, width(text(field(d, "model"))));
  }
  try out.writeAll("NAME");
  try out.splatByteAll(' ', name_width - "NAME".len + 2);
  try out.writeAll("MODEL");
  try out.splatByteAll(' ', model_width - "MODEL".len + 2);
  try out.writeAll("READINGS\n");
  for (devices) |d| {
    try out.writeAll(who(d));
    try out.splatByteAll(' ', name_width - width(who(d)) + 2);
    const model = if (field(d, "model")) |m| text(m) else "?";
    try out.writeAll(model);
    try out.splatByteAll(' ', model_width - width(model) + 2);
    var parts: usize = 0;
    const setup = text(field(d, "setup"));
    if (!eq(setup, "ready")) {
      try out.print("setup {s}", .{ setup });
      parts += 1;
    }
    var shown: usize = 0;
    if (field(d, "readings")) |readings| {
      for (readings.array.items) |r| {
        if (shown == 3) break;
        if (float(field(r, "scaled")) == null) continue;
        if (parts > 0) {
          try out.writeAll(", ");
        }
        try writeReading(out, r, .summary);
        parts += 1;
        shown += 1;
      }
    }
    if (parts == 0) {
      try out.writeByte('-');
    }
    try out.writeByte('\n');
  }
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
  if (float(field(a, "scaled")) != null) {
    try out.writeAll(", ");
    try writeReading(out, a, .summary);
  }
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

/// An event on a line: its time, then what happened, to which device: `plug: power 11.2 W`.
fn showEvent(out: *Io.Writer, e: std.json.Value) !void {
  const event = text(field(e, "event"));
  try out.print("{s} ", .{ text(field(e, "time")) });
  if (field(e, "device") != null) {
    try out.print("{s}: ", .{ who(e) });
  }
  if (eq(event, "attributes")) {
    for (field(e, "attributes").?.array.items, 0..) |attribute, i| {
      if (i > 0) {
        try out.writeAll(", ");
      }
      if (float(field(attribute, "scaled")) != null) {
        try writeReading(out, attribute, .summary);
      } else {
        try out.print("{d}/0x{x:0>4} 0x{x:0>4} = ", .{
          integer(field(e, "endpoint")) orelse 0,
          @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
          @as(u64, @intCast(integer(field(attribute, "id")) orelse 0)),
        });
        try showValue(out, attribute);
      }
    }
  } else if (eq(event, "command")) {
    try out.print("command 0x{x:0>2} on {d}/0x{x:0>4}", .{
      @as(u64, @intCast(integer(field(e, "command")) orelse 0)),
      integer(field(e, "endpoint")) orelse 0,
      @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
    });
    const payload = text(field(e, "payload"));
    if (payload.len > 0) {
      try out.print(", payload {s}", .{ payload });
    }
  } else if (eq(event, "permit_join")) {
    const seconds = integer(field(e, "seconds")) orelse 0;
    if (seconds == 0) {
      try out.writeAll("devices may no longer join");
    } else {
      try out.print("devices may join for {d} s", .{ seconds });
    }
  } else if (eq(event, "network_up")) {
    try out.print("network up ({s}): channel {d}, PAN ID 0x{x:0>4}", .{
      text(field(e, "origin")),
      integer(field(e, "channel")) orelse 0,
      @as(u64, @intCast(integer(field(e, "pan_id")) orelse 0)),
    });
  } else if (eq(event, "network_down")) {
    try out.print("network down: {s}", .{ text(field(e, "error")) });
  } else if (eq(event, "device_joined")) {
    try out.writeAll("joined");
  } else if (eq(event, "device_ready")) {
    try out.writeAll("ready");
  } else if (eq(event, "device_left")) {
    const removed = if (field(e, "removed")) |r| r == .bool and r.bool else false;
    try out.writeAll(if (removed) "removed" else "left");
  } else if (eq(event, "device_setup_failed")) {
    try out.writeAll("setup failed");
    if (field(e, "error")) |x| {
      try out.print(": {s}", .{ text(x) });
    }
    if (integer(field(e, "status"))) |s| {
      try out.print(": status 0x{x:0>2}", .{ @as(u64, @intCast(s)) });
    }
  } else if (eq(event, "device_renamed")) {
    try out.writeAll(if (field(e, "name") == null) "name forgotten" else "renamed");
    if (field(e, "old_name")) |o| {
      try out.print(", was {s}", .{ text(o) });
    }
  } else {
    try out.writeAll(event);
  }
  try out.writeByte('\n');
}

const testing = std.testing;

test "times from skepd are read to the millisecond" {
  try testing.expectEqual(0, parseTime("1970-01-01T00:00:00.000Z"));
  try testing.expectEqual(951_782_400_000, parseTime("2000-02-29T00:00:00.000Z"));
  try testing.expectEqual(1_794_865_152_250, parseTime("2026-11-16T21:39:12.250Z"));
  try testing.expectEqual(null, parseTime("2026-11-16 21:39:12"));
  try testing.expectEqual(null, parseTime("2026-13-16T21:39:12.250Z"));
}

test "readings are written short, in their units" {
  var buffer: [64]u8 = undefined;
  for ([_]struct { f64, []const u8 }{
    .{ 21.54, "21.54" },
    .{ 237.9, "237.9" },
    .{ 100, "100" },
    .{ 3.3, "3.3" },
    .{ 0.0012002777, "0.0012" },
    .{ 50.39370078740158, "50.39" },
    .{ -4.5, "-4.5" },
    .{ 0, "0" },
    .{ 12345.6, "12346" },
  }) |case| {
    var w: Io.Writer = .fixed(&buffer);
    try writeNumber(&w, case[0]);
    try testing.expectEqualStrings(case[1], w.buffered());
  }
  const temperature = try std.json.parseFromSlice(
    std.json.Value,
    testing.allocator,
    "{\"reading\": \"temperature\", \"scaled\": 21.54, \"unit\": \"°C\"}",
    .{},
  );
  defer temperature.deinit();
  const on = try std.json.parseFromSlice(
    std.json.Value,
    testing.allocator,
    "{\"reading\": \"on\", \"scaled\": 1, \"unit\": \"\"}",
    .{},
  );
  defer on.deinit();
  for ([_]struct { std.json.Value, Style, []const u8 }{
    .{ temperature.value, .table, "21.54 °C" },
    .{ temperature.value, .summary, "temperature 21.54 °C" },
    .{ on.value, .table, "yes" },
    .{ on.value, .summary, "on" },
  }) |case| {
    var w: Io.Writer = .fixed(&buffer);
    try writeReading(&w, case[0], case[1]);
    try testing.expectEqualStrings(case[2], w.buffered());
  }
  const a = testing.allocator;
  for ([_]struct { i64, []const u8 }{
    .{ -5, "0 s ago" },
    .{ 59_999, "59 s ago" },
    .{ 120_000, "2 min ago" },
    .{ 3 * 3600_000, "3 h ago" },
    .{ 49 * 3600_000, "2 d ago" },
  }) |case| {
    const s = try ago(a, case[0]);
    defer a.free(s);
    try testing.expectEqualStrings(case[1], s);
  }
}
