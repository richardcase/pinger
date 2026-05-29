//! Aggregates ProbeResult records into a ReportSummary, mirroring
//! internal/report/summary.go exactly (min initialised to max-float, averages
//! and min/max over successful probes only, uptime as a percentage).

const std = @import("std");
const rfc3339 = @import("../rfc3339.zig");
const record = @import("../store/record.zig");

pub const ProbeResult = record.ProbeResult;

pub const ReportSummary = struct {
    target: []const u8,
    from: rfc3339.Time,
    to: rfc3339.Time,
    total_probes: i64 = 0,
    successes: i64 = 0,
    failures: i64 = 0,
    uptime_pct: f64 = 0,
    min_rtt_ms: f64 = 0,
    max_rtt_ms: f64 = 0,
    avg_rtt_ms: f64 = 0,
};

/// Go's time.Time zero value renders as "0001-01-01T00:00:00Z".
fn goZeroTime() rfc3339.Time {
    return rfc3339.fromCivil(1, 1, 1, 0, 0, 0);
}

pub fn summarise(target: []const u8, records: []const ProbeResult) ReportSummary {
    var rs = ReportSummary{
        .target = target,
        .from = goZeroTime(),
        .to = goZeroTime(),
        .min_rtt_ms = std.math.floatMax(f64),
    };

    for (records) |r| {
        if (rs.total_probes == 0) {
            rs.from = r.timestamp;
            rs.to = r.timestamp;
        } else {
            if (rfc3339.lessThan(r.timestamp, rs.from)) rs.from = r.timestamp;
            if (rfc3339.lessThan(rs.to, r.timestamp)) rs.to = r.timestamp;
        }
        rs.total_probes += 1;
        if (r.success and r.rtt_ms != null) {
            const v = r.rtt_ms.?;
            rs.successes += 1;
            rs.avg_rtt_ms += v;
            if (v < rs.min_rtt_ms) rs.min_rtt_ms = v;
            if (v > rs.max_rtt_ms) rs.max_rtt_ms = v;
        } else {
            rs.failures += 1;
        }
    }

    if (rs.total_probes == 0) {
        rs.min_rtt_ms = 0;
        return rs;
    }
    if (rs.successes > 0) {
        rs.avg_rtt_ms /= @floatFromInt(rs.successes);
        rs.uptime_pct = @as(f64, @floatFromInt(rs.successes)) / @as(f64, @floatFromInt(rs.total_probes)) * 100;
    } else {
        rs.min_rtt_ms = 0;
    }
    return rs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn mk(ts: []const u8, success: bool, rtt: ?f64) ProbeResult {
    return .{ .timestamp = rfc3339.parse(ts) catch unreachable, .target = "", .success = success, .rtt_ms = rtt };
}

test "summarise aggregates like Go" {
    const recs = [_]ProbeResult{
        mk("2026-05-28T09:30:38Z", true, 3.0),
        mk("2026-05-28T09:30:40Z", true, 5.0),
        mk("2026-05-28T09:30:42Z", false, null),
        mk("2026-05-28T09:30:44Z", true, 4.0),
    };
    const rs = summarise("google", &recs);
    try std.testing.expectEqual(@as(i64, 4), rs.total_probes);
    try std.testing.expectEqual(@as(i64, 3), rs.successes);
    try std.testing.expectEqual(@as(i64, 1), rs.failures);
    try std.testing.expectEqual(@as(f64, 3.0), rs.min_rtt_ms);
    try std.testing.expectEqual(@as(f64, 5.0), rs.max_rtt_ms);
    try std.testing.expectEqual(@as(f64, 4.0), rs.avg_rtt_ms);
    try std.testing.expectEqual(@as(f64, 75.0), rs.uptime_pct);
    try std.testing.expectEqual((rfc3339.parse("2026-05-28T09:30:38Z") catch unreachable).secs, rs.from.secs);
    try std.testing.expectEqual((rfc3339.parse("2026-05-28T09:30:44Z") catch unreachable).secs, rs.to.secs);
}

test "summarise empty and all-failure" {
    {
        const rs = summarise("x", &[_]ProbeResult{});
        try std.testing.expectEqual(@as(i64, 0), rs.total_probes);
        try std.testing.expectEqual(@as(f64, 0), rs.min_rtt_ms);
    }
    {
        const recs = [_]ProbeResult{ mk("2026-05-28T09:30:38Z", false, null), mk("2026-05-28T09:30:40Z", false, null) };
        const rs = summarise("x", &recs);
        try std.testing.expectEqual(@as(i64, 2), rs.failures);
        try std.testing.expectEqual(@as(f64, 0), rs.min_rtt_ms);
        try std.testing.expectEqual(@as(f64, 0), rs.uptime_pct);
    }
}
