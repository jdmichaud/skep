//! The Zigbee Cluster Library's frames and data types: what devices and the coordinator say to
//! each other about clusters and attributes (ZCL revision 8, chapter 2).
//!
//! Parsing never trusts its input: everything here reads frames from the radio.

const std = @import("std");

/// A ZCL value, `struct skep_value`. Which member of `v` is used depends on the type: `u` for
/// booleans, unsigned integers, bitmaps, enumerations, data, times, ids and IEEE addresses; `i` for
/// signed integers; `f` for floats; `bytes` for strings (without their length), arrays, sets,
/// bags and structures (in their ZCL encoding) and keys.
pub const Value = extern struct {
  type: u8,
  v: extern union {
    u: u64,
    i: i64,
    f: f64,
    bytes: extern struct { data: ?[*]const u8, len: usize },
  },

  pub fn unsigned(t: u8, u: u64) Value {
    return .{ .type = t, .v = .{ .u = u } };
  }

  pub fn signed(t: u8, i: i64) Value {
    return .{ .type = t, .v = .{ .i = i } };
  }

  pub fn bytesOf(v: Value) []const u8 {
    return if (v.v.bytes.data) |data| data[0..v.v.bytes.len] else &.{};
  }
};

/// How a data type is encoded.
pub const Kind = union(enum) {
  none,
  unsigned: u4,
  signed: u4,
  float: u4,
  /// Bytes after a length of this many bytes.
  string: u2,
  /// Element type, count, elements: arrays, sets and bags.
  array,
  /// Count, then type and value of each member.
  structure,
  /// Bytes as they are, of this length: keys.
  raw: u5,
};

pub const Type = struct {
  pub const nodata: u8 = 0x00;
  pub const boolean: u8 = 0x10;
  pub const uint8: u8 = 0x20;
  pub const uint16: u8 = 0x21;
  pub const int16: u8 = 0x29;
  pub const enum8: u8 = 0x30;
  pub const char_string: u8 = 0x42;
  pub const array: u8 = 0x48;
  pub const structure: u8 = 0x4c;
};

/// The encoding of data type `t`, or null for a type the ZCL does not define.
pub fn kindOf(t: u8) ?Kind {
  return switch (t) {
    0x00 => .none,
    0x08...0x0f, 0x18...0x1f, 0x20...0x27 => .{ .unsigned = @intCast((t & 0x07) + 1) },
    0x10, 0x30 => .{ .unsigned = 1 },
    0x31 => .{ .unsigned = 2 },
    0x28...0x2f => .{ .signed = @intCast((t & 0x07) + 1) },
    0x38 => .{ .float = 2 },
    0x39 => .{ .float = 4 },
    0x3a => .{ .float = 8 },
    0x41, 0x42 => .{ .string = 1 },
    0x43, 0x44 => .{ .string = 2 },
    0x48, 0x50, 0x51 => .array,
    0x4c => .structure,
    0xe0, 0xe1, 0xe2, 0xea => .{ .unsigned = 4 },
    0xe8, 0xe9 => .{ .unsigned = 2 },
    0xf0 => .{ .unsigned = 8 },
    0xf1 => .{ .raw = 16 },
    else => null,
  };
}

/// Whether reporting a value of type `t` takes a reportable change: integers, floats and times.
pub fn isAnalog(t: u8) bool {
  return switch (t) {
    0x20...0x2f, 0x38...0x3a, 0xe0...0xe2 => true,
    else => false,
  };
}

pub const Error = error{
  /// The frame ends before what it announces.
  TooShort,
  /// A data type the ZCL does not define, or nested too deep.
  BadType,
};

/// Arrays and structures within arrays and structures, at most.
const max_depth = 4;

/// A value read, and how many bytes it took.
pub const Read = struct {
  value: Value,
  len: usize,
};

/// Reads a value of type `t` from the start of `bytes`. Byte values point into `bytes`.
pub fn readValue(t: u8, bytes: []const u8) Error!Read {
  return readValueDepth(t, bytes, 0);
}

fn readValueDepth(t: u8, bytes: []const u8, depth: u8) Error!Read {
  const kind = kindOf(t) orelse return error.BadType;
  switch (kind) {
    .none => return .{ .value = .unsigned(t, 0), .len = 0 },
    .unsigned => |size| {
      if (bytes.len < size) return error.TooShort;
      var u: u64 = 0;
      for (0..size) |i| {
        u |= @as(u64, bytes[i]) << @intCast(8 * i);
      }
      return .{ .value = .unsigned(t, u), .len = size };
    },
    .signed => |size| {
      if (bytes.len < size) return error.TooShort;
      var u: u64 = 0;
      for (0..size) |i| {
        u |= @as(u64, bytes[i]) << @intCast(8 * i);
      }
      // Sign-extended from its size.
      const shift: u6 = @intCast(64 - @as(u7, size) * 8);
      const i: i64 = @as(i64, @bitCast(u << shift)) >> shift;
      return .{ .value = .signed(t, i), .len = size };
    },
    .float => |size| {
      if (bytes.len < size) return error.TooShort;
      const f: f64 = switch (size) {
        2 => @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[0..2], .little)))),
        4 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))),
        else => @bitCast(std.mem.readInt(u64, bytes[0..8], .little)),
      };
      return .{ .value = .{ .type = t, .v = .{ .f = f } }, .len = size };
    },
    .string => |prefix| {
      if (bytes.len < prefix) return error.TooShort;
      var len: usize = if (prefix == 1) bytes[0] else std.mem.readInt(u16, bytes[0..2], .little);
      // All ones: an invalid string, of no characters.
      const invalid: usize = if (prefix == 1) 0xff else 0xffff;
      if (len == invalid) {
        len = 0;
      }
      if (bytes.len < prefix + len) return error.TooShort;
      return .{ .value = bytesValue(t, bytes[prefix..][0..len]), .len = prefix + len };
    },
    .raw => |size| {
      if (bytes.len < size) return error.TooShort;
      return .{ .value = bytesValue(t, bytes[0..size]), .len = size };
    },
    .array => {
      if (depth == max_depth) return error.BadType;
      if (bytes.len < 3) return error.TooShort;
      const element = bytes[0];
      var count: usize = std.mem.readInt(u16, bytes[1..3], .little);
      if (count == 0xffff) {
        count = 0;
      }
      var len: usize = 3;
      for (0..count) |_| {
        len += (try readValueDepth(element, bytes[len..], depth + 1)).len;
      }
      return .{ .value = bytesValue(t, bytes[0..len]), .len = len };
    },
    .structure => {
      if (depth == max_depth) return error.BadType;
      if (bytes.len < 2) return error.TooShort;
      var count: usize = std.mem.readInt(u16, bytes[0..2], .little);
      if (count == 0xffff) {
        count = 0;
      }
      var len: usize = 2;
      for (0..count) |_| {
        if (bytes.len < len + 1) return error.TooShort;
        const member = bytes[len];
        len += 1 + (try readValueDepth(member, bytes[len + 1..], depth + 1)).len;
      }
      return .{ .value = bytesValue(t, bytes[0..len]), .len = len };
    },
  }
}

fn bytesValue(t: u8, bytes: []const u8) Value {
  return .{ .type = t, .v = .{ .bytes = .{ .data = bytes.ptr, .len = bytes.len } } };
}

/// Writes a value in its ZCL encoding. Fails for types the ZCL does not define, values that do not
/// fit their type, and when `out` is full.
pub fn writeValue(w: *std.Io.Writer, value: Value) error{ WriteFailed, BadValue }!void {
  const kind = kindOf(value.type) orelse return error.BadValue;
  switch (kind) {
    .none => {},
    .unsigned => |size| {
      const u = value.v.u;
      if (size < 8 and u >> @intCast(@as(u7, size) * 8) != 0) return error.BadValue;
      for (0..size) |i| {
        try w.writeByte(@truncate(u >> @intCast(8 * i)));
      }
    },
    .signed => |size| {
      const i = value.v.i;
      if (size < 8) {
        const bits: u6 = @intCast(@as(u7, size) * 8 - 1);
        const limit = @as(i64, 1) << bits;
        if (i < -limit or i >= limit) return error.BadValue;
      }
      const u: u64 = @bitCast(i);
      for (0..size) |n| {
        try w.writeByte(@truncate(u >> @intCast(8 * n)));
      }
    },
    .float => |size| switch (size) {
      2 => try w.writeInt(u16, @bitCast(@as(f16, @floatCast(value.v.f))), .little),
      4 => try w.writeInt(u32, @bitCast(@as(f32, @floatCast(value.v.f))), .little),
      else => try w.writeInt(u64, @bitCast(value.v.f), .little),
    },
    .string => |prefix| {
      const bytes = value.bytesOf();
      if (prefix == 1) {
        if (bytes.len >= 0xff) return error.BadValue;
        try w.writeByte(@intCast(bytes.len));
      } else {
        if (bytes.len >= 0xffff) return error.BadValue;
        try w.writeInt(u16, @intCast(bytes.len), .little);
      }
      try w.writeAll(bytes);
    },
    .raw => |size| {
      const bytes = value.bytesOf();
      if (bytes.len != size) return error.BadValue;
      try w.writeAll(bytes);
    },
    // In their ZCL encoding already, which must be whole.
    .array, .structure => {
      const bytes = value.bytesOf();
      const read = readValue(value.type, bytes) catch return error.BadValue;
      if (read.len != bytes.len) return error.BadValue;
      try w.writeAll(bytes);
    },
  }
}

/// The header of a ZCL frame.
pub const Header = struct {
  /// Cluster-specific, or a global command (one of `Command`).
  cluster_specific: bool,
  /// For manufacturer-specific frames.
  manufacturer_code: ?u16 = null,
  /// From the server side of the cluster to the client: answers and reports.
  from_server: bool,
  disable_default_response: bool = false,
  sequence: u8,
  command: u8,

  pub fn write(h: Header, w: *std.Io.Writer) error{ WriteFailed }!void {
    var control: u8 = if (h.cluster_specific) 0x01 else 0x00;
    if (h.manufacturer_code != null) {
      control |= 0x04;
    }
    if (h.from_server) {
      control |= 0x08;
    }
    if (h.disable_default_response) {
      control |= 0x10;
    }
    try w.writeByte(control);
    if (h.manufacturer_code) |code| {
      try w.writeInt(u16, code, .little);
    }
    try w.writeByte(h.sequence);
    try w.writeByte(h.command);
  }
};

/// A frame: its header, and the payload after it.
pub const Frame = struct {
  header: Header,
  payload: []const u8,

  pub fn parse(bytes: []const u8) Error!Frame {
    if (bytes.len < 1) return error.TooShort;
    const control = bytes[0];
    // Frame types 2 and 3 are reserved.
    if (control & 0x03 > 1) return error.BadType;
    var i: usize = 1;
    var manufacturer_code: ?u16 = null;
    if (control & 0x04 != 0) {
      if (bytes.len < 3) return error.TooShort;
      manufacturer_code = std.mem.readInt(u16, bytes[1..3], .little);
      i = 3;
    }
    if (bytes.len < i + 2) return error.TooShort;
    return .{
      .header = .{
        .cluster_specific = control & 0x01 != 0,
        .manufacturer_code = manufacturer_code,
        .from_server = control & 0x08 != 0,
        .disable_default_response = control & 0x10 != 0,
        .sequence = bytes[i],
        .command = bytes[i + 1],
      },
      .payload = bytes[i + 2..],
    };
  }
};

/// Global commands.
pub const Command = struct {
  pub const read_attributes: u8 = 0x00;
  pub const read_attributes_response: u8 = 0x01;
  pub const write_attributes: u8 = 0x02;
  pub const write_attributes_response: u8 = 0x04;
  pub const configure_reporting: u8 = 0x06;
  pub const configure_reporting_response: u8 = 0x07;
  pub const report_attributes: u8 = 0x0a;
  pub const default_response: u8 = 0x0b;
};

pub const Status = struct {
  pub const success: u8 = 0x00;
  pub const failure: u8 = 0x01;
  pub const unsupported_attribute: u8 = 0x86;
};

/// An attribute in a frame: its id, the status a device gave it, and its value.
pub const Attribute = struct {
  id: u16,
  status: u8 = Status.success,
  /// Of type `Type.nodata` when the frame has none.
  value: Value = .unsigned(Type.nodata, 0),
};

/// The attributes of a Report Attributes frame, one after the other.
pub const ReportIterator = struct {
  bytes: []const u8,
  i: usize = 0,

  pub fn next(it: *ReportIterator) Error!?Attribute {
    if (it.i == it.bytes.len) return null;
    if (it.bytes.len < it.i + 3) return error.TooShort;
    const id = std.mem.readInt(u16, it.bytes[it.i..][0..2], .little);
    const read = try readValue(it.bytes[it.i + 2], it.bytes[it.i + 3..]);
    it.i += 3 + read.len;
    return .{ .id = id, .value = read.value };
  }
};

/// The records of a Read Attributes Response: id, status, and type and value if it succeeded.
pub const ReadResponseIterator = struct {
  bytes: []const u8,
  i: usize = 0,

  pub fn next(it: *ReadResponseIterator) Error!?Attribute {
    if (it.i == it.bytes.len) return null;
    if (it.bytes.len < it.i + 3) return error.TooShort;
    const id = std.mem.readInt(u16, it.bytes[it.i..][0..2], .little);
    const status = it.bytes[it.i + 2];
    it.i += 3;
    if (status != Status.success) return .{ .id = id, .status = status };
    if (it.bytes.len < it.i + 1) return error.TooShort;
    const read = try readValue(it.bytes[it.i], it.bytes[it.i + 1..]);
    it.i += 1 + read.len;
    return .{ .id = id, .value = read.value };
  }
};

/// The status of each attribute of a Write Attributes or Configure Reporting request, from the
/// response: a single success status covers them all; otherwise each failure is listed, with its
/// attribute id after its status (and, for Configure Reporting, a direction byte between them).
pub fn statusOf(payload: []const u8, command: u8, attribute: u16) Error!u8 {
  if (payload.len == 1) return payload[0];
  const record_len: usize = if (command == Command.configure_reporting_response) 4 else 3;
  if (payload.len == 0 or payload.len % record_len != 0) return error.TooShort;
  var i: usize = 0;
  while (i < payload.len) : (i += record_len) {
    const id = std.mem.readInt(u16, payload[i + record_len - 2..][0..2], .little);
    if (id == attribute) return payload[i];
  }
  return Status.success;
}

/// A Default Response: the command it answers, and its status.
pub fn parseDefaultResponse(payload: []const u8) Error!struct { command: u8, status: u8 } {
  if (payload.len < 2) return error.TooShort;
  return .{ .command = payload[0], .status = payload[1] };
}

/// How a device is to report an attribute, as Configure Reporting sends it.
pub const Reporting = struct {
  attribute: u16,
  type: u8,
  min_interval: u16,
  max_interval: u16,
  /// For analog types only: the change that triggers a report, of the attribute's type.
  change: Value,

  pub fn write(r: Reporting, w: *std.Io.Writer) error{ WriteFailed, BadValue }!void {
    // Reported by the server, which is the device.
    try w.writeByte(0x00);
    try w.writeInt(u16, r.attribute, .little);
    try w.writeByte(r.type);
    try w.writeInt(u16, r.min_interval, .little);
    try w.writeInt(u16, r.max_interval, .little);
    if (isAnalog(r.type)) {
      var change = r.change;
      change.type = r.type;
      try writeValue(w, change);
    }
  }
};

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}

test "values of every kind are read" {
  try testing.expectEqual(2361, (try readValue(0x21, &hex("3909"))).value.v.u);
  try testing.expectEqual(-2, (try readValue(0x29, &hex("feff"))).value.v.i);
  try testing.expectEqual(-0x800000, (try readValue(0x2a, &hex("000080"))).value.v.i);
  try testing.expectEqual(1, (try readValue(0x10, &hex("01"))).value.v.u);
  try testing.expectEqual(1.5, (try readValue(0x39, &hex("0000c03f"))).value.v.f);
  try testing.expectEqual(-2.0, (try readValue(0x38, &hex("00c0"))).value.v.f);
  const model = try readValue(0x42, &hex("0a3352544853303232345a"));
  try testing.expectEqualStrings("3RTHS0224Z", model.value.bytesOf());
  try testing.expectEqual(11, model.len);
  try testing.expectEqual(0, (try readValue(0x42, &hex("ff"))).value.v.bytes.len);
  // An array of two uint16, and a structure of a uint8 and a string.
  const array = try readValue(0x48, &hex("21" ++ "0200" ++ "0100" ++ "0200" ++ "ee"));
  try testing.expectEqual(7, array.len);
  try testing.expectEqual(7, array.value.v.bytes.len);
  const structure = try readValue(0x4c, &hex("0200" ++ "20" ++ "05" ++ "42" ++ "026869"));
  try testing.expectEqual(8, structure.len);
  try testing.expectError(error.TooShort, readValue(0x21, &hex("39")));
  try testing.expectError(error.TooShort, readValue(0x42, &hex("05414243")));
  try testing.expectError(error.BadType, readValue(0x07, &hex("00")));
}

test "values are written as they are read" {
  var buffer: [64]u8 = undefined;
  const values = [_]Value{
    .unsigned(0x21, 2361),
    .signed(0x29, -2),
    .signed(0x2a, -0x800000),
    .unsigned(0x10, 1),
    .{ .type = 0x39, .v = .{ .f = 1.5 } },
    bytesValue(0x42, "3RTHS0224Z"),
    bytesValue(0x48, &hex("21" ++ "0200" ++ "0100" ++ "0200")),
    bytesValue(0xf1, &@as([16]u8, @splat(0x11))),
  };
  for (values) |value| {
    var w: std.Io.Writer = .fixed(&buffer);
    try writeValue(&w, value);
    const read = try readValue(value.type, w.buffered());
    try testing.expectEqual(w.buffered().len, read.len);
    try testing.expectEqual(value.type, read.value.type);
  }
  var w: std.Io.Writer = .fixed(&buffer);
  try testing.expectError(error.BadValue, writeValue(&w, .unsigned(0x20, 256)));
  try testing.expectError(error.BadValue, writeValue(&w, .signed(0x28, 128)));
  try testing.expectError(
    error.BadValue,
    writeValue(&w, bytesValue(0x48, &hex("21" ++ "0200" ++ "01"))),
  );
  try testing.expectError(error.BadValue, writeValue(&w, .unsigned(0xff, 0)));
}

test "frames from the sensor and the plug" {
  // The plug reports its On/Off attribute: on.
  const on = try Frame.parse(&hex("08d90a00001001"));
  try testing.expect(!on.header.cluster_specific);
  try testing.expect(on.header.from_server);
  try testing.expectEqual(Command.report_attributes, on.header.command);
  var it: ReportIterator = .{ .bytes = on.payload };
  const attribute = (try it.next()).?;
  try testing.expectEqual(0x0000, attribute.id);
  try testing.expectEqual(1, attribute.value.v.u);
  try testing.expect((try it.next()) == null);

  // A read response from the sensor: a model, and an attribute it does not have.
  const read = try Frame.parse(
    &hex("1805" ++ "01" ++ "0500" ++ "00" ++ "42" ++ "0a3352544853303232345a" ++ "0400" ++ "86"),
  );
  var records: ReadResponseIterator = .{ .bytes = read.payload };
  try testing.expectEqualStrings("3RTHS0224Z", (try records.next()).?.value.bytesOf());
  const missing = (try records.next()).?;
  try testing.expectEqual(0x0004, missing.id);
  try testing.expectEqual(Status.unsupported_attribute, missing.status);
  try testing.expect((try records.next()) == null);

  // Manufacturer-specific, from the client: a write to the plug's LED brightness.
  var buffer: [16]u8 = undefined;
  var w: std.Io.Writer = .fixed(&buffer);
  const header: Header = .{
    .cluster_specific = false,
    .manufacturer_code = 0x1233,
    .from_server = false,
    .sequence = 7,
    .command = Command.write_attributes,
  };
  try header.write(&w);
  try testing.expectEqualSlices(u8, &hex("04" ++ "3312" ++ "07" ++ "02"), w.buffered());
  const parsed = try Frame.parse(w.buffered());
  try testing.expectEqual(0x1233, parsed.header.manufacturer_code);
  try testing.expectError(error.BadType, Frame.parse(&hex("02000a")));
}

test "statuses of a configuration" {
  const command = Command.configure_reporting_response;
  try testing.expectEqual(0, try statusOf(&hex("00"), command, 0x0505));
  // RMSVoltage refused, RMSCurrent accepted.
  try testing.expectEqual(0x8c, try statusOf(&hex("8c" ++ "00" ++ "0505"), command, 0x0505));
  try testing.expectEqual(0, try statusOf(&hex("8c" ++ "00" ++ "0505"), command, 0x0508));
  try testing.expectEqual(
    0x88,
    try statusOf(&hex("88" ++ "1000"), Command.write_attributes_response, 0x0010),
  );
  try testing.expectError(error.TooShort, statusOf(&hex("8c00"), command, 0x0505));
}

test "reporting configurations" {
  var buffer: [16]u8 = undefined;
  var w: std.Io.Writer = .fixed(&buffer);
  const temperature: Reporting = .{
    .attribute = 0x0000,
    .type = Type.int16,
    .min_interval = 10,
    .max_interval = 3600,
    .change = .signed(Type.int16, 100),
  };
  try temperature.write(&w);
  try testing.expectEqualSlices(
    u8,
    &hex("00" ++ "0000" ++ "29" ++ "0a00" ++ "100e" ++ "6400"),
    w.buffered(),
  );
  w = .fixed(&buffer);
  const on_off: Reporting = .{
    .attribute = 0x0000,
    .type = Type.boolean,
    .min_interval = 0,
    .max_interval = 3600,
    .change = .unsigned(Type.boolean, 0),
  };
  try on_off.write(&w);
  try testing.expectEqualSlices(u8, &hex("00" ++ "0000" ++ "10" ++ "0000" ++ "100e"), w.buffered());
}

test "fuzz: frames and values from devices are parsed safely" {
  try testing.fuzz({}, fuzzParse, .{
    .corpus = &.{
      &hex("08d90a00001001"),
      &hex("1805" ++ "01" ++ "0500" ++ "00" ++ "42" ++ "0a3352544853303232345a" ++ "0400" ++ "86"),
      &hex("180601" ++ "48" ++ "21" ++ "0200" ++ "0100" ++ "0200"),
    },
  });
}

fn fuzzParse(_: void, smith: *testing.Smith) !void {
  var bytes: [128]u8 = undefined;
  const len = smith.slice(&bytes);
  const frame = Frame.parse(bytes[0..len]) catch return;
  var report: ReportIterator = .{ .bytes = frame.payload };
  while (report.next() catch null) |attribute| {
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    // What was read is written back the same, where it can be.
    writeValue(&w, attribute.value) catch continue;
    const again = try readValue(attribute.value.type, w.buffered());
    try testing.expectEqual(w.buffered().len, again.len);
  }
  var read: ReadResponseIterator = .{ .bytes = frame.payload };
  while (read.next() catch null) |_| {}
  _ = statusOf(frame.payload, frame.header.command, 0) catch {};
  _ = parseDefaultResponse(frame.payload) catch {};
}
