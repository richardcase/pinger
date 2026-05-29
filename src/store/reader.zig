//! Reads ProbeResult records from pinger-*.jsonl files, mirroring
//! internal/store/reader.go: glob the data dir, filter by target label and
//! optional from/to bounds, silently skip malformed lines.

const std = @import("std");
const c = std.c;
const record = @import("record.zig");
const rfc3339 = @import("../rfc3339.zig");

pub const ProbeResult = record.ProbeResult;

fn matchesPattern(name: []const u8) bool {
    return name.len >= "pinger-".len + ".jsonl".len and
        std.mem.startsWith(u8, name, "pinger-") and
        std.mem.endsWith(u8, name, ".jsonl");
}

fn joinZ(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        return std.fmt.allocPrintSentinel(gpa, "{s}", .{name}, 0);
    }
    const d = std.mem.trimEnd(u8, dir, "/");
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, name }, 0);
}

fn readFile(gpa: std.mem.Allocator, path_z: [:0]const u8, out: *std.ArrayList(u8)) bool {
    const flags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.open(path_z.ptr, flags);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return false;
        if (n == 0) break;
        out.appendSlice(gpa, chunk[0..@intCast(n)]) catch return false;
    }
    return true;
}

/// Read all matching records for `target`, applying optional from/to bounds.
/// Caller owns the returned slice (free with gpa.free).
pub fn readResults(
    gpa: std.mem.Allocator,
    dir: []const u8,
    target: []const u8,
    from: ?rfc3339.Time,
    to: ?rfc3339.Time,
) ![]ProbeResult {
    var results: std.ArrayList(ProbeResult) = .empty;
    errdefer results.deinit(gpa);

    const dir_open: []const u8 = if (dir.len == 0) "." else dir;
    const dir_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{dir_open}, 0);
    defer gpa.free(dir_z);

    const dh = c.opendir(dir_z.ptr) orelse return results.toOwnedSlice(gpa);
    defer _ = c.closedir(dh);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    while (c.readdir(dh)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.name)));
        if (!matchesPattern(name)) continue;

        const path_z = try joinZ(gpa, dir, name);
        defer gpa.free(path_z);

        content.clearRetainingCapacity();
        if (!readFile(gpa, path_z, &content)) continue;

        var it = std.mem.splitScalar(u8, content.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const r = record.decodeForTarget(gpa, line, target) orelse continue;
            if (from) |f| {
                if (rfc3339.lessThan(r.timestamp, f)) continue;
            }
            if (to) |t| {
                if (rfc3339.lessThan(t, r.timestamp)) continue;
            }
            try results.append(gpa, r);
        }
    }

    return results.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Writer = @import("writer.zig").Writer;
const build_options = @import("build_options");

test "writer then reader round trip with filtering" {
    if (!build_options.integration) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const dir = "/tmp/pinger_zig_rt_test";
    _ = c.mkdir(dir, 0o755); // ignore EEXIST

    const ts1 = try rfc3339.parse("2026-05-28T09:30:38.5Z");
    const ts2 = try rfc3339.parse("2026-05-28T09:30:40Z");
    const ts3 = try rfc3339.parse("2026-05-28T09:30:42Z");

    var w = Writer.init(gpa, dir, null);
    try w.write(.{ .timestamp = ts1, .target = "google", .success = true, .rtt_ms = 3.5 });
    try w.write(.{ .timestamp = ts2, .target = "other", .success = true, .rtt_ms = 9.0 });
    try w.write(.{ .timestamp = ts3, .target = "google", .success = false, .fail_reason = "i/o timeout" });
    w.deinit();

    // Clean up the daily file afterwards.
    const file_z = try joinZ(gpa, dir, "pinger-2026-05-28.jsonl");
    defer {
        _ = c.unlink(file_z.ptr);
        gpa.free(file_z);
    }

    const all = try readResults(gpa, dir, "google", null, null);
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    // from filter excludes ts1 (keeps ts3)
    const since = try readResults(gpa, dir, "google", ts2, null);
    defer gpa.free(since);
    try std.testing.expectEqual(@as(usize, 1), since.len);
    try std.testing.expect(!since[0].success);

    // to filter excludes ts3 (keeps ts1)
    const until = try readResults(gpa, dir, "google", null, ts2);
    defer gpa.free(until);
    try std.testing.expectEqual(@as(usize, 1), until.len);
    try std.testing.expect(until[0].success);
}
