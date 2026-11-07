const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = error{
    CorruptInput,
    ShortBuffer,
};

const std_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub const Encoding = struct {
    encode_table: [64]u8,
    decode_table: [256]u8,
    pad_char: ?u8,

    pub fn init(alphabet: *const [64]u8, pad_char: ?u8) Encoding {
        var enc: Encoding = undefined;
        @memcpy(&enc.encode_table, alphabet);
        enc.pad_char = pad_char;
        @memset(&enc.decode_table, 0xFF);
        for (alphabet, 0..) |c, i| {
            enc.decode_table[c] = @intCast(i);
        }
        return enc;
    }

    pub fn encodedLen(self: Encoding, n: usize) usize {
        if (self.pad_char != null) {
            return (n + 2) / 3 * 4;
        }
        return n / 3 * 4 + switch (n % 3) {
            0 => @as(usize, 0),
            1 => @as(usize, 2),
            2 => @as(usize, 3),
            else => unreachable,
        };
    }

    pub fn decodedLen(self: Encoding, n: usize) usize {
        if (self.pad_char != null) {
            return n / 4 * 3;
        }
        return n / 4 * 3 + switch (n % 4) {
            0 => @as(usize, 0),
            1 => @as(usize, 0),
            2 => @as(usize, 1),
            3 => @as(usize, 2),
            else => unreachable,
        };
    }

    pub fn encode(self: Encoding, dst: []u8, src: []const u8) void {
        var di: usize = 0;
        var si: usize = 0;
        const n = (src.len / 3) * 3;

        while (si < n) : (si += 3) {
            const val = (@as(u32, src[si]) << 16) | (@as(u32, src[si + 1]) << 8) | @as(u32, src[si + 2]);
            dst[di + 0] = self.encode_table[(val >> 18) & 0x3F];
            dst[di + 1] = self.encode_table[(val >> 12) & 0x3F];
            dst[di + 2] = self.encode_table[(val >> 6) & 0x3F];
            dst[di + 3] = self.encode_table[val & 0x3F];
            di += 4;
        }

        const remain = src.len - si;
        if (remain == 0) return;

        var val = @as(u32, src[si]) << 16;
        if (remain == 2) {
            val |= @as(u32, src[si + 1]) << 8;
        }

        dst[di + 0] = self.encode_table[(val >> 18) & 0x3F];
        dst[di + 1] = self.encode_table[(val >> 12) & 0x3F];

        switch (remain) {
            2 => {
                dst[di + 2] = self.encode_table[(val >> 6) & 0x3F];
                if (self.pad_char) |pad| {
                    dst[di + 3] = pad;
                }
            },
            1 => {
                if (self.pad_char) |pad| {
                    dst[di + 2] = pad;
                    dst[di + 3] = pad;
                }
            },
            else => unreachable,
        }
    }

    pub fn encodeToString(self: Encoding, allocator: Allocator, src: []const u8) Allocator.Error![]u8 {
        const out_len = self.encodedLen(src.len);
        const buf = try allocator.alloc(u8, out_len);
        self.encode(buf, src);
        return buf;
    }

    pub fn decode(self: Encoding, dst: []u8, src: []const u8) Error!usize {
        var clean_src_len = src.len;
        if (self.pad_char) |pad| {
            while (clean_src_len > 0 and src[clean_src_len - 1] == pad) {
                clean_src_len -= 1;
            }
        }

        var si: usize = 0;
        var di: usize = 0;

        while (si + 4 <= clean_src_len) : (si += 4) {
            const d0 = self.decode_table[src[si + 0]];
            const d1 = self.decode_table[src[si + 1]];
            const d2 = self.decode_table[src[si + 2]];
            const d3 = self.decode_table[src[si + 3]];

            if (d0 == 0xFF or d1 == 0xFF or d2 == 0xFF or d3 == 0xFF) {
                return Error.CorruptInput;
            }

            const val = (@as(u32, d0) << 18) | (@as(u32, d1) << 12) | (@as(u32, d2) << 6) | @as(u32, d3);
            if (di + 3 > dst.len) return Error.ShortBuffer;
            dst[di + 0] = @intCast((val >> 16) & 0xFF);
            dst[di + 1] = @intCast((val >> 8) & 0xFF);
            dst[di + 2] = @intCast(val & 0xFF);
            di += 3;
        }

        const rem = clean_src_len - si;
        if (rem == 0) return di;
        if (rem == 1) return Error.CorruptInput;

        const d0 = self.decode_table[src[si + 0]];
        const d1 = self.decode_table[src[si + 1]];
        if (d0 == 0xFF or d1 == 0xFF) return Error.CorruptInput;

        var val = (@as(u32, d0) << 18) | (@as(u32, d1) << 12);
        if (rem == 3) {
            const d2 = self.decode_table[src[si + 2]];
            if (d2 == 0xFF) return Error.CorruptInput;
            val |= @as(u32, d2) << 6;
            if (di + 2 > dst.len) return Error.ShortBuffer;
            dst[di + 0] = @intCast((val >> 16) & 0xFF);
            dst[di + 1] = @intCast((val >> 8) & 0xFF);
            di += 2;
        } else if (rem == 2) {
            if (di + 1 > dst.len) return Error.ShortBuffer;
            dst[di + 0] = @intCast((val >> 16) & 0xFF);
            di += 1;
        }

        return di;
    }

    pub fn decodeString(self: Encoding, allocator: Allocator, src: []const u8) (Allocator.Error || Error)![]u8 {
        const max_len = self.decodedLen(src.len);
        const buf = try allocator.alloc(u8, max_len);
        errdefer allocator.free(buf);
        const actual_len = try self.decode(buf, src);
        if (actual_len == max_len) return buf;
        return try allocator.realloc(buf, actual_len);
    }
};

pub const std_encoding: Encoding = Encoding.init(std_alphabet, '=');
pub const url_encoding: Encoding = Encoding.init(url_alphabet, '=');
pub const raw_std_encoding: Encoding = Encoding.init(std_alphabet, null);
pub const raw_url_encoding: Encoding = Encoding.init(url_alphabet, null);

test "base64 std encoding & decoding" {
    const testing = std.testing;
    const test_cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "" },
        .{ .in = "f", .out = "Zg==" },
        .{ .in = "fo", .out = "Zm8=" },
        .{ .in = "foo", .out = "Zm9v" },
        .{ .in = "foob", .out = "Zm9vYg==" },
        .{ .in = "fooba", .out = "Zm9vYmE=" },
        .{ .in = "foobar", .out = "Zm9vYmFy" },
    };

    for (test_cases) |tc| {
        const enc = try std_encoding.encodeToString(testing.allocator, tc.in);
        defer testing.allocator.free(enc);
        try testing.expectEqualStrings(tc.out, enc);

        const dec = try std_encoding.decodeString(testing.allocator, tc.out);
        defer testing.allocator.free(dec);
        try testing.expectEqualStrings(tc.in, dec);
    }
}

test "base64 raw url encoding" {
    const testing = std.testing;
    const input = "subjects?_d=1";
    const enc = try raw_url_encoding.encodeToString(testing.allocator, input);
    defer testing.allocator.free(enc);

    // '-' and '_' should be used, without trailing '='
    for (enc) |c| {
        try testing.expect(c != '=' and c != '+' and c != '/');
    }

    const dec = try raw_url_encoding.decodeString(testing.allocator, enc);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(input, dec);
}
