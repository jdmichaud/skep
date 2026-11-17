//! Opening the serial port of a dongle: raw mode, 8 data bits, no parity, 1 stop bit, at a given
//! speed, with or without RTS/CTS. XON/XOFF stay in the data, for the driver to handle. Linux only.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

pub const OpenError = error{
  UnsupportedBaudrate,
  /// Another program, another skepd for one, has the port.
  InUse,
} || posix.OpenError || posix.TermiosSetError;

/// The speeds supported, as termios encodes them.
pub fn speed(baudrate: u32) ?linux.speed_t {
  return switch (baudrate) {
    57600 => .B57600,
    115200 => .B115200,
    230400 => .B230400,
    460800 => .B460800,
    921600 => .B921600,
    else => null,
  };
}

/// Opens `path` for reading and writing, non-blocking, and drops what it received before.
pub fn open(path: []const u8, baudrate: u32, rtscts: bool) OpenError!posix.fd_t {
  const s = speed(baudrate) orelse return error.UnsupportedBaudrate;
  const fd = try posix.openat(
    posix.AT.FDCWD,
    path,
    .{
      .ACCMODE = .RDWR,
      .NOCTTY = true,
      .NONBLOCK = true,
      .CLOEXEC = true,
    },
    0,
  );
  errdefer close(fd);
  // One program at a time drives a dongle: another skepd waits on the lock, and other programs
  // opening the port after this one are refused, unless they run as root.
  switch (linux.errno(linux.flock(fd, posix.LOCK.EX | posix.LOCK.NB))) {
    .SUCCESS => {},
    .AGAIN => return error.InUse,
    // A port that cannot be locked: the exclusive mode below still holds.
    else => {},
  }
  _ = linux.ioctl(fd, linux.T.IOCEXCL, 0);
  var t = try posix.tcgetattr(fd);
  t.iflag = .{};
  t.oflag = .{};
  t.lflag = .{};
  t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true, .CRTSCTS = rtscts };
  // The speed is in the CBAUD bits of cflag (asm-generic layout: x86, ARM, RISC-V).
  const cbaud: u32 = 0o010017;
  const cflag: u32 = @bitCast(t.cflag);
  t.cflag = @bitCast(cflag & ~cbaud | @backingInt(s));
  t.ispeed = s;
  t.ospeed = s;
  t.cc[@backingInt(linux.V.MIN)] = 0;
  t.cc[@backingInt(linux.V.TIME)] = 0;
  try posix.tcsetattr(fd, .NOW, t);
  _ = linux.ioctl(fd, linux.T.CFLSH, 0);
  return fd;
}

pub fn close(fd: posix.fd_t) void {
  // The exclusive mode outlives the descriptor while the port stays open elsewhere: a
  // pseudo-terminal's other side, for one.
  _ = linux.ioctl(fd, linux.T.IOCNXCL, 0);
  _ = linux.close(fd);
}

test "the usual speeds are supported" {
  try std.testing.expectEqual(linux.speed_t.B115200, speed(115200).?);
  try std.testing.expectEqual(null, speed(115201));
}

test "a port is opened by one program at a time" {
  // A pseudo-terminal, as a serial port.
  const rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
  if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
  const master: posix.fd_t = @intCast(rc);
  defer _ = linux.close(master);
  var unlock: c_int = 0;
  _ = linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock));
  var number: c_uint = 0;
  _ = linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number));
  var buffer: [32]u8 = undefined;
  const path = try std.fmt.bufPrint(&buffer, "/dev/pts/{d}", .{ number });
  const fd = try open(path, 115200, false);
  // Refused by the exclusive mode, or by the lock for root.
  const second = open(path, 115200, false);
  try std.testing.expect(second == error.DeviceBusy or second == error.InUse);
  close(fd);
  close(try open(path, 115200, false));
}
