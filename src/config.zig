//! TOML config loading and validation, mirroring internal/config of the Go
//! tool. Durations are read as raw strings and parsed with duration.zig so the
//! behaviour and error messages match Go's time.ParseDuration + viper defaults.

const std = @import("std");
const toml = @import("toml");
const duration = @import("duration.zig");
const gofmt = @import("gofmt.zig");

pub const Target = struct {
    label: []const u8,
    address: []const u8,
    timeout_ns: ?i64 = null,
};

pub const Config = struct {
    interval_ns: i64,
    timeout_ns: i64,
    data_dir: []const u8,
    targets: []Target,

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        for (self.targets) |t| {
            gpa.free(t.label);
            gpa.free(t.address);
        }
        gpa.free(self.targets);
        gpa.free(self.data_dir);
    }
};

pub const Error = error{Invalid} || std.mem.Allocator.Error;

// All-optional mirror of the TOML schema so missing-field handling and error
// text are decided here rather than by the TOML library.
const RawTarget = struct {
    label: ?[]const u8 = null,
    address: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
};

const RawConfig = struct {
    interval: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    targets: ?[]const RawTarget = null,
};

fn setMsg(msg: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    msg.clearRetainingCapacity();
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try msg.appendSlice(gpa, s);
}

const durationErrText = duration.goErrorText;

/// Parse a config duration field, formatting the Go error message on failure.
fn parseDurationField(
    gpa: std.mem.Allocator,
    msg: *std.ArrayList(u8),
    field: []const u8,
    str: []const u8,
) Error!i64 {
    const r = duration.parse(str);
    switch (r) {
        .ok => |ns| return ns,
        else => {
            const q = try gofmt.goQuote(gpa, str);
            defer gpa.free(q);
            const inner = try durationErrText(gpa, str, r);
            defer gpa.free(inner);
            try setMsg(msg, gpa, "error: config field '{s}' {s} is not a valid duration: {s}.", .{ field, q, inner });
            return error.Invalid;
        },
    }
}

fn fromParsed(gpa: std.mem.Allocator, raw: RawConfig, msg: *std.ArrayList(u8)) Error!Config {
    // interval (required)
    const interval_str = raw.interval orelse "";
    if (interval_str.len == 0) {
        try setMsg(msg, gpa, "error: config missing required field 'interval'. Add interval = \"30s\" to your config.", .{});
        return error.Invalid;
    }
    const interval_ns = try parseDurationField(gpa, msg, "interval", interval_str);

    // timeout (default "5s")
    const timeout_str = raw.timeout orelse "5s";
    const timeout_ns = try parseDurationField(gpa, msg, "timeout", timeout_str);

    // data_dir (default ".")
    const data_dir_src = raw.data_dir orelse ".";

    // targets (required, at least one entry)
    const raw_targets = raw.targets orelse &[_]RawTarget{};
    if (raw_targets.len == 0) {
        try setMsg(msg, gpa, "error: config missing required field 'targets'. Add at least one [[targets]] entry.", .{});
        return error.Invalid;
    }

    var targets = try gpa.alloc(Target, raw_targets.len);
    var built: usize = 0;
    errdefer {
        for (targets[0..built]) |t| {
            gpa.free(t.label);
            gpa.free(t.address);
        }
        gpa.free(targets);
    }

    for (raw_targets, 0..) |rt, i| {
        var to: ?i64 = null;
        if (rt.timeout) |ts| {
            if (ts.len != 0) {
                const r = duration.parse(ts);
                switch (r) {
                    .ok => |ns| to = ns,
                    else => {
                        const q = try gofmt.goQuote(gpa, ts);
                        defer gpa.free(q);
                        const inner = try durationErrText(gpa, ts, r);
                        defer gpa.free(inner);
                        try setMsg(msg, gpa, "error: target {d} 'timeout' {s} is not a valid duration: {s}.", .{ i, q, inner });
                        return error.Invalid;
                    },
                }
            }
        }
        const label = try gpa.dupe(u8, rt.label orelse "");
        errdefer gpa.free(label);
        const address = try gpa.dupe(u8, rt.address orelse "");
        targets[i] = .{ .label = label, .address = address, .timeout_ns = to };
        built += 1;
    }

    const data_dir = try gpa.dupe(u8, data_dir_src);
    return .{
        .interval_ns = interval_ns,
        .timeout_ns = timeout_ns,
        .data_dir = data_dir,
        .targets = targets,
    };
}

/// Parse config from an in-memory TOML string (used by tests).
pub fn loadString(gpa: std.mem.Allocator, content: []const u8, msg: *std.ArrayList(u8)) Error!Config {
    var parser = toml.Parser(RawConfig).init(gpa);
    defer parser.deinit();
    var parsed = parser.parseString(content) catch {
        try setMsg(msg, gpa, "error: reading config <string>: invalid TOML. Ensure the file exists and is valid TOML.", .{});
        return error.Invalid;
    };
    defer parsed.deinit();
    return fromParsed(gpa, parsed.value, msg);
}

/// Load and parse a TOML config file, applying defaults.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, msg: *std.ArrayList(u8)) Error!Config {
    var parser = toml.Parser(RawConfig).init(gpa);
    defer parser.deinit();
    var parsed = parser.parseFile(io, path) catch |err| {
        // Match Go's os.PathError wording for the common open failures; other
        // (TOML parse) errors fall back to the Zig error name.
        const reason = switch (err) {
            error.FileNotFound => try std.fmt.allocPrint(gpa, "open {s}: no such file or directory", .{path}),
            error.AccessDenied => try std.fmt.allocPrint(gpa, "open {s}: permission denied", .{path}),
            else => try std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}),
        };
        defer gpa.free(reason);
        try setMsg(msg, gpa, "error: reading config {s}: {s}. Ensure the file exists and is valid TOML.", .{ path, reason });
        return error.Invalid;
    };
    defer parsed.deinit();
    return fromParsed(gpa, parsed.value, msg);
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Validate Config constraints, producing Go-compatible error messages.
pub fn validate(gpa: std.mem.Allocator, cfg: Config, msg: *std.ArrayList(u8)) Error!void {
    var dbuf: [32]u8 = undefined;

    if (cfg.interval_ns <= 0) {
        try setMsg(msg, gpa, "error: config field 'interval' must be > 0. Got {s}.", .{duration.toString(&dbuf, cfg.interval_ns)});
        return error.Invalid;
    }
    if (cfg.timeout_ns <= 0) {
        try setMsg(msg, gpa, "error: config field 'timeout' must be > 0. Got {s}.", .{duration.toString(&dbuf, cfg.timeout_ns)});
        return error.Invalid;
    }
    if (cfg.data_dir.len == 0) {
        try setMsg(msg, gpa, "error: config field 'data_dir' must not be empty.", .{});
        return error.Invalid;
    }
    if (cfg.targets.len == 0) {
        try setMsg(msg, gpa, "error: config must have at least 1 target.", .{});
        return error.Invalid;
    }
    if (cfg.targets.len > 10) {
        try setMsg(msg, gpa, "error: config has {d} targets; maximum is 10. Remove {d} target(s).", .{ cfg.targets.len, cfg.targets.len - 10 });
        return error.Invalid;
    }

    for (cfg.targets, 0..) |t, i| {
        if (trimmed(t.label).len == 0) {
            try setMsg(msg, gpa, "error: target {d} has empty label. Every target must have a unique non-empty label.", .{i});
            return error.Invalid;
        }
        // Duplicate label check (exact match against earlier entries).
        for (cfg.targets[0..i]) |p| {
            if (std.mem.eql(u8, p.label, t.label)) {
                const q = try gofmt.goQuote(gpa, t.label);
                defer gpa.free(q);
                try setMsg(msg, gpa, "error: duplicate target label {s}. Labels must be unique.", .{q});
                return error.Invalid;
            }
        }
        if (trimmed(t.address).len == 0) {
            const q = try gofmt.goQuote(gpa, t.label);
            defer gpa.free(q);
            try setMsg(msg, gpa, "error: target {s} has empty address. Provide a hostname or IP address.", .{q});
            return error.Invalid;
        }
        for (cfg.targets[0..i]) |p| {
            if (std.mem.eql(u8, p.address, t.address)) {
                const q = try gofmt.goQuote(gpa, t.address);
                defer gpa.free(q);
                try setMsg(msg, gpa, "error: duplicate target address {s}. Addresses must be unique.", .{q});
                return error.Invalid;
            }
        }
        if (t.timeout_ns) |to| {
            if (to <= 0) {
                const q = try gofmt.goQuote(gpa, t.label);
                defer gpa.free(q);
                try setMsg(msg, gpa, "error: target {s} timeout must be > 0. Got {s}.", .{ q, duration.toString(&dbuf, to) });
                return error.Invalid;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "loadString applies defaults and parses durations" {
    const gpa = std.testing.allocator;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);

    const content =
        \\interval = "30s"
        \\[[targets]]
        \\label = "google"
        \\address = "8.8.8.8"
        \\
    ;
    var cfg = try loadString(gpa, content, &msg);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(i64, 30 * duration.second), cfg.interval_ns);
    try std.testing.expectEqual(@as(i64, 5 * duration.second), cfg.timeout_ns); // default
    try std.testing.expectEqualStrings(".", cfg.data_dir); // default
    try std.testing.expectEqual(@as(usize, 1), cfg.targets.len);
    try std.testing.expectEqualStrings("google", cfg.targets[0].label);
    try std.testing.expectEqualStrings("8.8.8.8", cfg.targets[0].address);
    try std.testing.expect(cfg.targets[0].timeout_ns == null);
}

test "loadString per-target timeout + overrides" {
    const gpa = std.testing.allocator;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);

    const content =
        \\interval = "10s"
        \\timeout = "2s"
        \\data_dir = "/var/lib/pinger"
        \\[[targets]]
        \\label = "a"
        \\address = "1.1.1.1"
        \\timeout = "10s"
        \\[[targets]]
        \\label = "b"
        \\address = "2.2.2.2"
        \\
    ;
    var cfg = try loadString(gpa, content, &msg);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(i64, 2 * duration.second), cfg.timeout_ns);
    try std.testing.expectEqualStrings("/var/lib/pinger", cfg.data_dir);
    try std.testing.expectEqual(@as(i64, 10 * duration.second), cfg.targets[0].timeout_ns.?);
    try std.testing.expect(cfg.targets[1].timeout_ns == null);
}

fn expectLoadErr(content: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try std.testing.expectError(error.Invalid, loadString(gpa, content, &msg));
    try std.testing.expectEqualStrings(want, msg.items);
}

test "loadString error messages match Go" {
    try expectLoadErr(
        \\[[targets]]
        \\label = "a"
        \\address = "1.1.1.1"
        \\
    , "error: config missing required field 'interval'. Add interval = \"30s\" to your config.");

    try expectLoadErr(
        \\interval = "30q"
        \\[[targets]]
        \\label = "a"
        \\address = "1.1.1.1"
        \\
    , "error: config field 'interval' \"30q\" is not a valid duration: time: unknown unit \"q\" in duration \"30q\".");

    try expectLoadErr(
        \\interval = "30s"
        \\
    , "error: config missing required field 'targets'. Add at least one [[targets]] entry.");
}

fn expectValidateErr(cfg: Config, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try std.testing.expectError(error.Invalid, validate(gpa, cfg, &msg));
    try std.testing.expectEqualStrings(want, msg.items);
}

test "validate constraints match Go" {
    const gpa = std.testing.allocator;
    {
        var t = [_]Target{.{ .label = "a", .address = "1.1.1.1" }};
        try expectValidateErr(.{ .interval_ns = 0, .timeout_ns = duration.second, .data_dir = ".", .targets = &t }, "error: config field 'interval' must be > 0. Got 0s.");
    }
    {
        var t = [_]Target{
            .{ .label = "dup", .address = "1.1.1.1" },
            .{ .label = "dup", .address = "2.2.2.2" },
        };
        try expectValidateErr(.{ .interval_ns = duration.second, .timeout_ns = duration.second, .data_dir = ".", .targets = &t }, "error: duplicate target label \"dup\". Labels must be unique.");
    }
    {
        var t = [_]Target{.{ .label = "a", .address = "1.1.1.1", .timeout_ns = -duration.second }};
        try expectValidateErr(.{ .interval_ns = duration.second, .timeout_ns = duration.second, .data_dir = ".", .targets = &t }, "error: target \"a\" timeout must be > 0. Got -1s.");
    }
    _ = gpa;
}
