//! HTTP Cookie Jar implementation conforming to Go's net/http CookieJar.
const std = @import("std");
const Cookie = @import("cookie.zig").Cookie;
const CookieIterator = @import("cookie.zig").CookieIterator;
const parseSetCookie = @import("cookie.zig").parseSetCookie;

pub const CookieJarEntry = struct {
    host: []const u8,
    name: []const u8,
    value: []const u8,
    path: ?[]const u8,
};

pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(CookieJarEntry),

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *CookieJar) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.host);
            self.allocator.free(e.name);
            self.allocator.free(e.value);
            if (e.path) |p| self.allocator.free(p);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn setCookiesFromHeader(self: *CookieJar, host: []const u8, set_cookie_raw: []const u8) !void {
        if (parseSetCookie(set_cookie_raw)) |c| {
            try self.setCookie(host, c);
        }
    }

    pub fn setCookie(self: *CookieJar, host: []const u8, c: Cookie) !void {
        for (self.entries.items) |*existing| {
            if (std.ascii.eqlIgnoreCase(existing.host, host) and std.mem.eql(u8, existing.name, c.name)) {
                self.allocator.free(existing.value);
                existing.value = try self.allocator.dupe(u8, c.value);
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

        try self.entries.append(self.allocator, .{
            .host = owned_host,
            .name = owned_name,
            .value = owned_value,
            .path = owned_path,
        });
    }

    pub fn formatCookieHeader(self: *const CookieJar, allocator: std.mem.Allocator, host: []const u8) !?[]u8 {
        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        var first = true;
        for (self.entries.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.host, host)) {
                if (!first) {
                    try list.appendSlice(allocator, "; ");
                }
                first = false;
                try list.appendSlice(allocator, e.name);
                try list.append(allocator, '=');
                try list.appendSlice(allocator, e.value);
            }
        }

        if (first) return null;
        return try list.toOwnedSlice(allocator);
    }
};
