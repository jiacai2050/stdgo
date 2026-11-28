//! Package mime/quotedprintable implements quoted-printable encoding as specified by RFC 2045.
//!
//! Provides streaming decoding and encoding, hex escaping of non-printable bytes (=XX),
//! and handling of soft line breaks (=\r\n and =\n) up to the 76-character limit.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const hex_digits = "0123456789ABCDEF";

fn hexVal(b: u8) ?u8 {
    return switch (b) {
        '0'...'9' => b - '0',
        'A'...'F' => b - 'A' + 10,
        'a'...'f' => b - 'a' + 10,
        else => null,
    };
}

/// DecodeAlloc parses and decodes a quoted-printable byte slice, allocating the result.
/// Expands `=XX` hex escapes and strips soft line breaks (`=\r\n` and `=\n`).
pub fn decodeAlloc(allocator: Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b == '=') {
            if (i + 1 >= src.len) return error.UnexpectedEof;
            const next = src[i + 1];

            // Soft line break: =\r\n or =\n
            if (next == '\r') {
                if (i + 2 < src.len and src[i + 2] == '\n') {
                    i += 3;
                    continue;
                }
                return error.MalformedQuotedPrintable;
            } else if (next == '\n') {
                i += 2;
                continue;
            }

            // Hex byte: =XX
            if (i + 2 >= src.len) return error.UnexpectedEof;
            const h1 = hexVal(src[i + 1]) orelse return error.MalformedQuotedPrintable;
            const h2 = hexVal(src[i + 2]) orelse return error.MalformedQuotedPrintable;
            try out.append(allocator, (h1 << 4) | h2);
            i += 3;
        } else {
            try out.append(allocator, b);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// EncodeAlloc encodes a byte slice into quoted-printable format, allocating the result.
/// Limits line length to 76 characters by automatically inserting soft line breaks (`=\r\n`).
pub fn encodeAlloc(allocator: Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var line_len: usize = 0;

    for (src) |b| {
        const is_printable = (b >= 33 and b <= 126 and b != '=');
        const is_space_or_tab = (b == ' ' or b == '\t');

        if (is_printable or is_space_or_tab) {
            // Need 1 char. If line exceeds 75 chars, insert soft break "=\r\n"
            if (line_len + 1 > 75) {
                try out.appendSlice(allocator, "=\r\n");
                line_len = 0;
            }
            try out.append(allocator, b);
            line_len += 1;
        } else {
            // Non-printable requires 3 chars: =XX
            if (line_len + 3 > 75) {
                try out.appendSlice(allocator, "=\r\n");
                line_len = 0;
            }
            try out.append(allocator, '=');
            try out.append(allocator, hex_digits[b >> 4]);
            try out.append(allocator, hex_digits[b & 0x0f]);
            line_len += 3;
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Reader is a streaming quoted-printable decoder wrapping an underlying std.Io.Reader.
pub const Reader = struct {
    src: *std.Io.Reader,
    reader_inst: std.Io.Reader = undefined,
    allocator: Allocator,

    pub fn init(allocator: Allocator, src: *std.Io.Reader) Reader {
        return .{
            .src = src,
            .allocator = allocator,
        };
    }

    /// Reads all remaining quoted-printable input from the underlying reader and returns the decoded bytes.
    /// Caller owns the returned slice.
    pub fn readAllDecoded(self: *Reader) ![]u8 {
        var raw_buf = std.ArrayList(u8).empty;
        defer raw_buf.deinit(self.allocator);

        var chunk: [512]u8 = undefined;
        while (true) {
            const n = try self.src.readSliceShort(&chunk);
            if (n == 0) break;
            try raw_buf.appendSlice(self.allocator, chunk[0..n]);
        }

        return try decodeAlloc(self.allocator, raw_buf.items);
    }
};

test "mime/quotedprintable encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw = "Hello, World! = 42 & non-ascii: \xc3\xa9 \xe4\xb8\xad\xe6\x96\x87";
    const enc = try encodeAlloc(allocator, raw);
    defer allocator.free(enc);

    // Verify non-ascii is escaped with =XX and '=' is escaped as =3D
    try testing.expect(mem.indexOf(u8, enc, "=3D") != null);
    try testing.expect(mem.indexOf(u8, enc, "=C3=A9") != null);

    // Decode back
    const dec = try decodeAlloc(allocator, enc);
    defer allocator.free(dec);
    try testing.expectEqualStrings(raw, dec);

    // Test soft line break =\r\n
    const soft_break =
        "Now's the time =\r\nfor all good men\r\nto come to the aid of their country.";
    const dec_soft = try decodeAlloc(allocator, soft_break);
    defer allocator.free(dec_soft);
    const expected =
        "Now's the time for all good men\r\nto come to the aid of their country.";
    try testing.expectEqualStrings(expected, dec_soft);

    // Test soft line break =\n
    const soft_break_lf = "Soft break=\ntest";
    const dec_soft_lf = try decodeAlloc(allocator, soft_break_lf);
    defer allocator.free(dec_soft_lf);
    try testing.expectEqualStrings("Soft breaktest", dec_soft_lf);
}

test "mime/quotedprintable Reader.readAllDecoded handles >512B input" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw_arr: [1024]u8 = @splat('A');
    const raw: []const u8 = &raw_arr;
    const enc = try encodeAlloc(allocator, raw);
    defer allocator.free(enc);
    try testing.expect(enc.len > 512);

    var src = std.Io.Reader.fixed(enc);
    var qp_reader = Reader.init(allocator, &src);
    const dec = try qp_reader.readAllDecoded();
    defer allocator.free(dec);

    try testing.expectEqualStrings(raw, dec);
}
