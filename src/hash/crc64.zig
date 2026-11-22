//! Package hash/crc64 implements the 64-bit cyclic redundancy check (CRC-64) checksum.
//!
//! Provides predefined tables for ISO-3309 (used in HDLC) and ECMA-182,
//! with one-shot and streaming `Digest` calculation.

const std = @import("std");
const mem = std.mem;

/// The ISO polynomial, defined in ISO 3309 and used in HDLC.
pub const ISO: u64 = 0xD800000000000000;

/// The ECMA polynomial, defined in ECMA 182.
pub const ECMA: u64 = 0xC96C5795D7870F42;

/// The size of a CRC-64 checksum in bytes.
pub const Size: usize = 8;

/// Table is a 256-word table representing the polynomial for efficient processing.
pub const Table = [256]u64;

/// MakeTable returns a Table constructed from the specified polynomial.
pub fn makeTable(poly: u64) Table {
    @setEvalBranchQuota(10000);
    var tab: Table = undefined;
    for (0..256) |i| {
        var crc: u64 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ poly;
            } else {
                crc >>= 1;
            }
        }
        tab[i] = crc;
    }
    return tab;
}

pub const iso_table: Table = makeTable(ISO);
pub const ecma_table: Table = makeTable(ECMA);

/// Update returns the result of adding the bytes in p to the crc.
pub fn update(crc: u64, tab: *const Table, p: []const u8) u64 {
    var c = ~crc;
    for (p) |b| {
        c = tab[@as(u8, @truncate(c ^ b))] ^ (c >> 8);
    }
    return ~c;
}

/// Checksum returns the CRC-64 checksum of data using the polynomial represented by the Table.
pub fn checksum(data: []const u8, tab: *const Table) u64 {
    return update(0, tab, data);
}

/// Digest computes a CRC-64 checksum and implements std.Io.Writer for streaming updates.
pub const Digest = struct {
    tab: *const Table,
    crc: u64 = 0,
    writer_inst: std.Io.Writer = undefined,

    pub fn init(tab: *const Table) Digest {
        return .{ .tab = tab, .crc = 0 };
    }

    pub fn reset(self: *Digest) void {
        self.crc = 0;
    }

    pub fn sum64(self: Digest) u64 {
        return self.crc;
    }

    pub fn sum(self: Digest, b: []u8) []u8 {
        var s: [8]u8 = undefined;
        mem.writeInt(u64, &s, self.crc, .big);
        @memcpy(b[0..8], &s);
        return b[0..8];
    }

    pub fn write(self: *Digest, p: []const u8) !usize {
        self.crc = update(self.crc, self.tab, p);
        return p.len;
    }

    pub fn writer(self: *Digest) *std.Io.Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .end = 0,
            .vtable = &.{
                .drain = drainImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *Digest = @alignCast(@fieldParentPtr("writer_inst", w));
        var total: usize = 0;
        for (data) |chunk| {
            _ = self.write(chunk) catch return error.WriteFailed;
            total += chunk.len;
        }
        return total;
    }
};

test "hash/crc64 standard vectors" {
    const testing = std.testing;

    // Test vectors from Go standard library
    try testing.expectEqual(@as(u64, 0), checksum("", &iso_table));
    try testing.expectEqual(@as(u64, 0), checksum("", &ecma_table));

    try testing.expectEqual(@as(u64, 0x3420000000000000), checksum("a", &iso_table));
    try testing.expectEqual(@as(u64, 0x330284772e652b05), checksum("a", &ecma_table));

    try testing.expectEqual(@as(u64, 0x36c4200000000000), checksum("ab", &iso_table));
    try testing.expectEqual(@as(u64, 0xbc6573200e84b046), checksum("ab", &ecma_table));

    try testing.expectEqual(@as(u64, 0x3776c42000000000), checksum("abc", &iso_table));
    try testing.expectEqual(@as(u64, 0x2cd8094a1a277627), checksum("abc", &ecma_table));

    try testing.expectEqual(@as(u64, 0x7f5b6e21b002d367), checksum("abcdefghij", &iso_table));
    try testing.expectEqual(@as(u64, 0x32093a2ecd5773f4), checksum("abcdefghij", &ecma_table));

    // Test Digest streaming
    var d = Digest.init(&iso_table);
    var w = d.writer();
    try w.writeAll("abc");
    try w.writeAll("defghij");
    try testing.expectEqual(@as(u64, 0x7f5b6e21b002d367), d.sum64());
}
