const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;

pub const Error = error{
    BufferTooSmall,
    Overflow,
    InvalidVarint,
};

pub const max_varint_len_16 = 3;
pub const max_varint_len_32 = 5;
pub const max_varint_len_64 = 10;

pub const Endian = enum {
    little,
    big,

    pub fn readU16(self: Endian, b: []const u8) Error!u16 {
        if (b.len < 2) return Error.BufferTooSmall;
        const arr = b[0..2].*;
        return switch (self) {
            .little => std.mem.readInt(u16, &arr, .little),
            .big => std.mem.readInt(u16, &arr, .big),
        };
    }

    pub fn readU32(self: Endian, b: []const u8) Error!u32 {
        if (b.len < 4) return Error.BufferTooSmall;
        const arr = b[0..4].*;
        return switch (self) {
            .little => std.mem.readInt(u32, &arr, .little),
            .big => std.mem.readInt(u32, &arr, .big),
        };
    }

    pub fn readU64(self: Endian, b: []const u8) Error!u64 {
        if (b.len < 8) return Error.BufferTooSmall;
        const arr = b[0..8].*;
        return switch (self) {
            .little => std.mem.readInt(u64, &arr, .little),
            .big => std.mem.readInt(u64, &arr, .big),
        };
    }

    pub fn writeU16(self: Endian, b: []u8, v: u16) Error!void {
        if (b.len < 2) return Error.BufferTooSmall;
        const target: *[2]u8 = b[0..2];
        switch (self) {
            .little => std.mem.writeInt(u16, target, v, .little),
            .big => std.mem.writeInt(u16, target, v, .big),
        }
    }

    pub fn writeU32(self: Endian, b: []u8, v: u32) Error!void {
        if (b.len < 4) return Error.BufferTooSmall;
        const target: *[4]u8 = b[0..4];
        switch (self) {
            .little => std.mem.writeInt(u32, target, v, .little),
            .big => std.mem.writeInt(u32, target, v, .big),
        }
    }

    pub fn writeU64(self: Endian, b: []u8, v: u64) Error!void {
        if (b.len < 8) return Error.BufferTooSmall;
        const target: *[8]u8 = b[0..8];
        switch (self) {
            .little => std.mem.writeInt(u64, target, v, .little),
            .big => std.mem.writeInt(u64, target, v, .big),
        }
    }
};

pub const LittleEndian = Endian.little;
pub const BigEndian = Endian.big;
pub const NativeEndian: Endian = if (@import("builtin").cpu.arch.endian() == .little) .little else .big;

/// PutUvarint encodes a uint64 into buf and returns the number of bytes written.
/// If the buffer is too small, returns Error.BufferTooSmall.
pub fn putUvarint(buf: []u8, x: u64) Error!usize {
    var val = x;
    var i: usize = 0;
    while (val >= 0x80) {
        if (i >= buf.len) return Error.BufferTooSmall;
        buf[i] = @as(u8, @truncate(val)) | 0x80;
        val >>= 7;
        i += 1;
    }
    if (i >= buf.len) return Error.BufferTooSmall;
    buf[i] = @as(u8, @truncate(val));
    return i + 1;
}

pub const UvarintResult = struct {
    val: u64,
    bytes_read: usize,
};

/// Uvarint decodes a uint64 from buf and returns that value and the number of bytes read.
pub fn uvarint(buf: []const u8) Error!UvarintResult {
    var x: u64 = 0;
    var s: u6 = 0;
    for (buf, 0..) |b, i| {
        if (i == max_varint_len_64) {
            return Error.Overflow;
        }
        if (b < 0x80) {
            if (i == max_varint_len_64 - 1 and b > 1) {
                return Error.Overflow;
            }
            x |= @as(u64, b) << s;
            return .{ .val = x, .bytes_read = i + 1 };
        }
        x |= @as(u64, b & 0x7f) << s;
        s += 7;
    }
    return Error.BufferTooSmall;
}

/// PutVarint encodes an int64 into buf using ZigZag encoding.
pub fn putVarint(buf: []u8, x: i64) Error!usize {
    const ux: u64 = @as(u64, @bitCast(x << 1)) ^ @as(u64, @bitCast(x >> 63));
    return putUvarint(buf, ux);
}

pub const VarintResult = struct {
    val: i64,
    bytes_read: usize,
};

/// Varint decodes an int64 from buf using ZigZag decoding.
pub fn varint(buf: []const u8) Error!VarintResult {
    const res = try uvarint(buf);
    const ux = res.val;
    var x: i64 = @as(i64, @bitCast(ux >> 1));
    if ((ux & 1) != 0) {
        x = ~x;
    }
    return .{ .val = x, .bytes_read = res.bytes_read };
}

/// Read reads structured binary data from r into data.
pub fn read(r: *io.Reader, endian: Endian, comptime T: type) anyerror!T {
    var buf: [@sizeOf(T)]u8 = undefined;
    _ = try io.readFull(r, &buf);
    return switch (endian) {
        .little => std.mem.readInt(T, &buf, .little),
        .big => std.mem.readInt(T, &buf, .big),
    };
}

/// Write writes the binary representation of data into w.
pub fn write(w: *io.Writer, endian: Endian, comptime T: type, val: T) anyerror!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    switch (endian) {
        .little => std.mem.writeInt(T, &buf, val, .little),
        .big => std.mem.writeInt(T, &buf, val, .big),
    }
    try w.writeAll(&buf);
}

test "binary endian read and write" {
    var buf: [8]u8 = undefined;

    try LittleEndian.writeU16(buf[0..2], 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), try LittleEndian.readU16(buf[0..2]));
    try std.testing.expectEqual(@as(u8, 0x34), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x12), buf[1]);

    try BigEndian.writeU32(buf[0..4], 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), try BigEndian.readU32(buf[0..4]));
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x78), buf[3]);
}

test "binary Go official varint tests" {
    const testing = std.testing;
    var buf: [max_varint_len_64]u8 = undefined;

    const go_tests = [_]i64{
        std.math.minInt(i64),
        std.math.minInt(i64) + 1,
        -1,
        0,
        1,
        2,
        10,
        20,
        63,
        64,
        65,
        127,
        128,
        129,
        255,
        256,
        257,
        std.math.maxInt(i64) - 1,
        std.math.maxInt(i64),
    };

    for (go_tests) |x| {
        // testVarint
        const n1 = try putVarint(&buf, x);
        const res1 = try varint(buf[0..n1]);
        try testing.expectEqual(x, res1.val);
        try testing.expectEqual(n1, res1.bytes_read);

        // negative if non-min
        if (x != std.math.minInt(i64)) {
            const neg_x = -x;
            const n2 = try putVarint(&buf, neg_x);
            const res2 = try varint(buf[0..n2]);
            try testing.expectEqual(neg_x, res2.val);
            try testing.expectEqual(n2, res2.bytes_read);
        }

        // testUvarint
        if (x >= 0) {
            const ux: u64 = @intCast(x);
            const un = try putUvarint(&buf, ux);
            const ures = try uvarint(buf[0..un]);
            try testing.expectEqual(ux, ures.val);
            try testing.expectEqual(un, ures.bytes_read);
        }
    }

    // Bit-shifting sweep (x <<= 1)
    var bit_sweep: u64 = 0x7;
    while (bit_sweep != 0) : (bit_sweep <<= 1) {
        const un = try putUvarint(&buf, bit_sweep);
        const ures = try uvarint(buf[0..un]);
        try testing.expectEqual(bit_sweep, ures.val);
        try testing.expectEqual(un, ures.bytes_read);
    }
}
