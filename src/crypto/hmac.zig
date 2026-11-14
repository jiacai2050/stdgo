const std = @import("std");
const hash_mod = @import("../hash/hash.zig");
const Hash = hash_mod.Hash;
const io = @import("../io.zig");

/// HMAC implements Keyed-Hash Message Authentication Code (RFC 2104).
pub const Hmac = struct {
    inner_hash: Hash,
    outer_hash: Hash,
    ipad: [128]u8,
    opad: [128]u8,
    block_size: usize,
    hash_size: usize,
    writer_inst: std.Io.Writer = undefined,

    /// New initializes an HMAC using the provided Hash instances for inner and outer hashing.
    /// The caller provides two Hash instances (inner and outer) initialized to the same algorithm,
    /// and the secret key.
    pub fn init(inner_h: Hash, outer_h: Hash, key: []const u8) Hmac {
        const b_size = inner_h.blockSize();
        const h_size = inner_h.size();
        std.debug.assert(b_size <= 128);

        var self = Hmac{
            .inner_hash = inner_h,
            .outer_hash = outer_h,
            .ipad = undefined,
            .opad = undefined,
            .block_size = b_size,
            .hash_size = h_size,
        };

        var key_buf: [128]u8 = @splat(0);
        if (key.len > b_size) {
            // Key is longer than block size: key = hash(key)
            inner_h.reset();
            _ = inner_h.write(key) catch {};
            const sum_slice = inner_h.sum(key_buf[0..h_size]);
            _ = sum_slice;
            inner_h.reset();
        } else {
            @memcpy(key_buf[0..key.len], key);
        }

        for (0..b_size) |i| {
            self.ipad[i] = key_buf[i] ^ 0x36;
            self.opad[i] = key_buf[i] ^ 0x5c;
        }

        self.reset();
        return self;
    }

    /// Reset resets the HMAC state to start processing a new message with the same key.
    pub fn reset(self: *Hmac) void {
        self.inner_hash.reset();
        _ = self.inner_hash.write(self.ipad[0..self.block_size]) catch {};
    }

    /// Write writes message data to the HMAC.
    pub fn write(self: *Hmac, bytes: []const u8) anyerror!usize {
        return self.inner_hash.write(bytes);
    }

    /// Sum computes the HMAC and copies the result into `out`.
    /// Returns the slice of written bytes.
    pub fn sum(self: *Hmac, out: []u8) []const u8 {
        var inner_sum_buf: [128]u8 = undefined;
        const inner_digest = self.inner_hash.sum(inner_sum_buf[0..self.hash_size]);

        self.outer_hash.reset();
        _ = self.outer_hash.write(self.opad[0..self.block_size]) catch {};
        _ = self.outer_hash.write(inner_digest) catch {};
        return self.outer_hash.sum(out);
    }

    /// Hash returns the Hash interface for this Hmac.
    pub fn hash(self: *Hmac) Hash {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeImpl,
                .sum = sumImpl,
                .reset = resetImpl,
                .size = sizeImpl,
                .blockSize = blockSizeImpl,
            },
        };
    }

    /// Writer returns an io.Writer interface.
    pub fn writer(self: *Hmac) *io.Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drainImpl,
                .flush = flushImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Hmac = @alignCast(@fieldParentPtr("writer_inst", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            _ = self.write(slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            _ = self.write(pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }

    fn flushImpl(_: *std.Io.Writer) std.Io.Writer.Error!void {}

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Hmac = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn sumImpl(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *Hmac = @ptrCast(@alignCast(ctx));
        return self.sum(out);
    }

    fn resetImpl(ctx: *anyopaque) void {
        const self: *Hmac = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    fn sizeImpl(ctx: *anyopaque) usize {
        const self: *Hmac = @ptrCast(@alignCast(ctx));
        return self.hash_size;
    }

    fn blockSizeImpl(ctx: *anyopaque) usize {
        const self: *Hmac = @ptrCast(@alignCast(ctx));
        return self.block_size;
    }
};

/// Convenience function to compute HMAC-SHA256 in a single call.
pub fn sha256(key: []const u8, message: []const u8, out: *[32]u8) void {
    const sha256_mod = @import("sha256.zig");
    var inner_d = sha256_mod.New();
    var outer_d = sha256_mod.New();
    var h = Hmac.init(inner_d.hash(), outer_d.hash(), key);
    _ = h.write(message) catch {};
    _ = h.sum(out);
}

/// Convenience function to compute HMAC-MD5 in a single call.
pub fn md5(key: []const u8, message: []const u8, out: *[16]u8) void {
    const md5_mod = @import("md5.zig");
    var inner_d = md5_mod.New();
    var outer_d = md5_mod.New();
    var h = Hmac.init(inner_d.hash(), outer_d.hash(), key);
    _ = h.write(message) catch {};
    _ = h.sum(out);
}

test "hmac-sha256 RFC 4231 test vectors" {
    const testing = std.testing;

    // RFC 4231 Test Case 2: Key = "Jefe", Data = "what do ya want for nothing?"
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected_hex = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";

    var mac: [32]u8 = undefined;
    sha256(key, data, &mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    try testing.expectEqualStrings(expected_hex, &hex);
}

test "hmac-md5 RFC 2202 test vector" {
    const testing = std.testing;

    // RFC 2202 Test Case 2: Key = "Jefe", Data = "what do ya want for nothing?"
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected_hex = "750c783e6ab0b503eaa86e310a5db738";

    var mac: [16]u8 = undefined;
    md5(key, data, &mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    try testing.expectEqualStrings(expected_hex, &hex);
}
