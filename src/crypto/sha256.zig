const std = @import("std");
const hash_mod = @import("../hash/hash.zig");
const Hash = hash_mod.Hash;
const io = @import("../io.zig");

pub const size = 32;
pub const block_size = 64;

pub const Digest = struct {
    inner: std.crypto.hash.sha2.Sha256,
    writer_inst: std.Io.Writer = undefined,

    pub fn init() Digest {
        return .{
            .inner = std.crypto.hash.sha2.Sha256.init(.{}),
            .writer_inst = undefined,
        };
    }

    pub fn reset(self: *Digest) void {
        self.inner = std.crypto.hash.sha2.Sha256.init(.{});
    }

    pub fn write(self: *Digest, bytes: []const u8) anyerror!usize {
        self.inner.update(bytes);
        return bytes.len;
    }

    pub fn sum(self: *Digest, out: *[size]u8) void {
        var copy = self.inner;
        copy.final(out);
    }

    pub fn hash(self: *Digest) Hash {
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

    pub fn writer(self: *Digest) *io.Writer {
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
        const self: *Digest = @alignCast(@fieldParentPtr("writer_inst", w));
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
        const self: *Digest = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn sumImpl(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *Digest = @ptrCast(@alignCast(ctx));
        var d: [size]u8 = undefined;
        self.sum(&d);
        const n = @min(out.len, size);
        @memcpy(out[0..n], d[0..n]);
        return out[0..n];
    }

    fn resetImpl(ctx: *anyopaque) void {
        const self: *Digest = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    fn sizeImpl(_: *anyopaque) usize {
        return size;
    }

    fn blockSizeImpl(_: *anyopaque) usize {
        return block_size;
    }
};

pub fn New() Digest {
    return Digest.init();
}

pub fn Sum256(data: []const u8) [size]u8 {
    var d: [size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return d;
}

test "crypto.sha256 streaming and Sum256" {
    const testing = std.testing;

    const input = "The quick brown fox jumps over the lazy dog";
    const expected_hex = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592";

    // Direct sum
    const d1 = Sum256(input);
    const hex1 = std.fmt.bytesToHex(d1, .lower);
    try testing.expectEqualStrings(expected_hex, &hex1);

    // Streaming
    var dig = New();
    _ = try dig.write("The quick brown ");
    _ = try dig.write("fox jumps over the lazy dog");
    var d2: [size]u8 = undefined;
    dig.sum(&d2);
    const hex2 = std.fmt.bytesToHex(d2, .lower);
    try testing.expectEqualStrings(expected_hex, &hex2);
}
