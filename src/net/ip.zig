//! Port of Go's `net` IP, IPMask, IPNet, and CIDR utilities to Zig 0.17.
//!
//! Provides `IP` (IPv4 and IPv6), `IPMask`, `IPNet`, `parseIp`, `parseCidr`,
//! `cidrMask`, and `ipv4Mask`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const IP = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub const ipv4_zero: IP = .{ .v4 = [_]u8{ 0, 0, 0, 0 } };
    pub const ipv6_zero: IP = .{ .v6 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    pub const ipv4_loopback: IP = .{ .v4 = [_]u8{ 127, 0, 0, 1 } };
    pub const ipv6_loopback: IP = .{
        .v6 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    };

    /// Returns true if ip is a loopback address.
    pub fn isLoopback(self: IP) bool {
        return switch (self) {
            .v4 => |b| b[0] == 127,
            .v6 => |b| std.mem.eql(u8, &b, &ipv6_loopback.v6) or (isV4InV6(b) and b[12] == 127),
        };
    }

    /// Returns true if ip is a multicast address.
    pub fn isMulticast(self: IP) bool {
        return switch (self) {
            .v4 => |b| (b[0] & 0xf0) == 0xe0,
            .v6 => |b| b[0] == 0xff,
        };
    }

    /// Returns true if ip is a private data address (RFC 1918 or RFC 4193).
    pub fn isPrivate(self: IP) bool {
        switch (self) {
            .v4 => |b| {
                // 10.0.0.0/8
                if (b[0] == 10) return true;
                // 172.16.0.0/12
                if (b[0] == 172 and (b[1] & 0xf0) == 16) return true;
                // 192.168.0.0/16
                if (b[0] == 192 and b[1] == 168) return true;
                return false;
            },
            .v6 => |b| {
                if (isV4InV6(b)) {
                    return (IP{ .v4 = b[12..16].* }).isPrivate();
                }
                // fc00::/7
                return (b[0] & 0xfe) == 0xfc;
            },
        }
    }

    /// Converts an IPv4 or IPv4-mapped IPv6 address to 4-byte representation.
    pub fn to4(self: IP) ?[4]u8 {
        return switch (self) {
            .v4 => |b| b,
            .v6 => |b| if (isV4InV6(b)) b[12..16].* else null,
        };
    }

    /// Converts the address to 16-byte representation.
    pub fn to16(self: IP) [16]u8 {
        return switch (self) {
            .v4 => |b| [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, b[0], b[1], b[2], b[3] },
            .v6 => |b| b,
        };
    }

    /// Returns true if this IP equals another IP.
    pub fn equal(self: IP, other: IP) bool {
        const a16 = self.to16();
        const b16 = other.to16();
        return std.mem.eql(u8, &a16, &b16);
    }

    /// Formats the IP address with `{f}`.
    pub fn format(self: IP, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .v4 => |b| try writer.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }),
            .v6 => |b| {
                if (isV4InV6(b)) {
                    try writer.print("::ffff:{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] });
                    return;
                }
                var i: usize = 0;
                while (i < 16) : (i += 2) {
                    const chunk: u16 = (@as(u16, b[i]) << 8) | b[i + 1];
                    try writer.print("{x}", .{chunk});
                    if (i < 14) try writer.writeByte(':');
                }
            },
        }
    }

    /// Formats the IP into the provided buffer and returns the written slice.
    pub fn stringBuf(self: IP, buf: []u8) []const u8 {
        switch (self) {
            .v4 => |b| {
                return std.fmt.bufPrint(
                    buf,
                    "{d}.{d}.{d}.{d}",
                    .{ b[0], b[1], b[2], b[3] },
                ) catch "";
            },
            .v6 => |b| {
                if (isV4InV6(b)) {
                    return std.fmt.bufPrint(
                        buf,
                        "::ffff:{d}.{d}.{d}.{d}",
                        .{ b[12], b[13], b[14], b[15] },
                    ) catch "";
                }
                var pos: usize = 0;
                var i: usize = 0;
                while (i < 16) : (i += 2) {
                    const chunk: u16 = (@as(u16, b[i]) << 8) | b[i + 1];
                    const written = std.fmt.bufPrint(buf[pos..], "{x}", .{chunk}) catch return "";
                    pos += written.len;
                    if (i < 14 and pos < buf.len) {
                        buf[pos] = ':';
                        pos += 1;
                    }
                }
                return buf[0..pos];
            },
        }
    }

    /// Formats the IP into a newly allocated string.
    pub fn string(self: IP, allocator: Allocator) Allocator.Error![]u8 {
        var buf: [64]u8 = undefined;
        const s = self.stringBuf(&buf);
        return allocator.dupe(u8, s);
    }

    fn isV4InV6(b: [16]u8) bool {
        for (b[0..10]) |byte| {
            if (byte != 0) return false;
        }
        return b[10] == 0xff and b[11] == 0xff;
    }
};

/// IPMask represents an IP network mask.
pub const IPMask = struct {
    bytes: [16]u8,
    len: u8, // 4 or 16

    pub fn slice(self: *const IPMask) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// IPv4Mask returns the IP mask (a.b.c.d).
pub fn ipv4Mask(a: u8, b: u8, c: u8, d: u8) IPMask {
    var m = IPMask{ .bytes = @splat(0), .len = 4 };
    m.bytes[0] = a;
    m.bytes[1] = b;
    m.bytes[2] = c;
    m.bytes[3] = d;
    return m;
}

/// CIDRMask returns an IPMask consisting of `ones` 1 bits followed by 0s
/// up to a total of `bits` bits.
pub fn cidrMask(ones: usize, bits: usize) ?IPMask {
    if (bits != 32 and bits != 128) return null;
    if (ones > bits) return null;

    const byte_len: u8 = if (bits == 32) 4 else 16;
    var m = IPMask{ .bytes = @splat(0), .len = byte_len };

    var rem = ones;
    var i: usize = 0;
    while (i < byte_len) : (i += 1) {
        if (rem >= 8) {
            m.bytes[i] = 0xff;
            rem -= 8;
        } else if (rem > 0) {
            const shift: u3 = @intCast(8 - rem);
            m.bytes[i] = @as(u8, 0xff) << shift;
            rem = 0;
        } else {
            m.bytes[i] = 0;
        }
    }
    return m;
}

/// IPNet represents an IP network.
pub const IPNet = struct {
    ip: IP,
    mask: IPMask,

    /// Contains reports whether the network includes ip.
    pub fn contains(self: IPNet, target: IP) bool {
        const mask_bytes = self.mask.slice();
        if (mask_bytes.len == 4) {
            const net4 = self.ip.to4() orelse return false;
            const target4 = target.to4() orelse return false;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if ((net4[i] & mask_bytes[i]) != (target4[i] & mask_bytes[i])) {
                    return false;
                }
            }
            return true;
        } else {
            const net16 = self.ip.to16();
            const target16 = target.to16();
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                if ((net16[i] & mask_bytes[i]) != (target16[i] & mask_bytes[i])) {
                    return false;
                }
            }
            return true;
        }
    }

    /// Network returns the base network address.
    pub fn network(self: IPNet) IP {
        const mask_bytes = self.mask.slice();
        if (mask_bytes.len == 4) {
            var b4 = self.ip.to4() orelse [4]u8{ 0, 0, 0, 0 };
            for (0..4) |i| {
                b4[i] &= mask_bytes[i];
            }
            return IP{ .v4 = b4 };
        } else {
            var b16 = self.ip.to16();
            for (0..16) |i| {
                b16[i] &= mask_bytes[i];
            }
            return IP{ .v6 = b16 };
        }
    }
};

fn parseIPv4Bytes(s: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |seg| {
        if (part_idx >= 4 or seg.len == 0 or seg.len > 3) return null;
        // No leading zero if length > 1
        if (seg.len > 1 and seg[0] == '0') return null;
        const val = std.fmt.parseInt(u8, seg, 10) catch return null;
        parts[part_idx] = val;
        part_idx += 1;
    }
    if (part_idx != 4) return null;
    return parts;
}

/// ParseIP parses s as an IPv4 dotted-decimal or IPv6 address.
pub fn parseIp(s: []const u8) ?IP {
    if (s.len == 0) return null;

    // Check for IPv4
    if (std.mem.indexOfScalar(u8, s, '.') != null and std.mem.indexOfScalar(u8, s, ':') == null) {
        const parts = parseIPv4Bytes(s) orelse return null;
        return IP{ .v4 = parts };
    }

    // Check for IPv6
    if (std.mem.indexOfScalar(u8, s, ':') != null) {
        return parseIPv6(s);
    }

    return null;
}

fn parseIPv6(s: []const u8) ?IP {
    // Support IPv4-mapped / mixed IPv6 dotted-quad suffix (e.g. "::ffff:10.0.0.1")
    // by converting the trailing dotted-quad into two hex groups.
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        const last_colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
        const v4 = parseIPv4Bytes(s[last_colon + 1 ..]) orelse return null;
        const w6: u16 = (@as(u16, v4[0]) << 8) | v4[1];
        const w7: u16 = (@as(u16, v4[2]) << 8) | v4[3];
        var rewritten_buf: [64]u8 = undefined;
        const rewritten = std.fmt.bufPrint(
            &rewritten_buf,
            "{s}{x}:{x}",
            .{ s[0 .. last_colon + 1], w6, w7 },
        ) catch return null;
        return parseIPv6Hex(rewritten);
    }
    return parseIPv6Hex(s);
}

fn parseIPv6Hex(s: []const u8) ?IP {
    var raw: [16]u8 = @splat(0);
    const dcolon_pos = std.mem.indexOf(u8, s, "::");

    if (dcolon_pos) |dc| {
        // Double colon present: parse left and right parts
        const left_str = s[0..dc];
        const right_str = s[dc + 2 ..];

        var left_words: [8]u16 = undefined;
        var left_count: usize = 0;
        if (left_str.len > 0) {
            var it = std.mem.splitScalar(u8, left_str, ':');
            while (it.next()) |chunk| {
                if (left_count >= 8 or chunk.len == 0 or chunk.len > 4) return null;
                left_words[left_count] = std.fmt.parseInt(u16, chunk, 16) catch return null;
                left_count += 1;
            }
        }

        var right_words: [8]u16 = undefined;
        var right_count: usize = 0;
        if (right_str.len > 0) {
            var it = std.mem.splitScalar(u8, right_str, ':');
            while (it.next()) |chunk| {
                if (right_count >= 8 or chunk.len == 0 or chunk.len > 4) return null;
                right_words[right_count] = std.fmt.parseInt(u16, chunk, 16) catch return null;
                right_count += 1;
            }
        }

        if (left_count + right_count > 7) return null;

        var w_idx: usize = 0;
        for (0..left_count) |i| {
            raw[w_idx * 2] = @truncate(left_words[i] >> 8);
            raw[w_idx * 2 + 1] = @truncate(left_words[i]);
            w_idx += 1;
        }

        const zeros_to_fill = 8 - (left_count + right_count);
        w_idx += zeros_to_fill;

        for (0..right_count) |i| {
            raw[w_idx * 2] = @truncate(right_words[i] >> 8);
            raw[w_idx * 2 + 1] = @truncate(right_words[i]);
            w_idx += 1;
        }

        return IP{ .v6 = raw };
    } else {
        // No double colon: must have exactly 8 chunks
        var words: [8]u16 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, s, ':');
        while (it.next()) |chunk| {
            if (count >= 8 or chunk.len == 0 or chunk.len > 4) return null;
            words[count] = std.fmt.parseInt(u16, chunk, 16) catch return null;
            count += 1;
        }
        if (count != 8) return null;

        for (0..8) |i| {
            raw[i * 2] = @truncate(words[i] >> 8);
            raw[i * 2 + 1] = @truncate(words[i]);
        }
        return IP{ .v6 = raw };
    }
}

pub const CidrResult = struct {
    ip: IP,
    ipnet: IPNet,
};

/// ParseCIDR parses s as a CIDR notation IP address and prefix length,
/// like "192.0.2.0/24" or "2001:db8::/32".
pub fn parseCidr(s: []const u8) !CidrResult {
    const slash_pos = std.mem.indexOfScalar(u8, s, '/') orelse return error.InvalidCidr;
    const ip_part = s[0..slash_pos];
    const mask_part = s[slash_pos + 1 ..];

    const ip = parseIp(ip_part) orelse return error.InvalidCidr;
    const total_bits: usize = switch (ip) {
        .v4 => 32,
        .v6 => 128,
    };

    const prefix_len = std.fmt.parseInt(usize, mask_part, 10) catch return error.InvalidCidr;
    const mask = cidrMask(prefix_len, total_bits) orelse return error.InvalidCidr;

    return CidrResult{
        .ip = ip,
        .ipnet = IPNet{
            .ip = ip,
            .mask = mask,
        },
    };
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "net.ip: parseIp IPv4 and IPv6" {
    const testing = std.testing;

    const ip4 = parseIp("192.168.1.1").?;
    try testing.expect(ip4.isPrivate());
    try testing.expect(!ip4.isLoopback());
    try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, ip4.to4().?);

    const loop4 = parseIp("127.0.0.1").?;
    try testing.expect(loop4.isLoopback());

    const loop6 = parseIp("::1").?;
    try testing.expect(loop6.isLoopback());

    const ip6 = parseIp("2001:db8::1").?;
    try testing.expect(!ip6.isLoopback());

    try testing.expect(parseIp("256.0.0.1") == null);
    try testing.expect(parseIp("1.2.3") == null);
    try testing.expect(parseIp("invalid") == null);
}

test "net.ip: parseCidr and IPNet.contains" {
    const testing = std.testing;

    const res = try parseCidr("192.168.1.0/24");
    try testing.expectEqual([4]u8{ 192, 168, 1, 0 }, res.ipnet.network().to4().?);

    const inside = parseIp("192.168.1.42").?;
    const outside = parseIp("192.168.2.1").?;

    try testing.expect(res.ipnet.contains(inside));
    try testing.expect(!res.ipnet.contains(outside));
}

test "net.ip: IPv6 CIDR" {
    const testing = std.testing;

    const res = try parseCidr("2001:db8::/32");
    const inside = parseIp("2001:db8:1234::1").?;
    const outside = parseIp("2001:db9::1").?;

    try testing.expect(res.ipnet.contains(inside));
    try testing.expect(!res.ipnet.contains(outside));
}

test "net.ip: IP format matches stringBuf" {
    const testing = std.testing;
    var fmt_buf: [64]u8 = undefined;
    var str_buf: [64]u8 = undefined;
    const v4_in_v6: IP = .{ .v6 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 } };
    for ([_]IP{ parseIp("192.168.1.1").?, v4_in_v6, parseIp("2001:db8::1").? }) |ip| {
        const expected = ip.stringBuf(&str_buf);
        const actual = try std.fmt.bufPrint(&fmt_buf, "{f}", .{ip});
        try testing.expectEqualStrings(expected, actual);
    }
    const v4_v6_fmt = try std.fmt.bufPrint(&fmt_buf, "{f}", .{v4_in_v6});
    try testing.expectEqualStrings("::ffff:10.0.0.1", v4_v6_fmt);

    // Round-trip IPv4-mapped IPv6 dotted-quad suffix through parseIp
    const parsed = parseIp("::ffff:10.0.0.1").?;
    try testing.expect(parsed.equal(v4_in_v6));
    try testing.expectEqual([4]u8{ 10, 0, 0, 1 }, parsed.to4().?);
    const parsed_full = parseIp("0:0:0:0:0:ffff:192.0.2.128").?;
    try testing.expectEqual([4]u8{ 192, 0, 2, 128 }, parsed_full.to4().?);
    try testing.expect(parseIp("::ffff:999.0.0.1") == null);
}
