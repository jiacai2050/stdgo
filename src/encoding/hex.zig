const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidByte,
    OddLength,
    ShortBuffer,
};

const hextable = "0123456789abcdef";

pub fn encodedLen(n: usize) usize {
    return n * 2;
}

pub fn decodedLen(n: usize) usize {
    return n / 2;
}

pub fn encode(dst: []u8, src: []const u8) usize {
    var j: usize = 0;
    for (src) |v| {
        dst[j] = hextable[v >> 4];
        dst[j + 1] = hextable[v & 0x0F];
        j += 2;
    }
    return j;
}

pub fn encodeToString(allocator: Allocator, src: []const u8) Allocator.Error![]u8 {
    const dst = try allocator.alloc(u8, encodedLen(src.len));
    _ = encode(dst, src);
    return dst;
}

fn fromHexChar(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn decode(dst: []u8, src: []const u8) Error!usize {
    if (src.len % 2 != 0) return Error.OddLength;
    if (dst.len < src.len / 2) return Error.ShortBuffer;

    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const a = fromHexChar(src[i]) orelse return Error.InvalidByte;
        const b = fromHexChar(src[i + 1]) orelse return Error.InvalidByte;
        dst[i / 2] = (a << 4) | b;
    }
    return src.len / 2;
}

pub fn decodeString(allocator: Allocator, src: []const u8) (Allocator.Error || Error)![]u8 {
    if (src.len % 2 != 0) return Error.OddLength;
    const dst = try allocator.alloc(u8, decodedLen(src.len));
    errdefer allocator.free(dst);
    _ = try decode(dst, src);
    return dst;
}

/// Formats data into the canonical Go hex.Dump format:
/// 00000000  7b 22 74 61 67 22 3a 20  22 76 31 22 7d 0a        |{"tag": "v1"}.|
pub fn dump(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        // Line offset (8 hex chars)
        var offset_buf: [8]u8 = undefined;
        var off: usize = i;
        var off_idx: usize = 8;
        while (off_idx > 0) {
            off_idx -= 1;
            offset_buf[off_idx] = hextable[off & 0x0F];
            off >>= 4;
        }
        try list.appendSlice(allocator, &offset_buf);
        try list.appendSlice(allocator, "  ");

        // 16 bytes of hex
        const chunk_len = @min(16, data.len - i);
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (j == 8) try list.append(allocator, ' ');
            if (j < chunk_len) {
                const b = data[i + j];
                try list.append(allocator, hextable[b >> 4]);
                try list.append(allocator, hextable[b & 0x0F]);
                try list.append(allocator, ' ');
            } else {
                try list.appendSlice(allocator, "   ");
            }
        }

        // ASCII representation
        try list.appendSlice(allocator, " |");
        j = 0;
        while (j < chunk_len) : (j += 1) {
            const b = data[i + j];
            if (b >= 32 and b <= 126) {
                try list.append(allocator, b);
            } else {
                try list.append(allocator, '.');
            }
        }
        try list.appendSlice(allocator, "|\n");

        i += chunk_len;
    }

    return list.toOwnedSlice(allocator);
}

test "hex encode and decode" {
    const testing = std.testing;
    const input = "Hello, Gophers and Ziggers!";
    const encoded = try encodeToString(testing.allocator, input);
    defer testing.allocator.free(encoded);

    const decoded = try decodeString(testing.allocator, encoded);
    defer testing.allocator.free(decoded);

    try testing.expectEqualStrings(input, decoded);
}

test "hex dump format" {
    const testing = std.testing;
    const input = "Go + Zig = StdGo!";
    const d = try dump(testing.allocator, input);
    defer testing.allocator.free(d);

    try testing.expect(std.mem.startsWith(u8, d, "00000000  "));
    try testing.expect(std.mem.indexOf(u8, d, "|Go + Zig = StdGo|") != null);
    try testing.expect(std.mem.indexOf(u8, d, "|!|") != null);
}
