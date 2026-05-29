//! RFC3339 / RFC3339Nano formatting and parsing matching Go's time package,
//! including the ".999999999" trailing-zero-trimmed fractional behaviour used
//! when Go marshals time.Time to JSON.

const std = @import("std");

pub const Time = struct {
    /// Seconds since the Unix epoch (UTC).
    secs: i64,
    /// Nanoseconds within the second, [0, 1_000_000_000).
    nanos: u32 = 0,
};

pub const ParseError = error{Invalid};

/// Chronological ordering of two times (compares seconds then nanoseconds).
pub fn lessThan(a: Time, b: Time) bool {
    if (a.secs != b.secs) return a.secs < b.secs;
    return a.nanos < b.nanos;
}

const Civil = struct { y: i64, m: u32, d: u32 };

/// Howard Hinnant's days_from_civil. Returns days since 1970-01-01.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, @intFromBool(m <= 2));
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Howard Hinnant's civil_from_days. `z` is days since 1970-01-01.
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = mp + (if (mp < 10) @as(i64, 3) else -9); // [1, 12]
    return .{ .y = y + @as(i64, @intFromBool(m <= 2)), .m = @intCast(m), .d = @intCast(d) };
}

/// Construct a Time from a UTC civil date/time.
pub fn fromCivil(y: i64, mo: u32, d: u32, h: u32, mi: u32, s: u32) Time {
    const days = daysFromCivil(y, @intCast(mo), @intCast(d));
    return .{ .secs = days * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, s), .nanos = 0 };
}

const Broken = struct { y: i64, mo: u32, d: u32, h: u32, mi: u32, s: u32 };

fn breakDown(secs: i64) Broken {
    const days = @divFloor(secs, 86400);
    const sod: i64 = secs - days * 86400; // [0, 86399]
    const c = civilFromDays(days);
    return .{
        .y = c.y,
        .mo = c.m,
        .d = c.d,
        .h = @intCast(@divTrunc(sod, 3600)),
        .mi = @intCast(@divTrunc(@mod(sod, 3600), 60)),
        .s = @intCast(@mod(sod, 60)),
    };
}

fn writePad4(buf: []u8, i: *usize, v: i64) void {
    // Year, zero-padded to at least 4 digits.
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    if (s.len < 4) {
        var pad: usize = 4 - s.len;
        while (pad > 0) : (pad -= 1) {
            buf[i.*] = '0';
            i.* += 1;
        }
    }
    @memcpy(buf[i.*..][0..s.len], s);
    i.* += s.len;
}

fn writePad2(buf: []u8, i: *usize, v: u32) void {
    buf[i.*] = @intCast('0' + (v / 10));
    buf[i.* + 1] = @intCast('0' + (v % 10));
    i.* += 2;
}

fn writeDate(buf: []u8, i: *usize, b: Broken) void {
    writePad4(buf, i, b.y);
    buf[i.*] = '-';
    i.* += 1;
    writePad2(buf, i, b.mo);
    buf[i.*] = '-';
    i.* += 1;
    writePad2(buf, i, b.d);
}

fn writeClock(buf: []u8, i: *usize, b: Broken) void {
    writePad2(buf, i, b.h);
    buf[i.*] = ':';
    i.* += 1;
    writePad2(buf, i, b.mi);
    buf[i.*] = ':';
    i.* += 1;
    writePad2(buf, i, b.s);
}

/// Append the ".fffffffff" fractional part (trailing zeros trimmed, dot
/// omitted when zero). Matches Go's ".999999999" verb.
fn writeFrac(buf: []u8, i: *usize, nanos: u32) void {
    if (nanos == 0) return;
    var digits: [9]u8 = undefined;
    var n = nanos;
    var k: usize = 9;
    while (k > 0) {
        k -= 1;
        digits[k] = @intCast('0' + (n % 10));
        n /= 10;
    }
    // Trim trailing zeros.
    var len: usize = 9;
    while (len > 0 and digits[len - 1] == '0') len -= 1;
    buf[i.*] = '.';
    i.* += 1;
    @memcpy(buf[i.*..][0..len], digits[0..len]);
    i.* += len;
}

/// "2006-01-02T15:04:05.999999999Z07:00" with UTC zone (Z), trailing-zero
/// trimmed fraction. This is Go's time.RFC3339Nano for UTC times.
pub fn formatRFC3339Nano(buf: []u8, t: Time) []const u8 {
    const b = breakDown(t.secs);
    var i: usize = 0;
    writeDate(buf, &i, b);
    buf[i] = 'T';
    i += 1;
    writeClock(buf, &i, b);
    writeFrac(buf, &i, t.nanos);
    buf[i] = 'Z';
    i += 1;
    return buf[0..i];
}

/// "2006-01-02T15:04:05Z07:00" with UTC zone, no fraction (Go time.RFC3339).
pub fn formatRFC3339(buf: []u8, secs: i64) []const u8 {
    const b = breakDown(secs);
    var i: usize = 0;
    writeDate(buf, &i, b);
    buf[i] = 'T';
    i += 1;
    writeClock(buf, &i, b);
    buf[i] = 'Z';
    i += 1;
    return buf[0..i];
}

/// "2006-01-02 15:04:05Z" — the report table period format.
pub fn formatTablePeriod(buf: []u8, secs: i64) []const u8 {
    const b = breakDown(secs);
    var i: usize = 0;
    writeDate(buf, &i, b);
    buf[i] = ' ';
    i += 1;
    writeClock(buf, &i, b);
    buf[i] = 'Z';
    i += 1;
    return buf[0..i];
}

/// "2006-01-02" — daily JSONL filename date component.
pub fn formatDay(buf: []u8, secs: i64) []const u8 {
    const b = breakDown(secs);
    var i: usize = 0;
    writeDate(buf, &i, b);
    return buf[0..i];
}

fn parseUint(comptime T: type, s: []const u8) ParseError!T {
    if (s.len == 0) return error.Invalid;
    var v: T = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.Invalid;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Parse an RFC3339 / RFC3339Nano timestamp. Accepts 'Z' or a ±HH:MM offset
/// and an optional fractional second of 1..9 digits.
pub fn parse(s: []const u8) ParseError!Time {
    // Minimum: "2006-01-02T15:04:05Z" = 20 chars.
    if (s.len < 20) return error.Invalid;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return error.Invalid;

    const year = try parseUint(i64, s[0..4]);
    const mon = try parseUint(u32, s[5..7]);
    const day = try parseUint(u32, s[8..10]);
    const hour = try parseUint(u32, s[11..13]);
    const min = try parseUint(u32, s[14..16]);
    const sec = try parseUint(u32, s[17..19]);
    if (mon < 1 or mon > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 60) return error.Invalid;

    var i: usize = 19;
    var nanos: u32 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        const ndig = i - start;
        if (ndig == 0 or ndig > 9) return error.Invalid;
        var frac = try parseUint(u32, s[start..i]);
        var scale: u32 = 9 - @as(u32, @intCast(ndig));
        while (scale > 0) : (scale -= 1) frac *= 10;
        nanos = frac;
    }

    // Zone.
    var offset_secs: i64 = 0;
    if (i >= s.len) return error.Invalid;
    const z = s[i];
    if (z == 'Z' or z == 'z') {
        i += 1;
    } else if (z == '+' or z == '-') {
        // ±HH:MM
        if (i + 6 > s.len or s[i + 3] != ':') return error.Invalid;
        const oh = try parseUint(i64, s[i + 1 .. i + 3]);
        const om = try parseUint(i64, s[i + 4 .. i + 6]);
        offset_secs = (oh * 3600 + om * 60) * (if (z == '-') @as(i64, -1) else 1);
        i += 6;
    } else return error.Invalid;
    if (i != s.len) return error.Invalid;

    const days = daysFromCivil(year, mon, day);
    const secs = days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec) - offset_secs;
    return .{ .secs = secs, .nanos = nanos };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectNano(t: Time, want: []const u8) !void {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings(want, formatRFC3339Nano(buf[0..], t));
}

test "formatRFC3339Nano epoch and fractions" {
    try expectNano(.{ .secs = 0, .nanos = 0 }, "1970-01-01T00:00:00Z");
    try expectNano(.{ .secs = 0, .nanos = 500000000 }, "1970-01-01T00:00:00.5Z");
    try expectNano(.{ .secs = 0, .nanos = 883747887 }, "1970-01-01T00:00:00.883747887Z");
    try expectNano(.{ .secs = 0, .nanos = 884411370 }, "1970-01-01T00:00:00.88441137Z");
    try expectNano(.{ .secs = 0, .nanos = 1000 }, "1970-01-01T00:00:00.000001Z");
}

test "round-trip real timestamp" {
    const s = "2026-05-28T09:30:38.883747887Z";
    const t = try parse(s);
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings(s, formatRFC3339Nano(buf[0..], t));
}

test "format variants" {
    const t = try parse("2026-05-28T09:30:38Z");
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2026-05-28T09:30:38Z", formatRFC3339(buf[0..], t.secs));
    try std.testing.expectEqualStrings("2026-05-28 09:30:38Z", formatTablePeriod(buf[0..], t.secs));
    try std.testing.expectEqualStrings("2026-05-28", formatDay(buf[0..], t.secs));
}

test "parse with offset normalises to UTC" {
    const a = try parse("2026-05-28T10:30:38+01:00");
    const b = try parse("2026-05-28T09:30:38Z");
    try std.testing.expectEqual(b.secs, a.secs);
}

test "parse rejects malformed" {
    try std.testing.expectError(error.Invalid, parse("2026-05-28"));
    try std.testing.expectError(error.Invalid, parse("not-a-time-at-all!"));
    try std.testing.expectError(error.Invalid, parse("2026/05/28T09:30:38Z"));
}
