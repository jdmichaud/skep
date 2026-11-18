//! The client's side of the authentication that opens a connection to the bus: the EXTERNAL
//! mechanism, in which the bus takes the client's uid from the socket and the client only says
//! which uid it is. Lines of text, before the binary protocol starts.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Longest line the bus may send, its CR LF included.
pub const max_line = 1024;

pub const Error = error{
  /// The bus refused the uid.
  Rejected,
  /// What the bus sent is not the protocol.
  Protocol,
  OutOfMemory,
};

pub const Client = struct {
  line: [max_line]u8 = undefined,
  line_len: usize = 0,
  /// Answered DATA once already.
  answered: bool = false,
  done: bool = false,

  /// Appends to `out` what starts the authentication of `uid`: a NUL, then the command, with
  /// the uid in decimal digits, hex-encoded.
  pub fn start(gpa: Allocator, out: *std.ArrayList(u8), uid: u32) Error!void {
    var digits: [10]u8 = undefined;
    const decimal = std.fmt.bufPrint(&digits, "{d}", .{ uid }) catch unreachable;
    try out.appendSlice(gpa, "\x00AUTH EXTERNAL ");
    for (decimal) |d| {
      try out.print(gpa, "{x:0>2}", .{ d });
    }
    try out.appendSlice(gpa, "\r\n");
  }

  /// Takes what the bus sent, answering it in `out`, and returns how much of it it took: once
  /// authenticated (`done`), what follows is the binary protocol's.
  pub fn feed(a: *Client, gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Error!usize {
    var taken: usize = 0;
    while (!a.done and taken < bytes.len) {
      const b = bytes[taken];
      taken += 1;
      if (a.line_len == a.line.len) return error.Protocol;
      a.line[a.line_len] = b;
      a.line_len += 1;
      if (b != '\n') continue;
      const line = a.line[0..a.line_len];
      a.line_len = 0;
      if (line.len < 2 or line[line.len - 2] != '\r') return error.Protocol;
      try a.answer(gpa, out, line[0..line.len - 2]);
    }
    return taken;
  }

  fn answer(a: *Client, gpa: Allocator, out: *std.ArrayList(u8), line: []const u8) Error!void {
    if (std.mem.startsWith(u8, line, "OK ") or std.mem.eql(u8, line, "OK")) {
      try out.appendSlice(gpa, "BEGIN\r\n");
      a.done = true;
    } else if (std.mem.startsWith(u8, line, "REJECTED")) {
      return error.Rejected;
    } else if ((std.mem.eql(u8, line, "DATA") or std.mem.startsWith(u8, line, "DATA ")) and
      !a.answered) {
      // A bus that wants the uid again, as it is: none to add.
      try out.appendSlice(gpa, "DATA\r\n");
      a.answered = true;
    } else {
      return error.Protocol;
    }
  }
};

const testing = std.testing;

test "the uid is sent, and BEGIN once the bus says OK" {
  var out: std.ArrayList(u8) = .empty;
  defer out.deinit(testing.allocator);
  try Client.start(testing.allocator, &out, 1000);
  try testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\n", out.items);
  out.clearRetainingCapacity();

  var a: Client = .{};
  const reply = "OK 1234deadbeef\r\nl\x01";
  // In pieces, as the socket may give it.
  try testing.expectEqual(5, try a.feed(testing.allocator, &out, reply[0..5]));
  try testing.expect(!a.done);
  try testing.expectEqual(12, try a.feed(testing.allocator, &out, reply[5..]));
  try testing.expect(a.done);
  try testing.expectEqualStrings("BEGIN\r\n", out.items);
}

test "a bus that refuses, or does not speak the protocol, fails the authentication" {
  var out: std.ArrayList(u8) = .empty;
  defer out.deinit(testing.allocator);
  var a: Client = .{};
  try testing.expectError(error.Rejected, a.feed(testing.allocator, &out, "REJECTED EXTERNAL\r\n"));
  a = .{};
  try testing.expectError(error.Protocol, a.feed(testing.allocator, &out, "HELLO\r\n"));
  a = .{};
  try testing.expectError(error.Protocol, a.feed(testing.allocator, &out, "OK\n"));
  a = .{};
  const long: [max_line + 1]u8 = @splat('A');
  try testing.expectError(error.Protocol, a.feed(testing.allocator, &out, &long));
  a = .{};
  _ = try a.feed(testing.allocator, &out, "DATA\r\n");
  try testing.expectError(error.Protocol, a.feed(testing.allocator, &out, "DATA\r\n"));
}
