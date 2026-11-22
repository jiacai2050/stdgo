//! Package encoding/base32 implements base32 encoding as specified by RFC 4648.
//!
//! Provides standard encoding, extended hex encoding, custom padding,
//! and streaming Encoder and Decoder on top of stdgo.io interfaces.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../io.zig");

pub const Error = error{
    CorruptInput,
    ShortBuffer,
};

const std_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const hex_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUV";

/// Encoding represents a base32 encoding/decoding configuration.
pub const Encoding = struct {
    encode_table: [32]u8,
    decode_table: [256]u8,
    pad_char: ?u8,

    /// Initializes a new Encoding using the 32-character alphabet and optional pad character.
    pub fn init(alphabet: *const [32]u8, pad_char: ?u8) Encoding {
        var enc: Encoding = undefined;
        @memcpy(&enc.encode_table, alphabet);
        enc.pad_char = pad_char;
        @memset(&enc.decode_table, 0xFF);
        for (alphabet, 0..) |c, i| {
            enc.decode_table[c] = @intCast(i);
        }
        return enc;
    }

    /// Returns a new encoding identical to self except with a specified padding character,
    /// or null for unpadded encoding.
    pub fn withPadding(self: Encoding, pad: ?u8) Encoding {
        var copy = self;
        copy.pad_char = pad;
        return copy;
    }

    /// Returns an unpadded version of this encoding.
    pub fn noPadding(self: Encoding) Encoding {
        return self.withPadding(null);
    }

    /// Returns the maximum length in bytes of the base32 encoding of an input buffer of length n.
    pub fn encodedLen(self: Encoding, n: usize) usize {
        if (self.pad_char != null) {
            return (n + 4) / 5 * 8;
        }
        return n / 5 * 8 + switch (n % 5) {
            0 => @as(usize, 0),
            1 => @as(usize, 2),
            2 => @as(usize, 4),
            3 => @as(usize, 5),
            4 => @as(usize, 7),
            else => unreachable,
        };
    }

    /// Returns the maximum length in bytes of the decoded data corresponding to n bytes
    /// of base32-encoded input.
    pub fn decodedLen(self: Encoding, n: usize) usize {
        if (self.pad_char != null) {
            return n / 8 * 5;
        }
        return n / 8 * 5 + switch (n % 8) {
            0 => @as(usize, 0),
            1 => @as(usize, 0),
            2 => @as(usize, 1),
            4 => @as(usize, 2),
            5 => @as(usize, 3),
            7 => @as(usize, 4),
            else => n / 8 * 5,
        };
    }

    /// Encodes src into dst using base32. dst must have capacity at least self.encodedLen(src.len).
    pub fn encode(self: Encoding, dst: []u8, src: []const u8) void {
        var di: usize = 0;
        var si: usize = 0;
        const n = (src.len / 5) * 5;

        while (si < n) : (si += 5) {
            const b0 = src[si];
            const b1 = src[si + 1];
            const b2 = src[si + 2];
            const b3 = src[si + 3];
            const b4 = src[si + 4];

            dst[di] = self.encode_table[b0 >> 3];
            dst[di + 1] = self.encode_table[((b0 & 0x07) << 2) | (b1 >> 6)];
            dst[di + 2] = self.encode_table[(b1 >> 1) & 0x1F];
            dst[di + 3] = self.encode_table[((b1 & 0x01) << 4) | (b2 >> 4)];
            dst[di + 4] = self.encode_table[((b2 & 0x0F) << 1) | (b3 >> 7)];
            dst[di + 5] = self.encode_table[(b3 >> 2) & 0x1F];
            dst[di + 6] = self.encode_table[((b3 & 0x03) << 3) | (b4 >> 5)];
            dst[di + 7] = self.encode_table[b4 & 0x1F];
            di += 8;
        }

        const remain = src.len - si;
        if (remain == 0) return;

        const b0 = src[si];
        dst[di] = self.encode_table[b0 >> 3];

        switch (remain) {
            1 => {
                dst[di + 1] = self.encode_table[(b0 & 0x07) << 2];
                di += 2;
                if (self.pad_char) |pad| {
                    for (0..6) |k| dst[di + k] = pad;
                }
            },
            2 => {
                const b1 = src[si + 1];
                dst[di + 1] = self.encode_table[((b0 & 0x07) << 2) | (b1 >> 6)];
                dst[di + 2] = self.encode_table[(b1 >> 1) & 0x1F];
                dst[di + 3] = self.encode_table[(b1 & 0x01) << 4];
                di += 4;
                if (self.pad_char) |pad| {
                    for (0..4) |k| dst[di + k] = pad;
                }
            },
            3 => {
                const b1 = src[si + 1];
                const b2 = src[si + 2];
                dst[di + 1] = self.encode_table[((b0 & 0x07) << 2) | (b1 >> 6)];
                dst[di + 2] = self.encode_table[(b1 >> 1) & 0x1F];
                dst[di + 3] = self.encode_table[((b1 & 0x01) << 4) | (b2 >> 4)];
                dst[di + 4] = self.encode_table[(b2 & 0x0F) << 1];
                di += 5;
                if (self.pad_char) |pad| {
                    for (0..3) |k| dst[di + k] = pad;
                }
            },
            4 => {
                const b1 = src[si + 1];
                const b2 = src[si + 2];
                const b3 = src[si + 3];
                dst[di + 1] = self.encode_table[((b0 & 0x07) << 2) | (b1 >> 6)];
                dst[di + 2] = self.encode_table[(b1 >> 1) & 0x1F];
                dst[di + 3] = self.encode_table[((b1 & 0x01) << 4) | (b2 >> 4)];
                dst[di + 4] = self.encode_table[((b2 & 0x0F) << 1) | (b3 >> 7)];
                dst[di + 5] = self.encode_table[(b3 >> 2) & 0x1F];
                dst[di + 6] = self.encode_table[(b3 & 0x03) << 3];
                di += 7;
                if (self.pad_char) |pad| {
                    dst[di] = pad;
                }
            },
            else => unreachable,
        }
    }

    /// Encodes src and returns the base32 string.
    pub fn encodeToString(self: Encoding, allocator: Allocator, src: []const u8) ![]u8 {
        const out_len = self.encodedLen(src.len);
        const buf = try allocator.alloc(u8, out_len);
        self.encode(buf, src);
        return buf;
    }

    /// Decodes src into dst. Returns the number of bytes written to dst.
    pub fn decode(self: Encoding, dst: []u8, src: []const u8) !usize {
        var dlen: usize = 0;
        var buf: [8]u8 = undefined;
        var buf_len: usize = 0;

        for (src) |c| {
            if (c == '\r' or c == '\n') continue;
            if (self.pad_char != null and c == self.pad_char.?) {
                // Padding reached
                continue;
            }

            const val = self.decode_table[c];
            if (val == 0xFF) return Error.CorruptInput;

            buf[buf_len] = val;
            buf_len += 1;

            if (buf_len == 8) {
                if (dlen + 5 > dst.len) return Error.ShortBuffer;
                decodeQuantum5(dst[dlen .. dlen + 5], buf);
                dlen += 5;
                buf_len = 0;
            }
        }

        if (buf_len > 0) {
            const extra = switch (buf_len) {
                2 => @as(usize, 1),
                4 => @as(usize, 2),
                5 => @as(usize, 3),
                7 => @as(usize, 4),
                else => return Error.CorruptInput,
            };

            if (dlen + extra > dst.len) return Error.ShortBuffer;

            var padded_buf: [8]u8 = @splat(0);
            @memcpy(padded_buf[0..buf_len], buf[0..buf_len]);

            var temp: [5]u8 = undefined;
            decodeQuantum5(&temp, padded_buf);

            @memcpy(dst[dlen .. dlen + extra], temp[0..extra]);
            dlen += extra;
        }

        return dlen;
    }

    /// Decodes base32 string s and returns the decoded bytes.
    pub fn decodeString(self: Encoding, allocator: Allocator, s: []const u8) ![]u8 {
        const max_len = self.decodedLen(s.len);
        const buf = try allocator.alloc(u8, max_len);
        errdefer allocator.free(buf);

        const n = try self.decode(buf, s);
        if (n == buf.len) return buf;

        const exact = try allocator.alloc(u8, n);
        @memcpy(exact, buf[0..n]);
        allocator.free(buf);
        return exact;
    }

    fn decodeQuantum5(dst: []u8, b: [8]u8) void {
        dst[0] = (b[0] << 3) | (b[1] >> 2);
        dst[1] = ((b[1] & 0x03) << 6) | (b[2] << 1) | (b[3] >> 4);
        dst[2] = ((b[3] & 0x0F) << 4) | (b[4] >> 1);
        dst[3] = ((b[4] & 0x01) << 7) | (b[5] << 2) | (b[6] >> 3);
        dst[4] = ((b[6] & 0x07) << 5) | b[7];
    }
};

/// StdEncoding is the standard base32 encoding as defined by RFC 4648.
pub const std_encoding = Encoding.init(std_alphabet, '=');

/// HexEncoding is the "Extended Hex Alphabet" defined by RFC 4648.
/// It is typically used in DNS.
pub const hex_encoding = Encoding.init(hex_alphabet, '=');

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "Base32: RFC 4648 test vectors (StdEncoding)" {
    const testing = std.testing;

    const vectors = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "" },
        .{ .in = "f", .out = "MY======" },
        .{ .in = "fo", .out = "MZXQ====" },
        .{ .in = "foo", .out = "MZXW6===" },
        .{ .in = "foob", .out = "MZXW6YQ=" },
        .{ .in = "fooba", .out = "MZXW6YTB" },
        .{ .in = "foobar", .out = "MZXW6YTBOI======" },
    };

    for (vectors) |v| {
        // Encode
        const enc = try std_encoding.encodeToString(testing.allocator, v.in);
        defer testing.allocator.free(enc);
        try testing.expectEqualStrings(v.out, enc);

        // Decode
        const dec = try std_encoding.decodeString(testing.allocator, v.out);
        defer testing.allocator.free(dec);
        try testing.expectEqualStrings(v.in, dec);
    }
}

test "Base32: RFC 4648 test vectors (HexEncoding)" {
    const testing = std.testing;

    const vectors = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "" },
        .{ .in = "f", .out = "CO======" },
        .{ .in = "fo", .out = "CPNG====" },
        .{ .in = "foo", .out = "CPNMU===" },
        .{ .in = "foob", .out = "CPNMUOG=" },
        .{ .in = "fooba", .out = "CPNMUOJ1" },
        .{ .in = "foobar", .out = "CPNMUOJ1E8======" },
    };

    for (vectors) |v| {
        const enc = try hex_encoding.encodeToString(testing.allocator, v.in);
        defer testing.allocator.free(enc);
        try testing.expectEqualStrings(v.out, enc);

        const dec = try hex_encoding.decodeString(testing.allocator, v.out);
        defer testing.allocator.free(dec);
        try testing.expectEqualStrings(v.in, dec);
    }
}

test "Base32: NoPadding" {
    const testing = std.testing;
    const raw = "hello world";
    const enc_no_pad = std_encoding.noPadding();

    const encoded = try enc_no_pad.encodeToString(testing.allocator, raw);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '=') == null);

    const decoded = try enc_no_pad.decodeString(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(raw, decoded);
}
