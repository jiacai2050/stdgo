//! Example demonstrating stdgo bytes and strings packages:
//! 1. bytes.Buffer: dynamic byte buffer with sliding window & io.Reader/Writer
//! 2. strings.Builder: zero-allocation string accumulation
//! 3. strings & bytes utility functions: Trim, Split, HasPrefix, Contains

const std = @import("std");
const stdgo = @import("stdgo");
const bytes = stdgo.bytes;
const strings = stdgo.strings;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: bytes & strings Manipulation Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. bytes.Buffer: Read/Write/Reset
    // -------------------------------------------------------------
    std.debug.print("1. bytes.Buffer dynamic manipulation:\n", .{});
    var buf = bytes.Buffer.init(gpa);
    defer buf.deinit();

    _ = try buf.write("Packet #100; ");
    _ = try buf.write("Status=READY; ");
    _ = try buf.write("Latency=12ms\n");

    std.debug.print("   Buffer content: {s}", .{buf.string()});
    std.debug.print("   Buffer length: {d} bytes, cap: {d}\n\n", .{ buf.len(), buf.cap() });

    // -------------------------------------------------------------
    // 2. strings.Builder: High performance string builder
    // -------------------------------------------------------------
    std.debug.print("2. strings.Builder:\n", .{});
    var sb = strings.Builder.init(gpa);
    defer sb.deinit();

    _ = try sb.writeString("SELECT * FROM users WHERE ");
    _ = try sb.writeString("active = true AND role = '");
    _ = try sb.writeString("admin");
    try sb.writeByte('\'');

    std.debug.print("   Constructed Query: \"{s}\"\n", .{sb.string()});
    std.debug.print("   Length: {d}\n\n", .{sb.len()});

    // -------------------------------------------------------------
    // 3. String & Byte helpers
    // -------------------------------------------------------------
    std.debug.print("3. String & Byte utilities:\n", .{});
    const url_path = "   /api/v2/users/info.json   ";
    const trimmed = strings.trimSpace(url_path);
    std.debug.print("   TrimSpace: \"{s}\" -> \"{s}\"\n", .{ url_path, trimmed });

    const without_prefix = strings.trimPrefix(trimmed, "/api/v2");
    std.debug.print("   TrimPrefix('/api/v2'): \"{s}\"\n", .{without_prefix});

    const without_suffix = strings.trimSuffix(without_prefix, ".json");
    std.debug.print("   TrimSuffix('.json'): \"{s}\"\n", .{without_suffix});

    // Split
    const csv_fields = "name,email,role,created_at";
    const parts = try strings.split(gpa, csv_fields, ",");
    defer gpa.free(parts);

    std.debug.print("   Split(\"{s}\", \",\"): [ ", .{csv_fields});
    for (parts, 0..) |part, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{part});
    }
    std.debug.print(" ]\n", .{});

    // Contains & HasPrefix
    std.debug.print("   strings.contains(\"stdgo\", \"go\"): {any}\n", .{strings.contains("stdgo", "go")});
    std.debug.print("   bytes.hasPrefix(\"0xDEADBEEF\", \"0x\"): {any}\n", .{bytes.hasPrefix("0xDEADBEEF", "0x")});

    std.debug.print("\n=== bytes & strings demo completed successfully! ===\n", .{});
}
