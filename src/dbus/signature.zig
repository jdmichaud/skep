//! Type signatures, which say the types of D-Bus values: a character for a basic type, more for a
//! container, such as `a{sv}` for a dictionary of variants by string.

const std = @import("std");

/// Longest signature, in bytes.
pub const max_len = 255;
/// Most arrays, and most structures, nested in one another. A dictionary counts as both: it is an
/// array of entries, which are structures. Variants count as structures, so that what a variant
/// holds cannot nest without end.
pub const max_depth = 32;

/// Whether `c` is a basic type: one that can be a dictionary's key.
pub fn isBasic(c: u8) bool {
  return switch (c) {
    'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
    else => false,
  };
}

/// How values of the type starting with `c` are aligned in a message.
pub fn alignment(c: u8) usize {
  return switch (c) {
    'y', 'g', 'v' => 1,
    'n', 'q' => 2,
    'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
    'x', 't', 'd', '(', '{' => 8,
    else => 1,
  };
}

/// The length of the complete type that `sig` starts with, or null if it starts with none.
pub fn completeLen(sig: []const u8) ?usize {
  return complete(sig, 0, 0, 0);
}

/// Whether `sig` is one complete type, as a variant holds.
pub fn isSingle(sig: []const u8) bool {
  return sig.len <= max_len and completeLen(sig) == sig.len;
}

/// Whether `sig` is a sequence of complete types, none or more, as a message's body has.
pub fn isValid(sig: []const u8) bool {
  if (sig.len > max_len) return false;
  var i: usize = 0;
  while (i < sig.len) {
    i += completeLen(sig[i..]) orelse return false;
  }
  return true;
}

/// Where the complete type at `i` ends, with `arrays` and `structs` around it.
fn complete(sig: []const u8, i: usize, arrays: usize, structs: usize) ?usize {
  if (i >= sig.len) return null;
  switch (sig[i]) {
    'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return i + 1,
    'a' => {
      if (arrays == max_depth) return null;
      if (i + 1 < sig.len and sig[i + 1] == '{') {
        if (structs == max_depth) return null;
        const key = i + 2;
        if (key >= sig.len or !isBasic(sig[key])) return null;
        const end = complete(sig, key + 1, arrays + 1, structs + 1) orelse return null;
        if (end >= sig.len or sig[end] != '}') return null;
        return end + 1;
      }
      return complete(sig, i + 1, arrays + 1, structs);
    },
    '(' => {
      if (structs == max_depth) return null;
      var j = i + 1;
      // A structure has at least one field.
      if (j < sig.len and sig[j] == ')') return null;
      while (j < sig.len) {
        if (sig[j] == ')') return j + 1;
        j = complete(sig, j, arrays, structs + 1) orelse return null;
      }
      return null;
    },
    else => return null,
  }
}

const testing = std.testing;

test "signatures are complete types, nested within bounds" {
  for ([_][]const u8{ "s", "v", "as", "a{sv}", "a{oa{sa{sv}}}", "(ii)", "a(yv)", "aai" }) |sig| {
    try testing.expect(isSingle(sig));
  }
  try testing.expect(isValid(""));
  try testing.expect(isValid("ssv"));
  try testing.expect(isValid("sa{sv}as"));
  for ([_][]const u8{
    "",
    "a",
    "()",
    "(i",
    "a{vs}",
    "a{s}",
    "a{sss}",
    "{sv}",
    "z",
    "ii",
    "a{sv",
  }) |sig| {
    try testing.expect(!isSingle(sig));
  }
  try testing.expect(!isValid("a"));
  try testing.expect(!isValid("s)"));

  var deep: [max_depth + 2]u8 = @splat('a');
  deep[deep.len - 1] = 'i';
  try testing.expect(!isSingle(&deep));
  try testing.expect(isSingle(deep[2..]));
  var structs: [2 * max_depth + 3]u8 = undefined;
  for (0..max_depth + 1) |k| {
    structs[k] = '(';
    structs[structs.len - 1 - k] = ')';
  }
  structs[max_depth + 1] = 'i';
  try testing.expect(!isSingle(&structs));
  try testing.expect(isSingle(structs[1..structs.len - 1]));
}
