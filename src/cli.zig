const std = @import("std");
const build_options = @import("build_options");
const sys = @import("sys.zig");
const config = @import("config.zig");
const rfc3339 = @import("rfc3339.zig");
const gofmt = @import("gofmt.zig");
const reader = @import("store/reader.zig");
const summary = @import("report/summary.zig");
const report = @import("report/format.zig");
const duration = @import("duration.zig");
const monitor = @import("monitor/monitor.zig");
const reporterm = @import("monitor/reporter.zig");

pub const default_config_path = "./pinger.toml";

/// Reported is returned after a user-facing message has already been printed to
/// stderr. Mirrors Go's pattern where main prints err.Error() and exits 1.
pub const CliError = error{Reported};

const root_help =
    "Periodic ICMP ping monitor\n" ++
    "\n" ++
    "Usage:\n" ++
    "  pinger [command]\n" ++
    "\n" ++
    "Available Commands:\n" ++
    "  completion  Generate the autocompletion script for the specified shell\n" ++
    "  help        Help about any command\n" ++
    "  monitor     Probe configured targets at interval and append results to daily JSONL files\n" ++
    "  report      Print connectivity history for a target\n" ++
    "  version     Print version\n" ++
    "\n" ++
    "Flags:\n" ++
    "      --config string   config file path (default \"./pinger.toml\")\n" ++
    "  -h, --help            help for pinger\n" ++
    "\n" ++
    "Use \"pinger [command] --help\" for more information about a command.\n";

const report_usage =
    "Usage:\n" ++
    "  pinger report [flags]\n" ++
    "\n" ++
    "Flags:\n" ++
    "      --from string     start time filter (RFC3339)\n" ++
    "  -h, --help            help for report\n" ++
    "      --json            emit report as JSON\n" ++
    "      --target string   target label to report on (required)\n" ++
    "      --to string       end time filter (RFC3339)\n" ++
    "\n" ++
    "Global Flags:\n" ++
    "      --config string   config file path (default \"./pinger.toml\")\n" ++
    "\n";

pub fn run(init: std.process.Init) u8 {
    const gpa = init.gpa;

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var it = init.minimal.args.iterate();
    while (it.next()) |a| {
        list.append(gpa, a) catch {
            sys.writeAll(sys.stderr_fd, "error: out of memory\n");
            return 1;
        };
    }
    const args = list.items;

    dispatch(init, args) catch |err| switch (err) {
        error.Reported => return 1,
        else => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error: unknown\n";
            sys.writeAll(sys.stderr_fd, msg);
            return 1;
        },
    };
    return 0;
}

fn dispatch(init: std.process.Init, args: []const []const u8) !void {
    var config_path: []const u8 = default_config_path;

    var cmd_index: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (isCommand(args[i])) {
            cmd_index = i;
            break;
        }
    }

    if (cmd_index == null) {
        sys.writeAll(sys.stdout_fd, root_help);
        return;
    }

    const ci = cmd_index.?;
    const cmd = args[ci];

    const gpa = init.gpa;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    var j: usize = 1;
    while (j < args.len) : (j += 1) {
        if (j == ci) continue;
        try rest.append(gpa, args[j]);
    }

    if (std.mem.eql(u8, cmd, "version")) {
        var out: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&out, "{s}\n", .{build_options.version}) catch "dev\n";
        sys.writeAll(sys.stdout_fd, line);
    } else if (std.mem.eql(u8, cmd, "monitor")) {
        try cmdMonitor(init, rest.items, &config_path);
    } else if (std.mem.eql(u8, cmd, "report")) {
        try cmdReport(init, rest.items, &config_path);
    }
}

fn isCommand(a: []const u8) bool {
    return std.mem.eql(u8, a, "monitor") or
        std.mem.eql(u8, a, "report") or
        std.mem.eql(u8, a, "version");
}

const monitor_usage =
    "Usage:\n" ++
    "  pinger monitor [flags]\n" ++
    "\n" ++
    "Flags:\n" ++
    "      --display string    terminal output mode: log or chart (default \"log\")\n" ++
    "      --duration string   run for this long then exit (e.g. 30s, 5m, 1h)\n" ++
    "  -h, --help              help for monitor\n" ++
    "      --output string     write results to this file (default: auto-named daily file in data_dir)\n" ++
    "\n" ++
    "Global Flags:\n" ++
    "      --config string   config file path (default \"./pinger.toml\")\n" ++
    "\n";

fn cmdMonitor(init: std.process.Init, flags: []const []const u8, config_path: *[]const u8) !void {
    const gpa = init.gpa;

    var display_str: []const u8 = "log";
    var duration_str: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        const a = flags[i];
        inline for (.{
            .{ "--config", config_path },
            .{ "--display", &display_str },
            .{ "--duration", &duration_str },
            .{ "--output", &output },
        }) |pair| {
            switch (take(flags, &i, a, pair[0])) {
                .value => |v| {
                    setOpt(pair[1], v);
                    break;
                },
                .missing => return cobraError(gpa, monitor_usage, "flag needs an argument: " ++ pair[0]),
                .no => {},
            }
        } else {
            if (std.mem.startsWith(u8, a, "-")) {
                return fatalCobra(gpa, monitor_usage, "unknown flag: {s}", .{flagName(a)});
            }
        }
    }

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var cfg = config.load(gpa, init.io, config_path.*, &msg) catch |e| switch (e) {
        error.Invalid => return cobraError(gpa, monitor_usage, msg.items),
        else => return e,
    };
    defer cfg.deinit(gpa);
    config.validate(gpa, cfg, &msg) catch |e| switch (e) {
        error.Invalid => return cobraError(gpa, monitor_usage, msg.items),
        else => return e,
    };

    const display: reporterm.Display = switch (reporterm.resolveDisplay(display_str, reporterm.isStdoutTty())) {
        .ok => |d| d,
        .not_tty => return cobraError(gpa, monitor_usage, "error: --display chart requires an interactive terminal. Use --display log when piping or redirecting output."),
        .invalid => |m| return cobraQuoted(gpa, monitor_usage, "error: invalid --display {s}: must be \"log\" or \"chart\".", m),
    };

    var opts = monitor.Options{ .display = display, .output_file = output };
    if (duration_str) |ds| {
        switch (duration.parse(ds)) {
            .ok => |ns| {
                if (ns <= 0) return cobraQuoted(gpa, monitor_usage, "error: --duration must be > 0. Got {s}.", ds);
                if (ns < cfg.interval_ns) {
                    var db: [32]u8 = undefined;
                    var ib: [32]u8 = undefined;
                    const warn = std.fmt.allocPrint(gpa, "warning: --duration {s} is less than interval {s}; may complete 0 cycles\n", .{
                        duration.toString(&db, ns), duration.toString(&ib, cfg.interval_ns),
                    }) catch return error.Reported;
                    defer gpa.free(warn);
                    sys.writeAll(sys.stderr_fd, warn);
                }
                opts.duration_ns = ns;
            },
            else => |r| {
                const inner = duration.goErrorText(gpa, ds, r) catch return error.Reported;
                defer gpa.free(inner);
                const q = gofmt.goQuote(gpa, ds) catch return error.Reported;
                defer gpa.free(q);
                return fatalCobra(gpa, monitor_usage, "error: invalid --duration {s}: {s}. Use a Go duration string like 30s, 5m, 1h.", .{ q, inner });
            },
        }
    }

    monitor.run(gpa, &cfg, opts, &msg) catch |e| switch (e) {
        error.Failed => return cobraError(gpa, monitor_usage, msg.items),
        else => return e,
    };
}

const Take = union(enum) {
    no,
    value: []const u8,
    missing,
};

/// Match `name` against flag token `a`, handling both "--name=value" and
/// "--name value" (consuming the next token).
fn take(flags: []const []const u8, i: *usize, a: []const u8, name: []const u8) Take {
    if (flagValue(a, name)) |v| return .{ .value = v };
    if (std.mem.eql(u8, a, name)) {
        if (i.* + 1 >= flags.len) return .missing;
        i.* += 1;
        return .{ .value = flags[i.*] };
    }
    return .no;
}

fn cmdReport(init: std.process.Init, flags: []const []const u8, config_path: *[]const u8) !void {
    const gpa = init.gpa;

    var target: ?[]const u8 = null;
    var from_str: ?[]const u8 = null;
    var to_str: ?[]const u8 = null;
    var json_output = false;

    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        const a = flags[i];
        inline for (.{
            .{ "--config", config_path },
            .{ "--target", &target },
            .{ "--from", &from_str },
            .{ "--to", &to_str },
        }) |pair| {
            switch (take(flags, &i, a, pair[0])) {
                .value => |v| {
                    setOpt(pair[1], v);
                    break;
                },
                .missing => return cobraError(gpa, report_usage, "flag needs an argument: " ++ pair[0]),
                .no => {},
            }
        } else {
            if (std.mem.eql(u8, a, "--json")) {
                json_output = true;
            } else if (std.mem.startsWith(u8, a, "-")) {
                const name = flagName(a);
                return fatalCobra(gpa, report_usage, "unknown flag: {s}", .{name});
            }
            // Non-flag positional args are ignored, as cobra does here.
        }
    }

    if (target == null or target.?.len == 0) {
        return cobraError(gpa, report_usage, "required flag(s) \"target\" not set");
    }
    const target_label = target.?;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var cfg = config.load(gpa, init.io, config_path.*, &msg) catch |e| switch (e) {
        error.Invalid => return cobraError(gpa, report_usage, msg.items),
        else => return e,
    };
    defer cfg.deinit(gpa);

    var from: ?rfc3339.Time = null;
    var to: ?rfc3339.Time = null;
    if (from_str) |fs| {
        from = rfc3339.parse(fs) catch return cobraQuoted(gpa, report_usage, "error: invalid --from {s}: not RFC3339. Example: 2026-05-27T00:00:00Z.", fs);
    }
    if (to_str) |ts| {
        to = rfc3339.parse(ts) catch return cobraQuoted(gpa, report_usage, "error: invalid --to {s}: not RFC3339. Example: 2026-05-27T23:59:59Z.", ts);
    }

    const records = reader.readResults(gpa, cfg.data_dir, target_label, from, to) catch |e| {
        return fatalCobra(gpa, report_usage, "error: reading data dir {s}: {s}.", .{ cfg.data_dir, @errorName(e) });
    };
    defer gpa.free(records);

    const rs = summary.summarise(target_label, records);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json_output) {
        try report.formatJson(&out, gpa, rs);
    } else {
        try report.formatTable(&out, gpa, rs);
    }
    sys.writeAll(sys.stdout_fd, out.items);
}

fn setOpt(slot: anytype, v: []const u8) void {
    slot.* = v;
}

fn flagValue(a: []const u8, name: []const u8) ?[]const u8 {
    if (a.len > name.len + 1 and std.mem.startsWith(u8, a, name) and a[name.len] == '=') {
        return a[name.len + 1 ..];
    }
    return null;
}

/// The flag name portion of a token, dropping any "=value" suffix.
fn flagName(a: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, a, '=')) |eq| return a[0..eq];
    return a;
}

fn fatal(fd: c_int, msg: []const u8) CliError {
    sys.writeAll(fd, msg);
    return error.Reported;
}

/// Emit a cobra-style error: `Error: <msg>` + usage block + bare `<msg>`.
fn cobraError(gpa: std.mem.Allocator, usage: []const u8, msg: []const u8) CliError {
    _ = gpa;
    sys.writeAll(sys.stderr_fd, "Error: ");
    sys.writeAll(sys.stderr_fd, msg);
    sys.writeAll(sys.stderr_fd, "\n");
    sys.writeAll(sys.stderr_fd, usage);
    sys.writeAll(sys.stderr_fd, msg);
    sys.writeAll(sys.stderr_fd, "\n");
    return error.Reported;
}

fn fatalCobra(gpa: std.mem.Allocator, usage: []const u8, comptime fmt: []const u8, args: anytype) CliError {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch {
        sys.writeAll(sys.stderr_fd, "error: out of memory\n");
        return error.Reported;
    };
    defer gpa.free(s);
    return cobraError(gpa, usage, s);
}

/// fatalCobra where the single argument is rendered Go %q-quoted.
fn cobraQuoted(gpa: std.mem.Allocator, usage: []const u8, comptime fmt: []const u8, value: []const u8) CliError {
    const q = gofmt.goQuote(gpa, value) catch {
        sys.writeAll(sys.stderr_fd, "error: out of memory\n");
        return error.Reported;
    };
    defer gpa.free(q);
    return fatalCobra(gpa, usage, fmt, .{q});
}
