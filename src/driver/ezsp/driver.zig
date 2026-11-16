//! The ezsp driver: starts an EmberZNet NCP and brings up the network it holds, if any.
//!
//! After the startup (`startup.zig`), the host configures the NCP, registers the coordinator's
//! endpoint, and calls `network_init`, which brings up the network stored on the dongle; then it
//! reads the network's parameters and the coordinator's IEEE address. This follows
//! zigbee-herdsman's ember driver (src/adapter/ember/adapter/emberAdapter.ts, MIT licensed). None of
//! these steps changes the network stored on the dongle: configuration and endpoints live in the
//! NCP's RAM, and the reset clears them.
//!
//! Like the link under it, the driver does no I/O.

const std = @import("std");
const command = @import("command.zig");
const frame = @import("frame.zig");
const link_layer = @import("link.zig");
const startup_layer = @import("startup.zig");
const test_ncp = @import("test_ncp.zig");

/// How long the NCP has to answer a command, or to bring the network up, in milliseconds.
pub const response_timeout = startup_layer.response_timeout;

/// Configuration values, as zigbee-herdsman sets them.
const configuration = [_]struct { id: command.ConfigId, value: u16 }{
  // Zigbee PRO, with network-level security as Zigbee 3.0 requires.
  .{ .id = .stack_profile, .value = 2 },
  .{ .id = .security_level, .value = 5 },
  // How long a parent holds a frame for a sleepy child: 7.68 s, as Zigbee PRO asks.
  .{ .id = .indirect_transmission_timeout, .value = 7680 },
  // Twice the network depth of Zigbee PRO, 15.
  .{ .id = .max_hops, .value = 30 },
  .{ .id = .max_end_device_children, .value = 32 },
  // The trust center needs it to route to devices joining through others.
  .{ .id = .trust_center_address_cache_size, .value = 2 },
};

/// The coordinator's endpoint, as zigbee-herdsman registers it (src/adapter/ember/adapter/endpoints.ts):
/// the clusters it serves and those it uses, which devices look for before binding to it.
const coordinator_endpoint: command.Endpoint = .{
  .endpoint = 1,
  // Home Automation.
  .profile_id = 0x0104,
  .device_id = 0x0065,
  .device_version = 1,
  .input_clusters = &.{ 0x0000, 0x0003, 0x0006, 0x0008, 0x000a, 0x0019, 0x0300 },
  .output_clusters = &.{
    0x0000, 0x0003, 0x0004, 0x0005, 0x0006, 0x0008, 0x0020, 0x0300, 0x0400,
    0x0402, 0x0405, 0x0406, 0x0500, 0x0702, 0x0b01, 0x0b03, 0x0b04, 0x1000,
  },
};

pub const Network = struct {
  node_type: command.NodeType,
  parameters: command.NetworkParameters,
};

pub const Ready = struct {
  version: command.Version,
  firmware: command.VersionInfo,
  /// The coordinator's IEEE address.
  ieee: u64,
  /// The network the dongle holds, now up, or null if it holds none.
  network: ?Network,
};

pub const Failure = union(enum) {
  startup: startup_layer.Failure,
  link: link_layer.Failure,
  /// The NCP did not answer a command, or did not bring its network up, in time.
  response_timeout,
  /// The NCP rejected a command, with this EZSP status.
  invalid_command: u8,
  /// The NCP refused the coordinator's endpoint.
  add_endpoint: command.Status,
  /// `network_init` failed for another reason than the absence of a network.
  network_init: command.Status,
  /// The network was up, but its parameters cannot be read.
  network_parameters: command.Status,
  /// A response that cannot be decoded.
  bad_response,
};

pub const Event = union(enum) {
  ready: Ready,
  failed: Failure,
  /// The firmware refused a configuration value and keeps its own.
  configuration_refused: struct { id: command.ConfigId, status: command.Status },
};

pub const Driver = struct {
  startup: startup_layer.Startup,
  step: Step = .idle,
  configuration_index: usize = 0,
  /// Sequence number of the last command, and when it was sent.
  sequence: u8 = 0,
  sent_at: u64 = 0,
  /// `stack_status_handler` reported the network up.
  network_up: bool = false,
  ready: Ready = undefined,
  events: [configuration.len + 1]Event = undefined,
  events_len: usize = 0,

  const Step = enum {
    idle,
    starting,
    configuring,
    adding_endpoint,
    initialising_network,
    waiting_for_network,
    reading_network,
    reading_ieee,
    finished,
  };

  pub fn init(options: link_layer.Options) Driver {
    return .{ .startup = .init(options) };
  }

  pub fn start(d: *Driver) void {
    const options = d.startup.link.options;
    d.* = .{ .startup = .init(options), .step = .starting };
    d.startup.start();
  }

  pub fn input(d: *Driver, bytes: []const u8, now: u64) void {
    if (d.step == .starting) {
      d.startup.input(bytes, now);
      d.afterStartup(now);
    } else {
      d.startup.link.input(bytes, now);
      d.process(now);
    }
  }

  pub fn output(d: *const Driver) []const u8 {
    return d.startup.link.output();
  }

  pub fn outputDone(d: *Driver, len: usize, now: u64) void {
    if (d.step == .starting) {
      d.startup.outputDone(len, now);
      d.afterStartup(now);
    } else {
      d.startup.link.outputDone(len, now);
      d.process(now);
    }
  }

  pub fn nextDeadline(d: *const Driver) ?u64 {
    if (d.step == .starting) return d.startup.nextDeadline();
    const link_deadline = d.startup.link.nextDeadline();
    const response_deadline: ?u64 = if (d.waiting()) d.sent_at + response_timeout else null;
    if (link_deadline == null) return response_deadline;
    if (response_deadline == null) return link_deadline;
    return @min(link_deadline.?, response_deadline.?);
  }

  pub fn advance(d: *Driver, now: u64) void {
    if (d.step == .starting) {
      d.startup.advance(now);
      return d.afterStartup(now);
    }
    d.startup.link.advance(now);
    d.process(now);
    if (d.waiting() and now >= d.sent_at + response_timeout) {
      d.fail(.response_timeout);
    }
  }

  pub fn nextEvent(d: *Driver) ?Event {
    if (d.events_len == 0) return null;
    const event = d.events[0];
    std.mem.copyForwards(Event, d.events[0..d.events_len - 1], d.events[1..d.events_len]);
    d.events_len -= 1;
    return event;
  }

  fn waiting(d: *const Driver) bool {
    return switch (d.step) {
      .idle, .starting, .finished => false,
      else => true,
    };
  }

  fn post(d: *Driver, event: Event) void {
    // Room for every refused configuration value, and the final event.
    d.events[d.events_len] = event;
    d.events_len += 1;
  }

  fn fail(d: *Driver, failure: Failure) void {
    d.step = .finished;
    d.post(.{ .failed = failure });
  }

  fn afterStartup(d: *Driver, now: u64) void {
    const result = d.startup.result orelse return;
    switch (result) {
      .failed => |failure| d.fail(.{ .startup = failure }),
      .done => |info| {
        d.ready = .{
          .version = info.version,
          .firmware = info.firmware,
          .ieee = 0,
          .network = null,
        };
        d.sequence = d.startup.sequence;
        d.step = .configuring;
        d.configure(now);
      },
    }
  }

  fn configure(d: *Driver, now: u64) void {
    var out: [3]u8 = undefined;
    const entry = configuration[d.configuration_index];
    d.send(
      .set_configuration_value,
      command.setConfigurationValue(&out, entry.id, entry.value),
      now,
    );
  }

  fn send(d: *Driver, id: frame.FrameId, parameters: []const u8, now: u64) void {
    var out: [5 + frame.max_parameters_len]u8 = undefined;
    d.sequence +%= 1;
    d.sent_at = now;
    d.startup.link.send(frame.encode(&out, d.sequence, id, parameters)) catch |err| switch (err) {
      // The link failed after the frame being handled arrived: its event comes next.
      error.NotConnected => {},
      // A command at a time, of the right length.
      error.QueueFull, error.InvalidLength => unreachable,
    };
  }

  fn process(d: *Driver, now: u64) void {
    while (d.startup.link.nextEvent()) |event| {
      if (d.step == .finished) continue;
      switch (event) {
        .frame => |bytes| d.receive(bytes, now),
        .failed => |failure| d.fail(.{ .link = failure }),
        // Reported by the startup's link once per reset; the link honours XON/XOFF anyway.
        .connected, .unexpected_flow_control => {},
      }
    }
  }

  fn receive(d: *Driver, bytes: []const u8, now: u64) void {
    const received = frame.decode(bytes) catch return d.fail(.bad_response);
    const version = d.ready.version.protocol_version;
    if (received.callback) {
      if (received.id == .stack_status_handler) {
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        if (status.is(.network_up)) {
          d.network_up = true;
          if (d.step == .waiting_for_network) {
            d.readNetwork(now);
          }
        }
      }
      // Other callbacks are not needed to start.
      return;
    }
    if (received.sequence != d.sequence) return;
    if (received.id == .invalid_command) {
      const status = if (received.parameters.len > 0) received.parameters[0] else 0;
      return d.fail(.{ .invalid_command = status });
    }
    switch (d.step) {
      .configuring => {
        if (received.id != .set_configuration_value) return d.fail(.bad_response);
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        const entry = configuration[d.configuration_index];
        if (!status.is(.ok)) {
          d.post(.{ .configuration_refused = .{ .id = entry.id, .status = status } });
        }
        d.configuration_index += 1;
        if (d.configuration_index < configuration.len) return d.configure(now);
        d.step = .adding_endpoint;
        var out: [8 + 2 * 32]u8 = undefined;
        d.send(.add_endpoint, coordinator_endpoint.encode(&out), now);
      },
      .adding_endpoint => {
        if (received.id != .add_endpoint) return d.fail(.bad_response);
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        if (!status.is(.ok)) return d.fail(.{ .add_endpoint = status });
        d.step = .initialising_network;
        var out: [2]u8 = undefined;
        d.send(.network_init, command.networkInit(&out), now);
      },
      .initialising_network => {
        if (received.id != .network_init) return d.fail(.bad_response);
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        if (status.is(.not_joined)) return d.readIeee(now);
        if (!status.is(.ok)) return d.fail(.{ .network_init = status });
        // The network comes up a moment later, unless it already did.
        if (d.network_up) return d.readNetwork(now);
        d.step = .waiting_for_network;
        d.sent_at = now;
      },
      .reading_network => {
        if (received.id != .get_network_parameters) return d.fail(.bad_response);
        const parsed = command.parseGetNetworkParameters(received.parameters, version) catch
          return d.fail(.bad_response);
        if (!parsed.status.is(.ok)) return d.fail(.{ .network_parameters = parsed.status });
        d.ready.network = .{ .node_type = parsed.node_type, .parameters = parsed.network };
        d.readIeee(now);
      },
      .reading_ieee => {
        if (received.id != .get_eui64) return d.fail(.bad_response);
        d.ready.ieee = command.parseEui64(received.parameters) catch return d.fail(.bad_response);
        d.step = .finished;
        d.post(.{ .ready = d.ready });
      },
      .idle, .starting, .waiting_for_network, .finished => {},
    }
  }

  fn readNetwork(d: *Driver, now: u64) void {
    d.step = .reading_network;
    d.send(.get_network_parameters, &.{}, now);
  }

  fn readIeee(d: *Driver, now: u64) void {
    d.step = .reading_ieee;
    d.send(.get_eui64, &.{}, now);
  }
};

// Tests: the driver against a scripted NCP that speaks EZSP 8, like our ZBDongle-E.

const testing = std.testing;
const hex = test_ncp.hex;
const Ncp = test_ncp.Ncp(Driver);

/// Takes the driver through the startup, to its first configuration value.
fn started(driver: *Driver) !Ncp {
  driver.* = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = driver };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&hex("0080000802306a"));
  try ncp.expectCommand(&hex("010001000008"));
  ncp.respond(&hex("01800100000802306a"));
  try ncp.expectCommand(&hex("020001aa0011"));
  ncp.respond(&hex("028001aa0000" ++ "07" ++ "2901" ++ "060a03" ++ "00" ++ "aa"));
  return ncp;
}

/// Answers the configuration values, refusing those in `refused`, and the endpoint.
fn configured(ncp: *Ncp, refused: []const usize) !void {
  for (configuration, 0..) |entry, i| {
    const sequence: u8 = @intCast(3 + i);
    var expected: [5 + 3]u8 = undefined;
    var out: [3]u8 = undefined;
    try ncp.expectCommand(
      frame.encode(
        &expected,
        sequence,
        .set_configuration_value,
        command.setConfigurationValue(&out, entry.id, entry.value),
      ),
    );
    const status: u8 = if (std.mem.indexOfScalar(usize, refused, i) != null) 0x35 else 0;
    ncp.respond(&.{ sequence, 0x80, 0x01, 0x53, 0x00, status });
  }
  const endpoint_sequence: u8 = 3 + configuration.len;
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(endpoint_sequence, sent[0]);
  try testing.expectEqual(@backingInt(frame.FrameId.add_endpoint), sent[3]);
  ncp.respond(&.{ endpoint_sequence, 0x80, 0x01, 0x02, 0x00, 0x00 });
}

test "a dongle holding a network brings it up" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  try ncp.expectCommand(&hex("0a000117000000"));
  ncp.respond(&hex("0a8001170000"));
  try testing.expectEqual(null, driver.nextEvent());
  // The network comes up: stack_status_handler, NETWORK_UP.
  ncp.respond(&hex("0a9001190090"));
  try ncp.expectCommand(&hex("0b00012800"));
  ncp.respond(
    &hex(
      "0b80012800" ++
        "00" ++
        "01" ++
        "efcdab8967452301" ++
        "3412" ++
        "05" ++
        "0f" ++
        "00" ++
        "0000" ++
        "00" ++
        "00f8ff07",
    ),
  );
  try ncp.expectCommand(&hex("0c00012600"));
  ncp.respond(&hex("0c80012600" ++ "8877665544332211"));
  const event = driver.nextEvent() orelse return error.TestExpectedEvent;
  const ready = event.ready;
  try testing.expectEqual(0x1122334455667788, ready.ieee);
  try testing.expectEqual(6, ready.firmware.major);
  try testing.expectEqual(297, ready.firmware.build);
  const network = ready.network orelse return error.TestExpectedNetwork;
  try testing.expectEqual(command.NodeType.coordinator, network.node_type);
  try testing.expectEqual(0x1234, network.parameters.pan_id);
  try testing.expectEqual(15, network.parameters.channel);
  try testing.expectEqual(null, driver.nextEvent());
  try testing.expectEqual(null, driver.nextDeadline());
}

test "a dongle without a network is ready without one" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  _ = ncp.take();
  // NOT_JOINED.
  ncp.respond(&hex("0a8001170093"));
  try ncp.expectCommand(&hex("0b00012600"));
  ncp.respond(&hex("0b80012600" ++ "8877665544332211"));
  const ready = (driver.nextEvent() orelse return error.TestExpectedEvent).ready;
  try testing.expectEqual(null, ready.network);
}

test "refused configuration values are reported, and the driver goes on" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{ 1, 4 });
  _ = ncp.take();
  ncp.respond(&hex("0a8001170093"));
  _ = ncp.take();
  ncp.respond(&hex("0b80012600" ++ "8877665544332211"));
  try testing.expectEqual(configuration[1].id, driver.nextEvent().?.configuration_refused.id);
  try testing.expectEqual(configuration[4].id, driver.nextEvent().?.configuration_refused.id);
  try testing.expect(driver.nextEvent().? == .ready);
}

test "the driver fails when the network does not come up" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  _ = ncp.take();
  ncp.now = 1000;
  ncp.respond(&hex("0a8001170000"));
  try testing.expectEqual(1000 + response_timeout, driver.nextDeadline());
  driver.advance(1000 + response_timeout);
  try testing.expectEqual(Failure.response_timeout, driver.nextEvent().?.failed);
}

test "a refused endpoint fails the driver" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  for (configuration, 0..) |_, i| {
    _ = ncp.take();
    const sequence: u8 = @intCast(3 + i);
    ncp.respond(&.{ sequence, 0x80, 0x01, 0x53, 0x00, 0x00 });
  }
  _ = ncp.take();
  ncp.respond(&hex("098001020036"));
  const failure = driver.nextEvent().?.failed;
  try testing.expectEqual(0x36, failure.add_endpoint.value);
}
