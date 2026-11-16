//! What libskep knows of particular devices: the steps that set one up once it is interviewed,
//! binding its clusters to the coordinator and configuring their reporting.
//!
//! A device is found by the model identifier of its Basic cluster. One that is not known is
//! interviewed and needs no setup: its endpoints and clusters are known, and requests can bind
//! and configure it.
//!
//! The entries are ported from zigbee-herdsman-converters (src/devices/third_reality.ts, and the
//! reporting defaults of src/lib/modernExtend.ts and src/lib/reporting.ts):
//!
//!   MIT License
//!
//!   Copyright (c) 2018 Koen Kanters
//!
//!   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//!   software and associated documentation files (the "Software"), to deal in the Software
//!   without restriction, including without limitation the rights to use, copy, modify, merge,
//!   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
//!   to whom the Software is furnished to do so, subject to the following conditions:
//!
//!   The above copyright notice and this permission notice shall be included in all copies or
//!   substantial portions of the Software.
//!
//!   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//!   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
//!   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
//!   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//!   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//!   DEALINGS IN THE SOFTWARE.

const std = @import("std");
const readings = @import("readings.zig");
const zcl = @import("zcl.zig");

pub const Step = union(enum) {
  /// Bind a cluster of an endpoint to the coordinator, so that the device sends it reports.
  bind: struct { endpoint: u8, cluster: u16 },
  /// Configure how the device reports an attribute.
  report: struct { endpoint: u8, cluster: u16, reporting: zcl.Reporting },
};

pub const Entry = struct {
  /// The model identifier the device gives in its Basic cluster.
  model: []const u8,
  steps: []const Step,
  /// Readings whose scale is the device's, or that it gets wrong, before the standard ones.
  readings: []const readings.Definition = &.{},
};

pub const Cluster = struct {
  pub const basic: u16 = 0x0000;
  pub const power_configuration: u16 = 0x0001;
  pub const on_off: u16 = 0x0006;
  pub const temperature: u16 = 0x0402;
  pub const humidity: u16 = 0x0405;
  pub const metering: u16 = 0x0702;
  pub const electrical_measurement: u16 = 0x0b04;
};

/// Seconds: the longest interval zigbee-herdsman-converters asks for.
const max_interval = 65000;
const hour = 3600;

fn report(endpoint: u8, cluster: u16, attribute: u16, t: u8, min: u16, max: u16, change: u64) Step {
  return .{
    .report = .{
      .endpoint = endpoint,
      .cluster = cluster,
      .reporting = .{
        .attribute = attribute,
        .type = t,
        .min_interval = min,
        .max_interval = max,
        .change = .unsigned(t, change),
      },
    },
  };
}

pub const entries = [_]Entry{
  // ThirdReality Temperature and Humidity Sensor Lite.
  .{
    .model = "3RTHS0224Z",
    .steps = &.{
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.temperature } },
      // MeasuredValue, in hundredths of a degree: on a change of 1 °C.
      report(1, Cluster.temperature, 0x0000, zcl.Type.int16, 10, hour, 100),
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.humidity } },
      // MeasuredValue, in hundredths of a percent: on a change of 1 %.
      report(1, Cluster.humidity, 0x0000, zcl.Type.uint16, 10, hour, 100),
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.power_configuration } },
      // BatteryPercentageRemaining, in halves of a percent: on a change of 5 %.
      report(1, Cluster.power_configuration, 0x0021, zcl.Type.uint8, hour, max_interval, 10),
    },
  },
  // ThirdReality Smart Plug E2.
  .{
    .model = "3RSPE01044BZ",
    .steps = &.{
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.on_off } },
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.electrical_measurement } },
      .{ .bind = .{ .endpoint = 1, .cluster = Cluster.metering } },
      // OnOff, whenever it changes.
      report(1, Cluster.on_off, 0x0000, zcl.Type.boolean, 0, hour, 0),
      // ActivePower, in tenths of a watt: on a change of 1 W.
      report(1, Cluster.electrical_measurement, 0x050b, zcl.Type.int16, 5, hour, 10),
      // RMSCurrent, in milliamperes: on a change of 0.05 A.
      report(1, Cluster.electrical_measurement, 0x0508, zcl.Type.uint16, 5, hour, 50),
      // RMSVoltage, in tenths of a volt: on a change of 0.5 V.
      report(1, Cluster.electrical_measurement, 0x0505, zcl.Type.uint16, 5, hour, 5),
    },
    // Its multipliers and divisors are not to be trusted: zigbee-herdsman-converters fixes them.
    .readings = &.{
      .{
        .cluster = Cluster.electrical_measurement,
        .attribute = 0x050b,
        .name = "power",
        .unit = "W",
        .divisor = 10,
      },
      .{
        .cluster = Cluster.metering,
        .attribute = 0x0000,
        .name = "energy",
        .unit = "kWh",
        .divisor = 3600000,
      },
      .{
        .cluster = Cluster.electrical_measurement,
        .attribute = 0x0505,
        .name = "voltage",
        .unit = "V",
        .divisor = 10,
      },
      .{
        .cluster = Cluster.electrical_measurement,
        .attribute = 0x0508,
        .name = "current",
        .unit = "A",
        .divisor = 1000,
      },
      .{
        .cluster = Cluster.electrical_measurement,
        .attribute = 0x0510,
        .name = "power_factor",
        .unit = "",
        .divisor = 100,
      },
      .{
        .cluster = Cluster.electrical_measurement,
        .attribute = 0x0300,
        .name = "frequency",
        .unit = "Hz",
      },
    },
  },
};

/// The entry of a device of this model, if libskep knows it.
pub fn find(model: []const u8) ?*const Entry {
  for (&entries) |*entry| {
    if (std.mem.eql(u8, entry.model, model)) return entry;
  }
  return null;
}

test "devices are found by model" {
  const sensor = find("3RTHS0224Z").?;
  try std.testing.expectEqual(6, sensor.steps.len);
  try std.testing.expectEqual(Cluster.temperature, sensor.steps[0].bind.cluster);
  try std.testing.expectEqual(null, find("3RTHS0224"));
  // Each reporting step reports a cluster an earlier step bound.
  for (entries) |entry| {
    for (entry.steps, 0..) |step, i| {
      const r = switch (step) {
        .report => |r| r,
        .bind => continue,
      };
      for (entry.steps[0..i]) |earlier| {
        if (earlier == .bind and
          earlier.bind.cluster == r.cluster and
          earlier.bind.endpoint == r.endpoint) {
          break;
        }
      } else {
        return error.TestUnboundReport;
      }
    }
  }
}
