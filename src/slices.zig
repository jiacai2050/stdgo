const std = @import("std");
const Allocator = std.mem.Allocator;

/// Equal reports whether two slices are equal: the same length and all
/// elements equal.
pub fn equal(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

/// Index returns the index of the first occurrence of v in s, or null if not present.
pub fn index(comptime T: type, s: []const T, v: T) ?usize {
    for (s, 0..) |item, i| {
        if (std.meta.eql(item, v)) return i;
    }
    return null;
}

/// Contains reports whether v is present in s.
pub fn contains(comptime T: type, s: []const T, v: T) bool {
    return index(T, s, v) != null;
}

/// Reverse reverses the elements of the slice in place.
pub fn reverse(comptime T: type, s: []T) void {
    if (s.len <= 1) return;
    var i: usize = 0;
    var j: usize = s.len - 1;
    while (i < j) {
        std.mem.swap(T, &s[i], &s[j]);
        i += 1;
        j -= 1;
    }
}

/// Clone returns a copy of the slice.
pub fn clone(comptime T: type, allocator: Allocator, s: []const T) Allocator.Error![]T {
    return allocator.dupe(T, s);
}

/// Compact replaces consecutive runs of equal elements with a single copy.
/// Returns the length of the compacted slice.
pub fn compact(comptime T: type, s: []T) usize {
    if (s.len <= 1) return s.len;
    var k: usize = 1;
    for (s[1..]) |item| {
        if (!std.meta.eql(item, s[k - 1])) {
            s[k] = item;
            k += 1;
        }
    }
    return k;
}

/// Sort sorts the slice in place according to lessFn.
pub fn sort(comptime T: type, s: []T, comptime lessFn: fn (a: T, b: T) bool) void {
    std.mem.sort(T, s, {}, struct {
        fn less(_: void, a: T, b: T) bool {
            return lessFn(a, b);
        }
    }.less);
}

/// IsSorted reports whether data is sorted.
pub fn isSorted(comptime T: type, s: []const T, comptime lessFn: fn (a: T, b: T) bool) bool {
    if (s.len <= 1) return true;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (lessFn(s[i], s[i - 1])) return false;
    }
    return true;
}

pub const BinarySearchResult = struct {
    found: bool,
    index: usize,
};

/// BinarySearch searches for target in a sorted slice.
pub fn binarySearch(comptime T: type, s: []const T, target: T, comptime lessFn: fn (a: T, b: T) bool) BinarySearchResult {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lessFn(s[mid], target)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const found = (lo < s.len and !lessFn(target, s[lo]));
    return .{ .found = found, .index = lo };
}

test "slices Go 1.21 generic slice utilities" {
    const testing = std.testing;

    var nums = [_]i32{ 5, 2, 8, 1, 9, 3 };

    // Sort
    const intLess = struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less;

    sort(i32, &nums, intLess);
    try testing.expect(isSorted(i32, &nums, intLess));
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 5, 8, 9 }, &nums);

    // BinarySearch
    const search_8 = binarySearch(i32, &nums, 8, intLess);
    try testing.expect(search_8.found);
    try testing.expectEqual(@as(usize, 4), search_8.index);

    const search_4 = binarySearch(i32, &nums, 4, intLess);
    try testing.expect(!search_4.found);
    try testing.expectEqual(@as(usize, 3), search_4.index); // insertion point

    // Reverse
    reverse(i32, &nums);
    try testing.expectEqualSlices(i32, &[_]i32{ 9, 8, 5, 3, 2, 1 }, &nums);

    // Contains & Index
    try testing.expect(contains(i32, &nums, 5));
    try testing.expectEqual(@as(?usize, 2), index(i32, &nums, 5));
    try testing.expect(!contains(i32, &nums, 99));

    // Compact
    var dupes = [_]i32{ 1, 1, 2, 2, 2, 3, 4, 4 };
    const comp_len = compact(i32, &dupes);
    try testing.expectEqual(@as(usize, 4), comp_len);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4 }, dupes[0..comp_len]);

    // Clone
    const cloned = try clone(i32, testing.allocator, dupes[0..comp_len]);
    defer testing.allocator.free(cloned);
    try testing.expect(equal(i32, dupes[0..comp_len], cloned));
}
