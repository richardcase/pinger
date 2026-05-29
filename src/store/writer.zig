//! Appends ProbeResult records to daily JSONL files, mirroring
//! internal/store/writer.go: file named pinger-YYYY-MM-DD.jsonl (by the
//! record's UTC date), O_APPEND|O_CREAT|O_WRONLY 0644, mutex-guarded, with the
//! "output file: <path>" stderr notice on each (re)open.

const std = @import("std");
const c = std.c;
const rfc3339 = @import("../rfc3339.zig");
const record = @import("record.zig");
const sys = @import("../sys.zig");

pub const ProbeResult = record.ProbeResult;

// Writes are driven from a single thread (the monitor collects probe results
// on the main thread, mirroring Go's single collector goroutine), so no lock
// is needed — Zig 0.16's std.Io.Mutex would require threading an Io through.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    dir: []const u8,
    fixed_path: ?[]const u8,
    fd: ?c_int = null,
    file_date: [10]u8 = undefined,
    file_date_len: usize = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, dir: []const u8, fixed_path: ?[]const u8) Writer {
        return .{ .gpa = gpa, .dir = dir, .fixed_path = fixed_path };
    }

    pub fn deinit(self: *Writer) void {
        self.close();
        self.buf.deinit(self.gpa);
    }

    pub fn write(self: *Writer, r: ProbeResult) !void {
        var daybuf: [10]u8 = undefined;
        const day = rfc3339.formatDay(&daybuf, r.timestamp.secs);
        try self.ensureFile(day);

        self.buf.clearRetainingCapacity();
        try record.encode(&self.buf, self.gpa, r);
        try self.buf.append(self.gpa, '\n');

        const fd = self.fd orelse return error.NoFile;
        sys.writeAll(fd, self.buf.items);
    }

    fn ensureFile(self: *Writer, day: []const u8) !void {
        if (self.fixed_path != null and self.fd != null) return;
        if (self.fixed_path == null and self.fd != null and
            std.mem.eql(u8, self.file_date[0..self.file_date_len], day)) return;

        if (self.fd) |fd| {
            _ = c.close(fd);
            self.fd = null;
        }

        const path_z = try self.buildPath(day);
        defer self.gpa.free(path_z);

        // Mirror Go's stderr notice on (re)open.
        const notice = try std.fmt.allocPrint(self.gpa, "output file: {s}\n", .{path_z});
        defer self.gpa.free(notice);
        sys.writeAll(sys.stderr_fd, notice);

        const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
        const fd = c.open(path_z.ptr, flags, @as(c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;
        self.fd = fd;
        if (self.fixed_path == null) {
            @memcpy(self.file_date[0..day.len], day);
            self.file_date_len = day.len;
        }
    }

    /// Build the file path. Mirrors filepath.Join(dir, "pinger-<day>.jsonl")
    /// for the common cases; returns a NUL-terminated, owned slice.
    fn buildPath(self: *Writer, day: []const u8) ![:0]u8 {
        if (self.fixed_path) |fp| {
            return std.fmt.allocPrintSentinel(self.gpa, "{s}", .{fp}, 0);
        }
        if (self.dir.len == 0 or std.mem.eql(u8, self.dir, ".")) {
            return std.fmt.allocPrintSentinel(self.gpa, "pinger-{s}.jsonl", .{day}, 0);
        }
        const dir = std.mem.trimEnd(u8, self.dir, "/");
        return std.fmt.allocPrintSentinel(self.gpa, "{s}/pinger-{s}.jsonl", .{ dir, day }, 0);
    }

    pub fn close(self: *Writer) void {
        if (self.fd) |fd| {
            _ = c.close(fd);
            self.fd = null;
        }
    }
};

/// Returns null if dir exists and is writable, else an allocated Go-style
/// error message (caller frees). Mirrors store.IsWritable.
pub fn isWritable(gpa: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const probe = if (dir.len == 0 or std.mem.eql(u8, dir, "."))
        try std.fmt.allocPrintSentinel(gpa, ".pinger-write-check", .{}, 0)
    else
        try std.fmt.allocPrintSentinel(gpa, "{s}/.pinger-write-check", .{std.mem.trimEnd(u8, dir, "/")}, 0);
    defer gpa.free(probe);

    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = c.open(probe.ptr, flags, @as(c.mode_t, 0o644));
    if (fd < 0) {
        return try std.fmt.allocPrint(gpa, "error: data dir {s} not writable: cannot create {s}. Ensure the directory exists and you have write permission.", .{ dir, probe });
    }
    _ = c.close(fd);
    _ = c.unlink(probe.ptr);
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildPath variants" {
    const gpa = std.testing.allocator;
    {
        var w = Writer.init(gpa, ".", null);
        const p = try w.buildPath("2026-05-28");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("pinger-2026-05-28.jsonl", p);
    }
    {
        var w = Writer.init(gpa, "/var/lib/pinger", null);
        const p = try w.buildPath("2026-05-28");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/var/lib/pinger/pinger-2026-05-28.jsonl", p);
    }
    {
        var w = Writer.init(gpa, "data/", null);
        const p = try w.buildPath("2026-05-28");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("data/pinger-2026-05-28.jsonl", p);
    }
    {
        var w = Writer.init(gpa, ".", "/tmp/custom.jsonl");
        const p = try w.buildPath("2026-05-28");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/tmp/custom.jsonl", p);
    }
}
