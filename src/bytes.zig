const std = @import("std");

pub const Buffer = @import("bytes/buffer.zig").Buffer;
pub const Reader = @import("bytes/reader.zig").Reader;

/// Equal reports whether a and b are the same length and contain the same bytes.
pub fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Compare returns an integer comparing two byte slices lexicographically.
/// The result will be 0 if a == b, -1 if a < b, and +1 if a > b.
pub fn compare(a: []const u8, b: []const u8) i8 {
    const order = std.mem.order(u8, a, b);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// HasPrefix tests whether the byte slice s begins with prefix.
pub fn hasPrefix(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

/// HasSuffix tests whether the byte slice s ends with suffix.
pub fn hasSuffix(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

/// Index returns the index of the first instance of sep in s, or null if sep is not present in s.
pub fn index(s: []const u8, sep: []const u8) ?usize {
    return std.mem.indexOf(u8, s, sep);
}

/// LastIndex returns the index of the last instance of sep in s, or null if sep is not present in s.
pub fn lastIndex(s: []const u8, sep: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, s, sep);
}

/// Contains reports whether subslice is within b.
pub fn contains(b: []const u8, subslice: []const u8) bool {
    return index(b, subslice) != null;
}

/// Count counts the number of non-overlapping instances of sep in s.
pub fn count(s: []const u8, sep: []const u8) usize {
    if (sep.len == 0) {
        return s.len + 1;
    }
    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor <= s.len - sep.len) {
        if (std.mem.eql(u8, s[cursor .. cursor + sep.len], sep)) {
            total += 1;
            cursor += sep.len;
        } else {
            cursor += 1;
        }
    }
    return total;
}

/// Repeat returns a new byte slice consisting of count copies of b.
pub fn repeat(allocator: std.mem.Allocator, b: []const u8, n: usize) std.mem.Allocator.Error![]u8 {
    if (n == 0 or b.len == 0) {
        return try allocator.alloc(u8, 0);
    }
    const total_len = b.len * n;
    const res = try allocator.alloc(u8, total_len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(res[i * b.len .. (i + 1) * b.len], b);
    }
    return res;
}

test "bytes utility functions" {
    const testing = std.testing;

    try testing.expect(equal("abc", "abc"));
    try testing.expect(!equal("abc", "abd"));

    try testing.expectEqual(@as(i8, 0), compare("abc", "abc"));
    try testing.expectEqual(@as(i8, -1), compare("abc", "abd"));
    try testing.expectEqual(@as(i8, 1), compare("abd", "abc"));

    try testing.expect(hasPrefix("golang", "go"));
    try testing.expect(!hasPrefix("golang", "lang"));

    try testing.expect(hasSuffix("golang", "lang"));
    try testing.expect(!hasSuffix("golang", "go"));

    try testing.expectEqual(@as(?usize, 2), index("banana", "nan"));
    try testing.expectEqual(@as(?usize, null), index("banana", "xyz"));

    try testing.expectEqual(@as(?usize, 5), lastIndex("banana", "a"));

    try testing.expect(contains("hello world", "world"));
    try testing.expect(!contains("hello world", "zig"));

    try testing.expectEqual(@as(usize, 3), count("banana", "a"));
    try testing.expectEqual(@as(usize, 2), count("aaaa", "aa"));

    const rep = try repeat(testing.allocator, "go", 3);
    defer testing.allocator.free(rep);
    try testing.expectEqualStrings("gogogo", rep);
}
