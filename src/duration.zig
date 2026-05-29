//! Go-compatible duration string parsing and formatting.
//! Ports time.ParseDuration and Duration.String() from the Go standard library
//! so config/CLI duration handling matches the original tool byte-for-byte.

const std = @import("std");
const gofmt = @import("gofmt.zig");

pub const nanosecond: i64 = 1;
pub const microsecond: i64 = 1000 * nanosecond;
pub const millisecond: i64 = 1000 * microsecond;
pub const second: i64 = 1000 * millisecond;
pub const minute: i64 = 60 * second;
pub const hour: i64 = 60 * minute;

/// Result of parsing a Go duration string. Mirrors the failure categories of
/// time.ParseDuration so callers can reproduce the exact error text.
pub const ParseResult = union(enum) {
    ok: i64,
    /// time: invalid duration "<orig>"
    invalid,
    /// time: missing unit in duration "<orig>"
    missing_unit,
    /// time: unknown unit "<slice>" in duration "<orig>"
    unknown_unit: []const u8,
};

fn unitValue(u: []const u8) ?i64 {
    if (std.mem.eql(u8, u, "ns")) return nanosecond;
    if (std.mem.eql(u8, u, "us")) return microsecond;
    if (std.mem.eql(u8, u, "\xc2\xb5s")) return microsecond; // µs  U+00B5
    if (std.mem.eql(u8, u, "\xce\xbcs")) return microsecond; // μs  U+03BC
    if (std.mem.eql(u8, u, "ms")) return millisecond;
    if (std.mem.eql(u8, u, "s")) return second;
    if (std.mem.eql(u8, u, "m")) return minute;
    if (std.mem.eql(u8, u, "h")) return hour;
    return null;
}

const max_i64: u64 = 1 << 63; // 1<<63 ; Duration max magnitude check threshold

/// Parse leading [0-9]* as u64, returning value and remaining slice.
/// Returns null on overflow (Go's errLeadingInt -> "invalid duration").
fn leadingInt(s: []const u8) ?struct { v: u64, rem: []const u8 } {
    var x: u64 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') break;
        if (x > max_i64 / 10) return null; // overflow
        x = x * 10 + (c - '0');
        if (x > max_i64) return null; // overflow
    }
    return .{ .v = x, .rem = s[i..] };
}

/// Parse leading fraction digits. Returns the integer value of the digits,
/// the scale (10^ndigits), and the remaining slice. Ignores overflow digits
/// the same way Go does (stops accumulating but keeps consuming).
fn leadingFraction(s: []const u8) struct { x: u64, scale: f64, rem: []const u8 } {
    var i: usize = 0;
    var x: u64 = 0;
    var scale: f64 = 1;
    var overflow = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') break;
        if (overflow) continue;
        if (x > max_i64 / 10) {
            // It's possible for overflow to give a positive but incorrect
            // answer; Go discards extra digits here.
            overflow = true;
            continue;
        }
        const y = x * 10 + (c - '0');
        if (y > max_i64) {
            overflow = true;
            continue;
        }
        x = y;
        scale *= 10;
    }
    return .{ .x = x, .scale = scale, .rem = s[i..] };
}

/// Parse a Go duration string into nanoseconds.
pub fn parse(orig: []const u8) ParseResult {
    var s = orig;
    var d: u64 = 0;
    var neg = false;

    if (s.len > 0) {
        const c = s[0];
        if (c == '-' or c == '+') {
            neg = c == '-';
            s = s[1..];
        }
    }
    // Special case: "0".
    if (std.mem.eql(u8, s, "0")) return .{ .ok = 0 };
    if (s.len == 0) return .invalid;

    while (s.len > 0) {
        var v: u64 = 0;
        var f: u64 = 0;
        var scale: f64 = 1;

        // The next character must be [0-9.]
        if (!(s[0] == '.' or (s[0] >= '0' and s[0] <= '9'))) return .invalid;

        const pl = s.len;
        const li = leadingInt(s) orelse return .invalid;
        v = li.v;
        s = li.rem;
        const pre = pl != s.len;

        var post = false;
        if (s.len > 0 and s[0] == '.') {
            s = s[1..];
            const pl2 = s.len;
            const lf = leadingFraction(s);
            f = lf.x;
            scale = lf.scale;
            s = lf.rem;
            post = pl2 != s.len;
        }
        if (!pre and !post) return .invalid;

        // Consume unit.
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.' or (c >= '0' and c <= '9')) break;
        }
        if (i == 0) return .missing_unit;
        const u = s[0..i];
        s = s[i..];
        const unit = unitValue(u) orelse return .{ .unknown_unit = u };
        const unit_u: u64 = @intCast(unit);

        if (v > max_i64 / unit_u) return .invalid; // overflow
        v *= unit_u;
        if (f > 0) {
            // float64 keeps nanosecond accuracy for fractions.
            const add: u64 = @intFromFloat(@as(f64, @floatFromInt(f)) * (@as(f64, @floatFromInt(unit_u)) / scale));
            v += add;
            if (v > max_i64) return .invalid;
        }
        d += v;
        if (d > max_i64) return .invalid;
    }

    if (neg) return .{ .ok = -@as(i64, @intCast(d)) };
    if (d > max_i64 - 1) return .invalid;
    return .{ .ok = @intCast(d) };
}

/// Build the inner "time: ..." text Go's ParseDuration returns for a failure,
/// for wrapping in higher-level error messages.
pub fn goErrorText(gpa: std.mem.Allocator, orig: []const u8, r: ParseResult) ![]u8 {
    return switch (r) {
        .ok => unreachable,
        .invalid => blk: {
            const q = try gofmt.goQuote(gpa, orig);
            defer gpa.free(q);
            break :blk std.fmt.allocPrint(gpa, "time: invalid duration {s}", .{q});
        },
        .missing_unit => blk: {
            const q = try gofmt.goQuote(gpa, orig);
            defer gpa.free(q);
            break :blk std.fmt.allocPrint(gpa, "time: missing unit in duration {s}", .{q});
        },
        .unknown_unit => |u| blk: {
            const qu = try gofmt.goQuote(gpa, u);
            defer gpa.free(qu);
            const qo = try gofmt.goQuote(gpa, orig);
            defer gpa.free(qo);
            break :blk std.fmt.allocPrint(gpa, "time: unknown unit {s} in duration {s}", .{ qu, qo });
        },
    };
}

/// Format nanoseconds the way Go's Duration.String() does.
/// Writes into `buf` (must be >= 32 bytes) and returns the used slice.
pub fn toString(buf: *[32]u8, ns: i64) []const u8 {
    var w: usize = buf.len;
    const neg = ns < 0;
    var u: u64 = if (neg) @intCast(-ns) else @intCast(ns);

    if (u < @as(u64, @intCast(second))) {
        // Sub-second: use ns, µs, or ms.
        var prec: usize = 0;
        w -= 1;
        buf[w] = 's';
        if (u == 0) return "0s";
        if (u < @as(u64, @intCast(microsecond))) {
            prec = 0;
            w -= 1;
            buf[w] = 'n';
        } else if (u < @as(u64, @intCast(millisecond))) {
            prec = 3;
            // Prepend "µ" (U+00B5 = 0xC2 0xB5) before the 's'.
            w -= 1;
            buf[w] = 0xb5;
            w -= 1;
            buf[w] = 0xc2;
        } else {
            prec = 6;
            w -= 1;
            buf[w] = 'm';
        }
        const r1 = fmtFrac(buf[0..w], u, prec);
        w = r1.w;
        u = r1.v;
        w = fmtInt(buf[0..w], u);
    } else {
        w -= 1;
        buf[w] = 's';
        const r1 = fmtFrac(buf[0..w], u, 9);
        w = r1.w;
        u = r1.v;
        // u is now integer seconds.
        w = fmtInt(buf[0..w], u % 60);
        u /= 60;
        if (u > 0) {
            w -= 1;
            buf[w] = 'm';
            w = fmtInt(buf[0..w], u % 60);
            u /= 60;
            if (u > 0) {
                w -= 1;
                buf[w] = 'h';
                w = fmtInt(buf[0..w], u);
            }
        }
    }

    if (neg) {
        w -= 1;
        buf[w] = '-';
    }
    return buf[w..];
}

/// Write the fractional part of v/10**prec into the tail of buf ending at w.
/// Trims trailing zeros and drops the decimal point if nothing remains.
/// Returns the new write index and the remaining integer value (v / 10**prec).
fn fmtFrac(buf: []u8, v_in: u64, prec: usize) struct { w: usize, v: u64 } {
    var w = buf.len;
    var v = v_in;
    var print = false;
    var i: usize = 0;
    while (i < prec) : (i += 1) {
        const digit = v % 10;
        print = print or digit != 0;
        if (print) {
            w -= 1;
            buf[w] = @intCast('0' + digit);
        }
        v /= 10;
    }
    if (print) {
        w -= 1;
        buf[w] = '.';
    }
    return .{ .w = w, .v = v };
}

/// Write the integer v into the tail of buf ending at w. Returns new index.
fn fmtInt(buf: []u8, v_in: u64) usize {
    var w = buf.len;
    var v = v_in;
    if (v == 0) {
        w -= 1;
        buf[w] = '0';
    } else {
        while (v > 0) {
            w -= 1;
            buf[w] = @intCast('0' + (v % 10));
            v /= 10;
        }
    }
    return w;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectParse(s: []const u8, ns: i64) !void {
    switch (parse(s)) {
        .ok => |v| try std.testing.expectEqual(ns, v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse basic units" {
    try expectParse("30s", 30 * second);
    try expectParse("5m", 5 * minute);
    try expectParse("1h", hour);
    try expectParse("1h30m", hour + 30 * minute);
    try expectParse("500ms", 500 * millisecond);
    try expectParse("1.5s", second + 500 * millisecond);
    try expectParse("0", 0);
    try expectParse("-2h", -2 * hour);
    try expectParse("100ns", 100);
    try expectParse("300us", 300 * microsecond);
    try expectParse("300\xc2\xb5s", 300 * microsecond); // µs
    try expectParse("300\xce\xbcs", 300 * microsecond); // μs
    try expectParse("1h30m10s", hour + 30 * minute + 10 * second);
}

test "parse errors" {
    try std.testing.expect(parse("") == .invalid);
    try std.testing.expect(parse("abc") == .invalid);
    try std.testing.expect(parse("5") == .missing_unit);
    switch (parse("5q")) {
        .unknown_unit => |u| try std.testing.expectEqualStrings("q", u),
        else => return error.TestUnexpectedResult,
    }
}

fn expectString(ns: i64, want: []const u8) !void {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(want, toString(&buf, ns));
}

test "toString matches Go Duration.String" {
    try expectString(0, "0s");
    try expectString(second, "1s");
    try expectString(-5 * second, "-5s");
    try expectString(90 * second, "1m30s");
    try expectString(3600 * second, "1h0m0s");
    try expectString(second + 500 * millisecond, "1.5s");
    try expectString(500 * millisecond, "500ms");
    try expectString(300 * microsecond, "300\xc2\xb5s"); // 300µs
    try expectString(100, "100ns");
    try expectString(hour + 30 * minute, "1h30m0s");
    try expectString(60 * second, "1m0s");
    try expectString(1500 * microsecond, "1.5ms");
}
