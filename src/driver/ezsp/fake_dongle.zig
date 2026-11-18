//! A made-up EmberZNet dongle for tests: it answers EZSP commands as a dongle speaking a given
//! EZSP version does, over ASH, and keeps a network, its keys and frame counters, so that the
//! same scenarios run at every version the driver supports. The layouts of answers and callbacks
//! follow zigbee-herdsman's (MIT): `src/adapter/ember/ezsp/ezsp.ts` from EZSP 13, and
//! `src/adapter/ezsp/driver/commands.ts` before; not our own parser, which they test.
//!
//! The host is anything with the ASH side of a driver: `output`, `outputDone` and `input`, such
//! as the EZSP driver or a libskep context with it.

const std = @import("std");
const ash = @import("ash.zig");

/// Ids of the frames the dongle knows, as EZSP numbers them.
const Id = struct {
  const version: u16 = 0x0000;
  const add_endpoint: u16 = 0x0002;
  const network_init: u16 = 0x0017;
  const stack_status_handler: u16 = 0x0019;
  const form_network: u16 = 0x001e;
  const leave_network: u16 = 0x0020;
  const permit_joining: u16 = 0x0022;
  const child_join_handler: u16 = 0x0023;
  const trust_center_join_handler: u16 = 0x0024;
  const get_eui64: u16 = 0x0026;
  const get_network_parameters: u16 = 0x0028;
  const send_unicast: u16 = 0x0034;
  const send_broadcast: u16 = 0x0036;
  const message_sent_handler: u16 = 0x003f;
  const incoming_message_handler: u16 = 0x0045;
  const invalid_command: u16 = 0x0058;
  const set_initial_security_state: u16 = 0x0068;
  const get_key: u16 = 0x006a;
  const clear_transient_link_keys: u16 = 0x006b;
  const broadcast_next_network_key: u16 = 0x0073;
  const broadcast_network_key_switch: u16 = 0x0074;
  const unicast_nwk_key_update: u16 = 0x00a9;
  const get_value: u16 = 0x00aa;
  const set_value: u16 = 0x00ab;
  const add_transient_link_key: u16 = 0x00af;
  const get_aps_key_info: u16 = 0x010c;
  const import_transient_key: u16 = 0x0111;
  const export_key: u16 = 0x0114;
  const get_network_key_info: u16 = 0x0116;
};

/// A status, as the version sends it: an EmberStatus byte before EZSP 14, an sl_status_t since.
pub const Status = struct {
  ember: u8,
  sl: u32,

  pub const ok: Status = .{ .ember = 0x00, .sl = 0x0000 };
  pub const network_up: Status = .{ .ember = 0x90, .sl = 0x0015 };
  pub const network_down: Status = .{ .ember = 0x91, .sl = 0x0016 };
  pub const not_joined: Status = .{ .ember = 0x93, .sl = 0x0017 };
  pub const network_opened: Status = .{ .ember = 0x9c, .sl = 0x0c18 };
  pub const network_closed: Status = .{ .ember = 0x9d, .sl = 0x0c19 };
  pub const invalid_call: Status = .{ .ember = 0x70, .sl = 0x0021 };
};

/// The network the dongle holds.
pub const Network = struct {
  extended_pan_id: u64,
  pan_id: u16,
  channel: u8,
  tx_power: i8 = 5,
  update_id: u8 = 0,
};

pub fn Dongle(comptime Host: type) type {
  return struct {
    const Self = @This();

    host: *Host,
    /// The EZSP version it speaks.
    version: u8,
    now: u64 = 0,
    ieee: u64 = 0x7cc6b6fffe49e11d,
    network: ?Network = null,
    /// Whether its network is up: from `network_init` or `form_network`, until a leave or a
    /// reset.
    up: bool = false,
    network_key: [16]u8 = @splat(0x22),
    network_key_sequence: u8 = 0,
    network_frame_counter: u32 = 70000,
    trust_center_key: [16]u8 = @splat(0x11),
    trust_center_frame_counter: u32 = 5000,
    /// The key sent ahead of a switch.
    next_key: ?[16]u8 = null,
    /// The command it answers with a refusal, if any.
    refuse: ?u16 = null,
    /// Commands taken, by id, for tests to check.
    taken: std.ArrayList(u16) = .empty,
    gpa: std.mem.Allocator,

    // ASH.
    frm_tx: u3 = 0,
    frm_rx: u3 = 0,
    decoder: ash.Decoder = .{},
    batch: std.ArrayList(u8) = .empty,
    aps_sequence: u8 = 0,
    /// Commands taken and not answered yet.
    held: [16][ash.max_data_len]u8 = undefined,
    held_lens: [16]usize = undefined,
    held_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, host: *Host, version: u8) Self {
      return .{ .gpa = gpa, .host = host, .version = version };
    }

    pub fn deinit(d: *Self) void {
      d.taken.deinit(d.gpa);
      d.batch.deinit(d.gpa);
    }

    /// Takes what the host wrote, answers it, and hands the answers over, until the host is
    /// quiet: at most `rounds` times.
    pub fn serve(d: *Self, rounds: usize) !void {
      for (0..rounds) |_| {
        if (!try d.round()) return;
      }
    }

    /// One exchange: whether the host wrote anything.
    pub fn round(d: *Self) !bool {
      const wrote = try d.take();
      try d.answerHeld();
      try d.flush();
      return wrote;
    }

    /// Answers the commands taken, soundly.
    pub fn answerHeld(d: *Self) !void {
      for (0..d.held_len) |i| {
        try d.answer(d.held[i][0..d.held_lens[i]]);
      }
      d.held_len = 0;
    }

    /// The last command taken, no longer held: for a test to answer as it pleases.
    pub fn popHeld(d: *Self) ?[]const u8 {
      if (d.held_len == 0) return null;
      d.held_len -= 1;
      return d.held[d.held_len][0..d.held_lens[d.held_len]];
    }

    /// Takes what the host wrote, holding its commands: whether it wrote anything.
    pub fn take(d: *Self) !bool {
      var wrote = false;
      while (true) {
        const bytes = d.host.output();
        if (bytes.len == 0) break;
        wrote = true;
        for (bytes) |byte| {
          const event = d.decoder.feed(byte) orelse continue;
          const f = switch (event) {
            .frame => |f| f,
            .invalid => continue,
          };
          switch (f) {
            .rst => try d.reset(),
            .data => |data| {
              // A frame sent again, after a timeout: taken already.
              if (data.frame_number != d.frm_rx) continue;
              d.frm_rx +%= 1;
              if (d.held_len == d.held.len) continue;
              @memcpy(d.held[d.held_len][0..data.payload.len], data.payload);
              d.held_lens[d.held_len] = data.payload.len;
              d.held_len += 1;
            },
            else => {},
          }
        }
        d.host.outputDone(bytes.len, d.now);
      }
      return wrote;
    }

    /// A reset: frame numbers start again, and the network is down until `network_init`.
    fn reset(d: *Self) !void {
      d.frm_tx = 0;
      d.frm_rx = 0;
      d.up = false;
      d.held_len = 0;
      d.batch.clearRetainingCapacity();
      try d.queue(.{ .rstack = .{ .version = ash.version, .code = 0x0b } });
    }

    /// Hands what was queued to the host, in one call.
    pub fn flush(d: *Self) !void {
      if (d.batch.items.len == 0) return;
      _ = d.host.input(d.batch.items, d.now);
      d.batch.clearRetainingCapacity();
    }

    /// An ASH frame.
    pub fn queue(d: *Self, f: ash.Frame) !void {
      var out: [ash.max_encoded_len]u8 = undefined;
      try d.batch.appendSlice(d.gpa, try ash.encode(f, &out));
    }

    /// Bytes, ASH or not.
    pub fn queueBytes(d: *Self, bytes: []const u8) !void {
      try d.batch.appendSlice(d.gpa, bytes);
    }

    /// A DATA frame holding `payload`, an EZSP frame or not.
    pub fn queueData(d: *Self, payload: []const u8) !void {
      try d.queue(.{
        .data = .{
          .frame_number = d.frm_tx,
          .ack_number = d.frm_rx,
          .retransmitted = false,
          .payload = payload,
        },
      });
      d.frm_tx +%= 1;
    }

    /// An EZSP frame: a response in the extended format, or a callback.
    pub fn queueEzsp(
      d: *Self,
      sequence: u8,
      callback: bool,
      id: u16,
      parameters: []const u8,
    ) !void {
      var payload: [ash.max_data_len]u8 = undefined;
      const len = @min(parameters.len, payload.len - 5);
      payload[0] = sequence;
      payload[1] = if (callback) 0x90 else 0x80;
      payload[2] = 0x01;
      std.mem.writeInt(u16, payload[3..5], id, .little);
      @memcpy(payload[5..][0..len], parameters[0..len]);
      try d.queueData(payload[0..5 + len]);
    }

    /// Parameters being written for an answer.
    const Out = struct {
      buffer: [ash.max_data_len]u8 = undefined,
      len: usize = 0,

      fn bytes(o: *Out, b: []const u8) void {
        @memcpy(o.buffer[o.len..][0..b.len], b);
        o.len += b.len;
      }

      fn int(o: *Out, comptime T: type, value: T) void {
        std.mem.writeInt(T, o.buffer[o.len..][0..@sizeOf(T)], value, .little);
        o.len += @sizeOf(T);
      }

      fn written(o: *const Out) []const u8 {
        return o.buffer[0..o.len];
      }
    };

    fn status(d: *const Self, o: *Out, s: Status) void {
      if (d.version < 14) {
        o.int(u8, s.ember);
      } else {
        o.int(u32, s.sl);
      }
    }

    /// Answers a command with a status alone.
    fn answerStatus(d: *Self, sequence: u8, id: u16, s: Status) !void {
      var o: Out = .{};
      d.status(&o, if (d.refuse == id) Status.invalid_call else s);
      try d.queueEzsp(sequence, false, id, o.written());
    }

    fn stackStatus(d: *Self, s: Status) !void {
      var o: Out = .{};
      d.status(&o, s);
      try d.queueEzsp(0, true, Id.stack_status_handler, o.written());
    }

    fn answer(d: *Self, payload: []const u8) !void {
      // The first version command, in the legacy format.
      if (payload.len == 4 and payload[2] == Id.version) {
        try d.taken.append(d.gpa, Id.version);
        return d.queueVersion(payload[0], true);
      }
      if (payload.len < 5) return;
      const sequence = payload[0];
      const id = std.mem.readInt(u16, payload[3..5], .little);
      const p = payload[5..];
      try d.taken.append(d.gpa, id);
      // EZSP 13 replaced the key commands with the security manager's.
      const before_13 = id == Id.get_key or id == Id.add_transient_link_key;
      const since_13 = id == Id.get_network_key_info or id == Id.export_key or
        id == Id.get_aps_key_info or id == Id.import_transient_key;
      if ((before_13 and d.version >= 13) or (since_13 and d.version < 13)) {
        return d.queueEzsp(sequence, false, Id.invalid_command, &.{ 0x58 });
      }
      switch (id) {
        Id.version => try d.queueVersion(sequence, false),
        Id.get_value => {
          var o: Out = .{};
          // VERSION_INFO: build, major, minor, patch, special, type.
          d.status(&o, Status.ok);
          o.int(u8, 7);
          o.bytes(&.{ 0x29, 0x01, 6, 10, 3, 0, 0xaa });
          try d.queueEzsp(sequence, false, id, o.written());
        },
        Id.network_init => {
          if (d.network == null) return d.answerStatus(sequence, id, Status.not_joined);
          try d.answerStatus(sequence, id, Status.ok);
          d.up = true;
          try d.stackStatus(Status.network_up);
        },
        Id.get_network_parameters => {
          var o: Out = .{};
          const n = d.network orelse return d.answerStatus(sequence, id, Status.not_joined);
          d.status(&o, Status.ok);
          // EMBER_COORDINATOR.
          o.int(u8, 1);
          o.int(u64, n.extended_pan_id);
          o.int(u16, n.pan_id);
          o.int(i8, n.tx_power);
          o.int(u8, n.channel);
          o.int(u8, 0); // join method
          o.int(u16, 0); // manager
          o.int(u8, n.update_id);
          o.int(u32, 0x07fff800);
          try d.queueEzsp(sequence, false, id, o.written());
        },
        Id.get_eui64 => {
          var o: Out = .{};
          o.int(u64, d.ieee);
          try d.queueEzsp(sequence, false, id, o.written());
        },
        // EmberKeyStruct, before EZSP 13: the status, then the bitmask, the type, the key, its
        // outgoing and incoming frame counters, its sequence number and its partner.
        Id.get_key => {
          var o: Out = .{};
          const network = p.len > 0 and p[0] == 3;
          o.int(u8, 0);
          o.int(u16, 0x001a);
          o.int(u8, if (p.len > 0) p[0] else 0);
          o.bytes(if (network) &d.network_key else &d.trust_center_key);
          o.int(u32, if (network) d.network_frame_counter else d.trust_center_frame_counter);
          o.int(u32, 0);
          o.int(u8, if (network) d.network_key_sequence else 0);
          o.int(u64, 0);
          try d.queueEzsp(sequence, false, id, o.written());
        },
        // sl_zb_sec_man_network_key_info_t: an sl_status_t first, whatever the version.
        Id.get_network_key_info => {
          var o: Out = .{};
          o.int(u32, 0);
          o.int(u8, 1); // key set
          o.int(u8, @intFromBool(d.next_key != null));
          o.int(u8, d.network_key_sequence);
          o.int(u8, d.network_key_sequence +% 1);
          o.int(u32, d.network_frame_counter);
          try d.queueEzsp(sequence, false, id, o.written());
        },
        // The key and the status with EZSP 13; the status, the key and the context since 14.
        Id.export_key => {
          var o: Out = .{};
          const key = if (p.len > 0 and p[0] == 1) &d.network_key else &d.trust_center_key;
          if (d.version < 14) {
            o.bytes(key);
            o.int(u32, 0);
          } else {
            o.int(u32, 0);
            o.bytes(key);
            o.bytes(p[0..@min(p.len, 18)]);
          }
          try d.queueEzsp(sequence, false, id, o.written());
        },
        // sl_zb_sec_man_aps_key_metadata_t: bitmask, outgoing and incoming frame counters, ttl.
        Id.get_aps_key_info => {
          var o: Out = .{};
          if (d.version >= 14) {
            o.int(u32, 0);
          }
          if (d.version < 14) {
            o.int(u64, 0);
          }
          o.int(u16, 0x0002); // has an outgoing frame counter
          o.int(u32, d.trust_center_frame_counter);
          o.int(u32, 0);
          o.int(u16, 0);
          if (d.version < 14) {
            o.int(u32, 0);
          } else {
            o.bytes(p[0..@min(p.len, 18)]);
          }
          try d.queueEzsp(sequence, false, id, o.written());
        },
        // EmberInitialSecurityState: bitmask, preconfigured key, network key, its sequence.
        Id.set_initial_security_state => {
          if (p.len >= 35) {
            @memcpy(&d.trust_center_key, p[2..18]);
            @memcpy(&d.network_key, p[18..34]);
            d.network_key_sequence = p[34];
          }
          try d.answerStatus(sequence, id, Status.ok);
        },
        Id.set_value => {
          // The frame counters to restore: NWK (0x23) and APS (0x24).
          if (p.len >= 6 and p[1] == 4) {
            const value = std.mem.readInt(u32, p[2..6], .little);
            if (p[0] == 0x23) {
              d.network_frame_counter = value;
            }
            if (p[0] == 0x24) {
              d.trust_center_frame_counter = value;
            }
          }
          try d.answerStatus(sequence, id, Status.ok);
        },
        // EmberNetworkParameters.
        Id.form_network => {
          if (p.len >= 20) {
            d.network = .{
              .extended_pan_id = std.mem.readInt(u64, p[0..8], .little),
              .pan_id = std.mem.readInt(u16, p[8..10], .little),
              .tx_power = @bitCast(p[10]),
              .channel = p[11],
              .update_id = p[15],
            };
          }
          try d.answerStatus(sequence, id, Status.ok);
          if (d.refuse != id) {
            d.up = true;
            try d.stackStatus(Status.network_up);
          }
        },
        Id.leave_network => {
          try d.answerStatus(sequence, id, Status.ok);
          d.network = null;
          d.up = false;
          try d.stackStatus(Status.network_down);
        },
        Id.permit_joining => {
          try d.answerStatus(sequence, id, Status.ok);
          try d.stackStatus(
            if (p.len > 0 and p[0] > 0) Status.network_opened else Status.network_closed,
          );
        },
        // Taken, with the APS sequence number, then delivered.
        Id.send_unicast, Id.send_broadcast => try d.sent(sequence, id, p),
        Id.clear_transient_link_keys => try d.queueEzsp(sequence, false, id, &.{}),
        // An sl_status_t, even with EZSP 13.
        Id.import_transient_key => {
          var o: Out = .{};
          o.int(u32, 0);
          try d.queueEzsp(sequence, false, id, o.written());
        },
        Id.unicast_nwk_key_update => {
          if (p.len >= 26) {
            d.next_key = p[10..26].*;
          }
          try d.answerStatus(sequence, id, Status.ok);
        },
        Id.broadcast_next_network_key => {
          if (p.len >= 16) {
            d.next_key = p[0..16].*;
          }
          try d.answerStatus(sequence, id, Status.ok);
        },
        Id.broadcast_network_key_switch => {
          if (d.next_key) |key| {
            d.network_key = key;
            d.network_key_sequence +%= 1;
            d.network_frame_counter = 0;
            d.next_key = null;
          }
          try d.answerStatus(sequence, id, Status.ok);
        },
        // Commands that answer with a status alone.
        Id.add_endpoint,
        0x0053, // set_configuration_value
        0x0055, // set_policy
        0x0099, // set_radio_power
        0x00b1, // clear_key_table
        Id.add_transient_link_key,
        => try d.answerStatus(sequence, id, Status.ok),
        // One it does not know.
        else => try d.queueEzsp(sequence, false, Id.invalid_command, &.{ 0x58 }),
      }
    }

    fn queueVersion(d: *Self, sequence: u8, legacy: bool) !void {
      const parameters = [_]u8{ d.version, 2, 0x30, 0x6a };
      if (!legacy) return d.queueEzsp(sequence, false, Id.version, &parameters);
      var payload: [7]u8 = undefined;
      payload[0..3].* = .{ sequence, 0x80, 0x00 };
      payload[3..7].* = parameters;
      try d.queueData(&payload);
    }

    /// `send_unicast` or `send_broadcast`: taken, then reported sent by `message_sent_handler`.
    fn sent(d: *Self, sequence: u8, id: u16, p: []const u8) !void {
      // Where the destination, the APS frame and the tag are: a unicast has the message type
      // first; a broadcast, from EZSP 14, an alias before the destination and a network
      // sequence after it, and a radius after the APS frame.
      const unicast = id == Id.send_unicast;
      const destination_at: usize = if (unicast) 1 else if (d.version < 14) 0 else 2;
      const aps_at: usize = destination_at +
        2 +
        @as(usize, if (!unicast and d.version >= 14) 1 else 0);
      const tag_at: usize = aps_at + 11 + @as(usize, if (unicast) 0 else 1);
      if (p.len < tag_at + 1) return d.queueEzsp(sequence, false, Id.invalid_command, &.{ 0x58 });
      var o: Out = .{};
      d.status(&o, Status.ok);
      o.int(u8, d.aps_sequence);
      d.aps_sequence +%= 1;
      try d.queueEzsp(sequence, false, id, o.written());
      d.network_frame_counter +%= 1;

      var cb: Out = .{};
      if (d.version >= 14) {
        cb.int(u32, 0);
      }
      cb.int(u8, if (unicast) 0 else 3); // direct unicast, or broadcast
      cb.bytes(p[destination_at..][0..2]);
      cb.bytes(p[aps_at..][0..11]);
      if (d.version < 14) {
        cb.int(u8, p[tag_at]);
        cb.int(u8, 0);
      } else {
        cb.bytes(p[tag_at..][0..2]);
      }
      cb.int(u8, 0); // no message contents
      try d.queueEzsp(0, true, Id.message_sent_handler, cb.written());
    }

    /// A device joins, as the trust center reports it.
    pub fn deviceJoins(d: *Self, ieee: u64, nwk: u16) !void {
      var o: Out = .{};
      o.int(u16, nwk);
      o.int(u64, ieee);
      o.int(u8, 1); // unsecured join
      o.int(u8, 0); // use the preconfigured key
      o.int(u16, 0); // parent: the coordinator
      try d.queueEzsp(0, true, Id.trust_center_join_handler, o.written());
      try d.flush();
    }

    /// A unicast from a device, to the coordinator: to its endpoint 1, or to ZDO (profile 0).
    pub fn message(d: *Self, sender: u16, profile: u16, cluster: u16, payload: []const u8) !void {
      const endpoint: u8 = if (profile == 0) 0 else 1;
      var o: Out = .{};
      o.int(u8, 0); // unicast
      o.int(u16, profile);
      o.int(u16, cluster);
      o.int(u8, endpoint);
      o.int(u8, endpoint);
      o.int(u16, 0x0140); // options
      o.int(u16, 0); // group
      o.int(u8, 0x21); // APS sequence
      if (d.version < 14) {
        o.int(u8, 0xff); // LQI
        o.int(i8, -40); // RSSI
        o.int(u16, sender);
        o.int(u8, 0xff); // binding index
        o.int(u8, 0xff); // address index
      } else {
        o.int(u16, sender);
        o.int(u64, 0);
        o.int(u8, 0xff);
        o.int(u8, 0xff);
        o.int(u8, 0xff);
        o.int(i8, -40);
        o.int(u32, 0); // timestamp
      }
      // As much as a frame carries.
      const len = @min(payload.len, o.buffer.len - o.len - 1 - 5);
      o.int(u8, @intCast(len));
      o.bytes(payload[0..len]);
      try d.queueEzsp(0, true, Id.incoming_message_handler, o.written());
      try d.flush();
    }
  };
}
