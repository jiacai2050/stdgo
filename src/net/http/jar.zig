//! HTTP Cookie Jar implementation conforming to Go's net/http CookieJar.
const std = @import("std");
const Cookie = @import("cookie.zig").Cookie;
const CookieIterator = @import("cookie.zig").CookieIterator;
const parseSetCookie = @import("cookie.zig").parseSetCookie;
const Mutex = @import("../../sync/mutex.zig").Mutex;

pub const CookieJarEntry = struct {
    host: []const u8,
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
};

pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(CookieJarEntry),
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *CookieJar) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |e| {
            self.freeEntry(e);
        }
        self.entries.deinit(self.allocator);
    }

    fn freeEntry(self: *CookieJar, e: CookieJarEntry) void {
        self.allocator.free(e.host);
        self.allocator.free(e.name);
        self.allocator.free(e.value);
        if (e.path) |p| self.allocator.free(p);
        if (e.domain) |d| self.allocator.free(d);
    }

    fn domainMatches(host: []const u8, domain: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(host, domain)) return true;
        if (host.len > domain.len and std.ascii.endsWithIgnoreCase(host, domain)) {
            return host[host.len - domain.len - 1] == '.';
        }
        return false;
    }

    fn pathMatches(req_path: []const u8, cookie_path: []const u8) bool {
        if (cookie_path.len == 0 or std.mem.eql(u8, cookie_path, "/")) return true;
        if (std.mem.eql(u8, req_path, cookie_path)) return true;
        if (std.mem.startsWith(u8, req_path, cookie_path)) {
            if (cookie_path[cookie_path.len - 1] == '/') return true;
            if (req_path.len > cookie_path.len and req_path[cookie_path.len] == '/') return true;
        }
        return false;
    }

    fn normalizeDomain(raw_domain: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, raw_domain, ".")) raw_domain[1..] else raw_domain;
    }

    /// Parses a `Set-Cookie` header value and stores or deletes the resulting cookie.
    pub fn setCookiesFromHeader(
        self: *CookieJar,
        host: []const u8,
        set_cookie_raw: []const u8,
    ) !void {
        if (parseSetCookie(set_cookie_raw)) |c| {
            try self.setCookie(host, c);
        }
    }

    /// Stores, updates, or deletes (when `max_age <= 0`) a cookie for `host`.
    pub fn setCookie(self: *CookieJar, host: []const u8, c: Cookie) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const norm_domain: ?[]const u8 = if (c.domain) |d| blk: {
            const stripped = normalizeDomain(d);
            if (stripped.len == 0) break :blk null;
            if (!domainMatches(host, stripped)) return;
            break :blk stripped;
        } else null;

        // Honor Max-Age <= 0 by removing matching cookies.
        if (c.max_age) |ma| {
            if (ma <= 0) {
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    const existing = self.entries.items[i];
                    const host_match = if (norm_domain) |d|
                        (existing.domain != null and std.ascii.eqlIgnoreCase(existing.domain.?, d)) or
                            std.ascii.eqlIgnoreCase(existing.host, host)
                    else
                        std.ascii.eqlIgnoreCase(existing.host, host);
                    const path_match = if (c.path) |p|
                        (existing.path != null and std.mem.eql(u8, existing.path.?, p))
                    else
                        true;
                    if (host_match and path_match and std.mem.eql(u8, existing.name, c.name)) {
                        const removed = self.entries.swapRemove(i);
                        self.freeEntry(removed);
                    } else {
                        i += 1;
                    }
                }
                return;
            }
        }

        for (self.entries.items) |*existing| {
            const same_scope = if (norm_domain) |d|
                (existing.domain != null and std.ascii.eqlIgnoreCase(existing.domain.?, d))
            else
                (existing.domain == null and std.ascii.eqlIgnoreCase(existing.host, host));
            const same_path = if (c.path) |p|
                (existing.path != null and std.mem.eql(u8, existing.path.?, p))
            else
                existing.path == null;

            if (same_scope and same_path and std.mem.eql(u8, existing.name, c.name)) {
                const new_val = try self.allocator.dupe(u8, c.value);
                self.allocator.free(existing.value);
                existing.value = new_val;
                existing.secure = c.secure;
                return;
            }
        }

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);
        const owned_name = try self.allocator.dupe(u8, c.name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, c.value);
        errdefer self.allocator.free(owned_value);
        const owned_path = if (c.path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (owned_path) |p| self.allocator.free(p);
        const owned_domain = if (norm_domain) |d| try self.allocator.dupe(u8, d) else null;
        errdefer if (owned_domain) |d| self.allocator.free(d);

        try self.entries.append(self.allocator, .{
            .host = owned_host,
            .name = owned_name,
            .value = owned_value,
            .path = owned_path,
            .domain = owned_domain,
            .secure = c.secure,
        });
    }

    /// Formats the `Cookie` header value for non-TLS requests to `host` at path `"/"`.
    pub fn formatCookieHeader(
        self: *CookieJar,
        allocator: std.mem.Allocator,
        host: []const u8,
    ) !?[]u8 {
        return self.formatCookieHeaderForRequest(allocator, host, "/", false);
    }

    /// Formats the `Cookie` header value for a request to `host`, `request_target`, and `is_tls`,
    /// enforcing domain, path, and `Secure` attribute matching.
    pub fn formatCookieHeaderForRequest(
        self: *CookieJar,
        allocator: std.mem.Allocator,
        host: []const u8,
        request_target: []const u8,
        is_tls: bool,
    ) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const req_path = if (std.mem.indexOfScalar(u8, request_target, '?')) |q|
            request_target[0..q]
        else
            request_target;

        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        var first = true;
        for (self.entries.items) |e| {
            if (e.secure and !is_tls) continue;
            const host_ok = if (e.domain) |d|
                domainMatches(host, d)
            else
                std.ascii.eqlIgnoreCase(e.host, host);
            if (!host_ok) continue;
            if (e.path) |p| {
                if (!pathMatches(req_path, p)) continue;
            }
            if (!first) {
                try list.appendSlice(allocator, "; ");
            }
            first = false;
            try list.appendSlice(allocator, e.name);
            try list.append(allocator, '=');
            try list.appendSlice(allocator, e.value);
        }

        if (first) return null;
        return try list.toOwnedSlice(allocator);
    }
};

test "CookieJar honors Secure, Domain, Path, and Max-Age removal" {
    const testing = std.testing;
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setCookiesFromHeader(
        "api.example.com",
        "sid=abc; Domain=.example.com; Path=/v1; Secure",
    );
    try jar.setCookiesFromHeader(
        "api.example.com",
        "pub=1; Path=/",
    );

    // Non-TLS request must not receive Secure cookie
    const http_hdr = (try jar.formatCookieHeaderForRequest(
        testing.allocator,
        "api.example.com",
        "/v1/users",
        false,
    )).?;
    defer testing.allocator.free(http_hdr);
    try testing.expectEqualStrings("pub=1", http_hdr);

    // TLS request to matching path receives both
    const https_hdr = (try jar.formatCookieHeaderForRequest(
        testing.allocator,
        "sub.example.com",
        "/v1/users?active=1",
        true,
    )).?;
    defer testing.allocator.free(https_hdr);
    try testing.expectEqualStrings("sid=abc", https_hdr);

    // TLS request to non-matching path must not receive /v1 cookie
    const wrong_path = try jar.formatCookieHeaderForRequest(
        testing.allocator,
        "sub.example.com",
        "/v2/users",
        true,
    );
    try testing.expect(wrong_path == null);

    // Max-Age=0 deletes cookie
    try jar.setCookiesFromHeader(
        "api.example.com",
        "sid=; Domain=.example.com; Path=/v1; Max-Age=0",
    );
    const after_del = try jar.formatCookieHeaderForRequest(
        testing.allocator,
        "sub.example.com",
        "/v1/users",
        true,
    );
    try testing.expect(after_del == null);
}
