//! Example demonstrating stdgo hash & math.rand packages:
//! 1. math.rand.Rand: Seeded pseudo-random number generator
//! 2. hash.Hash: VTable interface for streaming hash digests

const std = @import("std");
const stdgo = @import("stdgo");
const rand = stdgo.math.rand;
const crypto = stdgo.crypto;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("=== stdgo: math.rand & hash Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. math.rand: Deterministic PRNG
    // -------------------------------------------------------------
    std.debug.print("1. math.rand.Rand (Deterministic SplitMix64 PRNG):\n", .{});
    var r = rand.Rand.init(20261108);

    std.debug.print("   uint32():  0x{X:0>8}\n", .{r.uint32()});
    std.debug.print("   uint64():  0x{X:0>16}\n", .{r.uint64()});
    std.debug.print("   intn(100): {d}\n", .{r.intn(100)});
    std.debug.print("   float64(): {d:.6}\n\n", .{r.float64()});

    // Shuffling a deck
    std.debug.print("   Random integers between 1 and 10:\n   [ ", .{});
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{r.intn(10) + 1});
    }
    std.debug.print(" ]\n\n", .{});

    // -------------------------------------------------------------
    // 2. hash.Hash: Streaming interface
    // -------------------------------------------------------------
    std.debug.print("2. hash.Hash generic VTable interface:\n", .{});

    var sha_digest = crypto.sha256.Digest.init();
    const h = sha_digest.hash();

    std.debug.print("   Hash block size: {d} bytes\n", .{h.blockSize()});
    std.debug.print("   Hash output size: {d} bytes\n", .{h.size()});

    _ = try h.write("Chunk 1: Hello from stdgo. ");
    _ = try h.write("Chunk 2: Streaming through Hash VTable.");

    var sum_buf: [32]u8 = undefined;
    _ = h.sum(&sum_buf);
    std.debug.print("   Computed Digest: {s}\n", .{std.fmt.bytesToHex(sum_buf, .lower)});

    std.debug.print("\n=== hash & math demo completed successfully! ===\n", .{});
}
