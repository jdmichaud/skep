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

/// A command the NCP answered with a status other than success.
pub const Refused = struct {
  command: frame.FrameId,
  status: command.Status,
  /// For `set_value`, the value.
  value: ?command.ValueId = null,
};

pub const Failure = union(enum) {
  startup: startup_layer.Failure,
  link: link_layer.Failure,
  /// The NCP did not answer a command, or did not bring its network up or down, in time.
  response_timeout,
  /// The NCP rejected a command, with this EZSP status.
  invalid_command: u8,
  /// The NCP refused a command the driver needs.
  refused: Refused,
  /// A response that cannot be decoded.
  bad_response,
};

/// What `form` needs: the new network, and its keys.
pub const FormParameters = struct {
  channel: u8,
  pan_id: u16,
  extended_pan_id: u64,
  /// In dBm.
  tx_power: i8,
  network_key: [16]u8,
  /// The trust center's link key, from which the keys it gives devices are derived.
  trust_center_link_key: [16]u8,
};

pub const Event = union(enum) {
  ready: Ready,
  /// `form` formed the network.
  formed: Network,
  failed: Failure,
  /// The firmware refused a configuration value and keeps its own.
  configuration_refused: struct { id: command.ConfigId, status: command.Status },
  /// The NCP refused a command the driver can do without.
  command_refused: Refused,
};

pub const Driver = struct {
  startup: startup_layer.Startup,
  step: Step = .idle,
  configuration_index: usize = 0,
  /// Sequence number of the last command, and when it was sent.
  sequence: u8 = 0,
  sent_at: u64 = 0,
  /// The network is up, as `stack_status_handler` last reported.
  network_up: bool = false,
  /// The last time given, for commands sent from `form`.
  now: u64 = 0,
  form_parameters: FormParameters = undefined,
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
    /// Ready: running the network the dongle holds, if any.
    running,
    // `form`:
    leaving,
    waiting_for_leave,
    securing,
    extending_security,
    clearing_keys,
    forming,
    waiting_for_formed,
    writing_tokens,
    reading_formed,
    /// Failed: `start` begins again.
    failed,
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
    d.now = now;
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
    d.now = now;
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
    d.now = now;
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

  /// Forms a new network, once the driver is ready, leaving the dongle's network first if it holds
  /// one. Reports `formed`, or `failed`.
  pub fn form(d: *Driver, parameters: FormParameters) void {
    std.debug.assert(d.step == .running);
    d.form_parameters = parameters;
    if (d.network_up) {
      d.step = .leaving;
      var out: [1]u8 = undefined;
      d.send(.leave_network, command.leaveNetwork(&out, d.ready.version.protocol_version), d.now);
    } else {
      d.secure(d.now);
    }
  }

  fn waiting(d: *const Driver) bool {
    return switch (d.step) {
      .idle, .starting, .running, .failed => false,
      else => true,
    };
  }

  fn post(d: *Driver, event: Event) void {
    // Room for every refused configuration value, and the final event.
    d.events[d.events_len] = event;
    d.events_len += 1;
  }

  fn fail(d: *Driver, failure: Failure) void {
    d.step = .failed;
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
      if (d.step == .failed) continue;
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
          switch (d.step) {
            .waiting_for_network => d.readNetwork(now),
            .waiting_for_formed => d.writeTokens(now),
            else => {},
          }
        } else if (status.is(.network_down)) {
          d.network_up = false;
          if (d.step == .waiting_for_leave) {
            d.secure(now);
          }
        }
      }
      // Other callbacks are not needed yet.
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
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .add_endpoint, .status = status } });
        }
        d.step = .initialising_network;
        var out: [2]u8 = undefined;
        d.send(.network_init, command.networkInit(&out), now);
      },
      .initialising_network => {
        if (received.id != .network_init) return d.fail(.bad_response);
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        if (status.is(.not_joined)) return d.readIeee(now);
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .network_init, .status = status } });
        }
        // The network comes up a moment later, unless it already did.
        if (d.network_up) return d.readNetwork(now);
        d.step = .waiting_for_network;
        d.sent_at = now;
      },
      .reading_network => {
        if (received.id != .get_network_parameters) return d.fail(.bad_response);
        const parsed = command.parseGetNetworkParameters(received.parameters, version) catch
          return d.fail(.bad_response);
        if (!parsed.status.is(.ok)) {
          return d.fail(.{
            .refused = .{ .command = .get_network_parameters, .status = parsed.status },
          });
        }
        d.ready.network = .{ .node_type = parsed.node_type, .parameters = parsed.network };
        d.readIeee(now);
      },
      .reading_ieee => {
        if (received.id != .get_eui64) return d.fail(.bad_response);
        d.ready.ieee = command.parseEui64(received.parameters) catch return d.fail(.bad_response);
        d.step = .running;
        d.post(.{ .ready = d.ready });
      },
      .leaving => {
        const status = d.statusOf(received, .leave_network) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .leave_network, .status = status } });
        }
        // The network goes down a moment later, unless it already did.
        if (!d.network_up) return d.secure(now);
        d.step = .waiting_for_leave;
        d.sent_at = now;
      },
      .securing => {
        const status = d.statusOf(received, .set_initial_security_state) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{
            .refused = .{ .command = .set_initial_security_state, .status = status },
          });
        }
        d.step = .extending_security;
        const mask = command.ExtendedSecurity.joiner_global_link_key |
          command.ExtendedSecurity.nwk_leave_request_not_allowed;
        var value: [2]u8 = undefined;
        std.mem.writeInt(u16, &value, mask, .little);
        var out: [4]u8 = undefined;
        d.send(.set_value, command.setValue(&out, .extended_security_bitmask, &value), now);
      },
      .extending_security => {
        const status = d.statusOf(received, .set_value) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{
            .refused = .{
              .command = .set_value,
              .status = status,
              .value = .extended_security_bitmask,
            },
          });
        }
        d.step = .clearing_keys;
        d.send(.clear_key_table, &.{}, now);
      },
      .clearing_keys => {
        const status = d.statusOf(received, .clear_key_table) orelse return;
        // A new network starts without keys anyway; zigbee-herdsman also goes on.
        if (!status.is(.ok)) {
          d.post(.{ .command_refused = .{ .command = .clear_key_table, .status = status } });
        }
        d.step = .forming;
        const p = d.form_parameters;
        var out: [20]u8 = undefined;
        d.send(
          .form_network,
          command.formNetwork(&out, .{
            .extended_pan_id = p.extended_pan_id,
            .pan_id = p.pan_id,
            .tx_power = p.tx_power,
            .channel = p.channel,
            // MAC association.
            .join_method = 0,
            // The coordinator manages the network.
            .manager_id = 0,
            .update_id = 0,
            // Every 802.15.4 channel of the 2.4 GHz band.
            .channels = 0x07fff800,
          }),
          now,
        );
      },
      .forming => {
        const status = d.statusOf(received, .form_network) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .form_network, .status = status } });
        }
        if (d.network_up) return d.writeTokens(now);
        d.step = .waiting_for_formed;
        d.sent_at = now;
      },
      .writing_tokens => {
        const status = d.statusOf(received, .set_value) orelse return;
        // EmberZNet 6.10.3 refuses (0x70), and keeps the network across restarts anyway.
        if (!status.is(.ok)) {
          d.post(.{
            .command_refused = .{
              .command = .set_value,
              .status = status,
              .value = .stack_token_writing,
            },
          });
        }
        d.step = .reading_formed;
        d.send(.get_network_parameters, &.{}, now);
      },
      .reading_formed => {
        if (received.id != .get_network_parameters) return d.fail(.bad_response);
        const parsed = command.parseGetNetworkParameters(received.parameters, version) catch
          return d.fail(.bad_response);
        if (!parsed.status.is(.ok)) {
          return d.fail(.{
            .refused = .{ .command = .get_network_parameters, .status = parsed.status },
          });
        }
        d.step = .running;
        d.post(.{ .formed = .{ .node_type = parsed.node_type, .parameters = parsed.network } });
      },
      .idle,
      .starting,
      .waiting_for_network,
      .waiting_for_leave,
      .waiting_for_formed,
      .running,
      .failed,
      => {},
    }
  }

  /// The status of a response made of a status alone, to `id`; null if the driver failed instead.
  fn statusOf(d: *Driver, received: frame.Frame, id: frame.FrameId) ?command.Status {
    if (received.id != id) {
      d.fail(.bad_response);
      return null;
    }
    return command.parseStatus(received.parameters, d.ready.version.protocol_version) catch {
      d.fail(.bad_response);
      return null;
    };
  }

  /// Sets the security of the network to form.
  fn secure(d: *Driver, now: u64) void {
    d.step = .securing;
    const p = d.form_parameters;
    const s = command.InitialSecurityState;
    const state: s = .{
      // As zigbee-herdsman forms networks: devices join with the global link key, and get
      // link keys the trust center derives from its own.
      .bitmask = s.trust_center_global_link_key | s.have_preconfigured_key | s.have_network_key |
        s.trust_center_uses_hashed_link_key | s.require_encrypted_key,
      .preconfigured_key = p.trust_center_link_key,
      .network_key = p.network_key,
      .network_key_sequence_number = 0,
    };
    var out: [s.len]u8 = undefined;
    d.send(.set_initial_security_state, state.encode(&out), now);
  }

  /// Asks the NCP to keep the network in its tokens, across resets and power cycles.
  fn writeTokens(d: *Driver, now: u64) void {
    d.step = .writing_tokens;
    var out: [3]u8 = undefined;
    d.send(.set_value, command.setValue(&out, .stack_token_writing, &.{ 1 }), now);
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
  try testing.expectEqual(frame.FrameId.add_endpoint, failure.refused.command);
  try testing.expectEqual(0x36, failure.refused.status.value);
}

/// Answers the command just sent with `status`, checking it was `id`.
fn answer(ncp: *Ncp, id: frame.FrameId, status: u8) !void {
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(id), std.mem.readInt(u16, sent[3..5], .little));
  const code = @backingInt(id);
  ncp.respond(&.{ sent[0], 0x80, 0x01, @truncate(code), @truncate(code >> 8), status });
}

/// Takes the driver to `ready`, with or without a network on the dongle.
fn readyNcp(driver: *Driver, network: bool) !Ncp {
  var ncp = try started(driver);
  try configured(&ncp, &.{});
  if (network) {
    try answer(&ncp, .network_init, 0x00);
    ncp.respond(&hex("009001190090"));
    const sent = ncp.take() orelse return error.TestExpectedCommand;
    ncp.respond(
      &[_]u8{ sent[0], 0x80, 0x01, 0x28, 0x00 } ++
        hex(
          "00" ++
            "01" ++
            "69fef016be984281" ++
            "e021" ++
            "08" ++
            "0f" ++
            "00" ++
            "0000" ++
            "00" ++
            "00f8ff07",
        ),
    );
  } else {
    try answer(&ncp, .network_init, 0x93);
  }
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(&[_]u8{ sent[0], 0x80, 0x01, 0x26, 0x00 } ++ hex("1de149feffb6c67c"));
  try testing.expect(driver.nextEvent().? == .ready);
  return ncp;
}

const form_parameters: FormParameters = .{
  .channel = 20,
  .pan_id = 0x1a62,
  .extended_pan_id = 0xdddddddddddddddd,
  .tx_power = 5,
  .network_key = @splat(0x22),
  .trust_center_link_key = @splat(0x11),
};

/// The steps of forming after the security state, with `refuse_clear` refusing to clear keys.
fn formed(driver: *Driver, ncp: *Ncp, refuse_clear: bool) !void {
  try answer(ncp, .set_value, 0x00);
  try answer(ncp, .clear_key_table, if (refuse_clear) 0x35 else 0x00);
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.form_network), sent[3]);
  var expected: [20]u8 = undefined;
  try testing.expectEqualSlices(
    u8,
    command.formNetwork(&expected, .{
      .extended_pan_id = 0xdddddddddddddddd,
      .pan_id = 0x1a62,
      .tx_power = 5,
      .channel = 20,
      .join_method = 0,
      .manager_id = 0,
      .update_id = 0,
      .channels = 0x07fff800,
    }),
    sent[5..],
  );
  ncp.respond(&.{ sent[0], 0x80, 0x01, 0x1e, 0x00, 0x00 });
  try testing.expectEqual(null, ncp.take());
  // NETWORK_UP.
  ncp.respond(&hex("009001190090"));
  try answer(ncp, .set_value, 0x00);
  const read = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(
    &[_]u8{ read[0], 0x80, 0x01, 0x28, 0x00 } ++
      hex(
        "00" ++
          "01" ++
          "dddddddddddddddd" ++
          "621a" ++
          "05" ++
          "14" ++
          "00" ++
          "0000" ++
          "00" ++
          "00f8ff07",
      ),
  );
  _ = driver;
}

test "form a network on a dongle that holds none" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.form(form_parameters);
  const security = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.set_initial_security_state), security[3]);
  // The bitmask, then the trust center link key and the network key.
  try testing.expectEqualSlices(u8, &hex("840b"), security[5..7]);
  try testing.expectEqual(0x11, security[7]);
  try testing.expectEqual(0x22, security[23]);
  ncp.respond(&.{ security[0], 0x80, 0x01, 0x68, 0x00, 0x00 });
  try formed(&driver, &ncp, true);
  try testing.expectEqual(
    frame.FrameId.clear_key_table,
    driver.nextEvent().?.command_refused.command,
  );
  const network = driver.nextEvent().?.formed;
  try testing.expectEqual(20, network.parameters.channel);
  try testing.expectEqual(0x1a62, network.parameters.pan_id);
  try testing.expectEqual(null, driver.nextDeadline());
}

test "replacing a network leaves it first" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, true);
  driver.form(form_parameters);
  // EZSP 8: leave_network takes no parameters.
  const leave = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(5, leave.len);
  try testing.expectEqual(@backingInt(frame.FrameId.leave_network), leave[3]);
  ncp.respond(&.{ leave[0], 0x80, 0x01, 0x20, 0x00, 0x00 });
  try testing.expectEqual(null, ncp.take());
  // NETWORK_DOWN.
  ncp.respond(&hex("009001190091"));
  try answer(&ncp, .set_initial_security_state, 0x00);
  try formed(&driver, &ncp, false);
  try testing.expect(driver.nextEvent().? == .formed);
}

test "a refused security state fails the driver" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.form(form_parameters);
  try answer(&ncp, .set_initial_security_state, 0x94);
  const failure = driver.nextEvent().?.failed;
  try testing.expectEqual(frame.FrameId.set_initial_security_state, failure.refused.command);
}

test "a link failure after the start is reported" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  ncp.send(.{ .err = .{ .version = 2, .code = 0x51 } });
  try testing.expectEqual(
    link_layer.Failure{ .ncp_error = 0x51 },
    driver.nextEvent().?.failed.link,
  );
}
