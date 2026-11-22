//! Network address representation and service port lookup conforming to Go net conventions.
const std = @import("std");
const ip_mod = @import("ip.zig");
const hostport = @import("hostport.zig");
const IP = ip_mod.IP;
const Allocator = std.mem.Allocator;

/// Addr represents a generic network end point address.
pub const Addr = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        network: *const fn (ctx: *const anyopaque) []const u8,
        string: *const fn (ctx: *const anyopaque, allocator: Allocator) Allocator.Error![]u8,
    };

    pub fn network(self: Addr) []const u8 {
        return self.vtable.network(self.ptr);
    }

    pub fn string(self: Addr, allocator: Allocator) Allocator.Error![]u8 {
        return self.vtable.string(self.ptr, allocator);
    }
};

/// TCPAddr represents the address of a TCP end point.
pub const TCPAddr = struct {
    ip: IP,
    port: u16,

    pub fn addr(self: *const TCPAddr) Addr {
        return .{
            .ptr = self,
            .vtable = &tcp_addr_vtable,
        };
    }

    pub fn network(self: *const TCPAddr) []const u8 {
        _ = self;
        return "tcp";
    }

    pub fn string(self: *const TCPAddr, allocator: Allocator) Allocator.Error![]u8 {
        var ip_buf: [46]u8 = undefined;
        const ip_str = self.ip.stringBuf(&ip_buf);
        var port_buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{self.port}) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };
        return hostport.joinHostPort(allocator, ip_str, port_str);
    }

    pub fn parse(s: []const u8) !TCPAddr {
        const hp = try hostport.splitHostPort(s);
        const p = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
        const parsed_ip = ip_mod.parseIp(hp.host) orelse return error.InvalidIp;
        return .{
            .ip = parsed_ip,
            .port = p,
        };
    }

    const tcp_addr_vtable: Addr.VTable = .{
        .network = struct {
            fn f(ctx: *const anyopaque) []const u8 {
                const self: *const TCPAddr = @ptrCast(@alignCast(ctx));
                return self.network();
            }
        }.f,
        .string = struct {
            fn f(ctx: *const anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const self: *const TCPAddr = @ptrCast(@alignCast(ctx));
                return self.string(allocator);
            }
        }.f,
    };
};

/// UDPAddr represents the address of a UDP end point.
pub const UDPAddr = struct {
    ip: IP,
    port: u16,

    pub fn addr(self: *const UDPAddr) Addr {
        return .{
            .ptr = self,
            .vtable = &udp_addr_vtable,
        };
    }

    pub fn network(self: *const UDPAddr) []const u8 {
        _ = self;
        return "udp";
    }

    pub fn string(self: *const UDPAddr, allocator: Allocator) Allocator.Error![]u8 {
        var ip_buf: [46]u8 = undefined;
        const ip_str = self.ip.stringBuf(&ip_buf);
        var port_buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{self.port}) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };
        return hostport.joinHostPort(allocator, ip_str, port_str);
    }

    pub fn parse(s: []const u8) !UDPAddr {
        const hp = try hostport.splitHostPort(s);
        const p = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
        const parsed_ip = ip_mod.parseIp(hp.host) orelse return error.InvalidIp;
        return .{
            .ip = parsed_ip,
            .port = p,
        };
    }

    const udp_addr_vtable: Addr.VTable = .{
        .network = struct {
            fn f(ctx: *const anyopaque) []const u8 {
                const self: *const UDPAddr = @ptrCast(@alignCast(ctx));
                return self.network();
            }
        }.f,
        .string = struct {
            fn f(ctx: *const anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const self: *const UDPAddr = @ptrCast(@alignCast(ctx));
                return self.string(allocator);
            }
        }.f,
    };
};

/// LookupPort looks up the port for the given network and service name
/// (e.g. "http", "https", "ssh").
/// If service is already a numeric string, it parses and returns the number.
pub fn lookupPort(network: []const u8, service: []const u8) !u16 {
    _ = network;
    if (service.len == 0) return error.UnknownPort;

    // Direct decimal integer parsing
    if (std.fmt.parseInt(u16, service, 10)) |p| {
        return p;
    } else |_| {}

    // Well-known standard IANA service port mappings
    const services = [_]struct { name: []const u8, port: u16 }{
        .{ .name = "ftp", .port = 21 },
        .{ .name = "ssh", .port = 22 },
        .{ .name = "telnet", .port = 23 },
        .{ .name = "smtp", .port = 25 },
        .{ .name = "domain", .port = 53 },
        .{ .name = "dns", .port = 53 },
        .{ .name = "http", .port = 80 },
        .{ .name = "pop3", .port = 110 },
        .{ .name = "ntp", .port = 123 },
        .{ .name = "imap", .port = 143 },
        .{ .name = "snmp", .port = 161 },
        .{ .name = "ldap", .port = 389 },
        .{ .name = "https", .port = 443 },
        .{ .name = "smtps", .port = 465 },
        .{ .name = "submission", .port = 587 },
        .{ .name = "imaps", .port = 993 },
        .{ .name = "pop3s", .port = 995 },
        .{ .name = "socks5", .port = 1080 },
        .{ .name = "mysql", .port = 3306 },
        .{ .name = "postgres", .port = 5432 },
        .{ .name = "postgresql", .port = 5432 },
        .{ .name = "redis", .port = 6379 },
    };

    for (services) |entry| {
        if (std.ascii.eqlIgnoreCase(service, entry.name)) {
            return entry.port;
        }
    }

    return error.UnknownPort;
}

test "TCPAddr and UDPAddr formatting and parsing" {
    const testing = std.testing;

    const tcp = try TCPAddr.parse("127.0.0.1:8080");
    try testing.expect(tcp.ip.isLoopback());
    try testing.expectEqual(@as(u16, 8080), tcp.port);

    const s = try tcp.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("127.0.0.1:8080", s);

    const a = tcp.addr();
    try testing.expectEqualStrings("tcp", a.network());

    const udp = try UDPAddr.parse("[::1]:53");
    try testing.expect(udp.ip.isLoopback());
    try testing.expectEqual(@as(u16, 53), udp.port);

    const udp_a = udp.addr();
    try testing.expectEqualStrings("udp", udp_a.network());
}

test "lookupPort well-known and numeric ports" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 80), try lookupPort("tcp", "http"));
    try testing.expectEqual(@as(u16, 443), try lookupPort("tcp", "https"));
    try testing.expectEqual(@as(u16, 22), try lookupPort("tcp", "ssh"));
    try testing.expectEqual(@as(u16, 25), try lookupPort("tcp", "smtp"));
    try testing.expectEqual(@as(u16, 53), try lookupPort("udp", "dns"));
    try testing.expectEqual(@as(u16, 1080), try lookupPort("tcp", "socks5"));
    try testing.expectEqual(@as(u16, 8080), try lookupPort("tcp", "8080"));
    try testing.expectError(error.UnknownPort, lookupPort("tcp", "unknown_service_xyz"));
}
