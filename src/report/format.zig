//! Renders a ReportSummary as the human table or indented JSON, byte-for-byte
//! matching internal/report/format.go.

const std = @import("std");
const rfc3339 = @import("../rfc3339.zig");
const gofmt = @import("../gofmt.zig");
const summary = @import("summary.zig");

pub const ReportSummary = summary.ReportSummary;

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try out.appendSlice(gpa, s);
}

fn appendFloat(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f64) !void {
    var buf: [350]u8 = undefined;
    try out.appendSlice(gpa, gofmt.formatGoFloat(&buf, v));
}

fn appendFixed(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f64, prec: usize) !void {
    var buf: [350]u8 = undefined;
    try out.appendSlice(gpa, gofmt.formatFixed(&buf, v, prec));
}

/// Write the human-readable table (matches FormatTable).
pub fn formatTable(out: *std.ArrayList(u8), gpa: std.mem.Allocator, rs: ReportSummary) !void {
    if (rs.total_probes == 0) {
        try out.appendSlice(gpa, "no records found for target ");
        const q = try gofmt.goQuote(gpa, rs.target);
        defer gpa.free(q);
        try out.appendSlice(gpa, q);
        try out.append(gpa, '\n');
        return;
    }

    var pb1: [40]u8 = undefined;
    var pb2: [40]u8 = undefined;

    try out.appendSlice(gpa, "Target:      ");
    try out.appendSlice(gpa, rs.target);
    try out.append(gpa, '\n');

    try out.appendSlice(gpa, "Period:      ");
    try out.appendSlice(gpa, rfc3339.formatTablePeriod(&pb1, rs.from.secs));
    try out.appendSlice(gpa, " \xe2\x80\x93 "); // " – " (U+2013)
    try out.appendSlice(gpa, rfc3339.formatTablePeriod(&pb2, rs.to.secs));
    try out.append(gpa, '\n');

    try out.appendSlice(gpa, "Total:       ");
    try appendInt(out, gpa, rs.total_probes);
    try out.appendSlice(gpa, " probes\n");

    try out.appendSlice(gpa, "Successes:   ");
    try appendInt(out, gpa, rs.successes);
    try out.append(gpa, '\n');

    try out.appendSlice(gpa, "Failures:    ");
    try appendInt(out, gpa, rs.failures);
    try out.append(gpa, '\n');

    try out.appendSlice(gpa, "Uptime:      ");
    try appendFixed(out, gpa, rs.uptime_pct, 2);
    try out.appendSlice(gpa, "%\n");

    try out.appendSlice(gpa, "Min RTT:     ");
    try appendFixed(out, gpa, rs.min_rtt_ms, 3);
    try out.appendSlice(gpa, " ms\n");

    try out.appendSlice(gpa, "Max RTT:     ");
    try appendFixed(out, gpa, rs.max_rtt_ms, 3);
    try out.appendSlice(gpa, " ms\n");

    try out.appendSlice(gpa, "Avg RTT:     ");
    try appendFixed(out, gpa, rs.avg_rtt_ms, 3);
    try out.appendSlice(gpa, " ms\n");
}

/// Write the report as indented JSON (matches FormatJSON: MarshalIndent with a
/// 2-space indent, followed by a trailing newline from Fprintln).
pub fn formatJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, rs: ReportSummary) !void {
    var tb: [40]u8 = undefined;

    try out.appendSlice(gpa, "{\n  \"target\": ");
    try gofmt.appendJsonString(out, gpa, rs.target);
    try out.appendSlice(gpa, ",\n  \"from\": \"");
    try out.appendSlice(gpa, rfc3339.formatRFC3339Nano(&tb, rs.from));
    try out.appendSlice(gpa, "\",\n  \"to\": \"");
    try out.appendSlice(gpa, rfc3339.formatRFC3339Nano(&tb, rs.to));
    try out.appendSlice(gpa, "\",\n  \"total_probes\": ");
    try appendInt(out, gpa, rs.total_probes);
    try out.appendSlice(gpa, ",\n  \"successes\": ");
    try appendInt(out, gpa, rs.successes);
    try out.appendSlice(gpa, ",\n  \"failures\": ");
    try appendInt(out, gpa, rs.failures);
    try out.appendSlice(gpa, ",\n  \"uptime_pct\": ");
    try appendFloat(out, gpa, rs.uptime_pct);
    try out.appendSlice(gpa, ",\n  \"min_rtt_ms\": ");
    try appendFloat(out, gpa, rs.min_rtt_ms);
    try out.appendSlice(gpa, ",\n  \"max_rtt_ms\": ");
    try appendFloat(out, gpa, rs.max_rtt_ms);
    try out.appendSlice(gpa, ",\n  \"avg_rtt_ms\": ");
    try appendFloat(out, gpa, rs.avg_rtt_ms);
    try out.appendSlice(gpa, "\n}\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn sampleSummary() ReportSummary {
    return .{
        .target = "google",
        .from = rfc3339.parse("2026-05-28T09:30:38Z") catch unreachable,
        .to = rfc3339.parse("2026-05-28T09:30:44Z") catch unreachable,
        .total_probes = 4,
        .successes = 3,
        .failures = 1,
        .uptime_pct = 75,
        .min_rtt_ms = 3,
        .max_rtt_ms = 5,
        .avg_rtt_ms = 4,
    };
}

test "formatTable matches Go" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try formatTable(&out, gpa, sampleSummary());
    const want =
        "Target:      google\n" ++
        "Period:      2026-05-28 09:30:38Z \xe2\x80\x93 2026-05-28 09:30:44Z\n" ++
        "Total:       4 probes\n" ++
        "Successes:   3\n" ++
        "Failures:    1\n" ++
        "Uptime:      75.00%\n" ++
        "Min RTT:     3.000 ms\n" ++
        "Max RTT:     5.000 ms\n" ++
        "Avg RTT:     4.000 ms\n";
    try std.testing.expectEqualStrings(want, out.items);
}

test "formatTable empty" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var rs = sampleSummary();
    rs.target = "x";
    rs.total_probes = 0;
    try formatTable(&out, gpa, rs);
    try std.testing.expectEqualStrings("no records found for target \"x\"\n", out.items);
}

test "formatJson matches Go MarshalIndent" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try formatJson(&out, gpa, sampleSummary());
    const want =
        "{\n" ++
        "  \"target\": \"google\",\n" ++
        "  \"from\": \"2026-05-28T09:30:38Z\",\n" ++
        "  \"to\": \"2026-05-28T09:30:44Z\",\n" ++
        "  \"total_probes\": 4,\n" ++
        "  \"successes\": 3,\n" ++
        "  \"failures\": 1,\n" ++
        "  \"uptime_pct\": 75,\n" ++
        "  \"min_rtt_ms\": 3,\n" ++
        "  \"max_rtt_ms\": 5,\n" ++
        "  \"avg_rtt_ms\": 4\n" ++
        "}\n";
    try std.testing.expectEqualStrings(want, out.items);
}
