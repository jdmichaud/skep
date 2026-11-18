//! What the bus accepts as strings, object paths and names: a message breaking these rules is
//! refused by the bus, so they are checked before one is sent, and in what is received.

const std = @import("std");

/// Longest name: bus names, interfaces, members, error names.
pub const max_name = 255;

/// UTF-8, without NUL.
pub fn isString(s: []const u8) bool {
  return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}

/// "/", or elements of [A-Za-z0-9_] each after a slash, none empty.
pub fn isObjectPath(p: []const u8) bool {
  if (p.len == 0 or p[0] != '/') return false;
  if (p.len == 1) return true;
  var elements = std.mem.splitScalar(u8, p[1..], '/');
  while (elements.next()) |element| {
    if (element.len == 0) return false;
    for (element) |c| {
      if (!isPathChar(c)) return false;
    }
  }
  return true;
}

/// A character of an object path's element.
pub fn isPathChar(c: u8) bool {
  return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Two elements or more, separated by dots, of [A-Za-z0-9_], none starting with a digit; as
/// error names are too.
pub fn isInterface(name: []const u8) bool {
  return isDotted(name, false);
}

/// A well-known bus name, such as one a service owns: as an interface, with dashes allowed.
pub fn isBusName(name: []const u8) bool {
  return isDotted(name, true);
}

/// A method, signal or property: [A-Za-z0-9_], not starting with a digit.
pub fn isMember(name: []const u8) bool {
  return name.len > 0 and name.len <= max_name and isElement(name, false);
}

fn isDotted(name: []const u8, dashes: bool) bool {
  if (name.len == 0 or name.len > max_name) return false;
  var count: usize = 0;
  var elements = std.mem.splitScalar(u8, name, '.');
  while (elements.next()) |element| {
    if (element.len == 0 or !isElement(element, dashes)) return false;
    count += 1;
  }
  return count >= 2;
}

fn isElement(element: []const u8, dashes: bool) bool {
  if (std.ascii.isDigit(element[0])) return false;
  for (element) |c| {
    if (!(std.ascii.isAlphanumeric(c) or c == '_' or (dashes and c == '-'))) return false;
  }
  return true;
}

const testing = std.testing;

test "object paths and names follow the bus's rules" {
  for ([_][]const u8{ "/", "/a", "/io/github/x/Skep1/devices/f44250000d350000", "/_1" }) |p| {
    try testing.expect(isObjectPath(p));
  }
  for ([_][]const u8{ "", "a", "//", "/a/", "/a//b", "/a-b", "/a.b" }) |p| {
    try testing.expect(!isObjectPath(p));
  }
  try testing.expect(isInterface("org.freedesktop.DBus.Properties"));
  try testing.expect(!isInterface("org"));
  try testing.expect(!isInterface("org.1x"));
  try testing.expect(!isInterface("org..x"));
  try testing.expect(!isInterface("org.x-y"));
  try testing.expect(isBusName("io.github.some-one.Skep1"));
  try testing.expect(!isBusName(":1.42"));
  try testing.expect(isMember("GetAll"));
  try testing.expect(!isMember("Get.All"));
  try testing.expect(!isMember("1Get"));
  try testing.expect(!isMember(""));
  try testing.expect(isString("°C"));
  try testing.expect(!isString("\xc3"));
}
