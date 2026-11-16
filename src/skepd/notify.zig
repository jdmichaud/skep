//! Telling systemd how skepd is doing when it runs as a Type=notify service: sd_notify(3)'s
//! protocol, a datagram of lines such as READY=1 sent to the socket $NOTIFY_SOCKET names.

const std = @import("std");

const linux = std.os.linux;

pub const Notifier = struct {
  fd: ?linux.fd_t = null,
  address: linux.sockaddr.un = .{ .path = @splat(0) },
  len: linux.socklen_t = 0,

  /// A notifier for $NOTIFY_SOCKET, which does nothing when it is not set: skepd not run by
  /// systemd, or not as a Type=notify service.
  pub fn init(environ: *const std.process.Environ.Map) Notifier {
    var n: Notifier = .{};
    const path = environ.get("NOTIFY_SOCKET") orelse return n;
    if (path.len == 0 or path.len >= n.address.path.len) return n;
    // A path, or an abstract address after "@".
    if (path[0] != '/' and path[0] != '@') return n;
    @memcpy(n.address.path[0..path.len], path);
    if (path[0] == '@') {
      n.address.path[0] = 0;
    }
    n.len = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return n;
    n.fd = @intCast(rc);
    return n;
  }

  pub fn deinit(n: *Notifier) void {
    if (n.fd) |fd| {
      _ = linux.close(fd);
    }
    n.fd = null;
  }

  /// Sends lines such as "READY=1" or "STATUS=network up". Nothing to do if it fails: systemd
  /// only misses the news.
  pub fn send(n: *const Notifier, message: []const u8) void {
    const fd = n.fd orelse return;
    _ = linux.sendto(fd, message.ptr, message.len, linux.MSG.NOSIGNAL, @ptrCast(&n.address), n.len);
  }
};

test "systemd hears from skepd at the socket it names" {
  var tmp = std.testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [96]u8 = undefined;
  // In /tmp: the build directory may be on a filesystem without sockets.
  const path = try std.fmt.bufPrintSentinel(&buffer, "/tmp/skep-notify-{s}", .{ &tmp.sub_path }, 0);
  var address: linux.sockaddr.un = .{ .path = @splat(0) };
  @memcpy(address.path[0..path.len], path);
  const listener: linux.fd_t = @intCast(
    linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0),
  );
  defer _ = linux.close(listener);
  try std.testing.expectEqual(
    .SUCCESS,
    linux.errno(linux.bind(listener, @ptrCast(&address), @sizeOf(linux.sockaddr.un))),
  );
  defer _ = linux.unlink(path);

  var environ: std.process.Environ.Map = .init(std.testing.allocator);
  defer environ.deinit();
  try environ.put("NOTIFY_SOCKET", path);
  var n: Notifier = .init(&environ);
  defer n.deinit();
  n.send("READY=1\nSTATUS=listening");
  var received: [64]u8 = undefined;
  const len = linux.read(listener, &received, received.len);
  try std.testing.expectEqualStrings("READY=1\nSTATUS=listening", received[0..len]);

  // Without the variable, nothing.
  var none: std.process.Environ.Map = .init(std.testing.allocator);
  defer none.deinit();
  var quiet: Notifier = .init(&none);
  quiet.send("READY=1");
  try std.testing.expectEqual(null, quiet.fd);
}
