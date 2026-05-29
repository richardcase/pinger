//! The probe loop, mirroring internal/monitor/monitor.go: privilege and
//! writability pre-flight, prime-then-tick scheduling, one thread per target
//! per cycle, JSONL persistence + cumulative summaries, SIGINT/SIGTERM
//! graceful shutdown and an optional --duration deadline.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const config = @import("../config.zig");
const probe = @import("../probe.zig");
const store_writer = @import("../store/writer.zig");
const reporter = @import("reporter.zig");
const rfc3339 = @import("../rfc3339.zig");
const sys = @import("../sys.zig");

pub const Display = reporter.Display;

pub const Options = struct {
    duration_ns: i64 = 0,
    display: Display = .log,
    output_file: ?[]const u8 = null,
    skip_privilege_check: bool = false,
};

pub const Error = error{Failed} || std.mem.Allocator.Error;

const Summary = struct { sent: i64 = 0, errors: i64 = 0, total_rtt_ns: i64 = 0 };

var g_stop: std.atomic.Value(bool) = .init(false);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    g_stop.store(true, .monotonic);
}

fn installSignals() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn sleepNanos(ns: i64) void {
    if (ns <= 0) return;
    var ts = c.timespec{
        .sec = @intCast(@divTrunc(ns, 1_000_000_000)),
        .nsec = @intCast(@mod(ns, 1_000_000_000)),
    };
    _ = c.nanosleep(&ts, null);
}

fn worker(gpa: std.mem.Allocator, address: []const u8, timeout_ns: i64, slot: *probe.ProbeResult) void {
    slot.* = probe.probe(gpa, address, timeout_ns);
}

/// Run the monitor. Pre-flight failures fill `msg` and return error.Failed
/// (the caller frames them); the loop otherwise runs until a signal or the
/// duration deadline.
pub fn run(gpa: std.mem.Allocator, cfg: *const config.Config, opts: Options, msg: *std.ArrayList(u8)) Error!void {
    if (!opts.skip_privilege_check) {
        if (probe.checkPrivilege(gpa)) |m| {
            defer gpa.free(m);
            try msg.appendSlice(gpa, m);
            return error.Failed;
        }
    }
    if (try store_writer.isWritable(gpa, cfg.data_dir)) |m| {
        defer gpa.free(m);
        try msg.appendSlice(gpa, m);
        return error.Failed;
    }

    var writer = store_writer.Writer.init(gpa, cfg.data_dir, opts.output_file);
    defer writer.deinit();

    const labels = try gpa.alloc([]const u8, cfg.targets.len);
    defer gpa.free(labels);
    for (cfg.targets, 0..) |t, i| labels[i] = t.label;

    var rep: reporter.Reporter = if (opts.display == .chart)
        .{ .chart = try reporter.ChartReporter.init(gpa, labels) }
    else
        .{ .log = .{ .gpa = gpa } };
    defer rep.deinit();

    g_stop.store(false, .monotonic);
    installSignals();

    const summaries = try gpa.alloc(Summary, cfg.targets.len);
    defer gpa.free(summaries);
    @memset(summaries, .{});

    const start_mono = sys.monotonicNanos();
    const deadline: ?i64 = if (opts.duration_ns > 0) start_mono + opts.duration_ns else null;

    try runCycle(gpa, cfg, &writer, &rep, summaries);

    var next_tick = start_mono + cfg.interval_ns;
    while (!g_stop.load(.monotonic)) {
        const now = sys.monotonicNanos();
        if (deadline) |d| if (now >= d) break;
        if (now >= next_tick) {
            try runCycle(gpa, cfg, &writer, &rep, summaries);
            next_tick += cfg.interval_ns;
            continue;
        }
        var sleep_ns = next_tick - now;
        if (deadline) |d| sleep_ns = @min(sleep_ns, d - now);
        sleep_ns = @min(sleep_ns, 100 * std.time.ns_per_ms);
        sleepNanos(sleep_ns);
    }

    const ts = sys.nowUtc();
    const rows = buildRows(gpa, cfg, summaries, null) catch return;
    defer gpa.free(rows);
    rep.final(ts, rows);
}

fn runCycle(
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    writer: *store_writer.Writer,
    rep: *reporter.Reporter,
    summaries: []Summary,
) Error!void {
    const n = cfg.targets.len;
    const results = try gpa.alloc(probe.ProbeResult, n);
    defer gpa.free(results);
    const threads = try gpa.alloc(?std.Thread, n);
    defer gpa.free(threads);

    for (cfg.targets, 0..) |t, i| {
        const timeout = t.timeout_ns orelse cfg.timeout_ns;
        threads[i] = std.Thread.spawn(.{}, worker, .{ gpa, t.address, timeout, &results[i] }) catch null;
        if (threads[i] == null) results[i] = probe.probe(gpa, t.address, timeout);
    }
    for (threads) |th| if (th) |t| t.join();

    const cycle_rtt = try gpa.alloc(?f64, n);
    defer gpa.free(cycle_rtt);

    for (results, 0..) |*r, i| {
        r.target = cfg.targets[i].label;
        writer.write(r.*) catch {};
        const s = &summaries[i];
        s.sent += 1;
        if (r.success and r.rtt_ms != null) {
            s.total_rtt_ns += @intFromFloat(r.rtt_ms.? * 1_000_000.0);
            cycle_rtt[i] = r.rtt_ms;
        } else {
            s.errors += 1;
            cycle_rtt[i] = null;
        }
        if (r.fail_reason) |fr| gpa.free(fr);
    }

    const ts = sys.nowUtc();
    const rows = try buildRows(gpa, cfg, summaries, cycle_rtt);
    defer gpa.free(rows);
    rep.cycle(ts, rows);
}

fn buildRows(
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    summaries: []const Summary,
    cycle_rtt: ?[]const ?f64,
) ![]reporter.TargetCycle {
    const rows = try gpa.alloc(reporter.TargetCycle, cfg.targets.len);
    for (cfg.targets, 0..) |t, i| {
        const s = summaries[i];
        var avg: f64 = 0;
        if (s.sent > s.errors) {
            avg = @as(f64, @floatFromInt(s.total_rtt_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(s.sent - s.errors));
        }
        rows[i] = .{
            .label = t.label,
            .sent = s.sent,
            .errors = s.errors,
            .avg_ms = avg,
            .cycle_ms = if (cycle_rtt) |cr| cr[i] else null,
        };
    }
    return rows;
}
