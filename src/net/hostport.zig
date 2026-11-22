//! Port of Go's `net.SplitHostPort` and `net.JoinHostPort` to Zig 0.17.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    MissingPort,
    TooManyColons,
    InvalidHostPort,
};

pub const HostPort = struct {
    host: []const u8,
    port: []const u8,
};

/// SplitHostPort splits a network address of the form "host:port",
/// "host%zone:port", "[host]:port" or "[host%zone]:port" into host and port.
pub fn splitHostPort(hostport: []const u8) Error!HostPort {
    if (hostport.len == 0) return Error.MissingPort;

    if (hostport[0] == '[') {
        // Enclosed in brackets, e.g. "[::1]:80"
        const close_bracket = std.mem.indexOfScalar(u8, hostport, ']') orelse {
            return Error.MissingPort;
        };
        if (close_bracket + 1 >= hostport.len or hostport[close_bracket + 1] != ':') {
            return Error.MissingPort;
        }
        const host = hostport[1..close_bracket];
        const port = hostport[close_bracket + 2 ..];
        if (std.mem.indexOfScalar(u8, port, ':') != null) {
            return Error.TooManyColons;
        }
        return HostPort{ .host = host, .port = port };
    }

    const colon_pos = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return Error.MissingPort;
    // Check if there are other colons earlier in the string (naked IPv6 without brackets)
    if (std.mem.indexOfScalar(u8, hostport[0..colon_pos], ':') != null) {
        return Error.TooManyColons;
    }

    const host = hostport[0..colon_pos];
    const port = hostport[colon_pos + 1 ..];
    return HostPort{ .host = host, .port = port };
}

/// JoinHostPort combines host and port into a network address of the form "host:port".
/// If host contains a colon (as for an IPv6 address) and is not enclosed in brackets,
/// JoinHostPort returns "[host]:port".
pub fn joinHostPort(allocator: Allocator, host: []const u8, port: []const u8) Allocator.Error![]u8 {
    // If host needs brackets
    const needs_brackets = std.mem.indexOfScalar(u8, host, ':') != null and
        (host.len == 0 or host[0] != '[');
    if (needs_brackets) {
        return std.fmt.allocPrint(allocator, "[{s}]:{s}", .{ host, port });
    } else {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, port });
    }
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "net.hostport: splitHostPort IPv4 and hostnames" {
    const testing = std.testing;

    const hp1 = try splitHostPort("127.0.0.1:8080");
    try testing.expectEqualStrings("127.0.0.1", hp1.host);
    try testing.expectEqualStrings("8080", hp1.port);

    const hp2 = try splitHostPort("localhost:http");
    try testing.expectEqualStrings("localhost", hp2.host);
    try testing.expectEqualStrings("http", hp2.port);

    try testing.expectError(Error.MissingPort, splitHostPort("localhost"));
    try testing.expectError(Error.MissingPort, splitHostPort("127.0.0.1"));
}

test "net.hostport: splitHostPort IPv6" {
    const testing = std.testing;

    const hp1 = try splitHostPort("[::1]:443");
    try testing.expectEqualStrings("::1", hp1.host);
    try testing.expectEqualStrings("443", hp1.port);

    const hp2 = try splitHostPort("[2001:db8::1]:9000");
    try testing.expectEqualStrings("2001:db8::1", hp2.host);
    try testing.expectEqualStrings("9000", hp2.port);

    // Naked IPv6 with multiple colons should fail with TooManyColons
    try testing.expectError(Error.TooManyColons, splitHostPort("2001:db8::1:9000"));
}

test "net.hostport: joinHostPort" {
    const testing = std.testing;

    const s1 = try joinHostPort(testing.allocator, "127.0.0.1", "80");
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("127.0.0.1:80", s1);

    const s2 = try joinHostPort(testing.allocator, "::1", "443");
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("[::1]:443", s2);

    const s3 = try joinHostPort(testing.allocator, "[::1]", "443");
    defer testing.allocator.free(s3);
    try testing.expectEqualStrings("[::1]:443", s3);
}
