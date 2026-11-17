//! Times as skepd writes them, in its log and its protocol: UTC, ISO 8601, to the millisecond.

const std = @import("std");

const Io = std.Io;

/// The wall-clock time, in milliseconds since the epoch.
pub fn now(io: Io) i64 {
  return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// A time in milliseconds since the epoch: 2026-11-16T21:39:12.250Z.
pub fn format(buffer: *[32]u8, time: i64) []const u8 {
  const ms: u64 = @intCast(@max(time, 0));
  const epoch: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
  const year_day = epoch.getEpochDay().calculateYearDay();
  const month_day = year_day.calculateMonthDay();
  const day = epoch.getDaySeconds();
  return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
    year_day.year,
    @backingInt(month_day.month),
    month_day.day_index + 1,
    day.getHoursIntoDay(),
    day.getMinutesIntoHour(),
    day.getSecondsIntoMinute(),
    ms % 1000,
  }) catch unreachable;
}

test "times are written in UTC, to the millisecond" {
  var buffer: [32]u8 = undefined;
  try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", format(&buffer, 0));
  try std.testing.expectEqualStrings(
    "2026-11-16T21:39:12.250Z",
    format(&buffer, 1_794_865_152_250),
  );
}
