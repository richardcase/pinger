//! ProbeResult — the JSONL record. Encoding is hand-written to match Go's
//! encoding/json byte-for-byte (field order, omitempty on the nil pointers,
//! RFC3339Nano timestamps, shortest-float rtt_ms).

const std = @import("std");
const rfc3339 = @import("../rfc3339.zig");
const gofmt = @import("../gofmt.zig");

pub const ProbeResult = struct {
    timestamp: rfc3339.Time,
    target: []const u8,
    success: bool,
    rtt_ms: ?f64 = null,
    fail_reason: ?[]const u8 = null,
};

/// Append the compact JSON object for `r` (no trailing newline) to `out`.
pub fn encode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, r: ProbeResult) !void {
    var tbuf: [40]u8 = undefined;
    var fbuf: [350]u8 = undefined;

    try out.appendSlice(gpa, "{\"timestamp\":\"");
    try out.appendSlice(gpa, rfc3339.formatRFC3339Nano(&tbuf, r.timestamp));
    try out.appendSlice(gpa, "\",\"target\":");
    try gofmt.appendJsonString(out, gpa, r.target);
    try out.appendSlice(gpa, ",\"success\":");
    try out.appendSlice(gpa, if (r.success) "true" else "false");
    if (r.rtt_ms) |v| {
        try out.appendSlice(gpa, ",\"rtt_ms\":");
        try out.appendSlice(gpa, gofmt.formatGoFloat(&fbuf, v));
    }
    if (r.fail_reason) |fr| {
        try out.appendSlice(gpa, ",\"fail_reason\":");
        try gofmt.appendJsonString(out, gpa, fr);
    }
    try out.append(gpa, '}');
}

// Wire mirror used for decoding; defaults make every field optional so a line
// missing a field is tolerated rather than rejected (matches Go zero values).
const Wire = struct {
    timestamp: []const u8 = "",
    target: []const u8 = "",
    success: bool = false,
    rtt_ms: ?f64 = null,
    fail_reason: ?[]const u8 = null,
};

/// Decode a single JSONL line. Returns null for malformed lines (skipped, as
/// Go does). The returned record's `target`/`fail_reason` are not retained
/// (report aggregation only needs timestamp/success/rtt_ms).
pub fn decodeForTarget(gpa: std.mem.Allocator, line: []const u8, target: []const u8) ?ProbeResult {
    const parsed = std.json.parseFromSlice(Wire, gpa, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const w = parsed.value;
    if (!std.mem.eql(u8, w.target, target)) return null;
    const ts = rfc3339.parse(w.timestamp) catch return null;
    return ProbeResult{
        .timestamp = ts,
        .target = "",
        .success = w.success,
        .rtt_ms = w.rtt_ms,
        .fail_reason = null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectEncode(r: ProbeResult, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encode(&out, gpa, r);
    try std.testing.expectEqualStrings(want, out.items);
}

test "encode success record matches Go json" {
    const ts = try rfc3339.parse("2026-05-28T09:30:38.883747887Z");
    try expectEncode(
        .{ .timestamp = ts, .target = "google", .success = true, .rtt_ms = 3.836694 },
        "{\"timestamp\":\"2026-05-28T09:30:38.883747887Z\",\"target\":\"google\",\"success\":true,\"rtt_ms\":3.836694}",
    );
}

test "encode failure record matches Go json" {
    const ts = try rfc3339.parse("2026-05-28T09:30:38Z");
    try expectEncode(
        .{ .timestamp = ts, .target = "google", .success = false, .fail_reason = "i/o timeout" },
        "{\"timestamp\":\"2026-05-28T09:30:38Z\",\"target\":\"google\",\"success\":false,\"fail_reason\":\"i/o timeout\"}",
    );
}

test "decode round trips a line" {
    const gpa = std.testing.allocator;
    const line = "{\"timestamp\":\"2026-05-28T09:30:38.883747887Z\",\"target\":\"google\",\"success\":true,\"rtt_ms\":3.836694}";
    const r = decodeForTarget(gpa, line, "google").?;
    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(f64, 3.836694), r.rtt_ms.?);
    const expect_ts = try rfc3339.parse("2026-05-28T09:30:38.883747887Z");
    try std.testing.expectEqual(expect_ts.secs, r.timestamp.secs);
    try std.testing.expectEqual(expect_ts.nanos, r.timestamp.nanos);
    // Non-matching target -> null
    try std.testing.expect(decodeForTarget(gpa, line, "other") == null);
    // Malformed -> null
    try std.testing.expect(decodeForTarget(gpa, "{not json", "google") == null);
}
