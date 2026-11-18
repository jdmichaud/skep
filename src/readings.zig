//! Readings: what an attribute is in words and units, such as a temperature in °C, scaled from
//! the hundredths of a degree the ZCL reports it in. The ZCL fixes the scale of some attributes;
//! others, electrical measurements among them, are scaled by factors the device gives, which its
//! entry in devices.zig says, corrected where the device gives them wrong.
//!
//! Some readings can be set, a light's level or colour temperature among them: by a command of
//! their cluster, with the value scaled back.

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
  /// Whether the value is this divisor divided by the attribute's instead: a colour temperature
  /// in kelvins, from mireds.
  inverse: bool = false,
  /// How it is set, if it can be.
  set: ?Set = null,
};

/// How a reading is set: by a command of its cluster.
pub const Set = union(enum) {
  /// On/Off's On for a value other than 0, Off for 0.
  on_off,
  /// A command whose arguments are the attribute's value, of its type and at most `max`, then a
  /// transition time in tenths of a second: Move to Level with On/Off and the like. Move to Hue
  /// has a direction between them, 0 for the shortest way round.
  move: struct {
    command: u8,
    type: u8,
    max: u64,
    direction: bool = false,
    /// The attributes of the same cluster that hold the least and the greatest value the device
    /// itself takes, if it says: a light's own colour temperatures. Its interview reads them.
    bounds: ?[2]u16 = null,
  },
};

/// The attributes that bound a reading's values on a device, if any.
pub fn boundsOf(definition: *const Definition) ?[2]u16 {
  const set = definition.set orelse return null;
  return switch (set) {
    .move => |m| m.bounds,
    .on_off => null,
  };
}

/// The device's own limits of a reading's attribute, from the values of its bounds' attributes:
/// none unless both are known and make a range the reading can take.
pub fn deviceLimits(definition: *const Definition, least: ?u64, greatest: ?u64) ?[2]u64 {
  const set = definition.set orelse return null;
  const max = switch (set) {
    .move => |m| m.max,
    .on_off => return null,
  };
  const l = least orelse return null;
  const g = greatest orelse return null;
  if (l > g or g > max) return null;
  // A reading that is a divisor divided by the attribute has no value for 0.
  if (definition.inverse and l == 0) return null;
  return .{ l, g };
}

/// A command that sets a reading, and its arguments.
pub const Command = struct {
  id: u8,
  arguments: [3]zcl.Value = undefined,
  count: usize = 0,

  fn add(c: *Command, value: zcl.Value) void {
    c.arguments[c.count] = value;
    c.count += 1;
  }
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
  settable: u8,
  name: [*:0]const u8,
  unit: [*:0]const u8,
  min: f64 = 0,
  max: f64 = 0,
  reserved: [2]u64 = @splat(0),
};

/// `struct skep_setting`.
pub const CSetting = extern struct {
  device: u64,
  endpoint: u8,
  transition: f64,
  reserved: [4]u32,
};

/// Attributes whose scale the ZCL fixes, in the order devices list them: what matters most
/// first.
pub const standard = [_]Definition{
  // On/Off: 1 for on, 0 for off.
  .{
    .cluster = zcl.Cluster.on_off,
    .attribute = zcl.AttributeId.on_off.on_off,
    .name = "on",
    .unit = "",
    .set = .on_off,
  },
  // Level Control: CurrentLevel, 0 to 254, set by Move to Level with On/Off, which switches the
  // light off at 0 and on above.
  .{
    .cluster = zcl.Cluster.level_control,
    .attribute = zcl.AttributeId.level_control.current_level,
    .name = "level",
    .unit = "%",
    .divisor = 2.54,
    .set = .{
      .move = .{
        .command = zcl.ClusterCommand.level_control.move_to_level_with_on_off,
        .type = zcl.Type.uint8,
        .max = 254,
      },
    },
  },
  // Color Control: ColorTemperatureMireds, in kelvins; CurrentHue, 0 to 254 for the whole circle;
  // CurrentSaturation, 0 to 254; CurrentX and CurrentY, the CIE 1931 chromaticity, in 65536ths.
  .{
    .cluster = zcl.Cluster.color_control,
    .attribute = zcl.AttributeId.color_control.color_temperature_mireds,
    .name = "color_temperature",
    .unit = "K",
    .divisor = 1_000_000,
    .inverse = true,
    // Move to Color Temperature, within ColorTempPhysicalMinMireds and MaxMireds.
    .set = .{
      .move = .{
        .command = zcl.ClusterCommand.color_control.move_to_color_temperature,
        .type = zcl.Type.uint16,
        .max = 0xfeff,
        .bounds = .{
          zcl.AttributeId.color_control.physical_min_mireds,
          zcl.AttributeId.color_control.physical_max_mireds,
        },
      },
    },
  },
  // Move to Hue, the shortest way round.
  .{
    .cluster = zcl.Cluster.color_control,
    .attribute = zcl.AttributeId.color_control.current_hue,
    .name = "hue",
    .unit = "°",
    .divisor = 254.0 / 360.0,
    .set = .{
      .move = .{
        .command = zcl.ClusterCommand.color_control.move_to_hue,
        .type = zcl.Type.uint8,
        .max = 254,
        .direction = true,
      },
    },
  },
  // Move to Saturation.
  .{
    .cluster = zcl.Cluster.color_control,
    .attribute = zcl.AttributeId.color_control.current_saturation,
    .name = "saturation",
    .unit = "%",
    .divisor = 2.54,
    .set = .{
      .move = .{
        .command = zcl.ClusterCommand.color_control.move_to_saturation,
        .type = zcl.Type.uint8,
        .max = 254,
      },
    },
  },
  .{
    .cluster = zcl.Cluster.color_control,
    .attribute = zcl.AttributeId.color_control.current_x,
    .name = "color_x",
    .unit = "",
    .divisor = 65536,
  },
  .{
    .cluster = zcl.Cluster.color_control,
    .attribute = zcl.AttributeId.color_control.current_y,
    .name = "color_y",
    .unit = "",
    .divisor = 65536,
  },
  // Temperature Measurement: hundredths of a degree.
  .{
    .cluster = zcl.Cluster.temperature,
    .attribute = zcl.AttributeId.measured_value,
    .name = "temperature",
    .unit = "°C",
    .divisor = 100,
  },
  // Relative Humidity Measurement: hundredths of a percent.
  .{
    .cluster = zcl.Cluster.humidity,
    .attribute = zcl.AttributeId.measured_value,
    .name = "humidity",
    .unit = "%",
    .divisor = 100,
  },
  // Pressure Measurement: tenths of a kilopascal, which are hectopascals.
  .{
    .cluster = zcl.Cluster.pressure,
    .attribute = zcl.AttributeId.measured_value,
    .name = "pressure",
    .unit = "hPa",
  },
  // Power Configuration: BatteryPercentageRemaining in halves of a percent, BatteryVoltage in
  // tenths of a volt.
  .{
    .cluster = zcl.Cluster.power_configuration,
    .attribute = zcl.AttributeId.power_configuration.battery_percentage_remaining,
    .name = "battery",
    .unit = "%",
    .divisor = 2,
  },
  .{
    .cluster = zcl.Cluster.power_configuration,
    .attribute = zcl.AttributeId.power_configuration.battery_voltage,
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
  if (definition.inverse and raw == 0) return null;
  return .{
    .name = definition.name.ptr,
    .unit = definition.unit.ptr,
    .value = if (definition.inverse) definition.divisor / raw else raw / definition.divisor,
  };
}

/// The longest transition a setting takes, in seconds: 0xfffe tenths, SKEP_MAX_TRANSITION.
pub const max_transition = 6553.4;

/// Why a setting cannot be made: a value out of the reading's range, or a value, transition or
/// reading that is not one at all.
pub const SettingError = error{ OutOfRange, Invalid };

/// The values a settable reading takes, in its unit, within `limits` of the attribute's own if the
/// device has some, such as a light's range of colour temperatures.
pub fn range(definition: *const Definition, limits: ?[2]u64) [2]f64 {
  const set = definition.set orelse return .{ 0, 0 };
  switch (set) {
    .on_off => return .{ 0, 1 },
    .move => |m| {
      const raw: [2]f64 = if (limits) |l|
        .{ @floatFromInt(l[0]), @floatFromInt(l[1]) }
      else
        .{ if (definition.inverse) 1 else 0, @floatFromInt(m.max) };
      if (definition.inverse) return .{ definition.divisor / raw[1], definition.divisor / raw[0] };
      return .{ raw[0] / definition.divisor, raw[1] / definition.divisor };
    },
  }
}

/// The command that sets a reading to a value in its unit, over a transition in seconds where it
/// takes one, within `limits` of the attribute's own if the device has some.
pub fn setting(
  definition: *const Definition,
  value: f64,
  transition: f64,
  limits: ?[2]u64,
) SettingError!Command {
  const set = definition.set orelse return error.Invalid;
  if (!std.math.isFinite(value)) return error.Invalid;
  switch (set) {
    .on_off => return .{
      .id = if (value != 0) zcl.ClusterCommand.on_off.on else zcl.ClusterCommand.on_off.off,
    },
    .move => |m| {
      const tenths = try transitionOf(transition);
      if (definition.inverse and value <= 0) return error.OutOfRange;
      const raw = @round(
        if (definition.inverse) definition.divisor / value else value * definition.divisor,
      );
      if (!(raw >= 0 and raw <= @as(f64, @floatFromInt(m.max)))) return error.OutOfRange;
      if (limits) |l| {
        if (raw < @as(f64, @floatFromInt(l[0])) or raw > @as(f64, @floatFromInt(l[1]))) {
          return error.OutOfRange;
        }
      }
      var c: Command = .{ .id = m.command };
      c.add(.unsigned(m.type, @intFromFloat(raw)));
      if (m.direction) {
        c.add(.unsigned(zcl.Type.enum8, 0));
      }
      c.add(.unsigned(zcl.Type.uint16, tenths));
      return c;
    },
  }
}

/// The command that sets a light's colour, an sRGB colour as 0xRRGGBB, over a transition in
/// seconds: Color Control's Move to Color, with the colour's CIE 1931 chromaticity. Its brightness
/// is left to the level; black has none, and is invalid.
pub fn colorSetting(rgb: u32, transition: f64) SettingError!Command {
  if (rgb > 0xffffff) return error.Invalid;
  const tenths = try transitionOf(transition);
  // sRGB to linear light, then to CIE 1931 XYZ (IEC 61966-2-1).
  var linear: [3]f64 = undefined;
  for (&linear, [_]u5{ 16, 8, 0 }) |*l, shift| {
    const v = @as(f64, @floatFromInt((rgb >> shift) & 0xff)) / 255;
    l.* = if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
  }
  const r, const g, const b = linear;
  const x = 0.4124 * r + 0.3576 * g + 0.1805 * b;
  const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const z = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  const sum = x + y + z;
  if (sum == 0) return error.Invalid;
  var c: Command = .{ .id = zcl.ClusterCommand.color_control.move_to_color };
  for ([_]f64{ x / sum, y / sum }) |coordinate| {
    c.add(.unsigned(zcl.Type.uint16, @intFromFloat(@min(@round(coordinate * 65536), 0xfeff))));
  }
  c.add(.unsigned(zcl.Type.uint16, tenths));
  return c;
}

/// A transition in seconds, in the tenths of a second commands take; null if it does not fit.
fn transitionOf(seconds: f64) SettingError!u64 {
  if (!(seconds >= 0 and seconds <= max_transition)) return error.Invalid;
  return @intFromFloat(@round(seconds * 10));
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
  // Mireds, in kelvins.
  const color_temperature = find(&.{}, 0x0300, 0x0007).?;
  try testing.expectEqual(4000, read(color_temperature, .unsigned(zcl.Type.uint16, 250)).?.value);
  try testing.expectEqual(null, read(color_temperature, .unsigned(zcl.Type.uint16, 0)));
  const hue = find(&.{}, 0x0300, 0x0000).?;
  try testing.expectApproxEqAbs(180, read(hue, .unsigned(zcl.Type.uint8, 127)).?.value, 1e-9);
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

fn expectArguments(command: Command, id: u8, arguments: []const u64) !void {
  try testing.expectEqual(id, command.id);
  try testing.expectEqual(arguments.len, command.count);
  for (arguments, command.arguments[0..command.count]) |expected, actual| {
    try testing.expectEqual(expected, actual.v.u);
  }
}

test "readings are set by their clusters' commands, scaled back" {
  const level = find(&.{}, 0x0008, 0x0000).?;
  // 50 %, over 1 s: Move to Level with On/Off.
  try expectArguments(try setting(level, 50, 1, null), 0x04, &.{ 127, 10 });
  try testing.expectError(error.OutOfRange, setting(level, 101, 0, null));
  try testing.expectError(error.OutOfRange, setting(level, -1, 0, null));
  try testing.expectError(error.Invalid, setting(level, 50, -1, null));
  try testing.expectError(error.Invalid, setting(level, std.math.nan(f64), 0, null));
  // 2700 K: 370 mireds.
  try expectArguments(try setting(find(&.{}, 0x0300, 0x0007).?, 2700, 0, null), 0x0a, &.{ 370, 0 });
  try testing.expectError(error.OutOfRange, setting(find(&.{}, 0x0300, 0x0007).?, 0, 0, null));
  // 180°, the shortest way round.
  try expectArguments(
    try setting(find(&.{}, 0x0300, 0x0000).?, 180, 0, null),
    0x00,
    &.{ 127, 0, 0 },
  );
  const on = find(&.{}, 0x0006, 0x0000).?;
  try expectArguments(try setting(on, 1, 0, null), 0x01, &.{});
  try expectArguments(try setting(on, 0, 0, null), 0x00, &.{});
  // A light's own range: 142 to 454 mireds, 2203 to 7042 K.
  const color_temperature = find(&.{}, 0x0300, 0x0007).?;
  try testing.expectError(error.OutOfRange, setting(color_temperature, 1000, 0, .{ 142, 454 }));
  try expectArguments(try setting(color_temperature, 2700, 0, .{ 142, 454 }), 0x0a, &.{ 370, 0 });
  const kelvins = range(color_temperature, .{ 142, 454 });
  try testing.expectApproxEqAbs(2202.6, kelvins[0], 0.1);
  try testing.expectApproxEqAbs(7042.3, kelvins[1], 0.1);
  try testing.expectEqual(.{ 0, 100 }, range(level, null));
  // Not settable.
  try testing.expectError(error.Invalid, setting(find(&.{}, 0x0402, 0x0000).?, 20, 0, null));
}

test "colours are set by their chromaticity" {
  // sRGB's red primary, and its white point, D65.
  try expectArguments(try colorSetting(0xff0000, 0.5), 0x07, &.{ 0xa3dc, 0x5479, 5 });
  try expectArguments(try colorSetting(0xffffff, 0), 0x07, &.{ 0x500e, 0x5439, 0 });
  // Brightness is the level's: a darker orange has the same chromaticity.
  try expectArguments(try colorSetting(0xff8000, 0), 0x07, &.{ 0x8b03, 0x6833, 0 });
  try testing.expectError(error.Invalid, colorSetting(0x000000, 0));
  try testing.expectError(error.Invalid, colorSetting(0x1000000, 0));
}

test "a reading's limits are a device's bounds when they make a range" {
  const temperature = find(
    &.{},
    zcl.Cluster.color_control,
    zcl.AttributeId.color_control.color_temperature_mireds,
  ).?;
  try testing.expectEqual(
    [2]u16{
      zcl.AttributeId.color_control.physical_min_mireds,
      zcl.AttributeId.color_control.physical_max_mireds,
    },
    boundsOf(temperature).?,
  );
  try testing.expectEqual([2]u64{ 142, 454 }, deviceLimits(temperature, 142, 454).?);
  try testing.expectEqual(null, deviceLimits(temperature, 142, null));
  try testing.expectEqual(null, deviceLimits(temperature, 454, 142));
  // 0 mireds is no temperature; above the attribute's greatest is none either.
  try testing.expectEqual(null, deviceLimits(temperature, 0, 454));
  try testing.expectEqual(null, deviceLimits(temperature, 142, 0xffff));
  const level = find(&.{}, zcl.Cluster.level_control, 0x0000).?;
  try testing.expectEqual(null, boundsOf(level));
}
