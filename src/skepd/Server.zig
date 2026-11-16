//! skepd's side of its Unix socket: listening, accepting clients, cutting what they send into
//! lines, and holding what is to be written to them until they can take it. What the lines say is
//! the protocol's business, in protocol.zig.

const std = @import("std");

const linux = std.os.linux;

const Server = @This();

gpa: std.mem.Allocator,
fd: linux.fd_t,
/// The socket's path, to remove it when done.
path: [:0]const u8,
clients: std.ArrayList(*Client) = .empty,
next_client: u32 = 1,

/// Longest line a client may send, its newline included.
pub const max_line = 65536;
/// Most a client may leave unread before it is dropped: a client that watches events and does
/// not read them must not make skepd hold them forever.
pub const max_unread = 1 << 20;

pub const Client = struct {
  id: u32,
  fd: linux.fd_t,
  input: std.ArrayList(u8) = .empty,
  output: std.ArrayList(u8) = .empty,
  /// Events go to it.
  watching: bool = false,
  /// Requests of it still pending, which the protocol counts.
  pending: u32 = 0,
  /// It shut down its sending side: it makes no more requests, but still gets its answers, and
  /// events if it watches.
  input_closed: bool = false,
  /// It sent a line longer than `max_line`, which the protocol answers before it closes.
  overflowed: bool = false,
  /// To be closed once its output is written: after it sent a line too long, for one.
  close_when_written: bool = false,
  /// It went away, or cannot take its output: dropped at once.
  closing: bool = false,

  /// The next whole line it sent, without its newline, if there is one; `consumeLine` removes
  /// it once handled.
  pub fn nextLine(c: *const Client) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, c.input.items, '\n') orelse return null;
    return c.input.items[0..end];
  }

  pub fn consumeLine(c: *Client) void {
    const end = std.mem.indexOfScalar(u8, c.input.items, '\n').?;
    const rest = c.input.items.len - (end + 1);
    std.mem.copyForwards(u8, c.input.items[0..rest], c.input.items[end + 1..]);
    c.input.items.len = rest;
  }
};

pub const OpenError = error{
  /// Another skepd answers on the socket.
  InUse,
  /// A path longer than a Unix socket address holds.
  NameTooLong,
  OutOfMemory,
  /// A system call failed, as `errno` tells.
  System,
};

/// Listens on `path`, creating the directory it is in, readable by its owner only. A socket left
/// there by a skepd that is gone is replaced; one that another skepd answers on is not.
pub fn open(gpa: std.mem.Allocator, path: []const u8, errno: *linux.E) OpenError!Server {
  var address: linux.sockaddr.un = .{ .path = @splat(0) };
  if (path.len >= address.path.len) return error.NameTooLong;
  @memcpy(address.path[0..path.len], path);
  const owned = try gpa.dupeSentinel(u8, path, 0);
  errdefer gpa.free(owned);

  if (std.fs.path.dirname(path)) |dir| {
    var buffer: [linux.PATH_MAX]u8 = undefined;
    const dir_z = std.fmt.bufPrintSentinel(&buffer, "{s}", .{ dir }, 0) catch
      return error.NameTooLong;
    const made = linux.errno(linux.mkdir(dir_z, 0o700));
    if (made != .SUCCESS and made != .EXIST) return fail(errno, made);
  }
  if (answers(&address)) return error.InUse;
  _ = linux.unlink(owned);

  const rc = linux.socket(
    linux.AF.UNIX,
    linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
    0,
  );
  if (linux.errno(rc) != .SUCCESS) return fail(errno, linux.errno(rc));
  const fd: linux.fd_t = @intCast(rc);
  errdefer _ = linux.close(fd);
  const bound = linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)));
  if (bound != .SUCCESS) return fail(errno, bound);
  // Who may connect is the directory's business: its owner, and its group for a system service.
  _ = linux.chmod(owned, 0o660);
  const listening = linux.errno(linux.listen(fd, 16));
  if (listening != .SUCCESS) return fail(errno, listening);
  return .{ .gpa = gpa, .fd = fd, .path = owned };
}

fn fail(errno: *linux.E, e: linux.E) OpenError {
  errno.* = e;
  return error.System;
}

/// Whether something accepts connections at `address`.
fn answers(address: *const linux.sockaddr.un) bool {
  const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
  if (linux.errno(rc) != .SUCCESS) return false;
  const fd: linux.fd_t = @intCast(rc);
  defer _ = linux.close(fd);
  return linux.errno(linux.connect(fd, @ptrCast(address), @sizeOf(linux.sockaddr.un))) == .SUCCESS;
}

pub fn deinit(s: *Server) void {
  while (s.clients.items.len > 0) {
    s.drop(s.clients.items[s.clients.items.len - 1]);
  }
  s.clients.deinit(s.gpa);
  _ = linux.close(s.fd);
  _ = linux.unlink(s.path);
  s.gpa.free(s.path);
}

/// Accepts the clients waiting to connect.
pub fn accept(s: *Server) error{ OutOfMemory }!void {
  while (true) {
    const rc = linux.accept4(s.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    const client = s.gpa.create(Client) catch |e| {
      _ = linux.close(fd);
      return e;
    };
    client.* = .{ .id = s.next_client, .fd = fd };
    s.next_client +%= 1;
    s.clients.append(s.gpa, client) catch |e| {
      _ = linux.close(fd);
      s.gpa.destroy(client);
      return e;
    };
  }
}

/// Reads what a client sent. A client that shut down its sending side has `input_closed` set; one
/// that sends a line too long, `overflowed`.
pub fn read(s: *Server, c: *Client) void {
  var buffer: [4096]u8 = undefined;
  while (!c.closing and !c.input_closed and !c.overflowed) {
    const n = linux.read(c.fd, &buffer, buffer.len);
    switch (linux.errno(n)) {
      .SUCCESS => {},
      .INTR => continue,
      .AGAIN => return,
      else => {
        c.closing = true;
        return;
      },
    }
    if (n == 0) {
      c.input_closed = true;
      return;
    }
    c.input.appendSlice(s.gpa, buffer[0..n]) catch {
      c.closing = true;
      return;
    };
    // A line too long: there is no telling where the next one starts.
    if (c.nextLine() == null and c.input.items.len >= max_line) {
      c.overflowed = true;
    }
  }
}

/// Queues a line for a client: `line` and a newline. A client that leaves too much unread is set
/// to close.
pub fn send(s: *Server, c: *Client, line: []const u8) void {
  if (c.closing) return;
  if (c.output.items.len + line.len + 1 > max_unread) {
    c.closing = true;
    c.output.clearRetainingCapacity();
    return;
  }
  c.output.ensureUnusedCapacity(s.gpa, line.len + 1) catch {
    c.closing = true;
    return;
  };
  c.output.appendSliceAssumeCapacity(line);
  c.output.appendAssumeCapacity('\n');
}

/// Writes what a client can take of its output.
pub fn flush(c: *Client) void {
  while (c.output.items.len > 0) {
    const n = linux.write(c.fd, c.output.items.ptr, c.output.items.len);
    switch (linux.errno(n)) {
      .SUCCESS => {},
      .INTR => continue,
      .AGAIN => return,
      else => {
        c.closing = true;
        c.output.clearRetainingCapacity();
        return;
      },
    }
    const rest = c.output.items.len - n;
    std.mem.copyForwards(u8, c.output.items[0..rest], c.output.items[n..]);
    c.output.items.len = rest;
  }
}

/// Disconnects a client.
pub fn drop(s: *Server, c: *Client) void {
  _ = linux.close(c.fd);
  c.input.deinit(s.gpa);
  c.output.deinit(s.gpa);
  for (s.clients.items, 0..) |known, i| {
    if (known == c) {
      _ = s.clients.orderedRemove(i);
      break;
    }
  }
  s.gpa.destroy(c);
}

/// Whether a client is done with: it must go, or it made its last request, has its answers and
/// does not watch; and its output is written.
pub fn finished(c: *const Client) bool {
  if (c.closing) return true;
  if (c.output.items.len > 0) return false;
  return c.close_when_written or
    (c.input_closed and c.pending == 0 and !c.watching and c.nextLine() == null);
}

const testing = std.testing;

/// Removes the directory of a test's socket, once the socket is gone.
fn removeDirectory(path: [:0]const u8) void {
  var buffer: [128]u8 = undefined;
  const dir = std.fmt.bufPrintSentinel(&buffer, "{s}", .{ std.fs.path.dirname(path).? }, 0) catch
    return;
  _ = linux.rmdir(dir);
}

/// Connects to `path` as a client would.
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

test "clients connect, send lines and get answers" {
  var tmp = testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [128]u8 = undefined;
  // In /tmp: the build directory may be on a filesystem without sockets, such as sshfs.
  const path = try std.fmt.bufPrintSentinel(
    &buffer,
    "/tmp/skep-test-{s}/skepd.sock",
    .{ &tmp.sub_path },
    0,
  );
  defer removeDirectory(path);
  var errno: linux.E = .SUCCESS;
  var server = try open(testing.allocator, path, &errno);
  defer server.deinit();

  const fd = try connect(path);
  defer _ = linux.close(fd);
  try server.accept();
  try testing.expectEqual(1, server.clients.items.len);
  const client = server.clients.items[0];
  const request = "{\"id\": 1, \"method\": \"version\"}\n{\"id\": 2";
  _ = linux.write(fd, request.ptr, request.len);
  server.read(client);
  try testing.expectEqualStrings("{\"id\": 1, \"method\": \"version\"}", client.nextLine().?);
  client.consumeLine();
  // The second line is not whole yet.
  try testing.expectEqual(null, client.nextLine());

  server.send(client, "{\"id\": 1, \"result\": {}}");
  flush(client);
  var answer: [64]u8 = undefined;
  const n = linux.read(fd, &answer, answer.len);
  try testing.expectEqualStrings("{\"id\": 1, \"result\": {}}\n", answer[0..n]);

  // The client shuts down its sending side: no more requests, but it gets its answers.
  _ = linux.shutdown(fd, linux.SHUT.WR);
  server.read(client);
  try testing.expect(client.input_closed);
  try testing.expect(!client.closing);
  client.pending = 1;
  try testing.expect(!finished(client));
  client.pending = 0;
  try testing.expect(finished(client));
  server.drop(client);
  try testing.expectEqual(0, server.clients.items.len);

  // Another skepd on the same socket is refused.
  try testing.expectError(error.InUse, open(testing.allocator, path, &errno));
}

test "a line too long closes the client" {
  var tmp = testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [128]u8 = undefined;
  const path = try std.fmt.bufPrintSentinel(
    &buffer,
    "/tmp/skep-test-{s}/skepd.sock",
    .{ &tmp.sub_path },
    0,
  );
  defer removeDirectory(path);
  var errno: linux.E = .SUCCESS;
  var server = try open(testing.allocator, path, &errno);
  defer server.deinit();
  const fd = try connect(path);
  defer _ = linux.close(fd);
  try server.accept();
  const long: [4096]u8 = @splat('x');
  var written: usize = 0;
  while (written < max_line) {
    server.read(server.clients.items[0]);
    written += linux.write(fd, &long, long.len);
  }
  server.read(server.clients.items[0]);
  try testing.expect(server.clients.items[0].overflowed);
}
