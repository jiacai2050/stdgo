//! Example demonstrating stdgo compress package:
//! 1. compress.gzip: writing Gzip file with header (filename, mtime)
//! 2. compress.gzip: reading Gzip stream, verifying CRC32 and metadata

const std = @import("std");
const stdgo = @import("stdgo");
const gzip = stdgo.compress.gzip;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: compress (gzip) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Write Gzip compressed payload
    // -------------------------------------------------------------
    var compressed_buf = bytes.Buffer.init(gpa);
    defer compressed_buf.deinit();

    const original_text = "stdgo brings Go standard library ergonomics and compression to Zig 0.17!";

    var gzip_w = try gzip.Writer.init(compressed_buf.writer(), .{
        .name = "gopher_doc.txt",
        .mod_time = 1700000000,
        .os = 255, // unknown OS
    });

    _ = try gzip_w.write(original_text);
    try gzip_w.close();

    std.debug.print("1. Gzip Compression:\n", .{});
    std.debug.print("   Original text: \"{s}\" ({d} bytes)\n", .{ original_text, original_text.len });
    std.debug.print("   Compressed archive size: {d} bytes\n\n", .{compressed_buf.len()});

    // -------------------------------------------------------------
    // 2. Read Gzip header & payload
    // -------------------------------------------------------------
    std.debug.print("2. Gzip Decompression & Header parsing:\n", .{});

    var r_buf = bytes.Reader.init(compressed_buf.bytes());
    var gzip_r = try gzip.Reader.init(r_buf.reader());

    std.debug.print("   Header Name:     \"{s}\"\n", .{gzip_r.header.name});
    std.debug.print("   Header Mod Time: {d}\n", .{gzip_r.header.mod_time});

    const decompressed = try gzip_r.readAllAlloc(gpa);
    defer gpa.free(decompressed);

    std.debug.print("   Decompressed Content: \"{s}\"\n", .{decompressed});
    std.debug.print("   Integrity Verified: {any}\n", .{std.mem.eql(u8, original_text, decompressed)});

    std.debug.print("\n=== compress demo completed successfully! ===\n", .{});
}
