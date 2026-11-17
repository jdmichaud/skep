//! Bytes from hexadecimal digits, for tests that spell out frames.

const std = @import("std");

pub fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}
