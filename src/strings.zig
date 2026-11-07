const std = @import("std");
const bytes = @import("bytes.zig");
const Allocator = std.mem.Allocator;

pub const builder_mod = @import("strings/builder.zig");
pub const reader_mod = @import("strings/reader.zig");

pub const Builder = builder_mod.Builder;
pub const Reader = reader_mod.Reader;

pub fn contains(s: []const u8, substr: []const u8) bool {
    return std.mem.indexOf(u8, s, substr) != null;
}

pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

pub fn hasSuffix(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

pub fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn trim(s: []const u8, cutset: []const u8) []const u8 {
    return std.mem.trim(u8, s, cutset);
}

pub fn trimPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (hasPrefix(s, prefix)) {
        return s[prefix.len..];
    }
    return s;
}

pub fn trimSuffix(s: []const u8, suffix: []const u8) []const u8 {
    if (hasSuffix(s, suffix)) {
        return s[0 .. s.len - suffix.len];
    }
    return s;
}

pub fn split(allocator: Allocator, s: []const u8, sep: []const u8) Allocator.Error![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq_len, s.len);
            try list.append(allocator, s[i..end]);
            i = end;
        }
        return list.toOwnedSlice(allocator);
    }

    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |part| {
        try list.append(allocator, part);
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeSplit(allocator: Allocator, parts: [][]const u8) void {
    allocator.free(parts);
}

pub fn join(allocator: Allocator, elems: []const []const u8, sep: []const u8) Allocator.Error![]u8 {
    if (elems.len == 0) return try allocator.alloc(u8, 0);
    if (elems.len == 1) return try allocator.dupe(u8, elems[0]);

    var total_len: usize = 0;
    for (elems) |e| {
        total_len += e.len;
    }
    total_len += sep.len * (elems.len - 1);

    var res = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (elems, 0..) |e, idx| {
        if (idx > 0) {
            @memcpy(res[cursor .. cursor + sep.len], sep);
            cursor += sep.len;
        }
        @memcpy(res[cursor .. cursor + e.len], e);
        cursor += e.len;
    }
    return res;
}

pub fn fields(allocator: Allocator, s: []const u8) Allocator.Error![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |token| {
        try list.append(allocator, token);
    }
    return list.toOwnedSlice(allocator);
}

pub fn replaceAll(allocator: Allocator, s: []const u8, old: []const u8, new: []const u8) Allocator.Error![]u8 {
    if (old.len == 0 or s.len == 0) {
        return try allocator.dupe(u8, s);
    }

    var b = Builder.init(allocator);
    defer b.deinit();

    var cursor: usize = 0;
    while (cursor < s.len) {
        if (std.mem.startsWith(u8, s[cursor..], old)) {
            _ = try b.writeString(new);
            cursor += old.len;
        } else {
            try b.writeByte(s[cursor]);
            cursor += 1;
        }
    }
    return try allocator.dupe(u8, b.string());
}

pub fn repeat(allocator: Allocator, s: []const u8, count: usize) Allocator.Error![]u8 {
    return bytes.repeat(allocator, s, count);
}

pub fn toLower(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const res = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        res[i] = std.ascii.toLower(c);
    }
    return res;
}

pub fn toUpper(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const res = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        res[i] = std.ascii.toUpper(c);
    }
    return res;
}

test "strings utility functions" {
    const testing = std.testing;

    try testing.expect(contains("hello world", "world"));
    try testing.expect(hasPrefix("https://zig.guide", "https://"));
    try testing.expect(hasSuffix("archive.tar.gz", ".gz"));

    try testing.expectEqualStrings("foo", trimSpace("  \t foo \n"));
    try testing.expectEqualStrings("test.txt", trimPrefix("test.txt", "sub/"));
    try testing.expectEqualStrings(".txt", trimPrefix("sub/test.txt", "sub/test"));

    const parts = try split(testing.allocator, "a,b,c", ",");
    defer freeSplit(testing.allocator, parts);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("a", parts[0]);
    try testing.expectEqualStrings("b", parts[1]);
    try testing.expectEqualStrings("c", parts[2]);

    const joined = try join(testing.allocator, parts, " - ");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("a - b - c", joined);

    const fds = try fields(testing.allocator, "  one\ttwo \n three   ");
    defer freeSplit(testing.allocator, fds);
    try testing.expectEqual(@as(usize, 3), fds.len);
    try testing.expectEqualStrings("one", fds[0]);
    try testing.expectEqualStrings("two", fds[1]);
    try testing.expectEqualStrings("three", fds[2]);

    const repl = try replaceAll(testing.allocator, "banana", "a", "o");
    defer testing.allocator.free(repl);
    try testing.expectEqualStrings("bonono", repl);

    const up = try toUpper(testing.allocator, "zig lang");
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("ZIG LANG", up);
}
