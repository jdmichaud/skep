//! Opening the serial port of a dongle: raw mode, 8 data bits, no parity, 1 stop bit, at a given
//! speed, with or without RTS/CTS. XON/XOFF stay in the data, for the driver to handle. Linux only.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

pub const OpenError = error{ UnsupportedBaudrate } || posix.OpenError || posix.TermiosSetError;

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
  _ = linux.close(fd);
}

test "the usual speeds are supported" {
  try std.testing.expectEqual(linux.speed_t.B115200, speed(115200).?);
  try std.testing.expectEqual(null, speed(115201));
}
