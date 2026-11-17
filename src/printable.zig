//! Text from devices, made safe to print: on a terminal, control characters move the cursor, set
//! the window title or write the clipboard, and characters that reorder text disguise it; in a
//! log, a newline forges a line. skep escapes what skepd sends before printing it, and skepd what
//! it logs.

const std = @import("std");

/// Whether a code point is printed as it is: not a control (C0, DEL or C1), nor one of the
/// characters that reorder text (the bidirectional formatting characters), nor a line or
/// paragraph separator.
fn printable(c: u21) bool {
  return switch (c) {
    0x00...0x1f, 0x7f...0x9f => false,
    0x061c, 0x200e, 0x200f, 0x2028...0x202e, 0x2066...0x2069 => false,
    else => true,
  };
}

/// Whether `text` prints as it is: valid UTF-8, with nothing to escape.
pub fn is(text: []const u8) bool {
  var view = std.unicode.Utf8View.init(text) catch return false;
  var it = view.iterator();
  while (it.nextCodepoint()) |c| {
    if (!printable(c)) return false;
  }
  return true;
}

/// Writes `text` with what is not printable escaped: `\n`, `\r` and `\t`, other controls as
/// `\x1b`, the other characters as `\u{202e}`, and bytes that are not UTF-8 as `\xff`.
pub fn write(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
  var i: usize = 0;
  while (i < text.len) {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
    const c: ?u21 = if (len == 0 or i + len > text.len)
      null
    else
      std.unicode.utf8Decode(text[i..][0..len]) catch null;
    const code_point = c orelse {
      try w.print("\\x{x:0>2}", .{ text[i] });
      i += 1;
      continue;
    };
    if (printable(code_point)) {
      try w.writeAll(text[i..][0..len]);
    } else {
      switch (code_point) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{ code_point }),
        else => try w.print("\\u{{{x}}}", .{ code_point }),
      }
    }
    i += len;
  }
}

/// `text`, escaped by `write` when printed with `{f}`.
pub fn fmt(text: []const u8) std.fmt.Alt([]const u8, write) {
  return .{ .data = text };
}

/// `text` if it prints as it is, an escaped copy otherwise.
pub fn dupe(a: std.mem.Allocator, text: []const u8) error{ OutOfMemory }![]const u8 {
  if (is(text)) return text;
  return std.fmt.allocPrint(a, "{f}", .{ fmt(text) });
}

const testing = std.testing;

test "text that prints as it is is left alone" {
  for ([_][]const u8{ "", "lampe_canapé", "21.5 °C", "a\\b", "日本語" }) |text| {
    try testing.expect(is(text));
    try testing.expectEqual(text.ptr, (try dupe(testing.allocator, text)).ptr);
  }
}

test "controls, reordering characters and bytes that are not UTF-8 are escaped" {
  for ([_][2][]const u8{
    // A newline forging a line, a carriage return, a tab.
    .{ "on\n2026-11-17 skepd: forged", "on\\n2026-11-17 skepd: forged" },
    .{ "a\rb\tc", "a\\rb\\tc" },
    // Clearing the screen, setting the title, OSC 52 writing the clipboard.
    .{ "\x1b[2J", "\\x1b[2J" },
    .{ "\x1b]0;title\x07", "\\x1b]0;title\\x07" },
    .{ "\x1b]52;c;ZWNobw==\x1b\\", "\\x1b]52;c;ZWNobw==\\x1b\\" },
    .{ "\x7f", "\\x7f" },
    // C1: CSI, and NEL, a line break.
    .{ "\u{9b}2J", "\\u{9b}2J" },
    .{ "a\u{85}b", "a\\u{85}b" },
    // Right-to-left override, isolates, and the line separator.
    .{ "exe.\u{202e}txt", "exe.\\u{202e}txt" },
    .{ "\u{2066}a\u{2069}\u{2028}", "\\u{2066}a\\u{2069}\\u{2028}" },
    // Not UTF-8: a lone continuation byte, a sequence cut short, an overlong encoding.
    .{ "a\x80b", "a\\x80b" },
    .{ "a\xc3", "a\\xc3" },
    .{ "\xc0\xaf", "\\xc0\\xaf" },
  }) |case| {
    try testing.expect(!is(case[0]));
    const escaped = try dupe(testing.allocator, case[0]);
    defer testing.allocator.free(escaped);
    try testing.expectEqualStrings(case[1], escaped);
    try testing.expect(is(escaped));
  }
}

test "fuzz: what is escaped prints as it is" {
  try testing.fuzz({}, fuzzEscape, .{});
}

fn fuzzEscape(_: void, smith: *testing.Smith) !void {
  var bytes: [64]u8 = undefined;
  const text = bytes[0..smith.slice(&bytes)];
  var buffer: [64 * 8]u8 = undefined;
  var w: std.Io.Writer = .fixed(&buffer);
  try write(text, &w);
  try testing.expect(is(w.buffered()));
}
