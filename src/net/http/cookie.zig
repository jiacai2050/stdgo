//! RFC 6265 HTTP Cookie implementation corresponding to Go's net/http Cookie.
const std = @import("std");

pub const SameSite = enum {
    default,
    lax,
    strict,
    none,

    pub fn asString(self: SameSite) []const u8 {
        return switch (self) {
            .default => "",
            .lax => "Lax",
            .strict => "Strict",
            .none => "None",
        };
    }
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .default,
    raw: ?[]const u8 = null,
};

pub const CookieIterator = struct {
    raw: []const u8,
    index: usize = 0,

    pub fn next(self: *CookieIterator) ?Cookie {
        while (self.index < self.raw.len) {
            while (self.index < self.raw.len and (self.raw[self.index] == ' ' or self.raw[self.index] == ';')) {
                self.index += 1;
            }
            if (self.index >= self.raw.len) return null;

            const start = self.index;
            while (self.index < self.raw.len and self.raw[self.index] != ';') {
                self.index += 1;
            }
            const pair = self.raw[start..self.index];
            if (self.index < self.raw.len) self.index += 1;

            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const name = std.mem.trim(u8, pair[0..eq], " \t");
                var value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }
                if (name.len > 0) {
                    return Cookie{ .name = name, .value = value, .raw = pair };
                }
            }
        }
        return null;
    }
};

pub fn parseSetCookie(raw_header: []const u8) ?Cookie {
    var iter = std.mem.splitScalar(u8, raw_header, ';');
    const first = iter.next() orelse return null;
    const eq_idx = std.mem.indexOfScalar(u8, first, '=') orelse return null;

    var cookie = Cookie{
        .name = std.mem.trim(u8, first[0..eq_idx], " \t"),
        .value = std.mem.trim(u8, first[eq_idx + 1 ..], " \t"),
        .raw = raw_header,
    };
    if (cookie.value.len >= 2 and cookie.value[0] == '"' and cookie.value[cookie.value.len - 1] == '"') {
        cookie.value = cookie.value[1 .. cookie.value.len - 1];
    }

    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(trimmed, "secure")) {
            cookie.secure = true;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "httponly")) {
            cookie.http_only = true;
        } else if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const attr_name = std.mem.trim(u8, trimmed[0..eq], " \t");
            const attr_val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(attr_name, "path")) {
                cookie.path = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "domain")) {
                cookie.domain = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "max-age")) {
                cookie.max_age = std.fmt.parseInt(i64, attr_val, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "samesite")) {
                if (std.ascii.eqlIgnoreCase(attr_val, "lax")) {
                    cookie.same_site = .lax;
                } else if (std.ascii.eqlIgnoreCase(attr_val, "strict")) {
                    cookie.same_site = .strict;
                } else if (std.ascii.eqlIgnoreCase(attr_val, "none")) {
                    cookie.same_site = .none;
                }
            }
        }
    }

    return cookie;
}
