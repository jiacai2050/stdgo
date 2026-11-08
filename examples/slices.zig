//! Example demonstrating stdgo slices package:
//! 1. sort & isSorted: Generic slice sorting
//! 2. binarySearch: O(log n) lookups with exact or insertion index
//! 3. reverse: In-place slice reversing
//! 4. compact: In-place deduplication of consecutive equal elements
//! 5. contains & index: Element search

const std = @import("std");
const stdgo = @import("stdgo");
const slices = stdgo.slices;

fn intAscending(a: i32, b: i32) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("=== stdgo: slices (Go 1.21 generic slice algorithms) Example ===\n\n", .{});

    var data = [_]i32{ 73, 14, 88, 3, 42, 19, 5 };
    std.debug.print("1. Original slice:   {any}\n", .{data});

    // Sort
    slices.sort(i32, &data, intAscending);
    std.debug.print("   Sorted slice:     {any}\n", .{data});
    std.debug.print("   isSorted:         {any}\n\n", .{slices.isSorted(i32, &data, intAscending)});

    // Binary search
    std.debug.print("2. Binary Search in sorted slice:\n", .{});
    const targets = [_]i32{ 42, 15 };
    for (targets) |target| {
        const res = slices.binarySearch(i32, &data, target, intAscending);
        if (res.found) {
            std.debug.print("   binarySearch({d}) -> Found at index {d}\n", .{ target, res.index });
        } else {
            std.debug.print("   binarySearch({d}) -> Not found, insertion index: {d}\n", .{ target, res.index });
        }
    }

    // Reverse
    slices.reverse(i32, &data);
    std.debug.print("\n3. Reversed slice:   {any}\n\n", .{data});

    // Compact consecutive duplicates
    var dupes = [_]i32{ 10, 10, 20, 30, 30, 30, 40, 50, 50 };
    std.debug.print("4. Deduplicating consecutive runs with compact:\n", .{});
    std.debug.print("   Before compact:   {any}\n", .{dupes});
    const new_len = slices.compact(i32, &dupes);
    std.debug.print("   After compact:    {any} (length: {d})\n", .{ dupes[0..new_len], new_len });

    // Contains & Index
    std.debug.print("\n5. contains & index:\n", .{});
    std.debug.print("   contains(40): {any}, index(40): {any}\n", .{
        slices.contains(i32, dupes[0..new_len], 40),
        slices.index(i32, dupes[0..new_len], 40),
    });

    std.debug.print("\n=== slices demo completed successfully! ===\n", .{});
}
