//! Finding the dongle when skepd is not told where it is: the serial device under
//! /dev/serial/by-id/ whose name looks like a Zigbee dongle's. udev names the devices there after
//! their USB product's strings, which say what the product is, not what firmware it runs: the
//! driver's start tells that, as for a dongle named on the command line.

const std = @import("std");
const Io = std.Io;

/// Where udev names serial devices after their USB product.
pub const by_id = "/dev/serial/by-id";

/// Parts of Zigbee dongles' names, whatever their case: "Zigbee", which most have, and the names
/// of the EmberZNet dongles without it, as zigbee-herdsman lists them
/// (src/adapter/adapterDiscovery.ts): Nabu Casa's SkyConnect and Connect ZBT-1, SMLIGHT's SLZB
/// dongles, SONOFF's MG21 and MG24 ones.
const fragments = [_][]const u8{ "zigbee", "skyconnect", "zbt-", "slzb", "mg21", "mg24" };

pub fn looksLikeDongle(name: []const u8) bool {
  for (0..name.len) |i| {
    for (fragments) |fragment| {
      if (std.ascii.startsWithIgnoreCase(name[i..], fragment)) return true;
    }
  }
  return false;
}

/// The serial devices of a directory, by name, sorted: those that look like dongles, and the
/// others.
pub const Found = struct {
  dongles: std.ArrayList([]u8) = .empty,
  others: std.ArrayList([]u8) = .empty,

  pub fn deinit(f: *Found, gpa: std.mem.Allocator) void {
    for ([_]*std.ArrayList([]u8){ &f.dongles, &f.others }) |list| {
      for (list.items) |name| {
        gpa.free(name);
      }
      list.deinit(gpa);
    }
  }
};

/// The serial devices in `dir_path`: none if it does not exist, as when nothing is plugged in.
pub fn scan(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) error{ OutOfMemory }!Found {
  var found: Found = .{};
  errdefer found.deinit(gpa);
  var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return found;
  defer dir.close(io);
  var it = dir.iterate();
  while (it.next(io) catch null) |entry| {
    const list = if (looksLikeDongle(entry.name)) &found.dongles else &found.others;
    const name = try gpa.dupe(u8, entry.name);
    list.append(gpa, name) catch |e| {
      gpa.free(name);
      return e;
    };
  }
  for ([_]*std.ArrayList([]u8){ &found.dongles, &found.others }) |list| {
    std.mem.sort([]u8, list.items, {}, lessThan);
  }
  return found;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
  return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

test "the dongles are told from other serial devices by their names" {
  try testing.expect(
    looksLikeDongle(
      "usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_b8aeef8b3a1fef11b64250d0639e525b-if00-port0",
    ),
  );
  try testing.expect(
    looksLikeDongle("usb-Nabu_Casa_SkyConnect_v1.0_3abe54797c91ed118fc3cad13b20a111-if00-port0"),
  );
  try testing.expect(
    looksLikeDongle(
      "usb-Nabu_Casa_Home_Assistant_Connect_ZBT-1_9ab1da1ea4b3ed11a3b7b85b4f8e0d01-if00-port0",
    ),
  );
  try testing.expect(
    looksLikeDongle(
      "usb-SONOFF_SONOFF_Dongle_Plus_MG24_b023a583a66bef118e30a3adc169b110-if00-port0",
    ),
  );
  try testing.expect(!looksLikeDongle("usb-FTDI_FT232R_USB_UART_A10K1234-if00-port0"));
  try testing.expect(
    !looksLikeDongle("usb-Prolific_Technology_Inc._USB-Serial_Controller-if00-port0"),
  );
}

test "a directory's dongles and other serial devices are found, sorted" {
  var tmp = testing.tmpDir(.{});
  defer tmp.cleanup();
  for ([_][]const u8{
    "usb-SONOFF_SONOFF_Dongle_Lite_MG21_c82f-if00-port0",
    "usb-FTDI_FT232R_USB_UART_A10K1234-if00-port0",
    "usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_b8ae-if00-port0",
  }) |name| {
    var file = try tmp.dir.createFile(testing.io, name, .{});
    file.close(testing.io);
  }
  var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
  const len = try tmp.dir.realPath(testing.io, &buffer);
  var found = try scan(testing.allocator, testing.io, buffer[0..len]);
  defer found.deinit(testing.allocator);
  try testing.expectEqual(2, found.dongles.items.len);
  try testing.expectEqualStrings(
    "usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_b8ae-if00-port0",
    found.dongles.items[0],
  );
  try testing.expectEqualStrings(
    "usb-SONOFF_SONOFF_Dongle_Lite_MG21_c82f-if00-port0",
    found.dongles.items[1],
  );
  try testing.expectEqual(1, found.others.items.len);

  // No directory: nothing plugged in.
  var none = try scan(testing.allocator, testing.io, "/nonexistent/serial/by-id");
  defer none.deinit(testing.allocator);
  try testing.expectEqual(0, none.dongles.items.len + none.others.items.len);
}
