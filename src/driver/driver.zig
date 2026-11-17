//! The interface between libskep and the drivers that talk to dongles. Drivers do no I/O either:
//! the context hands them the bytes and the time it gets from the application.
//!
//! Drivers form a tagged union rather than a table of function pointers: they are internal and
//! few, chosen by name at run time, and a switch lets the compiler check that each one implements
//! every operation. What a driver reports is translated here into events that know nothing of the
//! dongle, so nothing outside a driver depends on one.

const std = @import("std");
const ezsp_adapter = @import("ezsp/adapter.zig");
const sim = @import("sim/sim.zig");

pub const Name = enum { ezsp, sim };

pub const FlowControl = enum { none, software, hardware };

pub const SerialDefaults = struct {
  baudrate: u32,
  flow_control: FlowControl,
};

/// A Zigbee network, as far as the rest of libskep cares.
pub const Network = struct {
  channel: u8,
  pan_id: u16,
  extended_pan_id: u64,
  /// Raised each time the network moves to another channel.
  update_id: u8 = 0,
};

/// A network's keys, and the outgoing frame counters that devices check the coordinator's frames
/// against: each frame must carry a higher counter than the last they saw.
pub const Security = struct {
  network_key: [16]u8,
  network_key_sequence_number: u8 = 0,
  network_frame_counter: u32 = 0,
  /// The key from which the trust center derives the link keys it gives devices.
  trust_center_link_key: [16]u8,
  /// Null when the dongle does not tell.
  trust_center_frame_counter: ?u32 = 0,
};

/// A network as a dongle holds it: what it is, and its keys.
pub const Held = struct {
  network: Network,
  security: Security,
};

/// A short text for the log, kept in the event that carries it.
pub const Message = struct {
  buffer: [160]u8 = undefined,
  len: usize = 0,

  /// Formats a message, cut short if it does not fit.
  pub fn init(comptime format: []const u8, args: anytype) Message {
    var m: Message = .{};
    var w: std.Io.Writer = .fixed(&m.buffer);
    w.print(format, args) catch {};
    m.len = w.end;
    return m;
  }

  pub fn text(m: *const Message) []const u8 {
    return m.buffer[0..m.len];
  }
};

pub const Level = enum { err, warning, info, debug };

pub const Ready = struct {
  /// The coordinator's IEEE address.
  ieee: u64,
  /// The network the dongle holds, now up, or null if it holds none.
  network: ?Held,
  /// What the dongle runs, for the log.
  firmware: Message,
};

pub const Failure = struct {
  kind: Kind,
  message: Message,

  pub const Kind = enum {
    /// The dongle stopped answering.
    timeout,
    /// The dongle broke the protocol.
    protocol,
    /// The dongle runs firmware the driver does not support.
    unsupported,
    /// The dongle refused something the driver needs.
    refused,
  };
};

/// What `form` needs: the network, and its keys.
pub const Form = struct {
  network: Network,
  security: Security,
  /// The network is a saved one put back: its frame counters are set too, so that its devices
  /// accept the coordinator's frames. A new network starts them at 0.
  restore: bool = false,
};

/// An APS frame to or from a device: its header, and its payload.
pub const Frame = struct {
  /// For a message to send, the network address of its destination, or a broadcast address with
  /// `broadcast`; for a message received, its sender's.
  address: u16,
  broadcast: bool = false,
  profile: u16,
  cluster: u16,
  source_endpoint: u8,
  destination_endpoint: u8,
  /// Matches `send_done` and `delivered` with the message sent.
  tag: u8 = 0,
  /// Of a message received: the quality of the last hop.
  lqi: u8 = 0,
  rssi: i8 = 0,
  len: u8 = 0,
  payload: [max_payload_len]u8 = undefined,

  /// Longest payload: what fits a Zigbee frame, with room to spare.
  pub const max_payload_len = 127;

  pub fn bytes(m: *const Frame) []const u8 {
    return m.payload[0..m.len];
  }

  /// Sets the payload. It must fit.
  pub fn setPayload(m: *Frame, payload: []const u8) void {
    m.len = @intCast(payload.len);
    @memcpy(m.payload[0..payload.len], payload);
  }
};

/// A device the trust center saw join, rejoin or leave.
pub const Device = struct {
  ieee: u64,
  /// Its network address.
  nwk: u16,
  kind: enum { joined, rejoined, left },
};

pub const Event = union(enum) {
  ready: Ready,
  /// `form` formed the network.
  formed: Held,
  /// `refresh` read the network again.
  refreshed: Held,
  /// `permitJoin` was done: null if it worked, why not otherwise.
  permit_join_done: ?Failure,
  /// The join window opened (true) or closed.
  join_window: bool,
  device: Device,
  /// `send` is done: null if the dongle took the message, why not otherwise.
  send_done: struct { tag: u8, failure: ?Failure },
  /// What became of a message the dongle took: delivered (acknowledged, for a unicast), or not.
  delivered: struct { tag: u8, ok: bool },
  /// A frame for the coordinator.
  message: Frame,
  failed: Failure,
  log: struct { level: Level, message: Message },
};

pub const Driver = union(Name) {
  ezsp: ezsp_adapter.Adapter,
  sim: sim.Driver,

  /// A driver, for a port opened with `flow_control`, or the driver's usual one if null, with
  /// the radio's transmit power in dBm, or the dongle's own if null.
  pub fn init(name: Name, flow_control: ?FlowControl, tx_power: ?i8) Driver {
    return switch (name) {
      .ezsp => .{ .ezsp = .init(flow_control, tx_power) },
      .sim => .{ .sim = .{} },
    };
  }

  /// The serial settings the driver's dongles usually need, or null if it talks to none.
  pub fn serialDefaults(name: Name) ?SerialDefaults {
    return switch (name) {
      .ezsp => ezsp_adapter.serial_defaults,
      .sim => null,
    };
  }

  pub fn start(d: *Driver) void {
    switch (d.*) {
      inline else => |*driver| driver.start(),
    }
  }

  /// Forms a network, new or saved, once the driver is ready, replacing the dongle's if it holds
  /// one.
  pub fn form(d: *Driver, f: Form) void {
    switch (d.*) {
      inline else => |*driver| driver.form(f),
    }
  }

  /// Sends a message, once the network is up. Reports `send_done`, then `delivered`.
  pub fn send(d: *Driver, message: *const Frame) void {
    switch (d.*) {
      inline else => |*driver| driver.send(message),
    }
  }

  /// Reads the network, its keys and frame counters again, once the network is up.
  pub fn refresh(d: *Driver) void {
    switch (d.*) {
      inline else => |*driver| driver.refresh(),
    }
  }

  /// Opens the network to new devices for `seconds`, or closes it with 0, once the network is up.
  /// The dongle only opens itself: libskep tells the routers, with a broadcast. A window that ends
  /// on its own may leave the trust center admitting devices: libskep closes it with 0.
  pub fn permitJoin(d: *Driver, seconds: u8) void {
    switch (d.*) {
      inline else => |*driver| driver.permitJoin(seconds),
    }
  }

  pub fn input(d: *Driver, bytes: []const u8, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.input(bytes, now),
    }
  }

  pub fn output(d: *const Driver) []const u8 {
    return switch (d.*) {
      inline else => |*driver| driver.output(),
    };
  }

  pub fn outputDone(d: *Driver, len: usize, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.outputDone(len, now),
    }
  }

  pub fn nextDeadline(d: *const Driver) ?u64 {
    return switch (d.*) {
      inline else => |*driver| driver.nextDeadline(),
    };
  }

  pub fn advance(d: *Driver, now: u64) void {
    switch (d.*) {
      inline else => |*driver| driver.advance(now),
    }
  }

  pub fn nextEvent(d: *Driver) ?Event {
    return switch (d.*) {
      inline else => |*driver| driver.nextEvent(),
    };
  }
};

const testing = std.testing;

test "messages are cut short rather than lost" {
  const x: [300]u8 = @splat('x');
  const long: Message = .init("{s}", .{ &x });
  try testing.expectEqual(160, long.text().len);
  const short: Message = .init("EZSP {d}", .{ 8 });
  try testing.expectEqualStrings("EZSP 8", short.text());
}

test "the sim driver talks to no serial device" {
  try testing.expectEqual(null, Driver.serialDefaults(.sim));
  try testing.expectEqual(115200, Driver.serialDefaults(.ezsp).?.baudrate);
}
