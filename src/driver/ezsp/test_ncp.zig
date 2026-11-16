//! A scripted NCP for tests: acknowledges every DATA frame the host sends and answers with the
//! EZSP frames a test gives. Works with anything that has the link's I/O functions and `start`.

const std = @import("std");
const ash = @import("ash.zig");
const link = @import("link.zig");

const testing = std.testing;

pub fn Ncp(comptime Host: type) type {
  return struct {
    const Self = @This();

    host: *Host,
    now: u64 = 0,
    frm_tx: u3 = 0,
    frm_rx: u3 = 0,
    command: [ash.max_data_len]u8 = undefined,
    command_len: usize = 0,

    /// Writes the host's output and returns the last EZSP command in it, if any.
    pub fn take(ncp: *Self) ?[]const u8 {
      var decoder: ash.Decoder = .{};
      var got = false;
      while (true) {
        const bytes = ncp.host.output();
        if (bytes.len == 0) break;
        for (bytes) |byte| {
          const event = decoder.feed(byte) orelse continue;
          if (event.frame != .data) continue;
          const payload = event.frame.data.payload;
          @memcpy(ncp.command[0..payload.len], payload);
          ncp.command_len = payload.len;
          ncp.frm_rx +%= 1;
          got = true;
        }
        ncp.host.outputDone(bytes.len, ncp.now);
      }
      return if (got) ncp.command[0..ncp.command_len] else null;
    }

    pub fn send(ncp: *Self, frame: ash.Frame) void {
      var out: [ash.max_encoded_len]u8 = undefined;
      ncp.host.input(ash.encode(frame, &out) catch unreachable, ncp.now);
    }

    /// Sends an EZSP frame, acknowledging what the host sent.
    pub fn respond(ncp: *Self, payload: []const u8) void {
      ncp.send(.{
        .data = .{
          .frame_number = ncp.frm_tx,
          .ack_number = ncp.frm_rx,
          .retransmitted = false,
          .payload = payload,
        },
      });
      ncp.frm_tx +%= 1;
    }

    /// Starts the host and answers its reset.
    pub fn connect(ncp: *Self) !void {
      ncp.host.start();
      try ncp.answerReset();
    }

    /// Answers a reset the host asked for, which starts the frame numbers again.
    pub fn answerReset(ncp: *Self) !void {
      try testing.expectEqual(null, ncp.take());
      ncp.frm_tx = 0;
      ncp.frm_rx = 0;
      ncp.send(.{ .rstack = .{ .version = ash.version, .code = link.reset_software } });
    }

    pub fn expectCommand(ncp: *Self, expected: []const u8) !void {
      const taken = ncp.take() orelse return error.TestExpectedCommand;
      try testing.expectEqualSlices(u8, expected, taken);
    }
  };
}

pub fn hex(comptime text: []const u8) [text.len / 2]u8 {
  var bytes: [text.len / 2]u8 = undefined;
  _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
  return bytes;
}
