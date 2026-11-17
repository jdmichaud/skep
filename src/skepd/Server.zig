//! skepd's side of its Unix socket: listening, accepting clients, cutting what they send into
//! lines, and holding what is to be written to them until they can take it. What the lines say is
//! the protocol's business, in protocol.zig.
//!
//! What a client may cost is bounded, so that a client that floods skepd, or never reads, delays
//! the others, the dongle and signals by a turn of the loop at most: `max_line` of input read at a
//! time, read only once the lines before are handled, `max_unread` of output, and `max_clients`.

const std = @import("std");

const linux = std.os.linux;

const Server = @This();

gpa: std.mem.Allocator,
fd: linux.fd_t,
/// The socket's path, to remove it when done.
path: [:0]const u8,
clients: std.ArrayList(*Client) = .empty,
next_client: u32 = 1,
/// When to accept clients again, after the system ran out of what a client takes.
accept_after: u64 = 0,

/// Longest line a client may send, its newline included.
pub const max_line = 65536;
/// Most a client may leave unread, besides the line being added, before it is dropped: a client
/// that watches events and does not read them must not make skepd hold them forever.
pub const max_unread = 1 << 20;
/// Most clients at once. Others wait to connect.
pub const max_clients = 32;
/// How long to wait before accepting again when the system cannot take a client, in ms: the
/// listening socket stays readable, and polling it again at once would spin.
const accept_pause = 1000;

pub const Client = struct {
  id: u32,
  fd: linux.fd_t,
  /// What it sent: `handled` bytes of lines handled, then what is left.
  input: std.ArrayList(u8) = .empty,
  handled: usize = 0,
  output: std.ArrayList(u8) = .empty,
  /// It shut down its sending side: it makes no more requests, but still gets its answers, and
  /// events if it watches.
  input_closed: bool = false,
  /// It sent a line longer than `max_line`, which the protocol answers before it closes.
  overflowed: bool = false,
  /// To be closed once its output is written: after it sent a line too long, for one.
  close_when_written: bool = false,
  /// It went away, or cannot take its output: dropped at once.
  closing: bool = false,

  /// The next whole line it sent, without its newline, if there is one; `consumeLine` passes it
  /// once handled.
  pub fn nextLine(c: *const Client) ?[]const u8 {
    const rest = c.input.items[c.handled..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
    return rest[0..end];
  }

  pub fn consumeLine(c: *Client) void {
    c.handled += c.nextLine().?.len + 1;
  }

  /// Drops the lines handled from its input. Once per turn: dropping each line as it is handled
  /// would copy the rest of the input as many times.
  pub fn compact(c: *Client) void {
    const rest = c.input.items.len - c.handled;
    std.mem.copyForwards(u8, c.input.items[0..rest], c.input.items[c.handled..]);
    c.input.items.len = rest;
    c.handled = 0;
  }

  /// Whether to read what it sends: not before the lines it sent are handled.
  fn reading(c: *const Client) bool {
    return !c.closing and !c.input_closed and !c.overflowed and c.nextLine() == null;
  }
};

pub const OpenError = error{
  /// Another skepd answers on the socket.
  InUse,
  /// Something other than a socket is at the path: not skepd's to replace.
  NotSocket,
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
  // A socket left by a skepd that is gone is replaced; anything else is left alone.
  var st: linux.Statx = undefined;
  switch (linux.errno(
    linux.statx(linux.AT.FDCWD, owned, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st),
  )) {
    .SUCCESS => {
      if (st.mode & linux.S.IFMT != linux.S.IFSOCK) return error.NotSocket;
      _ = linux.unlink(owned);
    },
    .NOENT => {},
    else => |e| return fail(errno, e),
  }

  const rc = linux.socket(
    linux.AF.UNIX,
    linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
    0,
  );
  if (linux.errno(rc) != .SUCCESS) return fail(errno, linux.errno(rc));
  const fd: linux.fd_t = @intCast(rc);
  errdefer _ = linux.close(fd);
  // Who may connect is the directory's business: its owner, and its group for a system service.
  // The socket is made readable and writable by both as it is created: setting its mode after,
  // by its path, would follow whatever replaced it there meanwhile.
  const umask = linux.syscall1(.umask, 0o117);
  const bound = linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)));
  _ = linux.syscall1(.umask, umask);
  if (bound != .SUCCESS) return fail(errno, bound);
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

pub const AcceptError = error{
  OutOfMemory,
  /// The system or skepd ran out of file descriptors, or memory: accepting resumes a moment
  /// later.
  SystemResources,
};

/// Accepts the clients waiting to connect, `max_clients` at most.
fn accept(s: *Server, now: u64) AcceptError!void {
  while (s.clients.items.len < max_clients) {
    const rc = linux.accept4(s.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    switch (linux.errno(rc)) {
      .SUCCESS => {},
      .MFILE, .NFILE, .NOBUFS, .NOMEM => {
        s.accept_after = now + accept_pause;
        return error.SystemResources;
      },
      // None waiting, or one that gave up waiting.
      else => return,
    }
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

/// Appends what to poll: the listening socket, then the clients, in order.
pub fn pollFds(
  s: *const Server,
  gpa: std.mem.Allocator,
  fds: *std.ArrayList(linux.pollfd),
  now: u64,
) error{ OutOfMemory }!void {
  const accepting = s.clients.items.len < max_clients and now >= s.accept_after;
  try fds.append(gpa, .{
    .fd = if (accepting) s.fd else -1,
    .events = linux.POLL.IN,
    .revents = 0,
  });
  for (s.clients.items) |c| {
    var events: i16 = 0;
    if (c.reading()) {
      events |= linux.POLL.IN;
    }
    if (c.output.items.len > 0) {
      events |= linux.POLL.OUT;
    }
    try fds.append(gpa, .{ .fd = c.fd, .events = events, .revents = 0 });
  }
}

/// Does what poll found, given the descriptors `pollFds` appended: reads the clients, and
/// accepts new ones.
pub fn polled(s: *Server, fds: []const linux.pollfd, now: u64) AcceptError!void {
  // The clients polled are the first ones of the list, which accepting only adds to.
  for (fds[1..], 0..) |fd, i| {
    const c = s.clients.items[i];
    // Gone altogether, not only done sending: what it asked is canceled.
    if (fd.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) {
      c.closing = true;
    } else if (fd.revents & linux.POLL.IN != 0) {
      s.read(c);
    }
  }
  if (fds[0].revents & linux.POLL.IN != 0) {
    try s.accept(now);
  }
}

/// Whether a client sent lines not handled yet: the loop is not to wait for more.
pub fn hasLines(s: *const Server) bool {
  for (s.clients.items) |c| {
    if (!c.closing and c.nextLine() != null) return true;
  }
  return false;
}

/// Reads what a client sent, up to a whole line, or `max_line`. A client that shut down its
/// sending side has `input_closed` set; one that sends a line too long, `overflowed`.
pub fn read(s: *Server, c: *Client) void {
  var buffer: [4096]u8 = undefined;
  while (c.reading()) {
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
    if (c.nextLine() == null and c.input.items.len - c.handled >= max_line) {
      c.overflowed = true;
    }
  }
}

/// Queues a line for a client: `line` and a newline. A client that leaves too much unread is set
/// to close.
pub fn send(s: *Server, c: *Client, line: []const u8) void {
  if (c.closing) return;
  if (c.output.items.len > max_unread) {
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
    // Not write(): to a client that went away, it raises SIGPIPE, which would end skepd.
    const n = linux.sendto(
      c.fd,
      c.output.items.ptr,
      c.output.items.len,
      linux.MSG.NOSIGNAL,
      null,
      0,
    );
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

/// Whether a client is done with: it must go; or its output is written, and it is to close, or it
/// made its last request and is `owed` nothing more, neither answers nor events.
pub fn finished(c: *const Client, owed: bool) bool {
  if (c.closing) return true;
  if (c.output.items.len > 0) return false;
  return c.close_when_written or (c.input_closed and !owed and c.nextLine() == null);
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
  try server.accept(0);
  try testing.expectEqual(1, server.clients.items.len);
  const client = server.clients.items[0];
  const request = "{\"id\": 1, \"method\": \"version\"}\n{\"id\": 2";
  _ = linux.write(fd, request.ptr, request.len);
  server.read(client);
  try testing.expectEqualStrings("{\"id\": 1, \"method\": \"version\"}", client.nextLine().?);
  // Not read further before the line is handled.
  try testing.expect(!client.reading());
  client.consumeLine();
  // The second line is not whole yet.
  try testing.expectEqual(null, client.nextLine());
  client.compact();
  try testing.expectEqualStrings("{\"id\": 2", client.input.items);

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
  try testing.expect(!finished(client, true));
  try testing.expect(finished(client, false));
  server.drop(client);
  try testing.expectEqual(0, server.clients.items.len);

  // Another skepd on the same socket is refused.
  try testing.expectError(error.InUse, open(testing.allocator, path, &errno));
  // Readable and writable by its owner and group.
  var st: linux.Statx = undefined;
  try testing.expectEqual(
    .SUCCESS,
    linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &st)),
  );
  try testing.expectEqual(0o660, st.mode & 0o777);
}

test "a file that is not a socket is not replaced" {
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
  var dir_buffer: [128]u8 = undefined;
  const dir = try std.fmt.bufPrintSentinel(&dir_buffer, "{s}", .{ std.fs.path.dirname(path).? }, 0);
  _ = linux.mkdir(dir, 0o700);
  const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
  try testing.expectEqual(.SUCCESS, linux.errno(rc));
  _ = linux.close(@intCast(rc));
  defer _ = linux.unlink(path);
  var errno: linux.E = .SUCCESS;
  try testing.expectError(error.NotSocket, open(testing.allocator, path, &errno));
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
  try server.accept(0);
  const long: [4096]u8 = @splat('x');
  var written: usize = 0;
  while (written < max_line) {
    server.read(server.clients.items[0]);
    written += linux.write(fd, &long, long.len);
  }
  server.read(server.clients.items[0]);
  try testing.expect(server.clients.items[0].overflowed);
}
