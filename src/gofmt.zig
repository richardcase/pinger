//! Go-compatible formatting primitives shared by the JSON encoders and the
//! error/report formatters: shortest-float rendering, encoding/json string
//! escaping (HTML-escaping on, matching Go's default), and %q quoting.

const std = @import("std");

/// Render f64 the way Go's strconv.AppendFloat(f, 'f', -1, 64) does: shortest
/// decimal representation that round-trips, fixed-point (never exponential).
/// `buf` must be large enough (>= 348 bytes for full-range f64 decimal).
pub fn formatGoFloat(buf: []u8, f: f64) []const u8 {
    return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = null }) catch "0";
}

/// Fixed-precision decimal matching Go's %.<n>f (correctly rounded,
/// ties-to-even, no exponent). Used by the report table.
pub fn formatFixed(buf: []u8, f: f64, precision: usize) []const u8 {
    return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = precision }) catch "0";
}

const hex = "0123456789abcdef";

/// Is this ASCII byte safe to emit unescaped under Go's default (HTML-escaping)
/// encoding/json string encoder? Printable ASCII except " \ < > &.
fn htmlSafe(b: u8) bool {
    if (b < 0x20 or b > 0x7e) return false;
    return switch (b) {
        '"', '\\', '<', '>', '&' => false,
        else => true,
    };
}

/// Append `s` as a quoted JSON string (including surrounding quotes), escaped
/// the way Go's encoding/json does by default. Bytes >= 0x80 are passed
/// through unchanged (valid UTF-8 assumed; the rare U+2028/U+2029 and invalid
/// UTF-8 handling Go performs is omitted as an accepted divergence).
pub fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |b| {
        if (b >= 0x80 or htmlSafe(b)) {
            try out.append(gpa, b);
            continue;
        }
        switch (b) {
            '\\', '"' => {
                try out.append(gpa, '\\');
                try out.append(gpa, b);
            },
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                try out.appendSlice(gpa, "\\u00");
                try out.append(gpa, hex[b >> 4]);
                try out.append(gpa, hex[b & 0xf]);
            },
        }
    }
    try out.append(gpa, '"');
}

/// Quote `s` the way Go's %q (strconv.Quote) does for typical inputs: wrap in
/// double quotes, escape " and \ and the common control chars, emit other
/// control bytes as \xHH. Printable ASCII and >=0x80 pass through.
pub fn goQuote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |b| {
        switch (b) {
            '"', '\\' => {
                try out.append(gpa, '\\');
                try out.append(gpa, b);
            },
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (b >= 0x20) {
                    try out.append(gpa, b);
                } else {
                    try out.appendSlice(gpa, "\\x");
                    try out.append(gpa, hex[b >> 4]);
                    try out.append(gpa, hex[b & 0xf]);
                }
            },
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectFloat(f: f64, want: []const u8) !void {
    var buf: [350]u8 = undefined;
    try std.testing.expectEqualStrings(want, formatGoFloat(buf[0..], f));
}

test "formatGoFloat matches Go 'f',-1" {
    try expectFloat(3.836694, "3.836694");
    try expectFloat(5.254354, "5.254354");
    try expectFloat(5.716288, "5.716288");
    try expectFloat(0, "0");
    try expectFloat(5, "5");
    try expectFloat(100, "100");
    try expectFloat(99.99, "99.99");
    try expectFloat(0.5, "0.5");
}

test "appendJsonString escapes like encoding/json" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try appendJsonString(&out, gpa, "google");
    try std.testing.expectEqualStrings("\"google\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(&out, gpa, "a\"b\\c");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(&out, gpa, "x<y>&z");
    try std.testing.expectEqualStrings("\"x\\u003cy\\u003e\\u0026z\"", out.items);
}

test "goQuote like %q" {
    const gpa = std.testing.allocator;
    const a = try goQuote(gpa, "5q");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("\"5q\"", a);

    const b = try goQuote(gpa, "-5s");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("\"-5s\"", b);
}
