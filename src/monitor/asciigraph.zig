//! A visually-equivalent port of guptarohit/asciigraph's multi-series line
//! plot: global min/max scaling, box-drawing line segments with NaN gaps,
//! right-aligned Y-axis labels, per-series ANSI colour, caption and legend.
//! Not byte-identical to the Go library (chart fidelity is "visual" per the
//! rewrite decision), but uses the same glyphs, palette and layout.

const std = @import("std");

const Glyph = enum {
    blank,
    start, // ┼
    horiz, // ─
    vert, // │
    up_corner, // ╭
    down_corner, // ╮
    up_elbow, // ╰
    down_elbow, // ╯
    tick, // ┤

    fn str(g: Glyph) []const u8 {
        return switch (g) {
            .blank => " ",
            .start => "┼",
            .horiz => "─",
            .vert => "│",
            .up_corner => "╭",
            .down_corner => "╮",
            .up_elbow => "╰",
            .down_elbow => "╯",
            .tick => "┤",
        };
    }
};

const Cell = struct { glyph: Glyph = .blank, color: u8 = 0 };

/// 8-bit ANSI colours approximating asciigraph's palette, in the same order as
/// the Go reporter's chartPalette.
pub const palette = [_]u8{ 1, 2, 4, 3, 6, 5, 214, 93, 48, 33, 198, 220 };

fn isFinite(v: f64) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

fn appendColored(out: *std.ArrayList(u8), gpa: std.mem.Allocator, color: u8, glyph: Glyph) !void {
    if (color == 0) {
        try out.appendSlice(gpa, glyph.str());
        return;
    }
    var buf: [16]u8 = undefined;
    const pre = std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{color}) catch unreachable;
    try out.appendSlice(gpa, pre);
    try out.appendSlice(gpa, glyph.str());
    try out.appendSlice(gpa, "\x1b[0m");
}

/// Render a multi-series plot. `series` rows may differ in length and contain
/// NaN (gaps). Returns an owned string with embedded ANSI colour.
pub fn plotMany(
    gpa: std.mem.Allocator,
    series: []const []const f64,
    labels: []const []const u8,
    height: usize,
    caption: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var cols: usize = 0;
    for (series) |s| cols = @max(cols, s.len);
    const rows = @max(height, 3);

    // Global min/max over finite values.
    var min: f64 = std.math.floatMax(f64);
    var max: f64 = -std.math.floatMax(f64);
    var any = false;
    for (series) |s| for (s) |v| {
        if (!isFinite(v)) continue;
        any = true;
        if (v < min) min = v;
        if (v > max) max = v;
    };
    if (!any or cols == 0) {
        try out.appendSlice(gpa, caption);
        try out.append(gpa, '\n');
        return out.toOwnedSlice(gpa);
    }
    const interval = if (max == min) 1.0 else max - min;

    const grid = try gpa.alloc(Cell, rows * cols);
    defer gpa.free(grid);
    @memset(grid, .{});

    const rowOf = struct {
        fn f(v: f64, mn: f64, iv: f64, r: usize) usize {
            const t = (mn + iv - v) / iv; // 0 at top (max), 1 at bottom (min)
            var idx: isize = @intFromFloat(@round(t * @as(f64, @floatFromInt(r - 1))));
            if (idx < 0) idx = 0;
            if (idx >= @as(isize, @intCast(r))) idx = @as(isize, @intCast(r)) - 1;
            return @intCast(idx);
        }
    }.f;

    for (series, 0..) |s, si| {
        const color = palette[si % palette.len];
        var prev_row: ?usize = null;
        for (s, 0..) |v, x| {
            if (!isFinite(v)) {
                prev_row = null;
                continue;
            }
            const r = rowOf(v, min, interval, rows);
            if (prev_row) |pr| {
                if (pr == r) {
                    set(grid, cols, r, x, .horiz, color);
                } else if (r < pr) {
                    set(grid, cols, r, x, .up_corner, color);
                    set(grid, cols, pr, x, .down_elbow, color);
                    var rr = r + 1;
                    while (rr < pr) : (rr += 1) set(grid, cols, rr, x, .vert, color);
                } else {
                    set(grid, cols, r, x, .up_elbow, color);
                    set(grid, cols, pr, x, .down_corner, color);
                    var rr = pr + 1;
                    while (rr < r) : (rr += 1) set(grid, cols, rr, x, .vert, color);
                }
            } else {
                set(grid, cols, r, x, .start, color);
            }
            prev_row = r;
        }
    }

    // Y-axis label width.
    var lbuf: [64]u8 = undefined;
    const max_lbl = std.fmt.bufPrint(&lbuf, "{d:.2}", .{max}) catch "";
    var label_width = max_lbl.len;
    {
        var b2: [64]u8 = undefined;
        const min_lbl = std.fmt.bufPrint(&b2, "{d:.2}", .{min}) catch "";
        label_width = @max(label_width, min_lbl.len);
    }

    // Rows with labels + ticks.
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const mag = max - (@as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(rows - 1))) * interval;
        var nb: [64]u8 = undefined;
        const num = std.fmt.bufPrint(&nb, "{d:.2}", .{mag}) catch "";
        var pad = label_width - num.len;
        while (pad > 0) : (pad -= 1) try out.append(gpa, ' ');
        try out.appendSlice(gpa, num);
        try out.appendSlice(gpa, Glyph.tick.str());
        var x: usize = 0;
        while (x < cols) : (x += 1) {
            const cell = grid[r * cols + x];
            try appendColored(&out, gpa, cell.color, cell.glyph);
        }
        try out.append(gpa, '\n');
    }

    // Caption, centred over the plot area.
    if (caption.len > 0) {
        const span = label_width + 1 + cols;
        var pad: usize = if (span > caption.len) (span - caption.len) / 2 else 0;
        while (pad > 0) : (pad -= 1) try out.append(gpa, ' ');
        try out.appendSlice(gpa, caption);
        try out.append(gpa, '\n');
    }

    // Legend.
    for (series, 0..) |_, si| {
        if (si >= labels.len) break;
        const color = palette[si % palette.len];
        if (si > 0) try out.append(gpa, ' ');
        var cb: [16]u8 = undefined;
        const pre = std.fmt.bufPrint(&cb, "\x1b[38;5;{d}m", .{color}) catch unreachable;
        try out.appendSlice(gpa, pre);
        try out.appendSlice(gpa, labels[si]);
        try out.appendSlice(gpa, "\x1b[0m");
    }
    try out.append(gpa, '\n');

    return out.toOwnedSlice(gpa);
}

fn set(grid: []Cell, cols: usize, r: usize, x: usize, glyph: Glyph, color: u8) void {
    grid[r * cols + x] = .{ .glyph = glyph, .color = color };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "plotMany renders a line with labels and legend" {
    const gpa = std.testing.allocator;
    const s0 = [_]f64{ 1.0, 3.0, 2.0, 5.0, 4.0 };
    const series = [_][]const f64{&s0};
    const labels = [_][]const u8{"google"};
    const out = try plotMany(gpa, &series, &labels, 6, "RTT (ms) over time");
    defer gpa.free(out);
    // Contains box-drawing glyphs, the caption, and the legend label.
    try std.testing.expect(std.mem.indexOf(u8, out, "┤") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "RTT (ms) over time") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "google") != null);
}

test "plotMany waiting state when all NaN" {
    const gpa = std.testing.allocator;
    const nan = std.math.nan(f64);
    const s0 = [_]f64{ nan, nan };
    const series = [_][]const f64{&s0};
    const labels = [_][]const u8{"x"};
    const out = try plotMany(gpa, &series, &labels, 6, "cap");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("cap\n", out);
}
