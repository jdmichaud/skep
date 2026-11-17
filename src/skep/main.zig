//! skep: the command-line client of skepd. It turns its arguments into a request of
//! skep-protocol(7), sends it on skepd's socket, and prints the answer, or the events it watches.
//! It holds no Zigbee logic of its own: skepd, and libskep behind it, do the work.

const std = @import("std");
const build_options = @import("build_options");
const commands = @import("commands.zig");
const output = @import("output.zig");

const Row = output.Row;
const chosen = output.chosen;
const field = output.field;
const integer = output.integer;
const items = output.items;
const label = output.label;
const readingText = output.readingText;
const showEvent = output.showEvent;
const showRows = output.showRows;
const statusOf = output.statusOf;
const text = output.text;
const writeError = output.writeError;

const linux = std.os.linux;
const Io = std.Io;

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
  const given = try init.minimal.args.toSlice(arena);
  const args = try arena.alloc([]const u8, given.len -| 1);
  for (args, given[1..]) |*arg, typed| {
    arg.* = typed;
  }
  const call = switch (try commands.parse(arena, args)) {
    .help => |command| {
      if (command) |c| {
        try commands.writeHelp(out, c);
      } else {
        try commands.writeUsage(out);
      }
      return ok;
    },
    .version => {
      try out.writeAll("skep " ++ build_options.version ++ "\n");
      return ok;
    },
    .problem => |p| {
      try commands.writeProblem(err, p);
      return misused;
    },
    .call => |call| call,
  };
  var request: Io.Writer.Allocating = .init(arena);
  try commands.writeRequest(&request.writer, &call);

  const fd = connect(arena, init.environ_map, call.global.socket, err) catch return failed;
  defer _ = linux.close(fd);
  try sendAll(fd, request.written());

  var client: Client = .{ .fd = fd, .arena = arena };
  if (call.form.flow == .watch) return watch(&client, init.gpa, out, err, call.global.json);
  // The request is all, except for reads of readings, which need the device first: skepd
  // answers, then closes.
  const by_reading = call.form.flow == .read_readings;
  if (!by_reading) {
    _ = linux.shutdown(fd, linux.SHUT.WR);
  }
  const line = (try client.nextLine()) orelse {
    try err.print("skep {s}: skepd closed the connection without answering\n", .{ call.name });
    return failed;
  };
  if (call.global.json and !by_reading) {
    try out.print("{s}\n", .{ line });
  }
  const response = output.parse(arena, line) catch {
    try err.print("skep {s}: skepd answered something that is not JSON\n", .{ call.name });
    return failed;
  };
  if (field(response, "error")) |e| {
    try writeError(err, call.name, e);
    return failed;
  }
  const result = field(response, "result") orelse {
    try err.print("skep {s}: skepd answered without a result\n", .{ call.name });
    return failed;
  };
  if (by_reading) return readReadings(&client, out, err, &call, result);
  if (call.global.json) return statusOf(result);
  const now: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
  return output.answer(
    &.{ .out = out, .err = err, .call = &call, .result = result, .now = now, .a = arena },
  );
}

fn eq(a: []const u8, b: []const u8) bool {
  return std.mem.eql(u8, a, b);
}

// Talking to skepd.

/// Connects to skepd's socket: the one given, $SKEP_SOCKET, or the usual places. Says why it
/// cannot, then fails.
fn connect(
  arena: std.mem.Allocator,
  environ: *const std.process.Environ.Map,
  given: ?[]const u8,
  err: *Io.Writer,
) !linux.fd_t {
  var paths: std.ArrayList([]const u8) = .empty;
  // A socket asked for is the only one tried: falling back to another would act on another
  // network than the one meant.
  if (given orelse environ.get("SKEP_SOCKET")) |path| {
    try paths.append(arena, path);
  } else {
    if (environ.get("XDG_RUNTIME_DIR")) |dir| {
      try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/skep/skepd.sock", .{ dir }));
    }
    try paths.append(arena, "/run/skep/skepd.sock");
  }
  // The most telling reason, from the socket it comes from: one skep may not use, then one
  // nothing listens on, then none at all.
  var denied: ?[]const u8 = null;
  var refused: ?[]const u8 = null;
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
    switch (e) {
      .ACCES, .PERM => denied = denied orelse path,
      .CONNREFUSED => refused = refused orelse path,
      else => {},
    }
  }
  if (denied) |path| {
    try err.print(
      "skep: cannot use skepd's socket {s}: permission denied; the system's skepd lets the skep group in\n",
      .{ path },
    );
  } else if (refused) |path| {
    try err.print("skep: nothing answers on {s}; is skepd running?\n", .{ path });
  } else {
    try err.writeAll("skep: no skepd socket at");
    for (paths.items, 0..) |path, i| {
      try err.print("{s} {s}", .{
        if (i == 0) "" else if (i + 1 == paths.items.len) " or" else ",",
        path,
      });
    }
    try err.writeAll("; is skepd running?\n");
  }
  return error.Unreachable;
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
      // The lines taken are dropped before reading more: watch reads for ever.
      const rest = c.buffer.items.len - c.start;
      std.mem.copyForwards(u8, c.buffer.items[0..rest], c.buffer.items[c.start..]);
      c.buffer.items.len = rest;
      c.start = 0;
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

fn watch(
  client: *Client,
  gpa: std.mem.Allocator,
  out: *Io.Writer,
  err: *Io.Writer,
  json: bool,
) !u8 {
  // What an event takes to print, freed after it: watch runs for ever.
  var scratch: std.heap.ArenaAllocator = .init(gpa);
  defer scratch.deinit();
  while (try client.nextLine()) |line| {
    _ = scratch.reset(.retain_capacity);
    if (json) {
      try out.print("{s}\n", .{ line });
    } else {
      const message = output.parse(scratch.allocator(), line) catch continue;
      if (field(message, "error")) |e| {
        try writeError(err, "watch", e);
        return failed;
      }
      if (field(message, "event") != null) {
        try showEvent(out, message);
      }
    }
    try out.flush();
  }
  try err.writeAll("skep watch: skepd closed the connection\n");
  return failed;
}

/// `read <device> <reading>...`: with the device's readings, which skepd gave, reads them from the
/// device, one request per cluster, and prints them as `get` does.
fn readReadings(
  client: *Client,
  out: *Io.Writer,
  err: *Io.Writer,
  call: *const commands.Call,
  device: std.json.Value,
) !u8 {
  const a = client.arena;
  const device_name = call.get("device").?;
  const wanted = try chosen(a, err, call.name, device_name, device, call.all("reading")) orelse
    return failed;
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
    try commands.writeTarget(
      &j,
      device_name,
      @intCast(integer(field(g, "endpoint")) orelse 0),
      @intCast(integer(field(g, "cluster")) orelse 0),
      call.global.timeout,
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
      try err.print("skep {s}: skepd closed the connection without answering\n", .{ call.name });
      return failed;
    };
    if (call.global.json) {
      try out.print("{s}\n", .{ line });
    }
    const response = output.parse(a, line) catch continue;
    const id = integer(field(response, "id")) orelse continue;
    if (id < 2 or id - 2 >= answers.len) continue;
    const k: usize = @intCast(id - 2);
    left -= 1;
    if (field(response, "error")) |e| {
      try writeError(err, call.name, e);
      status = failed;
    } else if (field(response, "result")) |result| {
      answers[k] = result;
      if (statusOf(result) != ok) {
        status = failed;
      }
    }
  }
  if (call.global.json) return status;

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
    for (items(attributes)) |attribute| {
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

test "a socket asked for is the only one tried" {
  var tmp = std.testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [128]u8 = undefined;
  // In /tmp: the build directory may be on a filesystem without sockets, such as sshfs.
  const dir = try std.fmt.bufPrintSentinel(&buffer, "/tmp/skep-test-{s}", .{ &tmp.sub_path }, 0);
  _ = linux.mkdir(dir, 0o700);
  defer _ = linux.rmdir(dir);
  var skep_buffer: [160]u8 = undefined;
  const skep_dir = try std.fmt.bufPrintSentinel(&skep_buffer, "{s}/skep", .{ dir }, 0);
  _ = linux.mkdir(skep_dir, 0o700);
  defer _ = linux.rmdir(skep_dir);
  // A skepd at the default path.
  var path_buffer: [192]u8 = undefined;
  const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/skepd.sock", .{ skep_dir }, 0);
  const listener: linux.fd_t = @intCast(
    linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0),
  );
  defer _ = linux.close(listener);
  var address: linux.sockaddr.un = .{ .path = @splat(0) };
  @memcpy(address.path[0..path.len], path);
  try std.testing.expectEqual(
    .SUCCESS,
    linux.errno(linux.bind(listener, @ptrCast(&address), @sizeOf(linux.sockaddr.un))),
  );
  defer _ = linux.unlink(path);
  try std.testing.expectEqual(.SUCCESS, linux.errno(linux.listen(listener, 1)));

  var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
  defer arena.deinit();
  var environ: std.process.Environ.Map = .init(std.testing.allocator);
  defer environ.deinit();
  try environ.put("XDG_RUNTIME_DIR", dir);
  var err_buffer: [256]u8 = undefined;
  var err: Io.Writer = .fixed(&err_buffer);
  // Found by default.
  _ = linux.close(try connect(arena.allocator(), &environ, null, &err));
  // Not when another is asked for, by the environment or by --socket.
  try environ.put("SKEP_SOCKET", "/tmp/skep-test-none/skepd.sock");
  try std.testing.expectError(error.Unreachable, connect(arena.allocator(), &environ, null, &err));
  try std.testing.expectEqualStrings(
    "skep: no skepd socket at /tmp/skep-test-none/skepd.sock; is skepd running?\n",
    err.buffered(),
  );
  err.end = 0;
  try std.testing.expectError(
    error.Unreachable,
    connect(arena.allocator(), &environ, "/tmp/skep-test-none/other.sock", &err),
  );
}

test {
  _ = commands;
  _ = output;
}
