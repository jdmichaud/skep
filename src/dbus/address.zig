//! Bus addresses, as DBUS_SESSION_BUS_ADDRESS and DBUS_SYSTEM_BUS_ADDRESS give them: transports
//! and their options, `unix:path=/run/user/1000/bus`, several separated by semicolons, values
//! escaped with %XX. Of the transports, Unix sockets only, by path or abstract name.

const std = @import("std");

/// The bus's default address, when DBUS_SYSTEM_BUS_ADDRESS gives none.
pub const default_system = "unix:path=/var/run/dbus/system_bus_socket";

/// Longest socket path, as a Unix socket's address holds.
pub const max_path = 107;

/// A socket to connect to.
pub const Socket = struct {
  kind: enum { path, abstract },
  name: [max_path]u8 = undefined,
  len: usize = 0,

  pub fn bytes(s: *const Socket) []const u8 {
    return s.name[0..s.len];
  }
};

/// The first Unix socket of `address`, or null if it has none this can connect to.
pub fn firstSocket(address: []const u8) ?Socket {
  var transports = std.mem.splitScalar(u8, address, ';');
  while (transports.next()) |transport| {
    if (!std.mem.startsWith(u8, transport, "unix:")) continue;
    var options = std.mem.splitScalar(u8, transport["unix:".len..], ',');
    while (options.next()) |option| {
      const eq = std.mem.indexOfScalar(u8, option, '=') orelse continue;
      const key = option[0..eq];
      var socket: Socket = .{ .kind = undefined };
      if (std.mem.eql(u8, key, "path")) {
        socket.kind = .path;
      } else if (std.mem.eql(u8, key, "abstract")) {
        socket.kind = .abstract;
      } else {
        continue;
      }
      socket.len = unescape(&socket.name, option[eq + 1..]) orelse break;
      if (socket.len == 0) break;
      return socket;
    }
  }
  return null;
}

/// Writes `value` without its %XX escapes into `out`, and returns its length; null if it does not
/// fit or is not escaped right.
fn unescape(out: []u8, value: []const u8) ?usize {
  var len: usize = 0;
  var i: usize = 0;
  while (i < value.len) : (len += 1) {
    if (len == out.len) return null;
    if (value[i] == '%') {
      if (value.len - i < 3) return null;
      out[len] = std.fmt.parseInt(u8, value[i + 1..i + 3], 16) catch return null;
      i += 3;
    } else {
      out[len] = value[i];
      i += 1;
    }
  }
  return len;
}

const testing = std.testing;

test "the first Unix socket of an address is the one connected to" {
  const s = firstSocket("unix:path=/run/user/1000/bus").?;
  try testing.expectEqual(.path, s.kind);
  try testing.expectEqualStrings("/run/user/1000/bus", s.bytes());
  const t = firstSocket("tcp:host=localhost,port=1;unix:guid=00ff,abstract=/tmp/dbus-%41b").?;
  try testing.expectEqual(.abstract, t.kind);
  try testing.expectEqualStrings("/tmp/dbus-Ab", t.bytes());
  try testing.expectEqual(null, firstSocket("tcp:host=localhost,port=1"));
  try testing.expectEqual(null, firstSocket("unix:path=/x%4"));
  try testing.expectEqual(null, firstSocket("unix:path="));
  try testing.expectEqual(null, firstSocket(""));
  const long: [max_path + 1]u8 = @splat('a');
  try testing.expectEqual(null, firstSocket("unix:path=" ++ long));
}
