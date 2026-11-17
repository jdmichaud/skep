//! The sim driver: a simulated dongle, for tests that need no hardware. No byte goes to any line.
//!
//! It holds a network and its keys, as the test gave them or as it formed them, and reports
//! devices the test makes join; it grows with the driver interface, so that each feature can be
//! tested without a dongle.

const std = @import("std");
const driver = @import("../driver.zig");
const zcl = @import("../../zcl.zig");
const zdo = @import("../../zdo.zig");

/// A simulated device, which answers its interview and setup as the ThirdReality sensor does.
pub const Device = struct {
  ieee: u64,
  nwk: u16,
  /// Its receiver is on when idle: false for a sleepy end device.
  rx_on_when_idle: bool = true,
  manufacturer: []const u8 = "Third Reality, Inc",
  model: []const u8 = "3RTHS0224Z",
  /// The input and output clusters of its only endpoint, 1.
  input_clusters: []const u16 = &.{ 0x0000, 0x0001, 0x0003, 0x0402, 0x0405 },
  output_clusters: []const u16 = &.{ 0x0019 },
  /// Picks nothing up, and answers nothing: asleep, or gone.
  silent: bool = false,
  /// The ZDO status it answers bindings with.
  bind_status: u8 = 0,
  /// The colour temperatures it shows, in mireds, if it is such a light.
  color_temperature_range: ?[2]u16 = null,
  /// The values of its endpoint's attributes, which it answers reads with.
  attributes: []const Attribute = &.{},
  /// What it accepted.
  binds: u8 = 0,
  configurations: u8 = 0,
};

/// An attribute of a simulated device's cluster, and its value.
pub const Attribute = struct {
  cluster: u16,
  id: u16,
  value: zcl.Value,
};

pub const Driver = struct {
  /// The network the simulated dongle holds. Tests set it before `start`, and advance its
  /// frame counters as they like.
  network: ?driver.Held = null,
  /// The coordinator's IEEE address: a locally administered one (bit 1 of the first byte), which
  /// no manufactured device carries.
  ieee: u64 = 0x0200_0000_0000_0001,
  pending: [32]driver.Event = undefined,
  pending_len: usize = 0,
  /// The messages sent, the last ones if more were.
  sent: [16]driver.Frame = undefined,
  sent_len: usize = 0,
  /// The devices of the simulated network, which the test owns and changes as it likes.
  devices: []Device = &.{},

  pub fn start(d: *Driver) void {
    d.pending_len = 0;
    d.post(.{
      .ready = .{
        .ieee = d.ieee,
        .network = d.network,
        .firmware = .init("simulated dongle", .{}),
      },
    });
  }

  /// Forms the network: the simulated dongle holds it from now on.
  pub fn form(d: *Driver, f: driver.Form) void {
    var held: driver.Held = .{ .network = f.network, .security = f.security };
    if (!f.restore) {
      held.security.network_frame_counter = 0;
      held.security.trust_center_frame_counter = 0;
    }
    d.network = held;
    d.post(.{ .formed = held });
  }

  pub fn refresh(d: *Driver) void {
    d.post(.{ .refreshed = d.network.? });
  }

  pub fn permitJoin(d: *Driver, seconds: u8) void {
    d.post(.{ .permit_join_done = null });
    d.post(.{ .join_window = seconds > 0 });
  }

  /// Takes the message; it is delivered at once.
  pub fn send(d: *Driver, message: *const driver.Frame) void {
    if (d.sent_len == d.sent.len) {
      std.mem.copyForwards(driver.Frame, d.sent[0..d.sent.len - 1], d.sent[1..]);
      d.sent_len -= 1;
    }
    d.sent[d.sent_len] = message.*;
    d.sent_len += 1;
    d.post(.{ .send_done = .{ .tag = message.tag, .failure = null } });
    const to = if (message.broadcast) null else d.deviceAt(message.address);
    if (to) |dev| {
      d.post(.{ .delivered = .{ .tag = message.tag, .ok = !dev.silent } });
      if (!dev.silent) {
        d.answer(dev, message);
      }
    } else {
      d.post(.{ .delivered = .{ .tag = message.tag, .ok = true } });
    }
  }

  fn deviceAt(d: *Driver, nwk: u16) ?*Device {
    for (d.devices) |*dev| {
      if (dev.nwk == nwk) return dev;
    }
    return null;
  }

  /// A simulated device answers a frame.
  fn answer(d: *Driver, dev: *Device, message: *const driver.Frame) void {
    var reply: driver.Frame = .{
      .address = dev.nwk,
      .profile = message.profile,
      .cluster = message.cluster,
      .source_endpoint = message.destination_endpoint,
      .destination_endpoint = message.source_endpoint,
    };
    var w: std.Io.Writer = .fixed(&reply.payload);
    if (message.profile == zdo.profile) {
      const request = message.bytes();
      reply.cluster = message.cluster | zdo.Cluster.response;
      w.writeByte(request[0]) catch unreachable;
      switch (message.cluster) {
        zdo.Cluster.node_descriptor_request => {
          w.writeAll(&.{ 0, @truncate(dev.nwk), @truncate(dev.nwk >> 8) }) catch unreachable;
          const logical: u8 = if (dev.rx_on_when_idle) 1 else 2;
          const capabilities: u8 = if (dev.rx_on_when_idle) 0x8e else 0x80;
          w.writeAll(
            &.{
              logical,
              0x40,
              capabilities,
              0x07,
              0x14,
              0x52,
              0x80,
              0x00,
              0x00,
              0x2c,
              0x80,
              0x00,
              0x00,
            },
          ) catch unreachable;
        },
        zdo.Cluster.active_endpoints_request => {
          w.writeAll(&.{ 0, @truncate(dev.nwk), @truncate(dev.nwk >> 8), 1, 1 }) catch unreachable;
        },
        zdo.Cluster.simple_descriptor_request => {
          const len = 8 + 2 * (dev.input_clusters.len + dev.output_clusters.len);
          w.writeAll(
            &.{
              0,
              @truncate(dev.nwk),
              @truncate(dev.nwk >> 8),
              @intCast(len),
              1,
              0x04,
              0x01,
              0x02,
              0x03,
              0,
            },
          ) catch unreachable;
          w.writeByte(@intCast(dev.input_clusters.len)) catch unreachable;
          for (dev.input_clusters) |c| {
            w.writeInt(u16, c, .little) catch unreachable;
          }
          w.writeByte(@intCast(dev.output_clusters.len)) catch unreachable;
          for (dev.output_clusters) |c| {
            w.writeInt(u16, c, .little) catch unreachable;
          }
        },
        zdo.Cluster.bind_request, zdo.Cluster.unbind_request => {
          w.writeByte(dev.bind_status) catch unreachable;
          if (dev.bind_status == 0) {
            dev.binds += 1;
          }
        },
        else => w.writeByte(zdo.Status.not_supported) catch unreachable,
      }
    } else {
      const request = zcl.Frame.parse(message.bytes()) catch return;
      const h = request.header;
      var response: zcl.Header = .{
        .cluster_specific = false,
        .from_server = true,
        .disable_default_response = true,
        .sequence = h.sequence,
        .command = zcl.Command.default_response,
      };
      if (h.cluster_specific) {
        response.write(&w) catch unreachable;
        w.writeAll(&.{ h.command, zcl.Status.success }) catch unreachable;
      } else {
        switch (h.command) {
          zcl.Command.read_attributes => {
            response.command = zcl.Command.read_attributes_response;
            response.write(&w) catch unreachable;
            var i: usize = 0;
            while (i + 2 <= request.payload.len) : (i += 2) {
              const id = std.mem.readInt(u16, request.payload[i..][0..2], .little);
              w.writeInt(u16, id, .little) catch unreachable;
              const text: ?[]const u8 = if (message.cluster != zcl.Cluster.basic)
                null
              else switch (id) {
                zcl.AttributeId.basic.manufacturer_name => dev.manufacturer,
                zcl.AttributeId.basic.model_identifier => dev.model,
                else => null,
              };
              const mireds: ?u16 = if (message.cluster != zcl.Cluster.color_control)
                null
              else switch (id) {
                zcl.AttributeId.color_control.physical_min_mireds,
                => if (dev.color_temperature_range) |r| r[0] else null,
                zcl.AttributeId.color_control.physical_max_mireds,
                => if (dev.color_temperature_range) |r| r[1] else null,
                else => null,
              };
              if (text) |t| {
                w.writeAll(&.{ zcl.Status.success, zcl.Type.char_string, @intCast(t.len) }) catch
                  unreachable;
                w.writeAll(t) catch unreachable;
              } else if (mireds) |m| {
                w.writeAll(&.{ zcl.Status.success, zcl.Type.uint16 }) catch unreachable;
                w.writeInt(u16, m, .little) catch unreachable;
              } else if (valueOf(dev, message.cluster, id)) |v| {
                w.writeAll(&.{ zcl.Status.success, v.type }) catch unreachable;
                zcl.writeValue(&w, v) catch unreachable;
              } else {
                w.writeByte(zcl.Status.unsupported_attribute) catch unreachable;
              }
            }
          },
          zcl.Command.configure_reporting => {
            response.command = zcl.Command.configure_reporting_response;
            response.write(&w) catch unreachable;
            w.writeByte(zcl.Status.success) catch unreachable;
            dev.configurations += 1;
          },
          zcl.Command.write_attributes => {
            response.command = zcl.Command.write_attributes_response;
            response.write(&w) catch unreachable;
            w.writeByte(zcl.Status.success) catch unreachable;
          },
          else => return,
        }
      }
    }
    reply.len = @intCast(w.end);
    d.post(.{ .message = reply });
  }

  /// A simulated device reports attributes of a cluster of its endpoint 1, the records given in
  /// their ZCL encoding. For tests.
  pub fn report(d: *Driver, dev: *const Device, cluster: u16, records: []const u8) void {
    var frame: driver.Frame = .{
      .address = dev.nwk,
      .profile = 0x0104,
      .cluster = cluster,
      .source_endpoint = 1,
      .destination_endpoint = 1,
    };
    var w: std.Io.Writer = .fixed(&frame.payload);
    const header: zcl.Header = .{
      .cluster_specific = false,
      .from_server = true,
      .disable_default_response = true,
      .sequence = 0x40,
      .command = zcl.Command.report_attributes,
    };
    header.write(&w) catch unreachable;
    w.writeAll(records) catch unreachable;
    frame.len = @intCast(w.end);
    d.post(.{ .message = frame });
  }

  /// A message comes in from a device. For tests.
  pub fn receive(d: *Driver, message: driver.Frame) void {
    d.post(.{ .message = message });
  }

  /// A simulated device joins, rejoins or leaves. For tests.
  pub fn device(d: *Driver, change: driver.Device) void {
    d.post(.{ .device = change });
  }

  fn post(d: *Driver, event: driver.Event) void {
    // Tests post few events between calls.
    d.pending[d.pending_len] = event;
    d.pending_len += 1;
  }

  pub fn input(_: *Driver, _: []const u8, _: u64) void {}

  pub fn output(_: *const Driver) []const u8 {
    return &.{};
  }

  pub fn outputDone(_: *Driver, _: usize, _: u64) void {}

  /// Now while it holds events, as the loop of skep.h has it: the application then calls
  /// skep_advance(), which takes them.
  pub fn nextDeadline(d: *const Driver) ?u64 {
    return if (d.pending_len > 0) 0 else null;
  }

  pub fn advance(_: *Driver, _: u64) void {}

  pub fn nextEvent(d: *Driver) ?driver.Event {
    if (d.pending_len == 0) return null;
    const event = d.pending[0];
    std.mem.copyForwards(
      driver.Event,
      d.pending[0..d.pending_len - 1],
      d.pending[1..d.pending_len],
    );
    d.pending_len -= 1;
    return event;
  }
};

/// A network for tests, with keys of no importance.
fn valueOf(dev: *const Device, cluster: u16, id: u16) ?zcl.Value {
  for (dev.attributes) |a| {
    if (a.cluster == cluster and a.id == id) return a.value;
  }
  return null;
}

pub fn testNetwork(network: driver.Network) driver.Held {
  return .{
    .network = network,
    .security = .{ .network_key = @splat(0x22), .trust_center_link_key = @splat(0x11) },
  };
}

test "the simulated dongle reports the network it was given" {
  var d: Driver = .{
    .network = testNetwork(.{ .channel = 20, .pan_id = 0x1a62, .extended_pan_id = 1 }),
  };
  d.start();
  const ready = d.nextEvent().?.ready;
  try std.testing.expectEqual(20, ready.network.?.network.channel);
  try std.testing.expectEqual(null, d.nextEvent());
}
