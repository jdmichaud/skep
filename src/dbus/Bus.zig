//! A service on D-Bus, for a program with a poll loop: the objects it publishes, and the
//! connection to the bus that publishes them, which this keeps up. This is the module's
//! interface: a program uses it and nothing else of the module, so that another D-Bus library can
//! replace the module behind it. Its terms are those such libraries share:
//!
//! - What is published: objects, by path below a root, each with interfaces whose properties are
//!   read-only (`put`, `set`, `remove`). The bus's standard interfaces answer from them, and
//!   changes are signalled. With sd-bus, GDBus or zbus, that is an object vtable whose getters
//!   read these values, an object manager at the root, and the signals they emit.
//! - The loop: `pollFd`, `deadline`, `polled` and `advance`, as sd-bus's get_fd, get_events,
//!   get_timeout and process. Time is given, in milliseconds of a monotonic clock.
//! - What happens to the bus, for the program to log: `nextNews`.
//!
//! The bus may not be there, or go away, or refuse the name: the objects are kept, and the bus is
//! tried again later, a second later at first, then less and less often, every 5 minutes at most,
//! and every 5 minutes after a refusal, which the bus's policy changing can lift.

const std = @import("std");
const addresses = @import("address.zig");
const Connection = @import("Connection.zig");
const Service = @import("Service.zig");

const linux = std.os.linux;
const posix = std.posix;

const Bus = @This();

pub const Value = @import("value.zig").Value;
pub const Interface = Service.Interface;
pub const PropertyInfo = Service.PropertyInfo;
pub const Property = Service.Property;
pub const Refusal = Service.Refusal;
/// Invalid: a path, interface or property not declared, or a value of another type than declared:
/// the program's mistake.
pub const Error = Service.Error;

pub const Options = struct {
  /// The well-known name to own, such as `io.github.example.Service1`.
  name: []const u8,
  /// The object implementing ObjectManager, above every object published.
  root: []const u8,
  /// The interfaces of the objects published, with their properties.
  interfaces: []const Interface,
  /// The bus's address, as `systemAddress` and `sessionAddress` give.
  address: []const u8,
};

/// What happened to the bus, told once each time it changes.
pub const News = union(enum) {
  /// The name is the service's: clients see its objects.
  published,
  /// The bus cannot be reached, or went away, as this says: tried again later.
  unavailable: []const u8,
  /// The bus refused the name: asked again later.
  refused: Refusal,
};

/// How long to wait before connecting again, at first and at most, in milliseconds.
pub const min_retry = 1000;
pub const max_retry = 300 * 1000;
const read_size = 16 * 1024;
/// Most reads in a turn of the loop: a bus that sends much delays the program's other work by
/// so much at most.
const reads_per_turn = 4;
/// Most news kept for the program.
const max_news = 8;

gpa: std.mem.Allocator,
service: Service,
bus_address: []u8,
uid: linux.uid_t,
fd: linux.fd_t = -1,
/// When to connect, while not connected.
retry_at: ?u64 = 0,
retry_delay: u64 = min_retry,
news: std.ArrayList(News) = .empty,
/// The last news told, so that news is told once.
told: std.meta.Tag(News) = .published,
told_anything: bool = false,

pub fn init(gpa: std.mem.Allocator, options: Options) Error!Bus {
  var service: Service = try .init(gpa, .{
    .name = options.name,
    .root = options.root,
    .interfaces = options.interfaces,
    .machine_id = readMachineId(),
  });
  errdefer service.deinit();
  return .{
    .gpa = gpa,
    .service = service,
    .bus_address = try gpa.dupe(u8, options.address),
    .uid = linux.getuid(),
  };
}

pub fn deinit(b: *Bus) void {
  b.close();
  b.service.deinit();
  b.gpa.free(b.bus_address);
  b.news.deinit(b.gpa);
}

/// The system bus's address: DBUS_SYSTEM_BUS_ADDRESS, or the usual one.
pub fn systemAddress(environ: *const std.process.Environ.Map) []const u8 {
  return environ.get("DBUS_SYSTEM_BUS_ADDRESS") orelse addresses.default_system;
}

/// The session bus's address, DBUS_SESSION_BUS_ADDRESS, if there is one.
pub fn sessionAddress(environ: *const std.process.Environ.Map) ?[]const u8 {
  const value = environ.get("DBUS_SESSION_BUS_ADDRESS") orelse return null;
  return if (value.len > 0) value else null;
}

/// Publishes the object at `path`, below the root, with `interface`, every property of which
/// `properties` gives; or gives new values to all of its properties if it has it.
pub fn put(
  b: *Bus,
  path: []const u8,
  interface: []const u8,
  properties: []const Property,
) Error!void {
  return b.service.put(path, interface, properties);
}

/// Gives new values to some properties of a published object's interface.
pub fn set(
  b: *Bus,
  path: []const u8,
  interface: []const u8,
  properties: []const Property,
) Error!void {
  return b.service.set(path, interface, properties);
}

/// Removes a published object.
pub fn remove(b: *Bus, path: []const u8) void {
  b.service.remove(path);
}

/// A published property's value, as clients read it.
pub fn get(b: *const Bus, path: []const u8, interface: []const u8, property: []const u8) ?Value {
  return b.service.get(path, interface, property);
}

/// What to poll: the bus's socket, if connected, for reading, and writing if there is output.
pub fn pollFd(b: *const Bus) posix.pollfd {
  if (b.fd < 0) return .{ .fd = -1, .events = 0, .revents = 0 };
  const writing = b.service.pending().len > 0;
  return .{
    .fd = b.fd,
    .events = if (writing) linux.POLL.IN | linux.POLL.OUT else linux.POLL.IN,
    .revents = 0,
  };
}

/// When to call `advance`, if it has something to do: connect again.
pub fn deadline(b: *const Bus) ?u64 {
  return if (b.fd < 0) b.retry_at else null;
}

/// Connects when it is time to.
pub fn advance(b: *Bus, now: u64) void {
  if (b.fd >= 0) return;
  if (now < b.retry_at orelse return) return;
  b.connect(now);
}

/// Reads and writes what the socket is ready for, as `revents` of `pollFd` says, and answers
/// what came.
pub fn polled(b: *Bus, revents: i16, now: u64) void {
  if (b.fd < 0) return;
  if (revents & (linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP) != 0) {
    var buffer: [read_size]u8 = undefined;
    for (0..reads_per_turn) |_| {
      const rc = linux.read(b.fd, &buffer, buffer.len);
      switch (linux.errno(rc)) {
        .SUCCESS => {
          if (rc == 0) return b.lose(now, "the bus closed the connection");
          b.service.received(buffer[0..rc]) catch |e| return b.lose(now, describe(e));
        },
        .AGAIN => break,
        .INTR => {},
        else => |e| return b.lose(now, @tagName(e)),
      }
    }
  }
  b.flush(now);
  if (b.fd < 0) return;
  switch (b.service.state) {
    .published => {
      b.tell(.published);
      b.retry_delay = min_retry;
    },
    .refused => {
      b.tell(.{ .refused = b.service.refusal });
      b.close();
      b.retry_at = now + max_retry;
    },
    else => {},
  }
}

/// The next news of the bus, if any.
pub fn nextNews(b: *Bus) ?News {
  if (b.news.items.len == 0) return null;
  return b.news.orderedRemove(0);
}

fn flush(b: *Bus, now: u64) void {
  if (b.service.failure) |e| return b.lose(now, describe(e));
  while (true) {
    const out = b.service.pending();
    if (out.len == 0) return;
    const rc = linux.sendto(b.fd, out.ptr, out.len, linux.MSG.NOSIGNAL, null, 0);
    switch (linux.errno(rc)) {
      .SUCCESS => b.service.written(rc),
      .AGAIN => return,
      .INTR => {},
      else => |e| return b.lose(now, @tagName(e)),
    }
  }
}

fn connect(b: *Bus, now: u64) void {
  b.retry_at = null;
  const socket = addresses.firstSocket(b.bus_address) orelse
    return b.lose(now, "no Unix socket in the bus's address");
  var sa: linux.sockaddr.un = .{ .path = @splat(0) };
  const name = socket.bytes();
  const len: linux.socklen_t = switch (socket.kind) {
    .path => blk: {
      @memcpy(sa.path[0..name.len], name);
      break :blk @sizeOf(linux.sockaddr.un);
    },
    // A NUL, then the name, which is as long as the address says.
    .abstract => blk: {
      @memcpy(sa.path[1..][0..name.len], name);
      break :blk @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len);
    },
  };
  const rc = linux.socket(
    linux.AF.UNIX,
    linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
    0,
  );
  if (linux.errno(rc) != .SUCCESS) return b.lose(now, @tagName(linux.errno(rc)));
  const fd: linux.fd_t = @intCast(rc);
  const connected = linux.errno(linux.connect(fd, &sa, len));
  if (connected != .SUCCESS) {
    _ = linux.close(fd);
    return b.lose(now, @tagName(connected));
  }
  b.service.connect(b.uid) catch {
    _ = linux.close(fd);
    return b.lose(now, "out of memory");
  };
  b.fd = fd;
}

/// The connection failed, or could not be made: tried again later.
fn lose(b: *Bus, now: u64, why: []const u8) void {
  if (b.service.state == .published) {
    b.retry_delay = min_retry;
  }
  b.close();
  b.tell(.{ .unavailable = why });
  b.retry_at = now + b.retry_delay;
  b.retry_delay = @min(2 * b.retry_delay, max_retry);
}

fn close(b: *Bus) void {
  if (b.fd >= 0) {
    _ = linux.close(b.fd);
  }
  b.fd = -1;
  b.service.disconnect();
}

fn tell(b: *Bus, news: News) void {
  if (b.told_anything and b.told == std.meta.activeTag(news)) return;
  b.told = std.meta.activeTag(news);
  b.told_anything = true;
  if (b.news.items.len == max_news) {
    _ = b.news.orderedRemove(0);
  }
  // Out of memory: news not told.
  b.news.append(b.gpa, news) catch {};
}

fn describe(e: Connection.Error) []const u8 {
  return switch (e) {
    error.Rejected => "the bus refused the connection",
    error.Protocol => "the bus does not speak D-Bus",
    error.Backlog => "the bus does not take what is sent",
    error.OutOfMemory => "out of memory",
  };
}

/// The machine's id, from /etc/machine-id, if it can be read.
fn readMachineId() ?[32]u8 {
  const rc = linux.open("/etc/machine-id", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
  if (linux.errno(rc) != .SUCCESS) return null;
  const fd: linux.fd_t = @intCast(rc);
  defer _ = linux.close(fd);
  var buffer: [33]u8 = undefined;
  const n = linux.read(fd, &buffer, buffer.len);
  if (linux.errno(n) != .SUCCESS or n < 32) return null;
  for (buffer[0..32]) |c| {
    if (!std.ascii.isHex(c)) return null;
  }
  return buffer[0..32].*;
}

const testing = std.testing;
const wire = @import("wire.zig");

const test_interfaces = [_]Interface{.{
  .name = "io.example.Thing1.Device",
  .properties = &.{.{ .name = "Name", .signature = "s" }},
}};

/// A bus played on a socket of its own in /tmp: the build directory may be on a filesystem
/// without sockets, such as sshfs.
const SocketBus = struct {
  tmp: testing.TmpDir,
  path: [96]u8 = undefined,
  path_len: usize = 0,
  listening: linux.fd_t = -1,
  peer: linux.fd_t = -1,
  arena: std.heap.ArenaAllocator,
  serial: u32 = 100,

  fn init() !SocketBus {
    var b: SocketBus = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator) };
    var dir: [80]u8 = undefined;
    const dir_z = try std.fmt.bufPrintSentinel(&dir, "/tmp/skep-test-{s}", .{ &b.tmp.sub_path }, 0);
    _ = linux.mkdir(dir_z, 0o700);
    b.path_len = (try std.fmt.bufPrint(&b.path, "{s}/bus", .{ dir_z })).len;
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(sa.path[0..b.path_len], b.path[0..b.path_len]);
    b.listening = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (linux.errno(linux.bind(b.listening, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) !=
      .SUCCESS) {
      return error.TestUnexpectedResult;
    }
    _ = linux.listen(b.listening, 4);
    return b;
  }

  fn deinit(b: *SocketBus) void {
    if (b.peer >= 0) {
      _ = linux.close(b.peer);
    }
    _ = linux.close(b.listening);
    var buffer: [104]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buffer, "{s}", .{ b.path[0..b.path_len] }, 0) catch
      unreachable;
    _ = linux.unlink(path);
    _ = linux.rmdir(
      std.fmt.bufPrintSentinel(
        &buffer,
        "{s}",
        .{ std.fs.path.dirname(b.path[0..b.path_len]).? },
        0,
      ) catch unreachable,
    );
    b.tmp.cleanup();
    b.arena.deinit();
  }

  fn address(b: *SocketBus) ![]const u8 {
    return std.fmt.allocPrint(b.arena.allocator(), "unix:path={s}", .{ b.path[0..b.path_len] });
  }

  fn accept(b: *SocketBus) void {
    b.peer = @intCast(
      linux.accept4(b.listening, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC),
    );
  }

  /// Lets the service turn: writes what it has, and reads what the bus sent.
  fn turn(b: *SocketBus, bus: *Bus, now: u64) void {
    _ = b;
    var fds = [_]posix.pollfd{ bus.pollFd() };
    _ = posix.poll(&fds, 0) catch unreachable;
    bus.polled(fds[0].revents, now);
  }

  /// What the service wrote.
  fn read(b: *SocketBus) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
      const rc = linux.read(b.peer, &buffer, buffer.len);
      if (linux.errno(rc) != .SUCCESS or rc == 0) break;
      try out.appendSlice(b.arena.allocator(), buffer[0..rc]);
    }
    return out.items;
  }

  fn write(b: *SocketBus, bytes: []const u8) void {
    _ = linux.write(b.peer, bytes.ptr, bytes.len);
  }

  /// Answers the method call `call` with `body`.
  fn reply(b: *SocketBus, call: wire.Message, body: []const Value) !void {
    var bytes: std.ArrayList(u8) = .empty;
    b.serial += 1;
    try wire.encode(
      b.arena.allocator(),
      &bytes,
      .{ .type = .method_return, .reply_serial = call.serial },
      b.serial,
      body,
    );
    b.write(bytes.items);
  }

  /// Plays the bus until the service owns its name.
  fn publish(b: *SocketBus, bus: *Bus) !void {
    b.accept();
    b.turn(bus, 0);
    try testing.expect(std.mem.startsWith(u8, try b.read(), "\x00AUTH EXTERNAL "));
    b.write("OK 0123456789abcdef0123456789abcdef\r\n");
    b.turn(bus, 0);
    b.turn(bus, 0);
    const begin = try b.read();
    try testing.expectEqualStrings("BEGIN\r\n", begin[0..7]);
    const a = b.arena.allocator();
    const hello = try wire.decode(a, begin[7..]);
    try b.reply(hello, &.{.{ .string = ":1.3" }});
    b.turn(bus, 0);
    b.turn(bus, 0);
    const request = try wire.decode(a, try b.read());
    try testing.expectEqualStrings("RequestName", request.member.?);
    try b.reply(request, &.{.{ .uint32 = 1 }});
    b.turn(bus, 0);
  }
};

test "the bus is connected to over its socket, and the name owned" {
  var b: SocketBus = try .init();
  defer b.deinit();
  var bus: Bus = try .init(testing.allocator, .{
    .name = "io.example.Thing1",
    .root = "/io/example/Thing1",
    .interfaces = &test_interfaces,
    .address = try b.address(),
  });
  defer bus.deinit();
  try testing.expectEqual(0, bus.deadline());
  bus.advance(0);
  try testing.expect(bus.pollFd().fd >= 0);
  try testing.expectEqual(null, bus.deadline());
  try b.publish(&bus);
  try testing.expectEqual(News.published, bus.nextNews().?);
  try testing.expectEqual(null, bus.nextNews());

  // A change, signalled over the socket.
  try bus.put(
    "/io/example/Thing1/a",
    "io.example.Thing1.Device",
    &.{.{ .name = "Name", .value = .{ .string = "x" } }},
  );
  try testing.expect(bus.pollFd().events & linux.POLL.OUT != 0);
  b.turn(&bus, 0);
  const added = try wire.decode(b.arena.allocator(), try b.read());
  try testing.expectEqualStrings("InterfacesAdded", added.member.?);

  // The bus going away: told, and connected to again a second later.
  _ = linux.close(b.peer);
  b.peer = -1;
  b.turn(&bus, 5000);
  try testing.expectEqualStrings("the bus closed the connection", bus.nextNews().?.unavailable);
  try testing.expectEqual(5000 + min_retry, bus.deadline());
  bus.advance(5000 + min_retry);
  try b.publish(&bus);
  try testing.expectEqual(News.published, bus.nextNews().?);
  // The objects were kept.
  try testing.expectEqualStrings(
    "x",
    bus.get("/io/example/Thing1/a", "io.example.Thing1.Device", "Name").?.string,
  );
}

test "a bus that is not there is tried again, less and less often, and told once" {
  var bus: Bus = try .init(testing.allocator, .{
    .name = "io.example.Thing1",
    .root = "/io/example/Thing1",
    .interfaces = &test_interfaces,
    .address = "unix:path=/nonexistent/bus",
  });
  defer bus.deinit();
  var now: u64 = 0;
  var delay: u64 = min_retry;
  for (0..12) |_| {
    bus.advance(now);
    try testing.expectEqual(-1, bus.pollFd().fd);
    try testing.expectEqual(now + delay, bus.deadline());
    now += delay;
    delay = @min(2 * delay, max_retry);
  }
  try testing.expectEqual(max_retry, delay);
  try testing.expectEqualStrings("NOENT", bus.nextNews().?.unavailable);
  try testing.expectEqual(null, bus.nextNews());
}

test "the bus's address is taken from the environment" {
  var environ: std.process.Environ.Map = .init(testing.allocator);
  defer environ.deinit();
  try testing.expectEqualStrings(addresses.default_system, systemAddress(&environ));
  try testing.expectEqual(null, sessionAddress(&environ));
  try environ.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus");
  try environ.put("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/run/dbus/x");
  try testing.expectEqualStrings("unix:path=/run/user/1000/bus", sessionAddress(&environ).?);
  try testing.expectEqualStrings("unix:path=/run/dbus/x", systemAddress(&environ));
}
