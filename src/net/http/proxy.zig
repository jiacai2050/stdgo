//! HTTP/HTTPS Proxy detection, environment parsing, and proxy authentication.
const std = @import("std");
const base64 = @import("../../encoding/base64.zig");
const Allocator = std.mem.Allocator;

/// Safely get an environment variable using libc getenv if available.
pub fn getEnv(key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;

    const val_ptr = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return std.mem.span(val_ptr);
}

/// Checks whether `host` (which may include a port like `example.com:8080`) matches NO_PROXY rules.
pub fn isNoProxy(no_proxy: []const u8, host_with_port: []const u8) bool {
    const trimmed_rule = std.mem.trim(u8, no_proxy, " \t\r\n");
    if (trimmed_rule.len == 0) return false;
    if (std.mem.eql(u8, trimmed_rule, "*")) return true;

    // Separate host and port
    var req_host = host_with_port;
    if (std.mem.lastIndexOfScalar(u8, host_with_port, ':')) |colon| {
        if (!std.mem.startsWith(u8, host_with_port, "[") or std.mem.indexOfScalar(u8, host_with_port, ']') != null) {
            req_host = host_with_port[0..colon];
        }
    }

    var iter = std.mem.splitScalar(u8, no_proxy, ',');
    while (iter.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;

        // Exact match with full host:port
        if (std.ascii.eqlIgnoreCase(entry, host_with_port)) return true;

        // Exact match with host only
        if (std.ascii.eqlIgnoreCase(entry, req_host)) return true;

        // Domain suffix match (e.g. .example.com or example.com matching sub.example.com)
        const domain = if (std.mem.startsWith(u8, entry, ".")) entry[1..] else entry;
        if (std.ascii.endsWithIgnoreCase(req_host, domain)) {
            if (req_host.len == domain.len) return true;
            if (req_host.len > domain.len and req_host[req_host.len - domain.len - 1] == '.') {
                return true;
            }
        }
    }

    return false;
}

/// Resolves proxy from system environment variables (HTTP_PROXY, HTTPS_PROXY, ALL_PROXY, NO_PROXY).
pub fn proxyFromEnvironment(allocator: Allocator, scheme: []const u8, host: []const u8) !?[]const u8 {
    return proxyFromEnvWithLookup(allocator, scheme, host, getEnv);
}

/// Testable proxy resolver accepting a custom environment lookup function.
pub fn proxyFromEnvWithLookup(
    allocator: Allocator,
    scheme: []const u8,
    host: []const u8,
    lookup: *const fn ([]const u8) ?[]const u8,
) !?[]const u8 {
    const no_proxy = lookup("NO_PROXY") orelse lookup("no_proxy");
    if (no_proxy) |np| {
        if (isNoProxy(np, host)) return null;
    }

    var proxy_val: ?[]const u8 = null;
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");

    if (is_https) {
        proxy_val = lookup("HTTPS_PROXY") orelse lookup("https_proxy") orelse
            lookup("ALL_PROXY") orelse lookup("all_proxy") orelse
            lookup("HTTP_PROXY") orelse lookup("http_proxy");
    } else {
        proxy_val = lookup("HTTP_PROXY") orelse lookup("http_proxy") orelse
            lookup("ALL_PROXY") orelse lookup("all_proxy");
    }

    if (proxy_val) |p| {
        const trimmed = std.mem.trim(u8, p, " \t\r\n");
        if (trimmed.len > 0) {
            // Only accept http:// or https:// proxy schemes
            if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
                return try allocator.dupe(u8, trimmed);
            }
        }
    }

    return null;
}

pub const ProxyDetails = struct {
    clean_proxy_url: []const u8,
    proxy_auth: ?[]const u8,

    pub fn deinit(self: *ProxyDetails, allocator: Allocator) void {
        allocator.free(self.clean_proxy_url);
        if (self.proxy_auth) |auth| allocator.free(auth);
    }
};

/// Parses a proxy URL and extracts Basic Auth credentials if present in userinfo.
/// e.g. "http://admin:secret123@proxy.com:8080" ->
/// clean_proxy_url = "http://proxy.com:8080"
/// proxy_auth = "Basic YWRtaW46c2VjcmV0MTIz"
pub fn parseProxyDetails(allocator: Allocator, raw_proxy_url: []const u8) !ProxyDetails {
    const scheme_sep = std.mem.indexOf(u8, raw_proxy_url, "://");
    const prefix_len = if (scheme_sep) |idx| idx + 3 else 0;
    const scheme = if (scheme_sep) |idx| raw_proxy_url[0 .. idx + 3] else "http://";
    const rest = raw_proxy_url[prefix_len..];

    const at_idx = std.mem.indexOfScalar(u8, rest, '@');
    if (at_idx) |idx| {
        const userinfo = rest[0..idx];
        const host_port = rest[idx + 1 ..];

        const clean_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ scheme, host_port });
        errdefer allocator.free(clean_url);

        const b64_userinfo = try base64.std_encoding.encodeToString(allocator, userinfo);
        defer allocator.free(b64_userinfo);

        const auth_header = try std.fmt.allocPrint(allocator, "Basic {s}", .{b64_userinfo});

        return .{
            .clean_proxy_url = clean_url,
            .proxy_auth = auth_header,
        };
    }

    return .{
        .clean_proxy_url = try allocator.dupe(u8, raw_proxy_url),
        .proxy_auth = null,
    };
}

test "proxy isNoProxy wildcard and suffix" {
    try std.testing.expect(isNoProxy("*", "example.com:80"));
    try std.testing.expect(isNoProxy("localhost, 127.0.0.1, .internal.net", "localhost:8080"));
    try std.testing.expect(isNoProxy("localhost, 127.0.0.1, .internal.net", "service.internal.net"));
    try std.testing.expect(isNoProxy("localhost, 127.0.0.1, .internal.net", "internal.net"));
    try std.testing.expect(!isNoProxy("localhost, 127.0.0.1, .internal.net", "external.com"));
    try std.testing.expect(!isNoProxy("localhost, 127.0.0.1, .internal.net", "fakeinternal.net"));
}

test "proxy parseProxyDetails basic auth" {
    const allocator = std.testing.allocator;
    var details = try parseProxyDetails(allocator, "http://admin:secret123@proxy.example.com:8888");
    defer details.deinit(allocator);

    try std.testing.expectEqualStrings("http://proxy.example.com:8888", details.clean_proxy_url);
    try std.testing.expect(details.proxy_auth != null);
    try std.testing.expectEqualStrings("Basic YWRtaW46c2VjcmV0MTIz", details.proxy_auth.?);
}

test "proxy proxyFromEnvWithLookup" {
    const allocator = std.testing.allocator;

    const mockLookup = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "HTTP_PROXY")) return "http://127.0.0.1:8080";
            if (std.mem.eql(u8, key, "HTTPS_PROXY")) return "http://127.0.0.1:8443";
            if (std.mem.eql(u8, key, "NO_PROXY")) return "localhost,127.0.0.1";
            return null;
        }
    }.get;

    // NO_PROXY bypass
    const p1 = try proxyFromEnvWithLookup(allocator, "http", "localhost:80", mockLookup);
    try std.testing.expect(p1 == null);

    // HTTP proxy
    const p2 = try proxyFromEnvWithLookup(allocator, "http", "example.com:80", mockLookup);
    try std.testing.expect(p2 != null);
    defer allocator.free(p2.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", p2.?);

    // HTTPS proxy
    const p3 = try proxyFromEnvWithLookup(allocator, "https", "example.com:443", mockLookup);
    try std.testing.expect(p3 != null);
    defer allocator.free(p3.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8443", p3.?);
}
