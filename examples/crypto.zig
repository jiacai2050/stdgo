//! Example demonstrating stdgo crypto package:
//! 1. crypto.sha256: One-shot Sum256 and streaming Digest
//! 2. crypto.md5: Sum calculation
//! (See also examples/hmac.zig for HMAC-SHA256 & HMAC-MD5)

const std = @import("std");
const stdgo = @import("stdgo");
const crypto = stdgo.crypto;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("=== stdgo: crypto (SHA256 & MD5) Example ===\n\n", .{});

    const payload = "The quick brown fox jumps over the lazy dog";
    std.debug.print("Input Payload: \"{s}\"\n\n", .{payload});

    // -------------------------------------------------------------
    // 1. SHA-256 One-shot & Streaming Digest
    // -------------------------------------------------------------
    std.debug.print("1. SHA-256:\n", .{});
    const sha_sum = crypto.sha256.Sum256(payload);
    std.debug.print("   One-shot Sum256: {s}\n", .{std.fmt.bytesToHex(sha_sum, .lower)});

    // Streaming writer
    var d = crypto.sha256.Digest.init();
    _ = try d.write("The quick brown fox ");
    _ = try d.write("jumps over the lazy dog");

    var stream_sum: [crypto.sha256.size]u8 = undefined;
    d.sum(&stream_sum);
    std.debug.print("   Streaming Digest: {s}\n", .{std.fmt.bytesToHex(stream_sum, .lower)});
    std.debug.print("   Matches: {any}\n\n", .{std.mem.eql(u8, &sha_sum, &stream_sum)});

    // -------------------------------------------------------------
    // 2. MD5 Sum
    // -------------------------------------------------------------
    std.debug.print("2. MD5:\n", .{});
    const md5_sum = crypto.md5.Sum(payload);
    std.debug.print("   MD5 Sum: {s}\n", .{std.fmt.bytesToHex(md5_sum, .lower)});

    std.debug.print("\n=== crypto demo completed successfully! ===\n", .{});
}
