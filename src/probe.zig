//! ICMP echo prober over raw sockets (IPv4 + IPv6), mirroring
//! internal/probe/prober.go: one echo per probe, privileged raw socket, a
//! per-target timeout, returning RTT in ms or a fail reason ("DNS: ...",
//! "i/o timeout"). Requires root or CAP_NET_RAW.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const record = @import("store/record.zig");
const rfc3339 = @import("rfc3339.zig");
const sys = @import("sys.zig");

pub const ProbeResult = record.ProbeResult;

const AF = posix.AF;
const SOCK = posix.SOCK;
const IPPROTO = posix.IPPROTO;
const POLL = posix.POLL;

var id_counter: std.atomic.Value(u16) = .init(1);

/// RFC1071 one's-complement checksum over `data` (treated as big-endian words).
fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn failResult(ts: rfc3339.Time, reason: ?[]const u8) ProbeResult {
    return .{ .timestamp = ts, .target = "", .success = false, .fail_reason = reason };
}

/// Probe `address` once. On failure, `fail_reason` is allocated with `gpa`
/// (the caller frees it after use); the success path allocates nothing.
pub fn probe(gpa: std.mem.Allocator, address: []const u8, timeout_ns: i64) ProbeResult {
    const ts = sys.nowUtc();

    const node = std.fmt.allocPrintSentinel(gpa, "{s}", .{address}, 0) catch return failResult(ts, null);
    defer gpa.free(node);

    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = AF.UNSPEC;
    hints.socktype = SOCK.RAW;

    var res: ?*c.addrinfo = null;
    const gai = c.getaddrinfo(node.ptr, null, &hints, &res);
    if (@intFromEnum(gai) != 0 or res == null) {
        const reason = dnsReason(gpa, gai);
        return failResult(ts, reason);
    }
    defer c.freeaddrinfo(res.?);

    const ai = res.?;
    const is_v6 = ai.family == AF.INET6;
    const proto: u32 = if (is_v6) IPPROTO.ICMPV6 else IPPROTO.ICMP;

    const fd = c.socket(@intCast(ai.family), @intCast(SOCK.RAW), @intCast(proto));
    if (fd < 0) return failResult(ts, gpa.dupe(u8, "socket: raw socket unavailable") catch null);
    defer _ = c.close(fd);

    const id = id_counter.fetchAdd(1, .monotonic);

    var pkt: [40]u8 = undefined;
    @memset(&pkt, 0);
    pkt[0] = if (is_v6) 128 else 8; // echo request type
    pkt[1] = 0; // code
    pkt[4] = @intCast(id >> 8);
    pkt[5] = @intCast(id & 0xff);
    pkt[6] = 0; // seq high
    pkt[7] = 1; // seq low
    for (pkt[8..], 0..) |*b, k| b.* = @intCast((k + 8) & 0xff);
    if (!is_v6) {
        const ck = checksum(&pkt);
        pkt[2] = @intCast(ck >> 8);
        pkt[3] = @intCast(ck & 0xff);
    }

    const start = sys.monotonicNanos();
    const sent = c.sendto(fd, &pkt, pkt.len, 0, ai.addr, ai.addrlen);
    if (sent < 0) return failResult(ts, gpa.dupe(u8, "i/o timeout") catch null);

    const deadline = start + timeout_ns;
    var buf: [1500]u8 = undefined;
    while (true) {
        const remaining_ns = deadline - sys.monotonicNanos();
        if (remaining_ns <= 0) break;
        const remaining_ms: c_int = @intCast(@min(@divTrunc(remaining_ns + 999_999, 1_000_000), @as(i64, std.math.maxInt(c_int))));

        var pfd = [_]c.pollfd{.{ .fd = fd, .events = POLL.IN, .revents = 0 }};
        const pr = c.poll(&pfd, 1, if (remaining_ms <= 0) 1 else remaining_ms);
        if (pr < 0) continue;
        if (pr == 0) break;
        if (pfd[0].revents & POLL.IN == 0) continue;

        const n = c.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (n <= 0) continue;
        if (matchReply(buf[0..@intCast(n)], is_v6, id)) {
            const rtt_ns = sys.monotonicNanos() - start;
            const rtt_ms = @as(f64, @floatFromInt(rtt_ns)) / 1_000_000.0;
            return .{ .timestamp = ts, .target = "", .success = true, .rtt_ms = rtt_ms };
        }
    }

    return failResult(ts, gpa.dupe(u8, "i/o timeout") catch null);
}

fn dnsReason(gpa: std.mem.Allocator, gai: c.EAI) ?[]const u8 {
    const msg = std.mem.span(c.gai_strerror(gai));
    return std.fmt.allocPrint(gpa, "DNS: {s}", .{msg}) catch null;
}

/// Does the received datagram echo our request (echo reply, our id, seq 1)?
fn matchReply(buf: []const u8, is_v6: bool, id: u16) bool {
    const icmp: []const u8 = if (is_v6) buf else blk: {
        if (buf.len < 1) return false;
        const ihl = @as(usize, buf[0] & 0x0f) * 4;
        if (buf.len < ihl) return false;
        break :blk buf[ihl..];
    };
    if (icmp.len < 8) return false;
    const want_type: u8 = if (is_v6) 129 else 0; // echo reply
    if (icmp[0] != want_type) return false;
    const rid = (@as(u16, icmp[4]) << 8) | icmp[5];
    return rid == id and icmp[6] == 0 and icmp[7] == 1;
}

/// checkPrivilege verifies raw ICMP socket access. Returns an allocated
/// Go-style error message on failure (caller frees), else null.
pub fn checkPrivilege(gpa: std.mem.Allocator) ?[]u8 {
    const fd = c.socket(@intCast(AF.INET), @intCast(SOCK.RAW), @intCast(IPPROTO.ICMP));
    if (fd < 0) {
        // Match Go's net.ListenPacket("ip4:icmp", "") error wording.
        const reason: []const u8 = switch (c.errno(fd)) {
            .ACCES => "permission denied",
            else => "operation not permitted",
        };
        return std.fmt.allocPrint(gpa, "error: raw socket unavailable: listen ip4:icmp : socket: {s}. Run as root or grant CAP_NET_RAW.", .{reason}) catch null;
    }
    _ = c.close(fd);
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const build_options = @import("build_options");

test "checksum of known data" {
    // ICMP echo header type=8 code=0 csum=0 id=0 seq=0 => checksum 0xf7ff.
    var pkt = [_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 };
    const ck = checksum(&pkt);
    try std.testing.expectEqual(@as(u16, 0xf7ff), ck);
}

test "matchReply v4 parses past IP header" {
    // IPv4 header (IHL=5 => 20 bytes) + ICMP echo reply, id=0x1234, seq=1.
    var buf: [28]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0x45; // version 4, IHL 5
    buf[20] = 0; // type echo reply
    buf[24] = 0x12;
    buf[25] = 0x34;
    buf[26] = 0;
    buf[27] = 1;
    try std.testing.expect(matchReply(&buf, false, 0x1234));
    try std.testing.expect(!matchReply(&buf, false, 0x9999));
}

test "probe IPv4 loopback success (integration)" {
    if (!build_options.integration) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const r = probe(gpa, "127.0.0.1", 2 * std.time.ns_per_s);
    defer if (r.fail_reason) |fr| gpa.free(fr);
    try std.testing.expect(r.success);
    try std.testing.expect(r.rtt_ms.? >= 0);
}

test "probe IPv6 loopback success (integration)" {
    if (!build_options.integration) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const r = probe(gpa, "::1", 2 * std.time.ns_per_s);
    defer if (r.fail_reason) |fr| gpa.free(fr);
    try std.testing.expect(r.success);
    try std.testing.expect(r.rtt_ms.? >= 0);
}
