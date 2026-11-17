//! The file where skepd keeps libskep's state: read once at start, and replaced as a whole on
//! each change, so that a crash leaves the old state or the new one, never half of each. It holds
//! the network key, so only its owner may read it.

const std = @import("std");

const linux = std.os.linux;

/// A step that failed, and why.
pub const Failure = struct {
  step: []const u8,
  errno: linux.E,
};

/// Larger than any state: a file this large is not one.
const max_len = 16 << 20;

/// Where the state goes by default: the state directory systemd gives the service, or the XDG
/// data directory. Null if neither can be found.
pub fn defaultPath(
  arena: std.mem.Allocator,
  environ: *const std.process.Environ.Map,
) ?[:0]const u8 {
  if (environ.get("STATE_DIRECTORY")) |directories| {
    // Several, separated by colons, when the unit names several.
    var it = std.mem.splitScalar(u8, directories, ':');
    const first = it.first();
    if (first.len > 0) {
      return std.fmt.allocPrintSentinel(arena, "{s}/state.json", .{ first }, 0) catch null;
    }
  }
  if (environ.get("XDG_DATA_HOME")) |data| {
    // Relative paths are invalid, and to be ignored.
    if (std.fs.path.isAbsolute(data)) {
      return std.fmt.allocPrintSentinel(arena, "{s}/skep/state.json", .{ data }, 0) catch null;
    }
  }
  const home = environ.get("HOME") orelse return null;
  if (home.len == 0) return null;
  return std.fmt.allocPrintSentinel(arena, "{s}/.local/share/skep/state.json", .{ home }, 0) catch
    null;
}

pub const Read = union(enum) {
  /// No file yet.
  none,
  /// The file's contents, to be freed with the allocator given.
  data: []u8,
  failed: Failure,
};

pub fn read(gpa: std.mem.Allocator, path: [:0]const u8) Read {
  const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
  switch (linux.errno(rc)) {
    .SUCCESS => {},
    .NOENT => return .none,
    else => |e| return .{ .failed = .{ .step = "open", .errno = e } },
  }
  const fd: linux.fd_t = @intCast(rc);
  defer _ = linux.close(fd);
  var data: std.ArrayList(u8) = .empty;
  errdefer data.deinit(gpa);
  while (true) {
    if (data.items.len >= max_len) {
      data.deinit(gpa);
      return .{ .failed = .{ .step = "read", .errno = .FBIG } };
    }
    data.ensureUnusedCapacity(gpa, 4096) catch {
      data.deinit(gpa);
      return .{ .failed = .{ .step = "read", .errno = .NOMEM } };
    };
    const free = data.unusedCapacitySlice();
    const n = linux.read(fd, free.ptr, free.len);
    switch (linux.errno(n)) {
      .SUCCESS => {},
      .INTR => continue,
      else => |e| {
        data.deinit(gpa);
        return .{ .failed = .{ .step = "read", .errno = e } };
      },
    }
    if (n == 0) break;
    data.items.len += n;
  }
  const bytes = data.toOwnedSlice(gpa) catch {
    data.deinit(gpa);
    return .{ .failed = .{ .step = "read", .errno = .NOMEM } };
  };
  return .{ .data = bytes };
}

/// Replaces the file with `data`: written to a temporary file of mode 0600 beside it, synced, then
/// renamed over it. Creates the missing directories, of mode 0700. Null on success.
pub fn write(path: [:0]const u8, data: []const u8) ?Failure {
  var buffer: [4096]u8 = undefined;
  const directory = std.fs.path.dirname(path) orelse ".";
  if (makeDirectories(directory)) |failure| return failure;
  const temporary = std.fmt.bufPrintSentinel(&buffer, "{s}.tmp", .{ path }, 0) catch
    return .{ .step = "open", .errno = .NAMETOOLONG };
  const rc = linux.open(
    temporary,
    .{
      .ACCMODE = .WRONLY,
      .CREAT = true,
      .TRUNC = true,
      .NOFOLLOW = true,
      .CLOEXEC = true,
    },
    0o600,
  );
  if (linux.errno(rc) != .SUCCESS) return .{ .step = "open", .errno = linux.errno(rc) };
  const fd: linux.fd_t = @intCast(rc);
  // A temporary file left from before keeps its mode, which the state would take.
  const mode = linux.errno(linux.fchmod(fd, 0o600));
  if (mode != .SUCCESS) {
    _ = linux.close(fd);
    return .{ .step = "chmod", .errno = mode };
  }
  var written: usize = 0;
  while (written < data.len) {
    const n = linux.write(fd, data[written..].ptr, data.len - written);
    switch (linux.errno(n)) {
      .SUCCESS => written += n,
      .INTR => {},
      else => |e| {
        _ = linux.close(fd);
        return .{ .step = "write", .errno = e };
      },
    }
  }
  const synced = linux.errno(linux.fsync(fd));
  _ = linux.close(fd);
  if (synced != .SUCCESS) return .{ .step = "fsync", .errno = synced };
  const renamed = linux.errno(linux.rename(temporary, path));
  if (renamed != .SUCCESS) return .{ .step = "rename", .errno = renamed };
  // The rename itself, on disk.
  var directory_buffer: [4096]u8 = undefined;
  const directory_z = std.fmt.bufPrintSentinel(&directory_buffer, "{s}", .{ directory }, 0) catch
    return null;
  const dir = linux.open(
    directory_z,
    .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
    0,
  );
  if (linux.errno(dir) == .SUCCESS) {
    _ = linux.fsync(@intCast(dir));
    _ = linux.close(@intCast(dir));
  }
  return null;
}

/// Creates `directory` and those above it that are missing, of mode 0700.
fn makeDirectories(directory: []const u8) ?Failure {
  var buffer: [4096]u8 = undefined;
  if (directory.len >= buffer.len) return .{ .step = "mkdir", .errno = .NAMETOOLONG };
  var end: usize = 1;
  while (end <= directory.len) : (end += 1) {
    if (end < directory.len and directory[end] != '/') continue;
    @memcpy(buffer[0..end], directory[0..end]);
    buffer[end] = 0;
    const made = linux.errno(linux.mkdir(buffer[0..end :0], 0o700));
    if (made != .SUCCESS and made != .EXIST) return .{ .step = "mkdir", .errno = made };
  }
  return null;
}

test "a state written is read back, and replaced as a whole" {
  var tmp = std.testing.tmpDir(.{});
  defer tmp.cleanup();
  var buffer: [4096]u8 = undefined;
  const base = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{ tmp.sub_path });
  var path_buffer: [4096]u8 = undefined;
  const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/skep/state.json", .{ base }, 0);
  try std.testing.expect(read(std.testing.allocator, path) == .none);
  try std.testing.expectEqual(null, write(path, "{\"first\": 1}"));
  // A temporary file left from before, readable by all, does not pass its mode on.
  var temporary_buffer: [4096]u8 = undefined;
  const temporary = try std.fmt.bufPrintSentinel(&temporary_buffer, "{s}.tmp", .{ path }, 0);
  const rc = linux.open(temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
  _ = linux.fchmod(@intCast(rc), 0o644);
  _ = linux.close(@intCast(rc));
  try std.testing.expectEqual(null, write(path, "{}"));
  const result = read(std.testing.allocator, path);
  defer std.testing.allocator.free(result.data);
  try std.testing.expectEqualStrings("{}", result.data);
  var st: linux.Statx = undefined;
  try std.testing.expectEqual(
    .SUCCESS,
    linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &st)),
  );
  try std.testing.expectEqual(0o600, st.mode & 0o777);
}
