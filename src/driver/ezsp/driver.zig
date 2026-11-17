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

/// Trust center policies: devices that lost the network key can always rejoin, and devices get
/// the trust center link key they ask for, but no application link keys, as zigbee-herdsman sets
/// them. New devices can join only while the window is open, when `permitJoin` allows them
/// (zigbee-herdsman allows them from the start, and relies on the window being closed).
const rejoins_only = command.TrustCenterDecision.allow_unsecured_rejoins;
const joins_and_rejoins = command.TrustCenterDecision.allow_joins | rejoins_only;
const policies = [_]struct { id: command.PolicyId, decision: u8 }{
  .{ .id = .trust_center_policy, .decision = rejoins_only },
  .{
    .id = .tc_key_request_policy,
    .decision = command.KeyRequestDecision.allow_tc_key_requests_and_send_current_key,
  },
  .{ .id = .app_key_request_policy, .decision = command.KeyRequestDecision.deny_app_key_requests },
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
  security: Security,
};

/// A network's keys and frame counters, as the NCP holds them.
pub const Security = struct {
  network_key: [16]u8,
  network_key_sequence_number: u8,
  /// The outgoing frame counter of the network key.
  network_frame_counter: u32,
  /// The key from which the trust center derives the link keys it gives devices.
  trust_center_link_key: [16]u8,
  /// Its outgoing frame counter; null from EZSP 13, which does not give it.
  trust_center_frame_counter: ?u32,
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
  /// Restarted after a saved network was put back, the NCP did not bring it up again.
  restored_network_lost,
};

/// What `form` needs: the network, and its keys.
pub const FormParameters = struct {
  channel: u8,
  pan_id: u16,
  extended_pan_id: u64,
  update_id: u8 = 0,
  /// In dBm.
  tx_power: i8,
  network_key: [16]u8,
  network_key_sequence_number: u8 = 0,
  /// The trust center's link key, from which the keys it gives devices are derived.
  trust_center_link_key: [16]u8,
  /// The outgoing frame counters to carry on from when a saved network is put back, so that
  /// its devices accept the coordinator's frames; null for a new network.
  frame_counters: ?FrameCounters = null,

  pub const FrameCounters = struct {
    network: u32,
    trust_center: u32,
  };
};

/// A device the trust center saw join, rejoin or leave.
pub const DeviceChange = struct {
  eui64: u64,
  node_id: u16,
  kind: enum { joined, rejoined, left },
};

pub const Event = union(enum) {
  ready: Ready,
  /// `form` formed the network.
  formed: Network,
  /// `refresh` read the network again.
  refreshed: Network,
  /// `permitJoin` was done: null if the NCP did it, what it refused otherwise.
  permit_join_done: ?Refused,
  /// The join window opened (true) or closed.
  join_window: bool,
  device: DeviceChange,
  failed: Failure,
  /// The firmware refused a configuration value and keeps its own.
  configuration_refused: struct { id: command.ConfigId, status: command.Status },
  /// The NCP refused a command the driver can do without.
  command_refused: Refused,
  /// `send` is done: null if the NCP took the message, what it refused otherwise.
  send_done: struct { tag: u8, refused: ?Refused },
  /// What became of a message the NCP took: delivered (acknowledged, for a unicast), or not.
  delivered: struct { tag: u8, status: command.Status },
  /// A message for the coordinator.
  message: Message,
  /// A callback, as received, for the debug log.
  callback: Callback,
};

/// A message, to send or received, with its payload copied.
pub const Message = struct {
  /// For a message to send, a unicast to a network address, or a broadcast to one of the
  /// broadcast addresses; for a message received, the sender.
  address: u16,
  broadcast: bool = false,
  aps: command.ApsFrame,
  /// Matches `send_done` and `delivered` with the message sent.
  tag: u8 = 0,
  /// Of a message received.
  lqi: u8 = 0,
  rssi: i8 = 0,
  len: u8 = 0,
  payload: [max_payload_len]u8 = undefined,

  /// Longest payload: what fits a Zigbee frame, with room to spare.
  pub const max_payload_len = 127;

  pub fn bytes(m: *const Message) []const u8 {
    return m.payload[0..m.len];
  }
};

/// A callback, copied.
pub const Callback = struct {
  id: frame.FrameId,
  len: u8,
  parameters: [frame.max_parameters_len]u8,

  pub fn bytes(c: *const Callback) []const u8 {
    return c.parameters[0..c.len];
  }
};

pub const Driver = struct {
  startup: startup_layer.Startup,
  step: Step = .idle,
  configuration_index: usize = 0,
  /// Sequence number of the last command, and when it was sent.
  sequence: u8 = 0,
  sent_at: u64 = 0,
  /// The last command is not written yet: `sent_at` is the time it was queued, which can be old
  /// when the caller asked for it after a quiet spell, and is replaced by the time it is written;
  /// until then, no answer is late.
  sent_unwritten: bool = false,
  /// The network is up, as `stack_status_handler` last reported.
  network_up: bool = false,
  /// The last time given, for commands sent from `form`.
  now: u64 = 0,
  form_parameters: FormParameters = undefined,
  /// What `permitJoin` asked for.
  permit_seconds: u8 = 0,
  /// The tag of the message `send` is sending.
  sending_tag: u8 = 0,
  ready: Ready = undefined,
  policy_index: usize = 0,
  /// Restarting after a saved network was put back: the network the NCP then resumes is reported
  /// as `formed`.
  restarting: bool = false,
  /// What reading the network is for, which says what to report once it is read.
  reading_for: enum { ready, formed, refreshed } = .ready,
  /// The network being read.
  reading: Network = undefined,
  /// Events for the caller. Callbacks arrive in bursts of at most the link's receive slots, and
  /// the caller takes events after each call: 32 leave room to spare.
  events: [32]Event = undefined,
  events_len: usize = 0,
  /// Events lost because the queue was full, which `takeDropped` reports.
  events_dropped: u32 = 0,

  const Step = enum {
    idle,
    starting,
    configuring,
    adding_endpoint,
    setting_policies,
    initialising_network,
    waiting_for_network,
    // Reading the network, for `start`, `form` and `refresh`:
    reading_network,
    reading_network_key,
    exporting_network_key,
    reading_trust_center_key,
    reading_ieee,
    /// Ready: running the network the dongle holds, if any.
    running,
    // `permitJoin`:
    adding_transient_key,
    clearing_transient_keys,
    setting_join_policy,
    permitting,
    // `send`:
    sending,
    // `form`:
    leaving,
    waiting_for_leave,
    restoring_frame_counter,
    restoring_trust_center_counter,
    securing,
    extending_security,
    clearing_keys,
    forming,
    waiting_for_formed,
    writing_tokens,
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
      if (d.sent_unwritten and len > 0) {
        d.sent_at = now;
        d.sent_unwritten = false;
      }
      d.process(now);
    }
  }

  pub fn nextDeadline(d: *const Driver) ?u64 {
    if (d.step == .starting) return d.startup.nextDeadline();
    const link_deadline = d.startup.link.nextDeadline();
    const response_deadline: ?u64 = if (d.answerDue()) d.sent_at + response_timeout else null;
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
    if (d.answerDue() and now >= d.sent_at + response_timeout) {
      d.fail(.response_timeout);
    }
  }

  /// Events lost because the caller did not take them in time, since the last call.
  pub fn takeDropped(d: *Driver) u32 {
    defer d.events_dropped = 0;
    return d.events_dropped;
  }

  pub fn nextEvent(d: *Driver) ?Event {
    if (d.events_len == 0) return null;
    const event = d.events[0];
    std.mem.copyForwards(Event, d.events[0..d.events_len - 1], d.events[1..d.events_len]);
    d.events_len -= 1;
    return event;
  }

  /// Forms a network, new or saved, once the driver is ready, leaving the dongle's network first
  /// if it holds one. Reports `formed`, or `failed`.
  pub fn form(d: *Driver, parameters: FormParameters) void {
    std.debug.assert(d.step == .running);
    d.form_parameters = parameters;
    if (d.network_up) {
      d.step = .leaving;
      var out: [1]u8 = undefined;
      d.send(.leave_network, command.leaveNetwork(&out, d.ready.version.protocol_version), d.now);
    } else {
      d.restoreFrameCounter(d.now);
    }
  }

  /// Sends a message, once the network is up. Reports `send_done`, then `delivered` once the
  /// message was delivered or given up on.
  pub fn sendMessage(d: *Driver, message: *const Message) void {
    std.debug.assert(d.step == .running);
    d.sending_tag = message.tag;
    d.step = .sending;
    const version = d.ready.version.protocol_version;
    var out: [21 + Message.max_payload_len]u8 = undefined;
    if (message.broadcast) {
      // The default radius of the network.
      const radius = 0;
      d.send(
        .send_broadcast,
        command.sendBroadcast(
          &out,
          message.address,
          message.aps,
          radius,
          message.tag,
          message.bytes(),
          version,
        ),
        d.now,
      );
    } else {
      d.send(
        .send_unicast,
        command.sendUnicast(
          &out,
          message.address,
          message.aps,
          message.tag,
          message.bytes(),
          version,
        ),
        d.now,
      );
    }
  }

  /// Reads the network's parameters, keys and frame counters again, once the network is up: the
  /// counters advance with every frame the NCP sends. Reports `refreshed`, or `failed`.
  pub fn refresh(d: *Driver) void {
    std.debug.assert(d.step == .running);
    d.readNetwork(.refreshed, d.now);
  }

  /// Opens the network to new devices for `seconds`, or closes it with 0. Reports
  /// `permit_join_done`, then `join_window` when the NCP opened or closed it.
  ///
  /// Joining devices use the well-known link key, which the trust center learns as a transient
  /// key for any device while the window is open, as zigbee-herdsman does: the trust center's own
  /// key is random, and the network key it sends a device that cannot decrypt it is lost on it.
  pub fn permitJoin(d: *Driver, seconds: u8) void {
    std.debug.assert(d.step == .running);
    d.permit_seconds = seconds;
    const version = d.ready.version.protocol_version;
    if (seconds == 0) {
      d.step = .clearing_transient_keys;
      d.send(.clear_transient_link_keys, &.{}, d.now);
    } else if (version < 13) {
      d.step = .adding_transient_key;
      var out: [24]u8 = undefined;
      d.send(
        .add_transient_link_key,
        command.addTransientLinkKey(&out, std.math.maxInt(u64), command.well_known_link_key),
        d.now,
      );
    } else {
      d.step = .adding_transient_key;
      var out: [25]u8 = undefined;
      d.send(
        .import_transient_key,
        command.importTransientKey(&out, 0, command.well_known_link_key, version),
        d.now,
      );
    }
  }

  /// Whether the NCP owes an answer, by `sent_at` plus the response timeout: not before the
  /// command is written, which the application may do after calling `advance`.
  fn answerDue(d: *const Driver) bool {
    return d.waiting() and !d.sent_unwritten;
  }

  fn waiting(d: *const Driver) bool {
    return switch (d.step) {
      .idle, .starting, .running, .failed => false,
      else => true,
    };
  }

  fn post(d: *Driver, event: Event) void {
    if (d.events_len == d.events.len) {
      d.events_dropped +|= 1;
      return;
    }
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
    d.sent_unwritten = true;
    d.startup.link.send(frame.encode(&out, d.sequence, id, parameters)) catch |err| switch (err) {
      // The link failed after the frame being handled arrived: its event comes next. In case it
      // does not, the command is due an answer now, which it will not get, so that the
      // response timeout fails the driver rather than leave it waiting with no deadline.
      error.NotConnected => d.sent_unwritten = false,
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
      var copy: Callback = .{
        .id = received.id,
        .len = @intCast(received.parameters.len),
        .parameters = undefined,
      };
      @memcpy(copy.parameters[0..copy.len], received.parameters);
      d.post(.{ .callback = copy });
      if (received.id == .stack_status_handler) {
        const status = command.parseStatus(received.parameters, version) catch
          return d.fail(.bad_response);
        if (status.is(.network_up)) {
          d.network_up = true;
          switch (d.step) {
            .waiting_for_network => d.readNetwork(.ready, now),
            .waiting_for_formed => d.writeTokens(now),
            else => {},
          }
        } else if (status.is(.network_down)) {
          d.network_up = false;
          if (d.step == .waiting_for_leave) {
            d.restoreFrameCounter(now);
          }
        } else if (status.is(.network_opened)) {
          d.post(.{ .join_window = true });
        } else if (status.is(.network_closed)) {
          d.post(.{ .join_window = false });
        }
      } else if (received.id == .incoming_message_handler) {
        const m = command.IncomingMessage.parse(received.parameters, version) catch
          return d.fail(.bad_response);
        if (m.payload.len > Message.max_payload_len) return;
        var message: Message = .{
          .address = m.sender,
          .broadcast = m.type >= 2,
          .aps = m.aps,
          .lqi = m.lqi,
          .rssi = m.rssi,
          .len = @intCast(m.payload.len),
        };
        @memcpy(message.payload[0..message.len], m.payload);
        d.post(.{ .message = message });
      } else if (received.id == .message_sent_handler) {
        const sent = command.MessageSent.parse(received.parameters, version) catch
          return d.fail(.bad_response);
        d.post(.{ .delivered = .{ .tag = sent.tag, .status = sent.status } });
      } else if (received.id == .trust_center_join_handler) {
        const join = command.TrustCenterJoin.parse(received.parameters) catch
          return d.fail(.bad_response);
        // A device the trust center turned away has not joined; the callback is in the debug log.
        if (join.update != .left and join.decision == command.TrustCenterJoin.deny_join) return;
        d.post(.{
          .device = .{
            .eui64 = join.eui64,
            .node_id = join.node_id,
            .kind = switch (join.update) {
              .unsecured_join => .joined,
              .secured_rejoin, .unsecured_rejoin => .rejoined,
              .left => .left,
              // An update the trust center does not know: not a device of ours.
              _ => return,
            },
          },
        });
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
        d.step = .setting_policies;
        d.setPolicy(now);
      },
      .setting_policies => {
        const status = d.statusOf(received, .set_policy) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .set_policy, .status = status } });
        }
        d.policy_index += 1;
        if (d.policy_index < policies.len) return d.setPolicy(now);
        d.step = .initialising_network;
        var out: [2]u8 = undefined;
        d.send(.network_init, command.networkInit(&out), now);
      },
      .adding_transient_key => {
        const status = if (received.id == .import_transient_key)
          command.parseImportTransientKey(received.parameters) catch return d.fail(.bad_response)
        else
          d.statusOf(received, .add_transient_link_key) orelse return;
        if (!status.is(.ok)) return d.permitJoinDone(.{ .command = received.id, .status = status });
        d.setJoinPolicy(joins_and_rejoins, now);
      },
      .clearing_transient_keys => {
        // No parameters: it cannot fail.
        if (received.id != .clear_transient_link_keys) return d.fail(.bad_response);
        d.setJoinPolicy(rejoins_only, now);
      },
      .setting_join_policy => {
        const status = d.statusOf(received, .set_policy) orelse return;
        if (!status.is(.ok)) return d.permitJoinDone(.{ .command = .set_policy, .status = status });
        d.step = .permitting;
        var out: [1]u8 = undefined;
        d.send(.permit_joining, command.permitJoining(&out, d.permit_seconds), now);
      },
      .sending => {
        if (received.id != .send_unicast and received.id != .send_broadcast) {
          return d.fail(.bad_response);
        }
        const status = command.parseSend(received.parameters, version) catch
          return d.fail(.bad_response);
        d.step = .running;
        d.post(.{
          .send_done = .{
            .tag = d.sending_tag,
            .refused = if (status.is(.ok)) null else .{ .command = received.id, .status = status },
          },
        });
      },
      .permitting => {
        const status = d.statusOf(received, .permit_joining) orelse return;
        d.step = .running;
        d.post(.{
          .permit_join_done = if (status.is(.ok))
            null
          else
            .{ .command = .permit_joining, .status = status },
        });
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
        if (d.network_up) return d.readNetwork(.ready, now);
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
        d.reading = .{
          .node_type = parsed.node_type,
          .parameters = parsed.network,
          .security = undefined,
        };
        d.step = .reading_network_key;
        if (version < 13) {
          d.send(.get_key, &.{ @backingInt(command.KeyStruct.Type.current_network_key) }, now);
        } else {
          d.send(.get_network_key_info, &.{}, now);
        }
      },
      .reading_network_key => {
        const security = &d.reading.security;
        if (version < 13) {
          const key = d.keyOf(received) orelse return;
          security.network_key = key.key;
          security.network_key_sequence_number = key.sequence_number;
          security.network_frame_counter = key.outgoing_frame_counter;
          d.step = .reading_trust_center_key;
          d.send(.get_key, &.{ @backingInt(command.KeyStruct.Type.trust_center_link_key) }, now);
          return;
        }
        if (received.id != .get_network_key_info) return d.fail(.bad_response);
        const info = command.NetworkKeyInfo.parse(received.parameters) catch
          return d.fail(.bad_response);
        if (!info.status.is(.ok) or !info.key_set) {
          return d.fail(.{
            .refused = .{ .command = .get_network_key_info, .status = info.status },
          });
        }
        security.network_key_sequence_number = info.sequence_number;
        security.network_frame_counter = info.frame_counter;
        d.step = .exporting_network_key;
        var out: [18]u8 = undefined;
        d.send(.export_key, command.exportKey(&out, .network), now);
      },
      .exporting_network_key => {
        d.reading.security.network_key = d.exportedKey(received) orelse return;
        d.step = .reading_trust_center_key;
        var out: [18]u8 = undefined;
        d.send(.export_key, command.exportKey(&out, .trust_center_link), now);
      },
      .reading_trust_center_key => {
        const security = &d.reading.security;
        if (version < 13) {
          const key = d.keyOf(received) orelse return;
          security.trust_center_link_key = key.key;
          security.trust_center_frame_counter = key.outgoing_frame_counter;
        } else {
          security.trust_center_link_key = d.exportedKey(received) orelse return;
          security.trust_center_frame_counter = null;
        }
        switch (d.reading_for) {
          .ready => {
            d.ready.network = d.reading;
            d.readIeee(now);
          },
          .formed => {
            d.step = .running;
            d.post(.{ .formed = d.reading });
          },
          .refreshed => {
            d.step = .running;
            d.post(.{ .refreshed = d.reading });
          },
        }
      },
      .reading_ieee => {
        if (received.id != .get_eui64) return d.fail(.bad_response);
        d.ready.ieee = command.parseEui64(received.parameters) catch return d.fail(.bad_response);
        if (d.restarting) {
          d.restarting = false;
          const network = d.ready.network orelse return d.fail(.restored_network_lost);
          d.step = .running;
          return d.post(.{ .formed = network });
        }
        d.step = .running;
        d.post(.{ .ready = d.ready });
      },
      .leaving => {
        const status = d.statusOf(received, .leave_network) orelse return;
        if (!status.is(.ok)) {
          return d.fail(.{ .refused = .{ .command = .leave_network, .status = status } });
        }
        // The network goes down a moment later, unless it already did.
        if (!d.network_up) return d.restoreFrameCounter(now);
        d.step = .waiting_for_leave;
        d.sent_at = now;
      },
      .restoring_frame_counter => {
        const status = d.statusOf(received, .set_value) orelse return;
        if (!status.is(.ok)) {
          d.post(.{
            .command_refused = .{
              .command = .set_value,
              .status = status,
              .value = .nwk_frame_counter,
            },
          });
        }
        d.restoreTrustCenterCounter(now);
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
            .update_id = p.update_id,
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
        if (d.form_parameters.frame_counters == null) return d.readNetwork(.formed, now);
        d.restart();
      },
      .restoring_trust_center_counter => {
        const status = d.statusOf(received, .set_value) orelse return;
        if (!status.is(.ok)) {
          d.post(.{
            .command_refused = .{
              .command = .set_value,
              .status = status,
              .value = .aps_frame_counter,
            },
          });
        }
        d.secure(now);
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

  /// The key in an answer to `get_key`; null if the driver failed instead.
  fn keyOf(d: *Driver, received: frame.Frame) ?command.KeyStruct {
    if (received.id != .get_key) {
      d.fail(.bad_response);
      return null;
    }
    const parsed = command.KeyStruct.parse(
      received.parameters,
      d.ready.version.protocol_version,
    ) catch {
      d.fail(.bad_response);
      return null;
    };
    if (!parsed.status.is(.ok)) {
      d.fail(.{ .refused = .{ .command = .get_key, .status = parsed.status } });
      return null;
    }
    return parsed.key;
  }

  /// The key in an answer to `export_key`; null if the driver failed instead.
  fn exportedKey(d: *Driver, received: frame.Frame) ?[16]u8 {
    if (received.id != .export_key) {
      d.fail(.bad_response);
      return null;
    }
    const parsed = command.parseExportKey(
      received.parameters,
      d.ready.version.protocol_version,
    ) catch {
      d.fail(.bad_response);
      return null;
    };
    if (!parsed.status.is(.ok)) {
      d.fail(.{ .refused = .{ .command = .export_key, .status = parsed.status } });
      return null;
    }
    return parsed.key;
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

  fn setJoinPolicy(d: *Driver, decision: u8, now: u64) void {
    d.step = .setting_join_policy;
    var out: [2]u8 = undefined;
    d.send(.set_policy, command.setPolicy(&out, .trust_center_policy, decision), now);
  }

  fn permitJoinDone(d: *Driver, refused: ?Refused) void {
    d.step = .running;
    d.post(.{ .permit_join_done = refused });
  }

  fn setPolicy(d: *Driver, now: u64) void {
    var out: [2]u8 = undefined;
    const entry = policies[d.policy_index];
    d.send(.set_policy, command.setPolicy(&out, entry.id, entry.decision), now);
  }

  /// Sets the network frame counter of a saved network put back, before its security state, as
  /// zigbee-herdsman does; goes straight to the security state for a new network.
  fn restoreFrameCounter(d: *Driver, now: u64) void {
    const counters = d.form_parameters.frame_counters orelse return d.secure(now);
    d.step = .restoring_frame_counter;
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, blockStart(counters.network), .little);
    var out: [6]u8 = undefined;
    d.send(.set_value, command.setValue(&out, .nwk_frame_counter, &value), now);
  }

  /// Sets the trust center's frame counter of a saved network put back, before its security state
  /// too: once the network is formed, EmberZNet 6.10.3 refuses it.
  fn restoreTrustCenterCounter(d: *Driver, now: u64) void {
    d.step = .restoring_trust_center_counter;
    var value: [4]u8 = undefined;
    std.mem.writeInt(
      u32,
      &value,
      blockStart(d.form_parameters.frame_counters.?.trust_center),
      .little,
    );
    var out: [6]u8 = undefined;
    d.send(.set_value, command.setValue(&out, .aps_frame_counter, &value), now);
  }

  /// Restarts the NCP once a saved network is back, and reports it as formed once it resumes it.
  ///
  /// EmberZNet saves the network frame counter in blocks of 4096 and resumes each start at a
  /// block it saved ahead, but `set_value` leaves nothing saved ahead: on our dongle, the first
  /// start after a restore went back below frames already sent, which devices then ignore
  /// (hardware.md). With the value set at a block's start and a restart once the network is
  /// formed, it resumed above every frame sent, and saved ahead again. At worst it would resume
  /// at the value set, using again the counters of the frames sent between forming and the
  /// restart, within a second or so.
  fn restart(d: *Driver) void {
    d.startup = .init(d.startup.link.options);
    d.step = .starting;
    d.configuration_index = 0;
    d.policy_index = 0;
    d.network_up = false;
    d.restarting = true;
    d.startup.start();
  }

  /// The start of the first block of 4096 at or above `counter`, from which EmberZNet resumes
  /// as it should after a restart (see `restart`).
  fn blockStart(counter: u32) u32 {
    return std.math.cast(u32, (@as(u64, counter) + 0xfff) & ~@as(u64, 0xfff)) orelse
      std.math.maxInt(u32) & ~@as(u32, 0xfff);
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
        s.trust_center_uses_hashed_link_key | s.require_encrypted_key |
        // A saved network keeps the frame counter just set.
        if (p.frame_counters != null) s.no_frame_counter_reset else 0,
      .preconfigured_key = p.trust_center_link_key,
      .network_key = p.network_key,
      .network_key_sequence_number = p.network_key_sequence_number,
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

  /// Reads the network's parameters, then its keys and frame counters.
  fn readNetwork(d: *Driver, purpose: @FieldType(Driver, "reading_for"), now: u64) void {
    d.reading_for = purpose;
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
const ash = @import("ash.zig");

/// The next event that is not a callback logged for debugging.
fn skipCallbacks(driver: *Driver) ?Event {
  while (driver.nextEvent()) |event| {
    if (event != .callback) return event;
  }
  return null;
}

/// Takes the driver through the startup, to its first configuration value.
fn started(driver: *Driver) !Ncp {
  return startedAt(driver, 8);
}

/// Takes the driver through the startup with an NCP speaking EZSP `version`.
fn startedAt(driver: *Driver, version: u8) !Ncp {
  driver.* = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = driver };
  try ncp.connect();
  try handshake(&ncp, version);
  return ncp;
}

/// Agrees on EZSP `version` and reads the firmware version, after a reset.
fn handshake(ncp: *Ncp, version: u8) !void {
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&(hex("008000") ++ .{ version } ++ hex("02306a")));
  try ncp.expectCommand(&(hex("0100010000") ++ .{ version }));
  ncp.respond(&(hex("0180010000") ++ .{ version } ++ hex("02306a")));
  try ncp.expectCommand(&hex("020001aa0011"));
  ncp.respond(&hex("028001aa0000" ++ "07" ++ "2901" ++ "060a03" ++ "00" ++ "aa"));
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
  for (policies, 0..) |entry, i| {
    const sequence: u8 = @intCast(endpoint_sequence + 1 + i);
    var expected: [5 + 2]u8 = undefined;
    var out: [2]u8 = undefined;
    try ncp.expectCommand(
      frame.encode(
        &expected,
        sequence,
        .set_policy,
        command.setPolicy(&out, entry.id, entry.decision),
      ),
    );
    ncp.respond(&.{ sequence, 0x80, 0x01, 0x55, 0x00, 0x00 });
  }
}

test "a dongle holding a network brings it up" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  try ncp.expectCommand(&hex("0d000117000000"));
  ncp.respond(&hex("0d8001170000"));
  try testing.expectEqual(null, skipCallbacks(&driver));
  // The network comes up: stack_status_handler, NETWORK_UP.
  ncp.respond(&hex("0a9001190090"));
  try ncp.expectCommand(&hex("0e00012800"));
  ncp.respond(
    &hex(
      "0e80012800" ++
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
  // EZSP 8: get_key, for the network key, then for the trust center link key.
  try ncp.expectCommand(&hex("0f00016a0003"));
  ncp.respond(&(hex("0f80016a00") ++ keyStruct(0x03, 0x22, 70000, 1)));
  try ncp.expectCommand(&hex("1000016a0001"));
  ncp.respond(&(hex("1080016a00") ++ keyStruct(0x01, 0x11, 1200, 0)));
  try ncp.expectCommand(&hex("1100012600"));
  ncp.respond(&hex("1180012600" ++ "8877665544332211"));
  const event = skipCallbacks(&driver) orelse return error.TestExpectedEvent;
  const ready = event.ready;
  try testing.expectEqual(0x1122334455667788, ready.ieee);
  try testing.expectEqual(6, ready.firmware.major);
  try testing.expectEqual(297, ready.firmware.build);
  const network = ready.network orelse return error.TestExpectedNetwork;
  try testing.expectEqual(command.NodeType.coordinator, network.node_type);
  try testing.expectEqual(0x1234, network.parameters.pan_id);
  try testing.expectEqual(15, network.parameters.channel);
  try testing.expectEqual(@as([16]u8, @splat(0x22)), network.security.network_key);
  try testing.expectEqual(1, network.security.network_key_sequence_number);
  try testing.expectEqual(70000, network.security.network_frame_counter);
  try testing.expectEqual(@as([16]u8, @splat(0x11)), network.security.trust_center_link_key);
  try testing.expectEqual(1200, network.security.trust_center_frame_counter);
  try testing.expectEqual(null, skipCallbacks(&driver));
  try testing.expectEqual(null, driver.nextDeadline());
}

/// The answer to `get_key`: a status of 0, then a key of `fill` bytes, of `type`.
fn keyStruct(key_type: u8, fill: u8, outgoing: u32, sequence: u8) [37]u8 {
  var out: [37]u8 = @splat(0);
  out[3] = key_type;
  @memset(out[4..20], fill);
  std.mem.writeInt(u32, out[20..24], outgoing, .little);
  out[28] = sequence;
  return out;
}

/// Answers the reading of the keys, by an NCP speaking EZSP 8.
fn keysRead(ncp: *Ncp, network_frame_counter: u32) !void {
  const network_key = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("6a0003"), network_key[3..]);
  ncp.respond(
    &[_]u8{ network_key[0], 0x80, 0x01, 0x6a, 0x00 } ++
      keyStruct(0x03, 0x22, network_frame_counter, 0),
  );
  const link_key = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("6a0001"), link_key[3..]);
  ncp.respond(&[_]u8{ link_key[0], 0x80, 0x01, 0x6a, 0x00 } ++ keyStruct(0x01, 0x11, 9, 0));
}

test "EZSP 13 reads the keys from the security manager" {
  var driver: Driver = undefined;
  var ncp = try startedAt(&driver, 13);
  try configured(&ncp, &.{});
  try answer(&ncp, .network_init, 0x00);
  ncp.respond(&hex("009001190090"));
  const parameters = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(
    &[_]u8{ parameters[0], 0x80, 0x01, 0x28, 0x00 } ++
      hex(
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
  const info = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("1601"), info[3..]);
  ncp.respond(
    &[_]u8{ info[0], 0x80, 0x01, 0x16, 0x01 } ++
      hex("00000000" ++ "01" ++ "00" ++ "02" ++ "00" ++ "70110100"),
  );
  // export_key, with a security manager context: the network key, then the trust center's.
  const network_key = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(
    u8,
    &(hex("1401" ++ "01") ++ @as([17]u8, @splat(0))),
    network_key[3..],
  );
  ncp.respond(
    &[_]u8{ network_key[0], 0x80, 0x01, 0x14, 0x01 } ++
      @as([16]u8, @splat(0x22)) ++
      hex("00000000"),
  );
  const link_key = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(0x02, link_key[5]);
  ncp.respond(
    &[_]u8{ link_key[0], 0x80, 0x01, 0x14, 0x01 } ++ @as([16]u8, @splat(0x11)) ++ hex("00000000"),
  );
  const ieee = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(&[_]u8{ ieee[0], 0x80, 0x01, 0x26, 0x00 } ++ hex("8877665544332211"));
  const security = (skipCallbacks(&driver) orelse
    return error.TestExpectedEvent).ready.network.?.security;
  try testing.expectEqual(@as([16]u8, @splat(0x22)), security.network_key);
  try testing.expectEqual(2, security.network_key_sequence_number);
  try testing.expectEqual(70000, security.network_frame_counter);
  try testing.expectEqual(@as([16]u8, @splat(0x11)), security.trust_center_link_key);
  try testing.expectEqual(null, security.trust_center_frame_counter);
}

test "a dongle without a network is ready without one" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  _ = ncp.take();
  // NOT_JOINED.
  ncp.respond(&hex("0d8001170093"));
  try ncp.expectCommand(&hex("0e00012600"));
  ncp.respond(&hex("0e80012600" ++ "8877665544332211"));
  const ready = (skipCallbacks(&driver) orelse return error.TestExpectedEvent).ready;
  try testing.expectEqual(null, ready.network);
}

test "refused configuration values are reported, and the driver goes on" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{ 1, 4 });
  _ = ncp.take();
  ncp.respond(&hex("0d8001170093"));
  _ = ncp.take();
  ncp.respond(&hex("0e80012600" ++ "8877665544332211"));
  try testing.expectEqual(configuration[1].id, skipCallbacks(&driver).?.configuration_refused.id);
  try testing.expectEqual(configuration[4].id, skipCallbacks(&driver).?.configuration_refused.id);
  try testing.expect(skipCallbacks(&driver).? == .ready);
}

test "the driver fails when the network does not come up" {
  var driver: Driver = undefined;
  var ncp = try started(&driver);
  try configured(&ncp, &.{});
  _ = ncp.take();
  ncp.now = 1000;
  ncp.respond(&hex("0d8001170000"));
  try testing.expectEqual(1000 + response_timeout, driver.nextDeadline());
  driver.advance(1000 + response_timeout);
  try testing.expectEqual(Failure.response_timeout, skipCallbacks(&driver).?.failed);
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
  const failure = skipCallbacks(&driver).?.failed;
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
    try keysRead(&ncp, 70000);
  } else {
    try answer(&ncp, .network_init, 0x93);
  }
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(&[_]u8{ sent[0], 0x80, 0x01, 0x26, 0x00 } ++ hex("1de149feffb6c67c"));
  try testing.expect(skipCallbacks(driver).? == .ready);
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
  try keysRead(ncp, 0);
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
    skipCallbacks(&driver).?.command_refused.command,
  );
  const network = skipCallbacks(&driver).?.formed;
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
  try testing.expect(skipCallbacks(&driver).? == .formed);
}

test "a saved network is put back with its frame counters" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  var parameters = form_parameters;
  parameters.network_key_sequence_number = 3;
  parameters.frame_counters = .{ .network = 0x00012345, .trust_center = 0x00000400 };
  driver.form(parameters);
  // The network frame counter first, refused here, which does not stop the driver.
  const counter = ncp.take() orelse return error.TestExpectedCommand;
  // 0x00012345, up to the start of a block of 4096.
  try testing.expectEqualSlices(u8, &hex("ab00" ++ "23" ++ "04" ++ "00300100"), counter[3..]);
  ncp.respond(&.{ counter[0], 0x80, 0x01, 0xab, 0x00, 0x35 });
  // Then the trust center's, before the security state too, also up to a block's start.
  const trust_center = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("ab00" ++ "24" ++ "04" ++ "00100000"), trust_center[3..]);
  ncp.respond(&.{ trust_center[0], 0x80, 0x01, 0xab, 0x00, 0x00 });
  const security = ncp.take() orelse return error.TestExpectedCommand;
  // The bitmask keeps the frame counter, and the network key's sequence number follows the keys.
  try testing.expectEqualSlices(u8, &hex("841b"), security[5..7]);
  try testing.expectEqual(3, security[39]);
  ncp.respond(&.{ security[0], 0x80, 0x01, 0x68, 0x00, 0x00 });
  try answer(&ncp, .set_value, 0x00);
  try answer(&ncp, .clear_key_table, 0x00);
  try answer(&ncp, .form_network, 0x00);
  ncp.respond(&hex("009001190090"));
  try answer(&ncp, .set_value, 0x00);
  // Then the NCP restarts, so that it saves its frame counter ahead, and resumes the network.
  try ncp.answerReset();
  try handshake(&ncp, 8);
  try configured(&ncp, &.{});
  try answer(&ncp, .network_init, 0x00);
  ncp.respond(&hex("009001190090"));
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
  try keysRead(&ncp, 0x00012345);
  const ieee = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(&[_]u8{ ieee[0], 0x80, 0x01, 0x26, 0x00 } ++ hex("8877665544332211"));
  // What was reported before the restart is still there.
  const refused = skipCallbacks(&driver).?.command_refused;
  try testing.expectEqual(command.ValueId.nwk_frame_counter, refused.value);
  const network = skipCallbacks(&driver).?.formed;
  try testing.expectEqual(0x00012345, network.security.network_frame_counter);
  try testing.expectEqual(0x1a62, network.parameters.pan_id);
  try testing.expectEqual(null, skipCallbacks(&driver));
}

test "a saved network the NCP does not bring back after its restart fails the driver" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  var parameters = form_parameters;
  parameters.frame_counters = .{ .network = 1, .trust_center = 1 };
  driver.form(parameters);
  for ([_]frame.FrameId{
    .set_value,
    .set_value,
    .set_initial_security_state,
    .set_value,
    .clear_key_table,
    .form_network,
  }) |id| {
    try answer(&ncp, id, 0x00);
  }
  ncp.respond(&hex("009001190090"));
  try answer(&ncp, .set_value, 0x00);
  try ncp.answerReset();
  try handshake(&ncp, 8);
  try configured(&ncp, &.{});
  // NOT_JOINED.
  try answer(&ncp, .network_init, 0x93);
  const ieee = ncp.take() orelse return error.TestExpectedCommand;
  ncp.respond(&[_]u8{ ieee[0], 0x80, 0x01, 0x26, 0x00 } ++ hex("8877665544332211"));
  try testing.expectEqual(Failure.restored_network_lost, skipCallbacks(&driver).?.failed);
}

test "restored counters start a block of 4096" {
  try testing.expectEqual(0, Driver.blockStart(0));
  try testing.expectEqual(4096, Driver.blockStart(1));
  try testing.expectEqual(4096, Driver.blockStart(4096));
  try testing.expectEqual(462848, Driver.blockStart(460471));
  try testing.expectEqual(0xfffff000, Driver.blockStart(0xffffffff));
}

test "refresh reads the network and its counters again" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, true);
  driver.refresh();
  const read = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.get_network_parameters), read[3]);
  ncp.respond(
    &[_]u8{ read[0], 0x80, 0x01, 0x28, 0x00 } ++
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
  try keysRead(&ncp, 71000);
  const network = skipCallbacks(&driver).?.refreshed;
  try testing.expectEqual(71000, network.security.network_frame_counter);
  try testing.expectEqual(null, driver.nextDeadline());
}

test "a command asked for after a quiet spell gets its full time" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, true);
  // An hour without a call: the driver's last time is an hour old.
  ncp.now = 3600 * 1000;
  driver.refresh();
  // As skepd does: the loop runs once before the command is written.
  driver.advance(ncp.now);
  try testing.expectEqual(null, skipCallbacks(&driver));
  _ = ncp.take() orelse return error.TestExpectedCommand;
  driver.advance(ncp.now + 1);
  try testing.expectEqual(null, skipCallbacks(&driver));
  try testing.expectEqual(ncp.now, driver.sent_at);
}

test "messages go out, and come in" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, true);
  var message: Message = .{
    .address = 0x7173,
    .aps = .{
      .profile = 0x0104,
      .cluster = 0x0006,
      .source_endpoint = 1,
      .destination_endpoint = 1,
      .options = command.ApsFrame.unicast_options,
    },
    .tag = 9,
    .len = 3,
  };
  @memcpy(message.payload[0..3], &hex("010000"));
  driver.sendMessage(&message);
  const unicast = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("3400" ++ "00" ++ "7371"), unicast[3..8]);
  try testing.expectEqualSlices(u8, &hex("09" ++ "03" ++ "010000"), unicast[unicast.len - 5..]);
  // EZSP 8: a status, and the APS sequence number.
  ncp.respond(&.{ unicast[0], 0x80, 0x01, 0x34, 0x00, 0x00, 0x2a });
  const done = skipCallbacks(&driver).?.send_done;
  try testing.expectEqual(9, done.tag);
  try testing.expectEqual(null, done.refused);
  // Delivered, then the plug answers with a Default Response.
  ncp.respond(
    &hex(
      "0090013f00" ++
        "00" ++
        "7371" ++
        "04010600010140110000" ++
        "2a" ++
        "09" ++
        "00" ++
        "03" ++
        "010000",
    ),
  );
  ncp.respond(
    &hex(
      "0090014500" ++
        "00" ++
        "04010600010140010000d9" ++
        "ff" ++
        "ee" ++
        "7371" ++
        "ffff" ++
        "05" ++
        "1800" ++
        "0b0000",
    ),
  );
  const delivered = skipCallbacks(&driver).?.delivered;
  try testing.expectEqual(9, delivered.tag);
  try testing.expect(delivered.status.is(.ok));
  const received = skipCallbacks(&driver).?.message;
  try testing.expectEqual(0x7173, received.address);
  try testing.expectEqual(0x0006, received.aps.cluster);
  try testing.expectEqualSlices(u8, &hex("18000b0000"), received.bytes());

  // A broadcast to the routers.
  var broadcast: Message = .{
    .address = 0xfffc,
    .broadcast = true,
    .aps = .{
      .profile = 0,
      .cluster = 0x0036,
      .source_endpoint = 0,
      .destination_endpoint = 0,
      .options = 0,
    },
    .tag = 10,
    .len = 3,
  };
  @memcpy(broadcast.payload[0..3], &hex("013c01"));
  driver.sendMessage(&broadcast);
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &hex("3600" ++ "fcff"), sent[3..7]);
  ncp.respond(&.{ sent[0], 0x80, 0x01, 0x36, 0x00, 0x70, 0x00 });
  const refused = skipCallbacks(&driver).?.send_done;
  try testing.expectEqual(10, refused.tag);
  try testing.expectEqual(0x70, refused.refused.?.status.value);
}

test "a refused security state fails the driver" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.form(form_parameters);
  try answer(&ncp, .set_initial_security_state, 0x94);
  const failure = skipCallbacks(&driver).?.failed;
  try testing.expectEqual(frame.FrameId.set_initial_security_state, failure.refused.command);
}

test "a link failure after the start is reported" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  ncp.send(.{ .err = .{ .version = 2, .code = 0x51 } });
  try testing.expectEqual(
    link_layer.Failure{ .ncp_error = 0x51 },
    skipCallbacks(&driver).?.failed.link,
  );
}

test "a link failure that comes with the startup's last answer fails the driver" {
  var driver: Driver = .init(.{ .software_flow_control = true });
  var ncp: Ncp = .{ .host = &driver };
  try ncp.connect();
  try ncp.expectCommand(&hex("00000013"));
  ncp.respond(&(hex("008000") ++ .{ 8 } ++ hex("02306a")));
  try ncp.expectCommand(&(hex("0100010000") ++ .{ 8 }));
  ncp.respond(&(hex("0180010000") ++ .{ 8 } ++ hex("02306a")));
  try ncp.expectCommand(&hex("020001aa0011"));
  // The answer to the firmware version, which ends the startup, then an ERROR frame, in one
  // read.
  var bytes: [2 * ash.max_encoded_len]u8 = undefined;
  const last = try ash.encode(
    .{
      .data = .{
        .frame_number = ncp.frm_tx,
        .ack_number = ncp.frm_rx,
        .retransmitted = false,
        .payload = &hex("028001aa0000" ++ "07" ++ "2901" ++ "060a03" ++ "00" ++ "aa"),
      },
    },
    bytes[0..ash.max_encoded_len],
  );
  const failure = try ash.encode(.{ .err = .{ .version = 2, .code = 0x51 } }, bytes[last.len..]);
  driver.input(bytes[0..last.len + failure.len], 0);
  // The driver goes on with its configuration, on a link that failed: it fails, or it at least
  // keeps a deadline, rather than waiting for ever.
  var now: u64 = 0;
  while (now < 60_000) : (now += 1000) {
    while (driver.nextEvent()) |event| {
      if (event == .failed) return;
    }
    _ = driver.nextDeadline() orelse return error.TestExpectedDeadline;
    driver.advance(now);
  }
  return error.TestExpectedFailure;
}

test "open the join window and see a device join" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.permitJoin(60);
  // EZSP 8: the well-known link key, for any device.
  const key = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.add_transient_link_key), key[3]);
  try testing.expectEqualSlices(u8, &hex("ffffffffffffffff") ++ "ZigBeeAlliance09", key[5..]);
  ncp.respond(&.{ key[0], 0x80, 0x01, 0xaf, 0x00, 0x00 });
  const policy = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &.{ 0x00, joins_and_rejoins }, policy[5..]);
  ncp.respond(&.{ policy[0], 0x80, 0x01, 0x55, 0x00, 0x00 });
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.permit_joining), sent[3]);
  try testing.expectEqualSlices(u8, &.{ 60 }, sent[5..]);
  ncp.respond(&.{ sent[0], 0x80, 0x01, 0x22, 0x00, 0x00 });
  try testing.expectEqual(null, skipCallbacks(&driver).?.permit_join_done);
  // NETWORK_OPENED, a device joining, a device the trust center refuses, NETWORK_CLOSED.
  ncp.respond(&hex("00900119009c"));
  ncp.respond(&hex("0090012400" ++ "3412" ++ "8877665544332211" ++ "01" ++ "00" ++ "0000"));
  ncp.respond(&hex("0090012400" ++ "3512" ++ "9977665544332211" ++ "01" ++ "02" ++ "0000"));
  ncp.respond(&hex("00900119009d"));
  try testing.expectEqual(true, skipCallbacks(&driver).?.join_window);
  const device = skipCallbacks(&driver).?.device;
  try testing.expectEqual(0x1122334455667788, device.eui64);
  try testing.expect(device.kind == .joined);
  try testing.expectEqual(false, skipCallbacks(&driver).?.join_window);
}

test "closing the join window forgets the well-known key" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.permitJoin(0);
  const clear = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqual(@backingInt(frame.FrameId.clear_transient_link_keys), clear[3]);
  ncp.respond(&.{ clear[0], 0x80, 0x01, 0x6b, 0x00 });
  const policy = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &.{ 0x00, rejoins_only }, policy[5..]);
  ncp.respond(&.{ policy[0], 0x80, 0x01, 0x55, 0x00, 0x00 });
  const sent = ncp.take() orelse return error.TestExpectedCommand;
  try testing.expectEqualSlices(u8, &.{ 0 }, sent[5..]);
  ncp.respond(&.{ sent[0], 0x80, 0x01, 0x22, 0x00, 0x00 });
  try testing.expectEqual(null, skipCallbacks(&driver).?.permit_join_done);
}

test "a refused transient key is reported, and the driver goes on" {
  var driver: Driver = undefined;
  var ncp = try readyNcp(&driver, false);
  driver.permitJoin(60);
  try answer(&ncp, .add_transient_link_key, 0x70);
  const refused = skipCallbacks(&driver).?.permit_join_done.?;
  try testing.expectEqual(frame.FrameId.add_transient_link_key, refused.command);
  driver.permitJoin(0);
  try testing.expect(ncp.take() != null);
}
