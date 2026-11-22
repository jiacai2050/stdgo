//! Package suffixarray implements substring search in logarithmic time using
//! an in-memory suffix array,
//! conforming to Go's index/suffixarray package.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Index = struct {
    allocator: Allocator,
    data: []const u8,
    sa: []usize,

    pub fn create(allocator: Allocator, data: []const u8) !*Index {
        const self = try allocator.create(Index);
        errdefer allocator.destroy(self);

        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);

        const sa = try allocator.alloc(usize, owned_data.len);
        errdefer allocator.free(sa);

        for (0..sa.len) |i| {
            sa[i] = i;
        }

        // Sort suffixes lexicographically
        const Context = struct {
            d: []const u8,
            pub fn less(ctx: @This(), a: usize, b: usize) bool {
                const s_a = ctx.d[a..];
                const s_b = ctx.d[b..];
                return std.mem.order(u8, s_a, s_b) == .lt;
            }
        };

        std.mem.sort(usize, sa, Context{ .d = owned_data }, Context.less);

        self.* = .{
            .allocator = allocator,
            .data = owned_data,
            .sa = sa,
        };

        return self;
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.sa);
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    pub fn bytes(self: *const Index) []const u8 {
        return self.data;
    }

    /// Lookup returns an unsorted or sorted slice of offsets where the byte slice s
    /// appears in data.
    /// If n < 0, all occurrences are returned. If n >= 0, at most n occurrences are returned.
    /// The returned offsets are sorted in ascending order.
    pub fn lookup(self: *const Index, s: []const u8, n: isize, allocator: Allocator) ![]usize {
        if (s.len == 0 or self.data.len == 0) return try allocator.alloc(usize, 0);

        // Find lower bound: first index where suffix >= s
        var low: usize = 0;
        var high: usize = self.sa.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const suffix = self.data[self.sa[mid]..];
            const cmp_len = @min(suffix.len, s.len);
            const ord = std.mem.order(u8, suffix[0..cmp_len], s[0..cmp_len]);

            if (ord == .lt or (ord == .eq and suffix.len < s.len)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        const start_idx = low;

        // Find upper bound: first index where suffix > s prefix
        low = start_idx;
        high = self.sa.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const suffix = self.data[self.sa[mid]..];
            const cmp_len = @min(suffix.len, s.len);
            const ord = std.mem.order(u8, suffix[0..cmp_len], s[0..cmp_len]);

            const is_mismatch = ord == .gt or
                (ord == .eq and suffix.len >= s.len and !std.mem.startsWith(u8, suffix, s));
            if (is_mismatch) {
                high = mid;
            } else if (ord == .eq and std.mem.startsWith(u8, suffix, s)) {
                low = mid + 1;
            } else {
                low = mid + 1;
            }
        }
        const end_idx = low;

        if (start_idx >= end_idx) {
            return try allocator.alloc(usize, 0);
        }

        const total_matches = end_idx - start_idx;
        const count = if (n < 0) total_matches else @min(@as(usize, @intCast(n)), total_matches);

        const result = try allocator.alloc(usize, count);
        @memcpy(result, self.sa[start_idx .. start_idx + count]);

        // Return offsets sorted in ascending index order
        std.mem.sort(usize, result, {}, struct {
            fn less(_: void, a: usize, b: usize) bool {
                return a < b;
            }
        }.less);

        return result;
    }

    /// FindAllIndex finds all occurrence indices of pattern in data.
    pub fn findAllIndex(self: *const Index, pattern: []const u8, allocator: Allocator) ![]usize {
        return self.lookup(pattern, -1, allocator);
    }
};

/// New creates a new Index for data.
pub fn new(allocator: Allocator, data: []const u8) !*Index {
    return Index.create(allocator, data);
}

test "index/suffixarray: create, lookup, and findAllIndex" {
    const testing = std.testing;

    const source = "banana panama bandana banana";
    var idx = try new(testing.allocator, source);
    defer idx.deinit();

    // 1. Search for "banana" (appears at index 0 and index 22)
    const matches = try idx.lookup("banana", -1, testing.allocator);
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqual(@as(usize, 0), matches[0]);
    try testing.expectEqual(@as(usize, 22), matches[1]);

    // 2. Search for "ana" (appears in banana: 1, 3; panama: 1; bandana: 16; banana: 23, 25)
    const ana_matches = try idx.findAllIndex("ana", testing.allocator);
    defer testing.allocator.free(ana_matches);

    try testing.expectEqual(@as(usize, 6), ana_matches.len);
    try testing.expectEqual(@as(usize, 1), ana_matches[0]);
    try testing.expectEqual(@as(usize, 3), ana_matches[1]);
    try testing.expectEqual(@as(usize, 8), ana_matches[2]); // p-ana-ma
    try testing.expectEqual(@as(usize, 18), ana_matches[3]); // band-ana
    try testing.expectEqual(@as(usize, 23), ana_matches[4]); // ban-ana
    try testing.expectEqual(@as(usize, 25), ana_matches[5]); // banan-a

    // 3. Limit search count n = 1
    const one_match = try idx.lookup("banana", 1, testing.allocator);
    defer testing.allocator.free(one_match);
    try testing.expectEqual(@as(usize, 1), one_match.len);

    // 4. Non-existent substring
    const none_matches = try idx.lookup("orange", -1, testing.allocator);
    defer testing.allocator.free(none_matches);
    try testing.expectEqual(@as(usize, 0), none_matches.len);
}
