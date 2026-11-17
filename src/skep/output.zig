//! What skep prints: skepd's answers, command by command, its events, and its errors, in words
//! and aligned columns for people; --json prints skepd's answers as they are instead.

const std = @import("std");
const commands = @import("commands.zig");

const Io = std.Io;

const ok = 0;
const failed = 1;

fn eq(a: []const u8, b: []const u8) bool {
  return std.mem.eql(u8, a, b);
}

/// An answer of skepd's to print: its command, its result, and what printing it needs.
pub const Answer = struct {
  out: *Io.Writer,
  err: *Io.Writer,
  call: *const commands.Call,
  result: std.json.Value,
  /// Milliseconds since the epoch, for how old readings are.
  now: i64,
  a: std.mem.Allocator,
};

/// How a command's answer is printed; its exit status.
pub const Render = *const fn (answer: *const Answer) anyerror!u8;

/// Prints an answer, by its command's way, then says what a device refused.
pub fn answer(x: *const Answer) !u8 {
  const status = if (x.call.command.render) |render| try render(x) else statusOf(x.result);
  if (statusOf(x.result) != ok) {
    if (integer(field(x.result, "status"))) |s| {
      if (s != 0) {
        try x.err.print("skep {s}: the device refused it, status 0x{x:0>2}\n", .{
          x.call.name,
          @as(u64, @intCast(s)),
        });
      }
    }
  }
  return status;
}

pub fn version(x: *const Answer) !u8 {
  try x.out.print("skepd {s}", .{ text(field(x.result, "skepd")) });
  if (field(x.result, "libskep")) |v| {
    try x.out.print(", libskep {s}", .{ text(v) });
  }
  try x.out.print(", protocol {d}\n", .{ integer(field(x.result, "protocol")) orelse 0 });
  return ok;
}

pub fn network(x: *const Answer) !u8 {
  const result = x.result;
  if (boolean(field(result, "up")) orelse false) {
    try x.out.print("up: channel {d}, PAN ID 0x{x:0>4}, extended PAN ID {s}", .{
      integer(field(result, "channel")) orelse 0,
      @as(u64, @intCast(integer(field(result, "pan_id")) orelse 0)),
      text(field(result, "extended_pan_id")),
    });
    const left = integer(field(result, "permit_join")) orelse 0;
    if (left > 0) {
      try x.out.print(", devices may join for {d} s", .{ left });
    }
  } else {
    try x.out.writeAll("down");
    if (field(result, "error")) |e| {
      try x.out.print(": {s}", .{ text(e) });
    }
  }
  try x.out.writeByte('\n');
  return ok;
}

pub fn permit(x: *const Answer) !u8 {
  const seconds = x.call.get("seconds") orelse "60";
  if (eq(seconds, "0")) {
    try x.out.writeAll("devices may no longer join\n");
  } else {
    try x.out.print("devices may join for {s} s\n", .{ seconds });
  }
  return ok;
}

pub fn devices(x: *const Answer) !u8 {
  try showDevices(x.out, items(field(x.result, "devices")));
  return ok;
}

pub fn device(x: *const Answer) !u8 {
  try showDevice(x.out, x.result);
  const readings = items(field(x.result, "readings"));
  if (readings.len > 0) {
    try x.out.writeAll("readings\n");
    const rows = try readingRows(x.a, x.result, readings, x.now);
    for (rows) |*r| {
      r.label = try std.fmt.allocPrint(x.a, "  {s}", .{ r.label });
    }
    try showRows(x.out, rows);
  }
  return ok;
}

pub fn get(x: *const Answer) !u8 {
  const call = x.call;
  const readings = try chosen(
    x.a,
    x.err,
    call.name,
    call.get("device").?,
    x.result,
    call.all("reading"),
  ) orelse
    return failed;
  try showRows(x.out, try readingRows(x.a, x.result, readings, x.now));
  return ok;
}

pub fn read(x: *const Answer) !u8 {
  for (items(field(x.result, "attributes"))) |attribute| {
    try showAttribute(x.out, attribute);
  }
  return statusOf(x.result);
}

/// write and report: the attributes the device refused.
pub fn refusals(x: *const Answer) !u8 {
  for (items(field(x.result, "attributes"))) |attribute| {
    const status = integer(field(attribute, "status")) orelse 0;
    if (status != 0) {
      try x.out.print("0x{x:0>4}: refused, status 0x{x:0>2}\n", .{
        @as(u64, @intCast(integer(field(attribute, "id")) orelse 0)),
        @as(u64, @intCast(status)),
      });
    }
  }
  return statusOf(x.result);
}

/// The readings of a device that `names` ask for, all of them without names: null, after telling
/// why, for a device whose interview is not done, or a name it has no reading for.
pub fn chosen(
  a: std.mem.Allocator,
  err: *Io.Writer,
  command_name: []const u8,
  device_name: []const u8,
  dev: std.json.Value,
  names: []const []const u8,
) !?[]const std.json.Value {
  const readings = items(
    field(dev, "readings") orelse {
      if (field(dev, "endpoints") != null) {
        try err.print("skep {s}: skepd gives no readings: it is older than skep\n", .{
          command_name,
        });
      } else {
        try err.print("skep {s}: {s} is not interviewed yet: its readings are not known\n", .{
          command_name,
          device_name,
        });
      }
      return null;
    },
  );
  if (names.len == 0) return readings;
  var list: std.ArrayList(std.json.Value) = .empty;
  for (names) |name| {
    const before = list.items.len;
    for (readings) |r| {
      if (eq(text(field(r, "reading")), name)) {
        try list.append(a, r);
      }
    }
    if (list.items.len == before) {
      try err.print("skep {s}: {s} has no reading {s}; it has", .{
        command_name,
        device_name,
        name,
      });
      for (readings, 0..) |r, i| {
        try err.print("{s} {s}", .{ if (i == 0) "" else ",", text(field(r, "reading")) });
      }
      if (readings.len == 0) {
        try err.writeAll(" none");
      }
      try err.writeByte('\n');
      return null;
    }
  }
  return list.items;
}

/// A line of a table of readings.
pub const Row = struct {
  label: []const u8,
  value: []const u8 = "-",
  age: []const u8 = "",
};

/// Rows in aligned columns.
pub fn showRows(out: *Io.Writer, rows: []const Row) !void {
  var label_width: usize = 0;
  var value_width: usize = 0;
  for (rows) |r| {
    label_width = @max(label_width, width(r.label));
    value_width = @max(value_width, width(r.value));
  }
  for (rows) |r| {
    try out.writeAll(r.label);
    try out.splatByteAll(' ', label_width - width(r.label) + 2);
    try out.writeAll(r.value);
    if (r.age.len > 0) {
      try out.splatByteAll(' ', value_width - width(r.value) + 2);
      try out.writeAll(r.age);
    }
    try out.writeByte('\n');
  }
}

/// The rows of a device's readings, with their last values and how old they are.
pub fn readingRows(
  a: std.mem.Allocator,
  dev: std.json.Value,
  readings: []const std.json.Value,
  now: i64,
) ![]Row {
  const rows = try a.alloc(Row, readings.len);
  for (readings, rows) |r, *row| {
    row.* = .{ .label = try label(a, dev, r) };
    if (float(field(r, "scaled")) == null) continue;
    row.value = try readingText(a, r, .table);
    if (parseTime(text(field(r, "time")))) |time| {
      row.age = try ago(a, now - time);
    }
  }
  return rows;
}

/// A reading's name, and its endpoint when the device has it on several.
pub fn label(a: std.mem.Allocator, dev: std.json.Value, r: std.json.Value) ![]const u8 {
  const name = text(field(r, "reading"));
  var count: usize = 0;
  if (field(dev, "readings")) |all| {
    for (items(all)) |other| {
      if (eq(text(field(other, "reading")), name)) {
        count += 1;
      }
    }
  }
  if (count < 2) return name;
  return std.fmt.allocPrint(a, "{s} ({d})", .{ name, integer(field(r, "endpoint")) orelse 0 });
}

/// How a reading is written: in a table, where "on" says yes or no next to its name, or in a
/// summary, where it says on or off on its own.
pub const Style = enum { table, summary };

/// A reading's value in its unit, `21.54 °C`, from its "scaled" and "unit" members.
pub fn writeReading(w: *Io.Writer, r: std.json.Value, style: Style) !void {
  const scaled = float(field(r, "scaled")) orelse return w.writeAll("-");
  const name = text(field(r, "reading"));
  if (eq(name, "on")) {
    return w.writeAll(
      switch (style) {
        .table => if (scaled != 0) "yes" else "no",
        .summary => if (scaled != 0) "on" else "off",
      },
    );
  }
  if (style == .summary) {
    try w.print("{s} ", .{ name });
  }
  try writeNumber(w, scaled);
  const unit = text(field(r, "unit"));
  if (unit.len > 0) {
    try w.print(" {s}", .{ unit });
  }
}

pub fn readingText(a: std.mem.Allocator, r: std.json.Value, style: Style) ![]const u8 {
  var w: Io.Writer.Allocating = .init(a);
  try writeReading(&w.writer, r, style);
  return w.written();
}

/// A number with four significant digits at most, without trailing zeros: 21.54, 237.9, 0.0012.
pub fn writeNumber(w: *Io.Writer, x: f64) !void {
  if (x == 0 or !std.math.isFinite(x)) return w.print("{d}", .{ x });
  const magnitude: i64 = @intFromFloat(@floor(std.math.log10(@abs(x))));
  const decimals: usize = @intCast(std.math.clamp(3 - magnitude, 0, 6));
  var buffer: [64]u8 = undefined;
  var s: []const u8 = std.fmt.bufPrint(&buffer, "{d:.[1]}", .{ x, decimals }) catch
    return w.print("{d}", .{ x });
  if (std.mem.indexOfScalar(u8, s, '.') != null) {
    s = std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
  }
  try w.writeAll(s);
}

/// How long ago, from milliseconds: `40 s ago`, `2 min ago`, `3 h ago`, `2 d ago`.
pub fn ago(a: std.mem.Allocator, ms: i64) ![]const u8 {
  const s: u64 = @intCast(@max(ms, 0) / 1000);
  if (s < 60) return std.fmt.allocPrint(a, "{d} s ago", .{ s });
  if (s < 3600) return std.fmt.allocPrint(a, "{d} min ago", .{ s / 60 });
  if (s < 86400) return std.fmt.allocPrint(a, "{d} h ago", .{ s / 3600 });
  return std.fmt.allocPrint(a, "{d} d ago", .{ s / 86400 });
}

/// Milliseconds since the epoch of a time skepd gives, `2026-11-16T21:39:12.250Z`.
pub fn parseTime(s: []const u8) ?i64 {
  if (s.len != 24 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or
    s[19] != '.' or s[23] != 'Z') {
    return null;
  }
  const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
  const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
  const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
  const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
  const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
  const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
  const ms = std.fmt.parseInt(i64, s[20..23], 10) catch return null;
  if (month < 1 or month > 12) return null;
  // Days since the epoch of a date: Howard Hinnant's days_from_civil.
  const y = if (month <= 2) year - 1 else year;
  const era = @divFloor(y, 400);
  const yoe = y - era * 400;
  const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
  const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
  const days = era * 146097 + doe - 719468;
  return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms;
}

/// Characters on screen, for alignment: UTF-8 code points.
pub fn width(s: []const u8) usize {
  return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// Printing.

/// An error from skepd, in words: what its members say, a setting's range or what a device can
/// set, and otherwise its message.
pub fn writeError(w: *Io.Writer, command: []const u8, e: std.json.Value) !void {
  if (field(e, "range")) |range| {
    if (float(field(range, "min"))) |min| {
      try w.print("skep {s}: {s}: from ", .{ command, text(field(range, "reading")) });
      try writeNumber(w, min);
      try w.writeAll(" to ");
      try writeNumber(w, float(field(range, "max")) orelse 0);
      const unit = text(field(range, "unit"));
      if (unit.len > 0) {
        try w.print(" {s}", .{ unit });
      }
      return w.writeByte('\n');
    }
  }
  try w.print("skep {s}: {s}", .{ command, text(field(e, "message")) });
  if (field(e, "settable") != null) {
    const names = items(field(e, "settable"));
    if (names.len == 0) {
      try w.writeAll("; it can set nothing");
    }
    for (names, 0..) |name, i| {
      const separator = if (i == 0) "; it can set " else if (i + 1 == names.len) " and " else ", ";
      try w.print("{s}{s}", .{ separator, text(name) });
    }
  }
  try w.writeByte('\n');
}

pub fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
  return switch (v) {
    .object => |o| o.get(name),
    else => null,
  };
}

pub fn text(v: ?std.json.Value) []const u8 {
  return switch (v orelse return "") {
    .string => |s| s,
    else => "",
  };
}

pub fn integer(v: ?std.json.Value) ?i64 {
  return switch (v orelse return null) {
    .integer => |i| i,
    else => null,
  };
}

pub fn boolean(v: ?std.json.Value) ?bool {
  return switch (v orelse return null) {
    .bool => |b| b,
    else => null,
  };
}

/// An array's items, or none if it is not one: what skepd sends is not trusted to have the
/// shape this skep expects, as a skepd of another version may not.
pub fn items(v: ?std.json.Value) []const std.json.Value {
  return switch (v orelse return &.{}) {
    .array => |a| a.items,
    else => &.{},
  };
}

pub fn float(v: ?std.json.Value) ?f64 {
  return switch (v orelse return null) {
    .integer => |i| @floatFromInt(i),
    .float => |f| f,
    else => null,
  };
}

/// What a device is called: its name, or its address.
pub fn who(d: std.json.Value) []const u8 {
  if (field(d, "name")) |n| return text(n);
  return text(field(d, "device"));
}

/// The exit status of a result: a device that refused is a failure.
pub fn statusOf(result: std.json.Value) u8 {
  const status = integer(field(result, "status")) orelse return ok;
  if (status != 0) return failed;
  if (field(result, "attributes")) |attributes| {
    for (items(attributes)) |a| {
      if ((integer(field(a, "status")) orelse 0) != 0) return failed;
    }
  }
  return ok;
}

/// The devices, one per line, under a header: what they are called, their model, and what they
/// last reported, the first three readings, or how far their setup is.
pub fn showDevices(out: *Io.Writer, list: []const std.json.Value) !void {
  var name_width: usize = "NAME".len;
  var model_width: usize = "MODEL".len;
  for (list) |d| {
    name_width = @max(name_width, width(who(d)));
    model_width = @max(model_width, width(text(field(d, "model"))));
  }
  try out.writeAll("NAME");
  try out.splatByteAll(' ', name_width - "NAME".len + 2);
  try out.writeAll("MODEL");
  try out.splatByteAll(' ', model_width - "MODEL".len + 2);
  try out.writeAll("READINGS\n");
  for (list) |d| {
    try out.writeAll(who(d));
    try out.splatByteAll(' ', name_width - width(who(d)) + 2);
    const model = if (field(d, "model")) |m| text(m) else "?";
    try out.writeAll(model);
    try out.splatByteAll(' ', model_width - width(model) + 2);
    var parts: usize = 0;
    const setup = text(field(d, "setup"));
    if (!eq(setup, "ready")) {
      try out.print("setup {s}", .{ setup });
      parts += 1;
    }
    var shown: usize = 0;
    if (field(d, "readings")) |readings| {
      for (items(readings)) |r| {
        if (shown == 3) break;
        if (float(field(r, "scaled")) == null) continue;
        if (parts > 0) {
          try out.writeAll(", ");
        }
        try writeReading(out, r, .summary);
        parts += 1;
        shown += 1;
      }
    }
    if (parts == 0) {
      try out.writeByte('-');
    }
    try out.writeByte('\n');
  }
}

pub fn typeName(t: []const u8) []const u8 {
  if (eq(t, "end_device")) return "end device";
  return if (t.len == 0) "?" else t;
}

pub fn showDevice(out: *Io.Writer, d: std.json.Value) !void {
  try out.print("device            {s}\n", .{ text(field(d, "device")) });
  if (field(d, "name")) |n| {
    try out.print("name              {s}\n", .{ text(n) });
  }
  if (integer(field(d, "network_address"))) |a| {
    try out.print("network address   0x{x:0>4}\n", .{ @as(u64, @intCast(a)) });
  }
  if (field(d, "type")) |t| {
    try out.print("type              {s}\n", .{ typeName(text(t)) });
  }
  if (field(d, "manufacturer")) |m| {
    try out.print("manufacturer      {s}\n", .{ text(m) });
  }
  if (integer(field(d, "manufacturer_code"))) |m| {
    try out.print("manufacturer code 0x{x:0>4}\n", .{ @as(u64, @intCast(m)) });
  }
  if (field(d, "model")) |m| {
    try out.print("model             {s}\n", .{ text(m) });
  }
  if (boolean(field(d, "rx_on_when_idle"))) |r| {
    try out.print("sleeps            {s}\n", .{ if (r) "no" else "yes" });
  }
  try out.print("setup             {s}\n", .{ text(field(d, "setup")) });
  if (field(d, "endpoints")) |endpoints| {
    for (items(endpoints)) |e| {
      try out.print("endpoint {d}: profile 0x{x:0>4}, device type 0x{x:0>4}\n", .{
        integer(field(e, "endpoint")) orelse 0,
        @as(u64, @intCast(integer(field(e, "profile")) orelse 0)),
        @as(u64, @intCast(integer(field(e, "device_type")) orelse 0)),
      });
      inline for (.{.{ "input_clusters", "in " }, .{ "output_clusters", "out" }}) |side| {
        try out.writeAll("  " ++ side[1] ++ ":");
        if (field(e, side[0])) |clusters| {
          for (items(clusters)) |cl| {
            try out.print(" 0x{x:0>4}", .{ @as(u64, @intCast(integer(cl) orelse 0)) });
          }
        }
        try out.writeByte('\n');
      }
    }
  }
}

pub fn showAttribute(out: *Io.Writer, a: std.json.Value) !void {
  const id: u64 = @intCast(integer(field(a, "id")) orelse 0);
  const status = integer(field(a, "status")) orelse 0;
  if (status != 0) {
    return out.print("0x{x:0>4}: status 0x{x:0>2}\n", .{ id, @as(u64, @intCast(status)) });
  }
  try out.print("0x{x:0>4} = ", .{ id });
  try showValue(out, a);
  if (float(field(a, "scaled")) != null) {
    try out.writeAll(", ");
    try writeReading(out, a, .summary);
  }
  try out.writeByte('\n');
}

/// A value and its type: `2154 (int16)`.
pub fn showValue(out: *Io.Writer, a: std.json.Value) !void {
  if (field(a, "value")) |v| {
    switch (v) {
      .integer => |i| try out.print("{d}", .{ i }),
      .float => |f| try out.print("{d}", .{ f }),
      .bool => |b| try out.writeAll(if (b) "true" else "false"),
      .string => |s| try out.print("\"{s}\"", .{ s }),
      .null => try out.writeAll("null"),
      else => try out.writeAll("?"),
    }
    try out.writeByte(' ');
  }
  switch (field(a, "type") orelse .null) {
    .string => |t| try out.print("({s})", .{ t }),
    .integer => |t| try out.print("(type 0x{x:0>2})", .{ @as(u64, @intCast(t)) }),
    else => {},
  }
}

/// An event on a line: its time, then what happened, to which device: `plug: power 11.2 W`.
pub fn showEvent(out: *Io.Writer, e: std.json.Value) !void {
  const event = text(field(e, "event"));
  try out.print("{s} ", .{ text(field(e, "time")) });
  if (field(e, "device") != null) {
    try out.print("{s}: ", .{ who(e) });
  }
  if (eq(event, "attributes")) {
    for (items(field(e, "attributes")), 0..) |attribute, i| {
      if (i > 0) {
        try out.writeAll(", ");
      }
      if (float(field(attribute, "scaled")) != null) {
        try writeReading(out, attribute, .summary);
      } else {
        try out.print("{d}/0x{x:0>4} 0x{x:0>4} = ", .{
          integer(field(e, "endpoint")) orelse 0,
          @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
          @as(u64, @intCast(integer(field(attribute, "id")) orelse 0)),
        });
        try showValue(out, attribute);
      }
    }
  } else if (eq(event, "command")) {
    try out.print("command 0x{x:0>2} on {d}/0x{x:0>4}", .{
      @as(u64, @intCast(integer(field(e, "command")) orelse 0)),
      integer(field(e, "endpoint")) orelse 0,
      @as(u64, @intCast(integer(field(e, "cluster")) orelse 0)),
    });
    const payload = text(field(e, "payload"));
    if (payload.len > 0) {
      try out.print(", payload {s}", .{ payload });
    }
  } else if (eq(event, "permit_join")) {
    const seconds = integer(field(e, "seconds")) orelse 0;
    if (seconds == 0) {
      try out.writeAll("devices may no longer join");
    } else {
      try out.print("devices may join for {d} s", .{ seconds });
    }
  } else if (eq(event, "network_up")) {
    try out.print("network up ({s}): channel {d}, PAN ID 0x{x:0>4}", .{
      text(field(e, "origin")),
      integer(field(e, "channel")) orelse 0,
      @as(u64, @intCast(integer(field(e, "pan_id")) orelse 0)),
    });
  } else if (eq(event, "network_down")) {
    try out.print("network down: {s}", .{ text(field(e, "error")) });
  } else if (eq(event, "device_joined")) {
    try out.writeAll("joined");
  } else if (eq(event, "device_ready")) {
    try out.writeAll("ready");
  } else if (eq(event, "device_left")) {
    const removed = boolean(field(e, "removed")) orelse false;
    try out.writeAll(if (removed) "removed" else "left");
  } else if (eq(event, "device_setup_failed")) {
    try out.writeAll("setup failed");
    if (field(e, "error")) |x| {
      try out.print(": {s}", .{ text(x) });
    }
    if (integer(field(e, "status"))) |s| {
      try out.print(": status 0x{x:0>2}", .{ @as(u64, @intCast(s)) });
    }
  } else if (eq(event, "device_renamed")) {
    try out.writeAll(if (field(e, "name") == null) "name forgotten" else "renamed");
    if (field(e, "old_name")) |o| {
      try out.print(", was {s}", .{ text(o) });
    }
  } else {
    try out.writeAll(event);
  }
  try out.writeByte('\n');
}

const testing = std.testing;

test "times from skepd are read to the millisecond" {
  try testing.expectEqual(0, parseTime("1970-01-01T00:00:00.000Z"));
  try testing.expectEqual(951_782_400_000, parseTime("2000-02-29T00:00:00.000Z"));
  try testing.expectEqual(1_794_865_152_250, parseTime("2026-11-16T21:39:12.250Z"));
  try testing.expectEqual(null, parseTime("2026-11-16 21:39:12"));
  try testing.expectEqual(null, parseTime("2026-13-16T21:39:12.250Z"));
}

test "readings are written short, in their units" {
  var buffer: [64]u8 = undefined;
  for ([_]struct { f64, []const u8 }{
    .{ 21.54, "21.54" },
    .{ 237.9, "237.9" },
    .{ 100, "100" },
    .{ 3.3, "3.3" },
    .{ 0.0012002777, "0.0012" },
    .{ 50.39370078740158, "50.39" },
    .{ -4.5, "-4.5" },
    .{ 0, "0" },
    .{ 12345.6, "12346" },
  }) |case| {
    var w: Io.Writer = .fixed(&buffer);
    try writeNumber(&w, case[0]);
    try testing.expectEqualStrings(case[1], w.buffered());
  }
  const temperature = try std.json.parseFromSlice(
    std.json.Value,
    testing.allocator,
    "{\"reading\": \"temperature\", \"scaled\": 21.54, \"unit\": \"°C\"}",
    .{},
  );
  defer temperature.deinit();
  const on = try std.json.parseFromSlice(
    std.json.Value,
    testing.allocator,
    "{\"reading\": \"on\", \"scaled\": 1, \"unit\": \"\"}",
    .{},
  );
  defer on.deinit();
  for ([_]struct { std.json.Value, Style, []const u8 }{
    .{ temperature.value, .table, "21.54 °C" },
    .{ temperature.value, .summary, "temperature 21.54 °C" },
    .{ on.value, .table, "yes" },
    .{ on.value, .summary, "on" },
  }) |case| {
    var w: Io.Writer = .fixed(&buffer);
    try writeReading(&w, case[0], case[1]);
    try testing.expectEqualStrings(case[2], w.buffered());
  }
  const a = testing.allocator;
  for ([_]struct { i64, []const u8 }{
    .{ -5, "0 s ago" },
    .{ 59_999, "59 s ago" },
    .{ 120_000, "2 min ago" },
    .{ 3 * 3600_000, "3 h ago" },
    .{ 49 * 3600_000, "2 d ago" },
  }) |case| {
    const s = try ago(a, case[0]);
    defer a.free(s);
    try testing.expectEqualStrings(case[1], s);
  }
}

test "skepd's errors are worded from their data" {
  var buffer: [256]u8 = undefined;
  for ([_]struct { []const u8, []const u8 }{
    .{
      "{\"code\": \"EINVAL\", \"message\": \"color_temperature out of range\", \"range\": {\"reading\": \"color_temperature\", \"min\": 2202.643, \"max\": 7042.25, \"unit\": \"K\"}}",
      "skep set: color_temperature: from 2203 to 7042 K\n",
    },
    .{
      "{\"code\": \"ENOENT\", \"message\": \"no reading levl\", \"settable\": [\"on\", \"level\", \"color\"]}",
      "skep set: no reading levl; it can set on, level and color\n",
    },
    .{
      "{\"code\": \"ENOENT\", \"message\": \"no reading on\", \"settable\": []}",
      "skep set: no reading on; it can set nothing\n",
    },
    .{
      "{\"code\": \"ENODEV\", \"message\": \"no device named lamp\"}",
      "skep set: no device named lamp\n",
    },
  }) |case| {
    const e = try std.json.parseFromSlice(std.json.Value, testing.allocator, case[0], .{});
    defer e.deinit();
    var w: Io.Writer = .fixed(&buffer);
    try writeError(&w, "set", e.value);
    try testing.expectEqualStrings(case[1], w.buffered());
  }
}
