//! libskep with the EZSP driver, as an application drives it, against a dongle the fuzzer
//! drives. The dongle speaks an EZSP version the fuzzer picks, and answers soundly until the
//! network is up (`fake_dongle.zig`); then the fuzzer
//! picks what comes next: answers to the command pending, callbacks, frames from a device,
//! frames that are not EZSP, link frames, time passing, and the application's own calls. libskep
//! must neither crash nor leak, whatever the dongle sends: the driver and the context were each
//! fuzzed alone, and failed together on what neither did alone.

const std = @import("std");
const CAllocator = @import("allocator.zig").CAllocator;
const Context = @import("Context.zig");
const requests = @import("requests.zig");
const ash = @import("driver/ezsp/ash.zig");
const frame = @import("driver/ezsp/frame.zig");
const Dongle = @import("driver/ezsp/fake_dongle.zig").Dongle(Context);

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

/// A turn of the application's loop, with a sound dongle; the context's events, dropped.
fn turn(ctx: *Context, d: *Dongle) !void {
  _ = ctx.advance(d.now);
  drain(ctx);
  _ = try d.round();
  drain(ctx);
}

fn drain(ctx: *Context) void {
  while (ctx.nextEvent()) |event| {
    event.destroy();
  }
}

fn fuzzDongle(_: void, smith: *testing.Smith) !void {
  const allocator = testing.allocator;
  const c_allocator: CAllocator = .wrap(&allocator);
  const ctx = try Context.create(c_allocator, @splat(5));
  defer ctx.destroy();
  if (ctx.setOption("driver", "ezsp") != 0) return error.TestUnexpectedResult;
  if (ctx.start() != 0) return error.TestUnexpectedResult;
  var d: Dongle = .init(
    allocator,
    ctx,
    smith.valueRangeAtMost(u8, frame.min_version, frame.max_version),
  );
  defer d.deinit();
  // Up, by a sound dongle.
  for (0..100) |_| {
    d.now += 10;
    try turn(ctx, &d);
    if (ctx.status == .running) break;
  }
  if (ctx.status != .running) return error.TestExpectedRunning;

  var steps: usize = 0;
  while (!smith.eos() and steps < 64) : (steps += 1) {
    switch (smith.value(Action)) {
      .answer => try turn(ctx, &d),
      .made_up_answer => {
        _ = try d.take();
        const command = d.popHeld() orelse continue;
        if (command.len < 5) continue;
        var parameters: [64]u8 = undefined;
        const len = smith.slice(&parameters);
        try d.queueEzsp(
          command[0],
          false,
          std.mem.readInt(u16, command[3..5], .little),
          parameters[0..len],
        );
        try d.flush();
      },
      .callback => {
        var parameters: [64]u8 = undefined;
        const len = smith.slice(&parameters);
        try d.queueEzsp(0, true, callbacks[smith.index(callbacks.len)], parameters[0..len]);
        try d.flush();
      },
      .message => {
        // To an endpoint, or to ZDO.
        var payload: [64]u8 = undefined;
        const len = smith.slice(&payload);
        const zdo = smith.value(bool);
        try d.message(smith.value(u16), if (zdo) 0 else 0x0104, smith.value(u16), payload[0..len]);
      },
      .frame => {
        var payload: [ash.max_data_len]u8 = undefined;
        const len = smith.slice(&payload);
        // As short as ASH allows: shorter is not a DATA frame.
        if (len >= ash.min_data_len) {
          try d.queueData(payload[0..len]);
        }
        try d.flush();
      },
      .link => {
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
          0 => try d.queue(.{
            .ack = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) },
          }),
          1 => try d.queue(.{
            .nak = .{ .ack_number = smith.value(u3), .not_ready = smith.value(bool) },
          }),
          2 => try d.queue(.{ .rstack = .{ .version = smith.value(u8), .code = smith.value(u8) } }),
          3 => try d.queue(.{ .err = .{ .version = smith.value(u8), .code = smith.value(u8) } }),
          else => {
            var bytes: [32]u8 = undefined;
            try d.queueBytes(bytes[0..smith.slice(&bytes)]);
          },
        }
        try d.flush();
      },
      .wait => {
        d.now +|= smith.valueRangeAtMost(u64, 0, 120_000);
        _ = ctx.advance(d.now);
      },
      .call => {
        var request: u32 = 0;
        switch (smith.valueRangeAtMost(u8, 0, 5)) {
          5 => _ = ctx.rotateNetworkKey(
            if (smith.value(bool)) .broadcast else .per_device,
            &request,
          ),
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
    drain(ctx);
  }
  // Stopped cleanly, whatever came before: everything it holds is freed.
  _ = ctx.stop();
  for (0..20) |_| {
    d.now += 1000;
    try turn(ctx, &d);
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
