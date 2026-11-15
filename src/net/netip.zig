//! Go 1.18+ net/netip immutable, zero-allocation IP address package.
const std = @import("std");
const testing = std.testing;

/// Addr represents an IPv4 or IPv6 address.
/// It is immutable, zero-allocation, and comparable.
pub const Addr = struct {
    bytes: [16]u8,
    is_v4: bool,

    pub const ipv4_unspecified = addrFrom4([_]u8{ 0, 0, 0, 0 });
    pub const ipv6_unspecified = addrFrom16([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    pub const ipv4_loopback = addrFrom4([_]u8{ 127, 0, 0, 1 });
    pub const ipv6_loopback = addrFrom16([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });

    pub fn addrFrom4(ip4: [4]u8) Addr {
        const b = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, ip4[0], ip4[1], ip4[2], ip4[3] };
        return .{
            .bytes = b,
            .is_v4 = true,
        };
    }

    pub fn addrFrom16(ip6: [16]u8) Addr {
        return .{
            .bytes = ip6,
            .is_v4 = false,
        };
    }

    pub fn is4(self: Addr) bool {
        return self.is_v4;
    }

    pub fn is6(self: Addr) bool {
        return !self.is_v4;
    }

    pub fn isLoopback(self: Addr) bool {
        if (self.is_v4) {
            return self.bytes[12] == 127;
        }
        return std.mem.eql(u8, &self.bytes, &ipv6_loopback.bytes);
    }

    pub fn isMulticast(self: Addr) bool {
        if (self.is_v4) {
            return (self.bytes[12] & 0xf0) == 0xe0;
        }
        return self.bytes[0] == 0xff;
    }

    pub fn isPrivate(self: Addr) bool {
        if (self.is_v4) {
            const b0 = self.bytes[12];
            const b1 = self.bytes[13];
            if (b0 == 10) return true;
            if (b0 == 172 and (b1 & 0xf0) == 16) return true;
            if (b0 == 192 and b1 == 168) return true;
            return false;
        }
        return (self.bytes[0] & 0xfe) == 0xfc;
    }

    pub fn isUnspecified(self: Addr) bool {
        if (self.is_v4) {
            return self.bytes[12] == 0 and self.bytes[13] == 0 and self.bytes[14] == 0 and self.bytes[15] == 0;
        }
        for (self.bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    pub fn as4(self: Addr) ?[4]u8 {
        if (!self.is_v4) return null;
        return self.bytes[12..16].*;
    }

    pub fn as16(self: Addr) [16]u8 {
        return self.bytes;
    }

    pub fn compare(self: Addr, other: Addr) std.math.Order {
        if (self.is_v4 != other.is_v4) {
            return if (self.is_v4) .lt else .gt;
        }
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn unmap(self: Addr) Addr {
        if (!self.is_v4) {
            if (std.mem.startsWith(u8, self.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                return addrFrom4(self.bytes[12..16].*);
            }
        }
        return self;
    }

    pub fn format(self: Addr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.is_v4) {
            try writer.print("{d}.{d}.{d}.{d}", .{
                self.bytes[12],
                self.bytes[13],
                self.bytes[14],
                self.bytes[15],
            });
        } else {
            // Format IPv6
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                const chunk = (@as(u16, self.bytes[i]) << 8) | self.bytes[i + 1];
                if (i > 0) try writer.writeByte(':');
                try writer.print("{x}", .{chunk});
            }
        }
    }
};

/// parseAddr parses a string as an IP address (IPv4 or IPv6).
pub fn parseAddr(s: []const u8) !Addr {
    if (std.mem.indexOfScalar(u8, s, ':') == null) {
        // Parse IPv4
        var parts = std.mem.splitScalar(u8, s, '.');
        var ip4: [4]u8 = undefined;
        var count: usize = 0;
        while (parts.next()) |part| {
            if (count >= 4 or part.len == 0 or (part.len > 1 and part[0] == '0')) return error.InvalidIp;
            const val = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIp;
            ip4[count] = val;
            count += 1;
        }
        if (count != 4) return error.InvalidIp;
        return Addr.addrFrom4(ip4);
    } else {
        // Parse IPv6 using standard parse
        const parsed = std.Io.net.IpAddress.parse(s, 0) catch return error.InvalidIp;
        return Addr.addrFrom16(parsed.ip6.bytes);
    }
}

/// Prefix represents an IP network prefix: an IP address and a prefix length.
pub const Prefix = struct {
    addr: Addr,
    bits: u8,

    pub fn init(addr: Addr, bits: u8) Prefix {
        const max_bits: u8 = if (addr.is4()) 32 else 128;
        return .{
            .addr = addr,
            .bits = @min(bits, max_bits),
        };
    }

    pub fn contains(self: Prefix, addr: Addr) bool {
        if (self.addr.is4() != addr.is4()) return false;
        const total_bits: usize = if (self.addr.is4()) 32 else 128;
        if (self.bits == 0) return true;
        if (self.bits > total_bits) return false;

        const offset: usize = if (self.addr.is4()) 12 else 0;
        var remaining = self.bits;
        var i: usize = 0;

        while (remaining >= 8) : (remaining -= 8) {
            if (self.addr.bytes[offset + i] != addr.bytes[offset + i]) return false;
            i += 1;
        }

        if (remaining > 0) {
            const shift: u3 = @intCast(8 - remaining);
            const mask = @as(u8, 0xff) << shift;
            if ((self.addr.bytes[offset + i] & mask) != (addr.bytes[offset + i] & mask)) return false;
        }
        return true;
    }
};

/// parsePrefix parses a string as an IP network prefix (CIDR notation).
pub fn parsePrefix(s: []const u8) !Prefix {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.InvalidPrefix;
    const ip_part = s[0..slash];
    const bit_part = s[slash + 1 ..];

    const addr = try parseAddr(ip_part);
    const bits = std.fmt.parseInt(u8, bit_part, 10) catch return error.InvalidPrefix;
    const max_bits: u8 = if (addr.is4()) 32 else 128;
    if (bits > max_bits) return error.InvalidPrefix;

    return Prefix.init(addr, bits);
}

/// AddrPort represents an IP address and a port number.
pub const AddrPort = struct {
    addr: Addr,
    port: u16,

    pub fn init(addr: Addr, port: u16) AddrPort {
        return .{
            .addr = addr,
            .port = port,
        };
    }
};

/// parseAddrPort parses a string as an IP address and port.
pub fn parseAddrPort(s: []const u8) !AddrPort {
    const hp = try @import("hostport.zig").splitHostPort(s);
    const addr = try parseAddr(hp.host);
    const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
    return AddrPort.init(addr, port);
}

test "netip: Addr parsing and properties" {
    const a1 = try parseAddr("192.168.1.1");
    try testing.expect(a1.is4());
    try testing.expect(!a1.is6());
    try testing.expect(a1.isPrivate());
    try testing.expect(!a1.isLoopback());

    const a2 = try parseAddr("127.0.0.1");
    try testing.expect(a2.isLoopback());

    const a3 = try parseAddr("::1");
    try testing.expect(a3.is6());
    try testing.expect(a3.isLoopback());
}

test "netip: Prefix and contains" {
    const p1 = try parsePrefix("10.0.0.0/8");
    try testing.expect(p1.contains(try parseAddr("10.1.2.3")));
    try testing.expect(!p1.contains(try parseAddr("192.168.1.1")));

    const p2 = try parsePrefix("192.168.1.0/24");
    try testing.expect(p2.contains(try parseAddr("192.168.1.254")));
    try testing.expect(!p2.contains(try parseAddr("192.168.2.1")));
}

test "netip: AddrPort parsing" {
    const ap = try parseAddrPort("127.0.0.1:8080");
    try testing.expect(ap.addr.isLoopback());
    try testing.expectEqual(@as(u16, 8080), ap.port);
}

test "netip: Addr format" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("192.168.1.1", try std.fmt.bufPrint(&buf, "{f}", .{try parseAddr("192.168.1.1")}));
    try testing.expectEqualStrings("2001:db8:0:0:0:0:0:1", try std.fmt.bufPrint(&buf, "{f}", .{try parseAddr("2001:db8::1")}));
}
