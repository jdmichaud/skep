//! Readings: what an attribute is in words and units, such as a temperature in °C, scaled from
//! the hundredths of a degree the ZCL reports it in. The ZCL fixes the scale of some attributes;
//! others, electrical measurements among them, are scaled by factors the device gives, which its
//! entry in devices.zig says, corrected where the device gives them wrong.

const std = @import("std");
const zcl = @import("zcl.zig");

/// An attribute that libskep names, and how to scale it.
pub const Definition = struct {
  cluster: u16,
  attribute: u16,
  name: [:0]const u8,
  /// Empty for none.
  unit: [:0]const u8,
  /// The value in its unit is the attribute's divided by this.
  divisor: f64 = 1,
};

/// A reading of an attribute.
pub const Reading = struct {
  name: [*:0]const u8,
  unit: [*:0]const u8,
  value: f64,
};

/// `struct skep_reading_source`.
pub const CSource = extern struct {
  endpoint: u8,
  cluster: u16,
  attribute: u16,
  name: [*:0]const u8,
  unit: [*:0]const u8,
  reserved: [2]u64 = @splat(0),
};

/// Attributes whose scale the ZCL fixes, in the order devices list them: what matters most
/// first.
pub const standard = [_]Definition{
  // On/Off: 1 for on, 0 for off.
  .{ .cluster = 0x0006, .attribute = 0x0000, .name = "on", .unit = "" },
  // Level Control: CurrentLevel, 0 to 254.
  .{ .cluster = 0x0008, .attribute = 0x0000, .name = "level", .unit = "%", .divisor = 2.54 },
  // Color Control: ColorTemperatureMireds.
  .{ .cluster = 0x0300, .attribute = 0x0007, .name = "color_temperature", .unit = "mired" },
  // Temperature Measurement: hundredths of a degree.
  .{ .cluster = 0x0402, .attribute = 0x0000, .name = "temperature", .unit = "°C", .divisor = 100 },
  // Relative Humidity Measurement: hundredths of a percent.
  .{ .cluster = 0x0405, .attribute = 0x0000, .name = "humidity", .unit = "%", .divisor = 100 },
  // Pressure Measurement: tenths of a kilopascal, which are hectopascals.
  .{ .cluster = 0x0403, .attribute = 0x0000, .name = "pressure", .unit = "hPa" },
  // Power Configuration: BatteryPercentageRemaining in halves of a percent, BatteryVoltage in
  // tenths of a volt.
  .{ .cluster = 0x0001, .attribute = 0x0021, .name = "battery", .unit = "%", .divisor = 2 },
  .{
    .cluster = 0x0001,
    .attribute = 0x0020,
    .name = "battery_voltage",
    .unit = "V",
    .divisor = 10,
  },
};

/// The definition of an attribute: the device's, then the standard one.
pub fn find(device: []const Definition, cluster: u16, attribute: u16) ?*const Definition {
  for (device) |*d| {
    if (d.cluster == cluster and d.attribute == attribute) return d;
  }
  for (&standard) |*d| {
    if (d.cluster == cluster and d.attribute == attribute) return d;
  }
  return null;
}

/// The reading of a value, or null if it has none: of a type that is not a number, or the value
/// the ZCL reserves for "invalid", such as 0x8000 for a 16-bit signed measurement.
pub fn read(definition: *const Definition, value: zcl.Value) ?Reading {
  const kind = zcl.kindOf(value.type) orelse return null;
  const raw: f64 = switch (kind) {
    .unsigned => |size| blk: {
      // All ones: invalid, except for booleans.
      if (value.type != zcl.Type.boolean and
        size < 8 and
        value.v.u == (@as(u64, 1) << @intCast(@as(u7, size) * 8)) - 1) {
        return null;
      }
      break :blk @floatFromInt(value.v.u);
    },
    .signed => |size| blk: {
      // The lowest value: invalid.
      if (size < 8 and value.v.i == -(@as(i64, 1) << @intCast(@as(u7, size) * 8 - 1))) return null;
      break :blk @floatFromInt(value.v.i);
    },
    .float => if (std.math.isFinite(value.v.f)) value.v.f else return null,
    else => return null,
  };
  return .{
    .name = definition.name.ptr,
    .unit = definition.unit.ptr,
    .value = raw / definition.divisor,
  };
}

const testing = std.testing;

test "readings are scaled as the ZCL or the device says" {
  const temperature = find(&.{}, 0x0402, 0x0000).?;
  try testing.expectEqual(21.54, read(temperature, .signed(zcl.Type.int16, 2154)).?.value);
  try testing.expectEqualStrings(
    "°C",
    std.mem.span(read(temperature, .signed(zcl.Type.int16, 2154)).?.unit),
  );
  // 0x8000: invalid.
  try testing.expectEqual(null, read(temperature, .signed(zcl.Type.int16, -0x8000)));
  const battery = find(&.{}, 0x0001, 0x0021).?;
  try testing.expectEqual(100, read(battery, .unsigned(zcl.Type.uint8, 200)).?.value);
  try testing.expectEqual(null, read(battery, .unsigned(zcl.Type.uint8, 0xff)));
  const on = find(&.{}, 0x0006, 0x0000).?;
  try testing.expectEqual(1, read(on, .unsigned(zcl.Type.boolean, 1)).?.value);
  // A device's own scale comes first.
  const power: Definition = .{
    .cluster = 0x0b04,
    .attribute = 0x050b,
    .name = "power",
    .unit = "W",
    .divisor = 10,
  };
  try testing.expectEqual(
    11.2,
    read(find(&.{ power }, 0x0b04, 0x050b).?, .signed(zcl.Type.int16, 112)).?.value,
  );
  try testing.expectEqual(null, find(&.{}, 0x0b04, 0x050b));
}
