//! Example demonstrating stdgo path & path.filepath packages:
//! 1. path.match: Shell glob pattern matching (*, ?, [a-z])
//! 2. path.filepath: OS-specific separator and path matching

const std = @import("std");
const stdgo = @import("stdgo");
const path = stdgo.path;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("=== stdgo: path & filepath Pattern Matching Example ===\n\n", .{});

    std.debug.print("1. Filepath separator on this platform: '{c}'\n\n", .{path.filepath.separator});

    // Patterns to test
    const test_cases = [_]struct { pattern: []const u8, filename: []const u8 }{
        .{ .pattern = "*.zig", .filename = "main.zig" },
        .{ .pattern = "*.zig", .filename = "main.c" },
        .{ .pattern = "test_??.txt", .filename = "test_01.txt" },
        .{ .pattern = "test_??.txt", .filename = "test_999.txt" },
        .{ .pattern = "img_[0-9].png", .filename = "img_5.png" },
        .{ .pattern = "img_[0-9].png", .filename = "img_a.png" },
        .{ .pattern = "v[0-9].[0-9].[0-9]", .filename = "v1.2.3" },
        .{ .pattern = "release-[a-z]*", .filename = "release-beta2" },
    };

    std.debug.print("2. Glob Pattern Matching:\n", .{});
    for (test_cases) |tc| {
        const is_matched = try path.match(tc.pattern, tc.filename);
        std.debug.print("   match(\"{s}\", \"{s}\") -> {any}\n", .{ tc.pattern, tc.filename, is_matched });
    }

    std.debug.print("\n=== path demo completed successfully! ===\n", .{});
}
