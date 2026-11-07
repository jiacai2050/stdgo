const std = @import("std");
const assert = std.debug.assert;

/// Rand is a deterministic pseudo-random number generator implementing
/// Go's math/rand semantics using the SplitMix64 generator.
///
/// It requires zero OS syscalls, no global state, and no implicit I/O.
pub const Rand = struct {
    state: u64,

    pub fn init(seed_val: u64) Rand {
        return .{ .state = seed_val };
    }

    pub fn seed(self: *Rand, seed_val: u64) void {
        self.state = seed_val;
    }

    /// Returns a pseudo-random 64-bit value as a uint64.
    pub fn uint64(self: *Rand) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// Returns a pseudo-random 32-bit value as a uint32.
    pub fn uint32(self: *Rand) u32 {
        return @truncate(self.uint64() >> 32);
    }

    /// Returns a non-negative pseudo-random 63-bit integer as an i64.
    pub fn int63(self: *Rand) i64 {
        const u = self.uint64();
        return @intCast(u & 0x7FFFFFFFFFFFFFFF);
    }

    /// Returns, as an i64, a non-negative pseudo-random number in the half-open interval [0,n).
    pub fn intn(self: *Rand, n: i64) i64 {
        assert(n > 0);
        const max: u64 = @intCast(n);
        const u = self.uint64();
        const x: u128 = @as(u128, u) * @as(u128, max);
        return @intCast(x >> 64);
    }

    /// Returns, as a f64, a pseudo-random number in the half-open interval [0.0,1.0).
    pub fn float64(self: *Rand) f64 {
        const f = @as(f64, @floatFromInt(self.uint64() >> 11));
        return f / (1 << 53);
    }

    /// Shuffle pseudo-randomizes the order of elements using Fisher-Yates algorithm.
    pub fn shuffle(self: *Rand, comptime T: type, slice: []T) void {
        var i = slice.len;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(self.intn(@intCast(i + 1)));
            const tmp = slice[i];
            slice[i] = slice[j];
            slice[j] = tmp;
        }
    }
};

test "math/rand deterministic sequence" {
    const testing = std.testing;

    var r1 = Rand.init(42);
    var r2 = Rand.init(42);

    try testing.expectEqual(r1.uint64(), r2.uint64());
    try testing.expectEqual(r1.intn(100), r2.intn(100));
    try testing.expectEqual(r1.float64(), r2.float64());

    for (0..100) |_| {
        const v = r1.intn(50);
        try testing.expect(v >= 0 and v < 50);

        const f = r1.float64();
        try testing.expect(f >= 0.0 and f < 1.0);
    }
}

test "math/rand shuffle" {
    const testing = std.testing;

    var r = Rand.init(12345);
    var items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    r.shuffle(i32, &items);

    var sum: i32 = 0;
    for (items) |x| sum += x;
    try testing.expectEqual(@as(i32, 55), sum);
}
