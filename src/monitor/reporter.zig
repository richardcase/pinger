//! Monitor output reporters, mirroring internal/monitor/reporter.go: a
//! byte-for-byte log reporter and a realtime chart reporter that maintains
//! per-target rolling RTT buffers and redraws an asciigraph plot in the
//! alternate screen buffer.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const rfc3339 = @import("../rfc3339.zig");
const gofmt = @import("../gofmt.zig");
const sys = @import("../sys.zig");
const asciigraph = @import("asciigraph.zig");

pub const Display = enum { log, chart };

pub const ResolveResult = union(enum) {
    ok: Display,
    not_tty,
    invalid: []const u8,
};

/// Validate a --display value against TTY availability (matches ResolveDisplay).
pub fn resolveDisplay(mode: []const u8, is_tty: bool) ResolveResult {
    if (std.mem.eql(u8, mode, "log")) return .{ .ok = .log };
    if (std.mem.eql(u8, mode, "chart")) {
        if (!is_tty) return .not_tty;
        return .{ .ok = .chart };
    }
    return .{ .invalid = mode };
}

pub fn isStdoutTty() bool {
    return c.isatty(sys.stdout_fd) != 0;
}

/// One target's data for a probe cycle. Sent/Errors/AvgMs are cumulative;
/// CycleMs is this cycle's RTT (null on failure).
pub const TargetCycle = struct {
    label: []const u8,
    sent: i64,
    errors: i64,
    avg_ms: f64,
    cycle_ms: ?f64,
};

const enter_alt_screen = "\x1b[?1049h";
const leave_alt_screen = "\x1b[?1049l";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const clear_and_home = "\x1b[H\x1b[2J";

fn writeLogLines(gpa: std.mem.Allocator, ts: rfc3339.Time, rows: []const TargetCycle, comptime total: bool) void {
    var tb: [40]u8 = undefined;
    const tsstr = rfc3339.formatRFC3339(&tb, ts.secs);
    for (rows) |row| {
        if (!total and row.sent == 0) continue;
        var ab: [350]u8 = undefined;
        const avg = gofmt.formatFixed(&ab, row.avg_ms, 2);
        const line = if (total)
            std.fmt.allocPrint(gpa, "[{s}] {s} TOTAL sent={d} errors={d} avg_rtt={s}ms\n", .{ tsstr, row.label, row.sent, row.errors, avg }) catch return
        else
            std.fmt.allocPrint(gpa, "[{s}] {s} sent={d} errors={d} avg_rtt={s}ms\n", .{ tsstr, row.label, row.sent, row.errors, avg }) catch return;
        defer gpa.free(line);
        sys.writeAll(sys.stdout_fd, line);
    }
    if (total) {
        const stopped = std.fmt.allocPrint(gpa, "[{s}] monitor stopped\n", .{tsstr}) catch return;
        defer gpa.free(stopped);
        sys.writeAll(sys.stdout_fd, stopped);
    }
}

pub const LogReporter = struct {
    gpa: std.mem.Allocator,

    pub fn cycle(self: *LogReporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        writeLogLines(self.gpa, ts, rows, false);
    }
    pub fn final(self: *LogReporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        writeLogLines(self.gpa, ts, rows, true);
    }
};

pub const ChartReporter = struct {
    gpa: std.mem.Allocator,
    labels: [][]const u8,
    series: []std.ArrayList(f64),
    started: bool = false,

    pub fn init(gpa: std.mem.Allocator, labels: []const []const u8) !ChartReporter {
        const lbl = try gpa.alloc([]const u8, labels.len);
        const ser = try gpa.alloc(std.ArrayList(f64), labels.len);
        for (labels, 0..) |l, i| {
            lbl[i] = l;
            ser[i] = .empty;
        }
        return .{ .gpa = gpa, .labels = lbl, .series = ser };
    }

    pub fn deinit(self: *ChartReporter) void {
        for (self.series) |*s| s.deinit(self.gpa);
        self.gpa.free(self.series);
        self.gpa.free(self.labels);
    }

    pub fn cycle(self: *ChartReporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        _ = ts;
        if (!self.started) {
            sys.writeAll(sys.stdout_fd, enter_alt_screen ++ hide_cursor);
            self.started = true;
        }
        const sz = termSize();
        for (rows, 0..) |row, i| {
            if (i >= self.series.len) break;
            const v = row.cycle_ms orelse std.math.nan(f64);
            self.series[i].append(self.gpa, v) catch {};
            if (sz.w > 0 and self.series[i].items.len > sz.w) {
                const drop = self.series[i].items.len - sz.w;
                std.mem.copyForwards(f64, self.series[i].items[0..sz.w], self.series[i].items[drop..]);
                self.series[i].shrinkRetainingCapacity(sz.w);
            }
        }
        self.render(sz.w, sz.h);
    }

    fn render(self: *ChartReporter, width: usize, height: usize) void {
        _ = width;
        var plot_h: usize = if (height > 4) height - 4 else 3;
        if (plot_h < 3) plot_h = 3;

        var any = false;
        for (self.series) |s| for (s.items) |v| {
            if (!std.math.isNan(v)) {
                any = true;
                break;
            }
        };

        if (!any) {
            sys.writeAll(sys.stdout_fd, clear_and_home);
            sys.writeAll(sys.stdout_fd, "RTT (ms) over time \xe2\x80\x94 waiting for data\xe2\x80\xa6\n");
            return;
        }

        const slices = self.gpa.alloc([]const f64, self.series.len) catch return;
        defer self.gpa.free(slices);
        for (self.series, 0..) |s, i| slices[i] = s.items;

        const graph = asciigraph.plotMany(self.gpa, slices, self.labels, plot_h, "RTT (ms) over time") catch return;
        defer self.gpa.free(graph);
        sys.writeAll(sys.stdout_fd, clear_and_home);
        sys.writeAll(sys.stdout_fd, graph);
    }

    pub fn final(self: *ChartReporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        if (self.started) {
            sys.writeAll(sys.stdout_fd, leave_alt_screen ++ show_cursor);
        }
        writeLogLines(self.gpa, ts, rows, true);
    }
};

pub const Reporter = union(enum) {
    log: LogReporter,
    chart: ChartReporter,

    pub fn cycle(self: *Reporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        switch (self.*) {
            inline else => |*r| r.cycle(ts, rows),
        }
    }
    pub fn final(self: *Reporter, ts: rfc3339.Time, rows: []const TargetCycle) void {
        switch (self.*) {
            inline else => |*r| r.final(ts, rows),
        }
    }
    pub fn deinit(self: *Reporter) void {
        switch (self.*) {
            .chart => |*c2| c2.deinit(),
            .log => {},
        }
    }
};

const TermSize = struct { w: usize, h: usize };

fn termSize() TermSize {
    var ws: posix.winsize = undefined;
    const rc = c.ioctl(sys.stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .w = 80, .h = 24 };
    return .{ .w = ws.col, .h = ws.row };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveDisplay" {
    try std.testing.expect(resolveDisplay("log", false) == .ok);
    try std.testing.expect(resolveDisplay("chart", false) == .not_tty);
    try std.testing.expect(resolveDisplay("chart", true) == .ok);
    try std.testing.expect(resolveDisplay("bogus", true) == .invalid);
}
