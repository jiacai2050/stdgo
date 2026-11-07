const std = @import("std");
const bytes = @import("../bytes.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidUrl,
    InvalidHexEscape,
};

const upper_hex = "0123456789ABCDEF";

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

const EscapeMode = enum { query, path };

fn shouldEscape(c: u8, mode: EscapeMode) bool {
    // §2.3 Unreserved characters (alphanumeric, -, _, ., ~)
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
        return false;
    }
    switch (c) {
        '-', '_', '.', '~' => return false,
        '/' => if (mode == .path) return false,
        else => {},
    }
    return true;
}

/// QueryEscape escapes the string, making it safe to be placed in a URL query.
pub fn queryEscape(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    return escape(allocator, s, .query);
}

/// PathEscape escapes the string, making it safe to be placed in a URL path segment.
pub fn pathEscape(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    return escape(allocator, s, .path);
}

fn escape(allocator: Allocator, s: []const u8, mode: EscapeMode) Allocator.Error![]u8 {
    var extra: usize = 0;
    var has_space_query = false;
    for (s) |c| {
        if (c == ' ' and mode == .query) {
            has_space_query = true;
        } else if (shouldEscape(c, mode)) {
            extra += 2;
        }
    }
    if (extra == 0 and !has_space_query) {
        return try allocator.dupe(u8, s);
    }

    const t = try allocator.alloc(u8, s.len + extra);
    var j: usize = 0;
    for (s) |c| {
        if (c == ' ' and mode == .query) {
            t[j] = '+';
            j += 1;
        } else if (shouldEscape(c, mode)) {
            t[j] = '%';
            t[j + 1] = upper_hex[c >> 4];
            t[j + 2] = upper_hex[c & 15];
            j += 3;
        } else {
            t[j] = c;
            j += 1;
        }
    }
    assert(j == t.len);
    return t;
}

/// QueryUnescape does the inverse transformation of QueryEscape.
pub fn queryUnescape(allocator: Allocator, s: []const u8) (Allocator.Error || Error)![]u8 {
    return unescape(allocator, s, .query);
}

/// PathUnescape does the inverse transformation of PathEscape.
pub fn pathUnescape(allocator: Allocator, s: []const u8) (Allocator.Error || Error)![]u8 {
    return unescape(allocator, s, .path);
}

fn unescape(allocator: Allocator, s: []const u8, mode: enum { query, path }) (Allocator.Error || Error)![]u8 {
    var t = try allocator.alloc(u8, s.len);
    errdefer allocator.free(t);

    var i: usize = 0;
    var j: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len and isHex(s[i + 1]) and isHex(s[i + 2])) {
            t[j] = (hexVal(s[i + 1]) << 4) | hexVal(s[i + 2]);
            j += 1;
            i += 3;
        } else if (c == '%' and (i + 2 >= s.len or !isHex(s[i + 1]) or !isHex(s[i + 2]))) {
            return Error.InvalidHexEscape;
        } else if (c == '+' and mode == .query) {
            t[j] = ' ';
            j += 1;
            i += 1;
        } else {
            t[j] = c;
            j += 1;
            i += 1;
        }
    }
    return try allocator.realloc(t, j);
}

pub const Values = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        key: []const u8,
        values: std.ArrayList([]const u8),
    };

    pub fn init(allocator: Allocator) Values {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).empty,
        };
    }

    pub fn deinit(self: *Values) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.key);
            for (entry.values.items) |val| {
                self.allocator.free(val);
            }
            entry.values.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const Values, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                if (entry.values.items.len > 0) {
                    return entry.values.items[0];
                }
            }
        }
        return null;
    }

    pub fn add(self: *Values, key: []const u8, value: []const u8) Allocator.Error!void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                try entry.values.append(self.allocator, try self.allocator.dupe(u8, value));
                return;
            }
        }
        var new_entry = Entry{
            .key = try self.allocator.dupe(u8, key),
            .values = std.ArrayList([]const u8).empty,
        };
        try new_entry.values.append(self.allocator, try self.allocator.dupe(u8, value));
        try self.entries.append(self.allocator, new_entry);
    }

    /// Encode encodes the values into URL encoded form ("bar=baz&foo=quux").
    pub fn encode(self: *const Values, allocator: Allocator) Allocator.Error![]u8 {
        var buf = bytes.Buffer.init(allocator);
        defer buf.deinit();

        var first = true;
        for (self.entries.items) |entry| {
            for (entry.values.items) |val| {
                if (!first) {
                    try buf.writeByte('&');
                }
                first = false;
                const ek = try queryEscape(allocator, entry.key);
                defer allocator.free(ek);
                _ = try buf.write(ek);
                try buf.writeByte('=');
                const ev = try queryEscape(allocator, val);
                defer allocator.free(ev);
                _ = try buf.write(ev);
            }
        }
        return try allocator.dupe(u8, buf.bytes());
    }
};

pub const URL = struct {
    scheme: []const u8 = "",
    host: []const u8 = "",
    path: []const u8 = "",
    raw_query: []const u8 = "",
    fragment: []const u8 = "",

    pub fn query(self: *const URL, allocator: Allocator) !Values {
        var v = Values.init(allocator);
        errdefer v.deinit();

        var it = std.mem.splitScalar(u8, self.raw_query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            var key: []const u8 = pair;
            var val: []const u8 = "";
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                key = pair[0..eq];
                val = pair[eq + 1 ..];
            }
            const unescaped_k = try queryUnescape(allocator, key);
            defer allocator.free(unescaped_k);
            const unescaped_v = try queryUnescape(allocator, val);
            defer allocator.free(unescaped_v);
            try v.add(unescaped_k, unescaped_v);
        }
        return v;
    }

    pub fn string(self: *const URL, allocator: Allocator) Allocator.Error![]u8 {
        var buf = bytes.Buffer.init(allocator);
        defer buf.deinit();

        if (self.scheme.len > 0) {
            _ = try buf.write(self.scheme);
            _ = try buf.write("://");
        }
        if (self.host.len > 0) {
            _ = try buf.write(self.host);
        }
        if (self.path.len > 0) {
            _ = try buf.write(self.path);
        }
        if (self.raw_query.len > 0) {
            try buf.writeByte('?');
            _ = try buf.write(self.raw_query);
        }
        if (self.fragment.len > 0) {
            try buf.writeByte('#');
            _ = try buf.write(self.fragment);
        }
        return try allocator.dupe(u8, buf.bytes());
    }
};

/// Parse parses raw_url into a URL structure.
pub fn parse(raw_url: []const u8) Error!URL {
    var u = URL{};
    var rest = raw_url;

    // Fragment
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        u.fragment = rest[hash + 1 ..];
        rest = rest[0..hash];
    }

    // Query
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        u.raw_query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    // Scheme
    if (std.mem.indexOf(u8, rest, "://")) |scheme_end| {
        u.scheme = rest[0..scheme_end];
        rest = rest[scheme_end + 3 ..];

        // Host and Path
        if (std.mem.indexOfScalar(u8, rest, '/')) |path_start| {
            u.host = rest[0..path_start];
            u.path = rest[path_start..];
        } else {
            u.host = rest;
            u.path = "";
        }
    } else {
        u.path = rest;
    }

    return u;
}

test "net.url escape and unescape" {
    const testing = std.testing;

    const raw = "hello world & foo=bar/baz";
    const q_esc = try queryEscape(testing.allocator, raw);
    defer testing.allocator.free(q_esc);
    try testing.expectEqualStrings("hello+world+%26+foo%3Dbar%2Fbaz", q_esc);

    const q_unesc = try queryUnescape(testing.allocator, q_esc);
    defer testing.allocator.free(q_unesc);
    try testing.expectEqualStrings(raw, q_unesc);
}

test "net.url parse diverse forms" {
    const testing = std.testing;

    const UrlTestCase = struct {
        raw: []const u8,
        scheme: []const u8,
        host: []const u8,
        path: []const u8,
        raw_query: []const u8,
        fragment: []const u8,
    };

    const cases = [_]UrlTestCase{
        .{
            .raw = "http://www.google.com",
            .scheme = "http",
            .host = "www.google.com",
            .path = "",
            .raw_query = "",
            .fragment = "",
        },
        .{
            .raw = "http://www.google.com/",
            .scheme = "http",
            .host = "www.google.com",
            .path = "/",
            .raw_query = "",
            .fragment = "",
        },
        .{
            .raw = "http://localhost:8080/v1/api?foo=bar#section",
            .scheme = "http",
            .host = "localhost:8080",
            .path = "/v1/api",
            .raw_query = "foo=bar",
            .fragment = "section",
        },
        .{
            .raw = "https://pkg.go.dev/std?q=bufio#Index",
            .scheme = "https",
            .host = "pkg.go.dev",
            .path = "/std",
            .raw_query = "q=bufio",
            .fragment = "Index",
        },
        .{
            .raw = "/relative/path/only?k=v",
            .scheme = "",
            .host = "",
            .path = "/relative/path/only",
            .raw_query = "k=v",
            .fragment = "",
        },
    };

    for (cases) |c| {
        const u = try parse(c.raw);
        try testing.expectEqualStrings(c.scheme, u.scheme);
        try testing.expectEqualStrings(c.host, u.host);
        try testing.expectEqualStrings(c.path, u.path);
        try testing.expectEqualStrings(c.raw_query, u.raw_query);
        try testing.expectEqualStrings(c.fragment, u.fragment);
    }
}

test "net.url Values multi-value encode roundtrip" {
    const testing = std.testing;

    var v = Values.init(testing.allocator);
    defer v.deinit();

    try v.add("tag", "zig");
    try v.add("tag", "golang");
    try v.add("author", "jiacai");

    const encoded = try v.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings("tag=zig&tag=golang&author=jiacai", encoded);
}
