//! HTTP Request representation conforming to Go's net/http Request.
const std = @import("std");
const Method = @import("method.zig").Method;
const Header = @import("header.zig").Header;
const io = @import("../../io.zig");

pub const ParsedTarget = struct {
    scheme: []const u8,
    is_tls: bool,
    host: []const u8,
    port: u16,
    request_target: []const u8,
};

/// Parses target URL into scheme, bare host (IPv6 brackets stripped), port,
/// path/query (fragment stripped), and TLS flag.
/// Supports http, https, socks5, and socks5h:
/// - `socks5://`: Standard SOCKS5 proxy protocol (historically local DNS).
/// - `socks5h://`: SOCKS5 proxy with remote Host DNS resolution (prevents DNS leaks).
pub fn parseUrlTarget(raw_url: []const u8) !ParsedTarget {
    var rest = raw_url;
    var is_tls = false;
    var port: u16 = 80;
    var scheme: []const u8 = "http";

    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
        is_tls = false;
        port = 80;
        scheme = "http";
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
        is_tls = true;
        port = 443;
        scheme = "https";
    } else if (std.mem.startsWith(u8, rest, "socks5://")) {
        rest = rest[9..];
        is_tls = false;
        port = 1080;
        scheme = "socks5";
    } else if (std.mem.startsWith(u8, rest, "socks5h://")) {
        rest = rest[10..];
        is_tls = false;
        port = 1080;
        scheme = "socks5h";
    } else if (std.mem.indexOf(u8, rest, "://") != null) {
        return error.UnsupportedScheme;
    } else {
        // Default to http:// when scheme is omitted (like curl)
        is_tls = false;
        port = 80;
        scheme = "http";
    }

    // Strip any #fragment before parsing authority and request target.
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash_idx| {
        rest = rest[0..hash_idx];
    }

    const delim_idx = std.mem.indexOfAny(u8, rest, "/?");
    const authority = if (delim_idx) |idx| rest[0..idx] else rest;
    const req_target = if (delim_idx) |idx| rest[idx..] else "/";

    var host: []const u8 = authority;

    if (std.mem.startsWith(u8, authority, "[")) {
        const rb = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidHost;
        host = authority[1..rb];
        if (rb + 1 < authority.len) {
            if (authority[rb + 1] != ':') return error.InvalidPort;
            port = std.fmt.parseInt(u16, authority[rb + 2 ..], 10) catch {
                return error.InvalidPort;
            };
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
        host = authority[0..colon_idx];
        port = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch {
            return error.InvalidPort;
        };
    }

    return .{
        .scheme = scheme,
        .is_tls = is_tls,
        .host = host,
        .port = port,
        .request_target = req_target,
    };
}

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method = .GET,
    url: []const u8,
    header: Header,
    body: ?[]const u8 = null,
    body_reader: ?*io.Reader = null,
    content_length: ?u64 = null,
    get_body: ?*const fn (ctx_ptr: *anyopaque) anyerror!*io.Reader = null,
    get_body_ctx: ?*anyopaque = null,
    /// Preallocated reader storage for slice bodies, populated when `setBody()` is called.
    slice_reader: std.Io.Reader = undefined,
    cl_str: ?[]u8 = null,
    extra_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .url = url,
            .header = Header.init(allocator),
            .body = null,
            .body_reader = null,
            .content_length = null,
            .get_body = null,
            .get_body_ctx = null,
            .slice_reader = undefined,
            .cl_str = null,
            .extra_strings = .empty,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.cl_str) |s| {
            self.allocator.free(s);
            self.cl_str = null;
        }
        for (self.extra_strings.items) |s| {
            self.allocator.free(s);
        }
        self.extra_strings.deinit(self.allocator);
        self.header.deinit();
    }

    pub fn setHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.header.set(name, value);
    }

    /// Sets an in-memory slice body for the request and updates `Content-Length`.
    /// Leaves `body_reader` and `get_body` null so the slice can be reused directly
    /// across redirects and stale-connection retries without self-referential pointers.
    pub fn setBody(self: *Request, body: []const u8) !void {
        const s = try std.fmt.allocPrint(self.allocator, "{d}", .{body.len});
        errdefer self.allocator.free(s);
        try self.header.set("Content-Length", s);

        if (self.cl_str) |old| {
            self.allocator.free(old);
        }
        self.cl_str = s;
        self.body = body;
        self.body_reader = null;
        self.get_body = null;
        self.get_body_ctx = null;
        self.content_length = body.len;
    }

    pub fn userAgent(self: *const Request) ?[]const u8 {
        return self.header.get("User-Agent");
    }

    pub const BasicAuth = struct {
        username: []u8,
        password: []u8,

        pub fn deinit(self: *BasicAuth, allocator: std.mem.Allocator) void {
            allocator.free(self.username);
            allocator.free(self.password);
        }
    };

    /// basicAuth returns the username and password provided in the request's
    /// Authorization header, if the request uses HTTP Basic Authentication.
    pub fn basicAuth(self: *const Request, allocator: std.mem.Allocator) !?BasicAuth {
        const auth = self.header.get("Authorization") orelse return null;
        if (!std.mem.startsWith(u8, auth, "Basic ")) return null;

        const b64 = std.mem.trim(u8, auth[6..], " \t");
        const dec_size = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        const decoded = try allocator.alloc(u8, dec_size);
        defer allocator.free(decoded);

        try std.base64.standard.Decoder.decode(decoded, b64);

        const colon_idx = std.mem.indexOfScalar(u8, decoded, ':') orelse return null;
        const u = try allocator.dupe(u8, decoded[0..colon_idx]);
        errdefer allocator.free(u);
        const p = try allocator.dupe(u8, decoded[colon_idx + 1 ..]);
        errdefer allocator.free(p);

        return BasicAuth{
            .username = u,
            .password = p,
        };
    }

    /// cookies parses and returns the HTTP cookies sent with the request.
    pub fn cookies(
        self: *const Request,
        allocator: std.mem.Allocator,
    ) ![]@import("cookie.zig").Cookie {
        var list = std.ArrayListUnmanaged(@import("cookie.zig").Cookie).empty;
        errdefer list.deinit(allocator);

        for (self.header.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "Cookie")) {
                var it = @import("cookie.zig").CookieIterator{ .raw = entry.value };
                while (it.next()) |c| {
                    try list.append(allocator, c);
                }
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// clone returns a copy of the request with an independent header copy and
    /// no dangling self-referential pointers.
    pub fn clone(self: *const Request, allocator: std.mem.Allocator) !Request {
        var copy = Request.init(allocator, self.method, self.url);
        errdefer copy.deinit();

        try copy.header.entries.ensureTotalCapacity(allocator, self.header.entries.items.len);
        for (self.header.entries.items) |entry| {
            const name_copy = try allocator.dupe(u8, entry.name);
            var name_owned = false;
            errdefer if (!name_owned) allocator.free(name_copy);
            try copy.extra_strings.append(allocator, name_copy);
            name_owned = true;

            const val_copy = try allocator.dupe(u8, entry.value);
            var val_owned = false;
            errdefer if (!val_owned) allocator.free(val_copy);
            try copy.extra_strings.append(allocator, val_copy);
            val_owned = true;

            try copy.header.add(name_copy, val_copy);
        }

        copy.body = self.body;
        copy.body_reader = if (self.body != null) null else self.body_reader;
        copy.content_length = self.content_length;
        copy.get_body = if (self.body != null) null else self.get_body;
        copy.get_body_ctx = if (self.body != null) null else self.get_body_ctx;
        return copy;
    }

    /// Sets a streaming reader body for the request, configuring either
    /// `Content-Length` or `Transfer-Encoding: chunked`.
    pub fn setBodyReader(self: *Request, r: *io.Reader, cl: ?u64) !void {
        if (cl) |len| {
            const s = try std.fmt.allocPrint(self.allocator, "{d}", .{len});
            errdefer self.allocator.free(s);
            try self.header.set("Content-Length", s);
            if (self.cl_str) |old| {
                self.allocator.free(old);
            }
            self.cl_str = s;
        } else {
            try self.header.set("Transfer-Encoding", "chunked");
        }

        self.body = null;
        self.body_reader = r;
        self.content_length = cl;
    }

    /// Sets the `Authorization` header using HTTP Basic Authentication.
    pub fn setBasicAuth(self: *Request, username: []const u8, password: []const u8) !void {
        const raw = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(raw);

        const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
        const encoded = try self.allocator.alloc(u8, enc_len + 6);
        var owned_by_extra = false;
        errdefer if (!owned_by_extra) self.allocator.free(encoded);

        @memcpy(encoded[0..6], "Basic ");
        _ = std.base64.standard.Encoder.encode(encoded[6..], raw);
        try self.extra_strings.append(self.allocator, encoded);
        owned_by_extra = true;
        try self.header.set("Authorization", encoded);
    }

    /// Adds a cookie to the request's `Cookie` header.
    pub fn addCookie(self: *Request, cookie: @import("cookie.zig").Cookie) !void {
        if (self.header.get("Cookie")) |existing| {
            const combined = try std.fmt.allocPrint(
                self.allocator,
                "{s}; {s}={s}",
                .{ existing, cookie.name, cookie.value },
            );
            var owned_by_extra = false;
            errdefer if (!owned_by_extra) self.allocator.free(combined);
            try self.extra_strings.append(self.allocator, combined);
            owned_by_extra = true;
            try self.header.set("Cookie", combined);
        } else {
            const s = try std.fmt.allocPrint(
                self.allocator,
                "{s}={s}",
                .{ cookie.name, cookie.value },
            );
            var owned_by_extra = false;
            errdefer if (!owned_by_extra) self.allocator.free(s);
            try self.extra_strings.append(self.allocator, s);
            owned_by_extra = true;
            try self.header.set("Cookie", s);
        }
    }
};

pub fn newRequest(
    allocator: std.mem.Allocator,
    method: Method,
    url: []const u8,
    body: ?[]const u8,
) !Request {
    var req = Request.init(allocator, method, url);
    errdefer req.deinit();
    if (body) |b| {
        try req.setBody(b);
    }
    return req;
}

pub fn newRequestWithReader(
    allocator: std.mem.Allocator,
    method: Method,
    url: []const u8,
    body_r: ?*io.Reader,
    content_len: ?u64,
) !Request {
    var req = Request.init(allocator, method, url);
    errdefer req.deinit();
    if (body_r) |r| {
        try req.setBodyReader(r, content_len);
    }
    return req;
}

test "parseUrlTarget with query string without slash" {
    const target = try parseUrlTarget("https://example.com?foo=bar&baz=1");
    try std.testing.expectEqualStrings("example.com", target.host);
    try std.testing.expectEqualStrings("?foo=bar&baz=1", target.request_target);
    try std.testing.expectEqual(@as(u16, 443), target.port);
    try std.testing.expect(target.is_tls);
}

test "parseUrlTarget strips fragment and unbrackets IPv6 hosts" {
    const t1 = try parseUrlTarget("http://[::1]:8080/path?x=1#section");
    try std.testing.expectEqualStrings("::1", t1.host);
    try std.testing.expectEqual(@as(u16, 8080), t1.port);
    try std.testing.expectEqualStrings("/path?x=1", t1.request_target);

    const t2 = try parseUrlTarget("https://[2001:db8::1]/#frag");
    try std.testing.expectEqualStrings("2001:db8::1", t2.host);
    try std.testing.expectEqual(@as(u16, 443), t2.port);
    try std.testing.expectEqualStrings("/", t2.request_target);
    try std.testing.expect(t2.is_tls);

    const t3 = try parseUrlTarget("http://example.com#only-frag");
    try std.testing.expectEqualStrings("example.com", t3.host);
    try std.testing.expectEqualStrings("/", t3.request_target);
}

test "Request.setBody and clone have no dangling self-pointers" {
    const testing = std.testing;
    var req = try newRequest(testing.allocator, .POST, "http://example.com/submit", "payload");
    try testing.expect(req.body != null);
    try testing.expect(req.body_reader == null);
    try testing.expect(req.get_body == null);
    try testing.expect(req.get_body_ctx == null);

    var cloned = try req.clone(testing.allocator);
    defer cloned.deinit();
    req.deinit();

    try testing.expectEqualStrings("payload", cloned.body.?);
    try testing.expect(cloned.body_reader == null);
    try testing.expectEqualStrings("7", cloned.header.get("Content-Length").?);
}
