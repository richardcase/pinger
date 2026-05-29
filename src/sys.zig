//! Thin libc helpers shared across modules. We link libc and use std.c
//! directly because Zig 0.16 removed the std.posix socket/write wrappers in
//! favour of the new Io model, which we sidestep for low-level POSIX work.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const rfc3339 = @import("rfc3339.zig");

pub const stdout_fd: c_int = 1;
pub const stderr_fd: c_int = 2;

/// Current wall-clock time (UTC) as epoch seconds + nanoseconds.
pub fn nowUtc() rfc3339.Time {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(posix.CLOCK.REALTIME, &ts);
    return .{ .secs = @intCast(ts.sec), .nanos = @intCast(ts.nsec) };
}

/// Monotonic clock reading in nanoseconds, for measuring elapsed RTT.
pub fn monotonicNanos() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

/// Write all bytes to a file descriptor, retrying short writes.
pub fn writeAll(fd: c_int, bytes: []const u8) void {
    var idx: usize = 0;
    while (idx < bytes.len) {
        const n = c.write(fd, bytes.ptr + idx, bytes.len - idx);
        if (n <= 0) return;
        idx += @intCast(n);
    }
}
