//! libskep with the EZSP driver, as an application drives it, against a dongle the fuzzer
//! drives. The dongle answers as EmberZNet 6.10.3 does until the network is up; then the fuzzer
//! picks what comes next: answers to the command pending, callbacks, frames from a device,
//! frames that are not EZSP, link frames, time passing, and the application's own calls. libskep
//! must neither crash nor leak, whatever the dongle sends: the driver and the context were each
//! fuzzed alone, and failed together on what neither did alone.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;
const Context = @import("Context.zig");
const requests = @import("requests.zig");
const ash = @import("driver/ezsp/ash.zig");

const testing = std.testing;

/// What the fuzzer may do once the network is up.
const Action = enum(u8) {
  /// Answer what the host sent, as a sound dongle does.
  answer,
  /// Answer the command pending with parameters the fuzzer makes up.
  made_up_answer,
  /// A callback, of an id the driver handles, with made-up parameters.
  callback,
  /// A frame from a device, to the coordinator.
  message,
  /// An EZSP frame of made-up bytes.
  frame,
  /// ASH frames other than DATA: ACK, NAK, RSTACK, ERROR; or bytes that are not ASH.
  link,
  /// Time passes.
  wait,
  /// The application asks for something.
  call,
};

/// Callbacks the driver handles.
const callbacks = [_]u16{ 0x0019, 0x0023, 0x0024, 0x003f, 0x0044, 0x0045 };

/// A dongle speaking ASH and EZSP 8 to a context.
const Dongle = struct {
  ctx: *Context,
  now: u64 = 0,
  frm_tx: u3 = 0,
  frm_rx: u3 = 0,
  /// What goes to the context in the next call to `input`.
  batch: [4096]u8 = undefined,
  batch_len: usize = 0,
  /// The commands the context sent, not answered yet.
  commands: [16][ash.max_data_len]u8 = undefined,
  command_lens: [16]usize = undefined,
  commands_len: usize = 0,
  holds_network: bool = false,
  network_key: [16]u8 = @splat(0xaa),
  trust_center_key: [16]u8 = @splat(0xbb),

  fn queue(d: *Dongle, frame: ash.Frame) void {
    var out: [ash.max_encoded_len]u8 = undefined;
    const bytes = ash.encode(frame, &out) catch return;
    d.queueBytes(bytes);
  }

  fn queueBytes(d: *Dongle, bytes: []const u8) void {
    // Full: what is queued goes first.
    if (d.batch_len + bytes.len > d.batch.len) {
      d.flush();
    }
    const n = @min(bytes.len, d.batch.len);
    @memcpy(d.batch[d.batch_len..][0..n], bytes[0..n]);
    d.batch_len += n;
  }

  fn queueData(d: *Dongle, payload: []const u8) void {
    d.queue(.{
      .data = .{
        .frame_number = d.frm_tx,
        .ack_number = d.frm_rx,
        .retransmitted = false,
        .payload = payload,
      },
    });
    d.frm_tx +%= 1;
  }

  /// An EZSP frame in the extended format: a response, or a callback.
  fn queueEzsp(d: *Dongle, sequence: u8, callback: bool, id: u16, parameters: []const u8) void {
    var payload: [ash.max_data_len]u8 = undefined;
    const n = @min(parameters.len, payload.len - 5);
    payload[0] = sequence;
    payload[1] = if (callback) 0x90 else 0x80;
    payload[2] = 0x01;
    std.mem.writeInt(u16, payload[3..5], id, .little);
    @memcpy(payload[5..][0..n], parameters[0..n]);
    d.queueData(payload[0..5 + n]);
  }

  fn flush(d: *Dongle) void {
    if (d.batch_len == 0) return;
    _ = d.ctx.input(d.batch[0..d.batch_len], d.now);
    d.batch_len = 0;
  }

  /// Takes what the context wrote: its commands, which a RST starts again.
  fn take(d: *Dongle) void {
    var decoder: ash.Decoder = .{};
    while (true) {
      const bytes = d.ctx.output();
      if (bytes.len == 0) break;
      for (bytes) |byte| {
        const event = decoder.feed(byte) orelse continue;
        const frame = switch (event) {
          .frame => |f| f,
          .invalid => continue,
        };
        switch (frame) {
          .rst => {
            d.frm_tx = 0;
            d.frm_rx = 0;
            d.commands_len = 0;
            d.queue(.{ .rstack = .{ .version = ash.version, .code = 0x0b } });
          },
          .data => |data| {
            if (data.frame_number != d.frm_rx) continue;
            d.frm_rx +%= 1;
            if (d.commands_len == d.commands.len) continue;
            @memcpy(d.commands[d.commands_len][0..data.payload.len], data.payload);
            d.command_lens[d.commands_len] = data.payload.len;
            d.commands_len += 1;
          },
          else => {},
        }
      }
      d.ctx.outputDone(bytes.len, d.now);
    }
  }

  /// Answers the commands taken, as EmberZNet 6.10.3 does.
  fn answerAll(d: *Dongle) void {
    for (0..d.commands_len) |i| {
      d.answer(d.commands[i][0..d.command_lens[i]]);
    }
    d.commands_len = 0;
  }

  fn answer(d: *Dongle, command: []const u8) void {
    if (command.len == 4) {
      // The first version command, in the legacy format.
      d.queueData(&.{ command[0], 0x80, 0x00, 0x08, 0x02, 0x30, 0x6a });
      return;
    }
    if (command.len < 5) return;
    const sequence = command[0];
    const id = std.mem.readInt(u16, command[3..5], .little);
    const p = command[5..];
    switch (id) {
      0x0000 => d.queueEzsp(sequence, false, id, &.{ 0x08, 0x02, 0x30, 0x6a }),
      0x00aa => d.queueEzsp(
        sequence,
        false,
        id,
        &.{ 0x00, 0x07, 0x29, 0x01, 0x06, 0x0a, 0x03, 0x00, 0xaa },
      ),
      // network_init: the network comes up, if the dongle holds one.
      0x0017 => if (d.holds_network) {
        d.queueEzsp(sequence, false, id, &.{ 0x00 });
        d.queueEzsp(0, true, 0x0019, &.{ 0x90 });
      } else {
        d.queueEzsp(sequence, false, id, &.{ 0x93 });
      },
      0x0026 => d.queueEzsp(
        sequence,
        false,
        id,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
      ),
      // set_initial_security_state: the keys.
      0x0068 => {
        if (p.len >= 34) {
          @memcpy(&d.trust_center_key, p[2..18]);
          @memcpy(&d.network_key, p[18..34]);
        }
        d.queueEzsp(sequence, false, id, &.{ 0x00 });
      },
      // form_network.
      0x001e => {
        d.holds_network = true;
        d.queueEzsp(sequence, false, id, &.{ 0x00 });
        d.queueEzsp(0, true, 0x0019, &.{ 0x90 });
      },
      // leave_network.
      0x0020 => {
        d.holds_network = false;
        d.queueEzsp(sequence, false, id, &.{ 0x00 });
        d.queueEzsp(0, true, 0x0019, &.{ 0x91 });
      },
      0x0028 => d.queueEzsp(
        sequence,
        false,
        id,
        &.{
          0x00,
          0x01,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          0x34,
          0x12,
          5,
          15,
          0,
          0,
          0,
          0,
          0x00,
          0xf8,
          0xff,
          0x07,
        },
      ),
      // get_key: the network key, or the trust center's.
      0x006a => {
        var parameters: [37]u8 = @splat(0);
        const network = p.len > 0 and p[0] == 3;
        parameters[3] = if (p.len > 0) p[0] else 0;
        @memcpy(parameters[4..20], if (network) &d.network_key else &d.trust_center_key);
        std.mem.writeInt(u32, parameters[20..24], if (network) 1_000_000 else 5000, .little);
        d.queueEzsp(sequence, false, id, &parameters);
      },
      // permit_joining: the window opens or closes.
      0x0022 => {
        d.queueEzsp(sequence, false, id, &.{ 0x00 });
        d.queueEzsp(0, true, 0x0019, &.{ if (p.len > 0 and p[0] > 0) 0x9c else 0x9d });
      },
      0x006b => d.queueEzsp(sequence, false, id, &.{}),
      // send_unicast and send_broadcast: taken, then delivered.
      0x0034, 0x0036 => {
        d.queueEzsp(sequence, false, id, &.{ 0x00, 0x01 });
        if (p.len >= 15) {
          var sent: [17]u8 = @splat(0);
          @memcpy(sent[0..14], p[0..14]);
          sent[14] = p[14];
          d.queueEzsp(0, true, 0x003f, &sent);
        }
      },
      else => d.queueEzsp(sequence, false, id, &.{ 0x00 }),
    }
  }

  /// A turn of the application's loop, with a sound dongle.
  fn turn(d: *Dongle) void {
    _ = d.ctx.advance(d.now);
    d.drain();
    d.take();
    d.answerAll();
    d.flush();
    d.drain();
  }

  /// Takes the context's events: whether it is running, or stopped.
  fn drain(d: *Dongle) void {
    while (d.ctx.nextEvent()) |event| {
      event.destroy();
    }
  }
};

fn fuzzDongle(_: void, smith: *testing.Smith) !void {
  const allocator = testing.allocator;
  const c_allocator: CAllocator = .wrap(&allocator);
  const ctx = try Context.create(c_allocator, @splat(5));
  defer ctx.destroy();
  if (ctx.setOption("driver", "ezsp") != 0) return error.TestUnexpectedResult;
  if (ctx.start() != 0) return error.TestUnexpectedResult;
  var d: Dongle = .{ .ctx = ctx };
  // Up, by a sound dongle.
  for (0..100) |_| {
    d.now += 10;
    d.turn();
    if (ctx.status == .running) break;
  }
  if (ctx.status != .running) return error.TestExpectedRunning;

  var steps: usize = 0;
  while (!smith.eos() and steps < 64) : (steps += 1) {
    switch (smith.value(Action)) {
      .answer => d.turn(),
      .made_up_answer => {
        d.take();
        if (d.commands_len == 0) continue;
        const command = d.commands[d.commands_len - 1][0..d.command_lens[d.commands_len - 1]];
        d.commands_len -= 1;
        if (command.len < 5) continue;
        var parameters: [64]u8 = undefined;
        const len = smith.slice(&parameters);
        d.queueEzsp(
          command[0],
          false,
          std.mem.readInt(u16, command[3..5], .little),
          parameters[0..len],
        );
        d.flush();
      },
      .callback => {
        var parameters: [64]u8 = undefined;
        const len = smith.slice(&parameters);
        d.queueEzsp(0, true, callbacks[smith.index(callbacks.len)], parameters[0..len]);
        d.flush();
      },
      .message => {
        // incomingMessageHandler: a unicast from a device, to endpoint 1 or ZDO.
        var parameters: [17 + 64]u8 = @splat(0);
        const zdo = smith.value(bool);
        std.mem.writeInt(u16, parameters[1..3], if (zdo) 0x0000 else 0x0104, .little);
        std.mem.writeInt(u16, parameters[3..5], smith.value(u16), .little);
        parameters[5] = if (zdo) 0 else 1;
        parameters[6] = if (zdo) 0 else 1;
        std.mem.writeInt(u16, parameters[13..15], smith.value(u16), .little);
        const len = smith.slice(parameters[17..]);
        parameters[16] = @intCast(len);
        d.queueEzsp(0, true, 0x0045, parameters[0..17 + len]);
        d.flush();
      },
      .frame => {
        var payload: [ash.max_data_len]u8 = undefined;
        const len = smith.slice(&payload);
        if (len > 0) {
          d.queueData(payload[0..len]);
        }
        d.flush();
      },
      .link => {
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
          0 => d.queue(.{
            .ack = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) },
          }),
          1 => d.queue(.{
            .nak = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) },
          }),
          2 => d.queue(.{ .rstack = .{ .version = smith.value(u8), .code = smith.value(u8) } }),
          3 => d.queue(.{ .err = .{ .version = smith.value(u8), .code = smith.value(u8) } }),
          else => {
            var bytes: [32]u8 = undefined;
            d.queueBytes(bytes[0..smith.slice(&bytes)]);
          },
        }
        d.flush();
      },
      .wait => {
        d.now +|= smith.valueRangeAtMost(u64, 0, 120_000);
        _ = ctx.advance(d.now);
      },
      .call => {
        var request: u32 = 0;
        switch (smith.valueRangeAtMost(u8, 0, 5)) {
          5 => _ = ctx.rotateNetworkKey(&request),
          0 => _ = ctx.permitJoin(smith.valueRangeAtMost(u8, 0, 254), &request),
          1 => _ = ctx.refreshState(&request),
          2 => if (ctx.state) |s| {
            if (s.devices.items.len > 0) {
              const target: requests.Target = .{
                .device = s.devices.items[0].ieee,
                .endpoint = 1,
                .cluster = smith.value(u16),
                .manufacturer_code = 0,
                .reserved = @splat(0),
              };
              _ = requests.read(ctx, &target, &.{ 0x0000 }, d.now + 30_000, &request);
            }
          },
          3 => _ = ctx.stop(),
          else => _ = ctx.start(),
        }
      },
    }
    d.drain();
  }
  // Stopped cleanly, whatever came before: everything it holds is freed.
  _ = ctx.stop();
  for (0..20) |_| {
    d.now += 1000;
    d.turn();
  }
}

test "fuzz: libskep survives whatever the dongle sends" {
  try testing.fuzz({}, fuzzDongle, .{
    .corpus = &.{
      // Sound answers only.
      &.{ 0, 0, 0, 0 },
      // The window opens, a device joins and talks.
      &.{ 7, 0, 0, 0, 0, 2, 4 },
      // Answers and link failures in one read.
      &.{ 0, 5, 3, 0x02, 0x51, 0 },
    },
  });
}
