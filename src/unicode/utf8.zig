//! Package unicode/utf8 implements functions and constants to support text encoded in UTF-8.
//! It implements the Unicode Standard and RFC 3629.

const std = @import("std");

/// Numbers fundamental to the encoding.
pub const RuneError: u21 = 0xFFFD; // the "error" Rune or "Unicode replacement character"
// Characters below RuneSelf are represented as themselves in a single byte
pub const RuneSelf: u8 = 0x80;
pub const MaxRune: u21 = 0x10FFFF; // maximum valid Unicode code point
pub const UTFMax: usize = 4; // maximum number of bytes of a UTF-8 encoded Unicode character

/// Code points in the surrogate range are not valid Unicode code points.
pub const surrogate_min: u21 = 0xD800;
pub const surrogate_max: u21 = 0xDFFF;

const t1: u8 = 0b00000000;
const tx: u8 = 0b10000000;
const t2: u8 = 0b11000000;
const t3: u8 = 0b11100000;
const t4: u8 = 0b11110000;
const t5: u8 = 0b11111000;

const maskx: u8 = 0b00111111;
const mask2: u8 = 0b00011111;
const mask3: u8 = 0b00001111;
const mask4: u8 = 0b00000111;

const rune1_max: u21 = (1 << 7) - 1;
const rune2_max: u21 = (1 << 11) - 1;
const rune3_max: u21 = (1 << 16) - 1;

/// Decoded represents the rune and number of bytes decoded.
pub const Decoded = struct {
    rune: u21,
    size: usize,
};

/// fullRune reports whether the bytes in p begin with a full UTF-8 encoding of a rune.
/// An invalid encoding is considered a full Rune since it will convert as a RuneError.
pub fn fullRune(p: []const u8) bool {
    if (p.len == 0) return false;
    const x = p[0];
    if (x < RuneSelf) return true;
    if (x < t2) return true; // invalid byte is treated as full rune (RuneError, size 1)

    if (x < t3) {
        return p.len >= 2;
    } else if (x < t4) {
        return p.len >= 3;
    } else if (x < t5) {
        return p.len >= 4;
    }
    return true; // invalid lead byte
}

/// fullRuneInString is like fullRune but its input is a string.
pub fn fullRuneInString(s: []const u8) bool {
    return fullRune(s);
}

/// decodeRune unpacks the first UTF-8 encoding in p and returns the rune and
/// its width in bytes. If p is empty it returns { RuneError, 0 }. Otherwise, if
/// the encoding is invalid, it returns { RuneError, 1 }. Both are impossible
/// results for correct, non-empty UTF-8.
pub fn decodeRune(p: []const u8) Decoded {
    if (p.len == 0) return .{ .rune = RuneError, .size = 0 };

    const b0 = p[0];
    if (b0 < RuneSelf) {
        return .{ .rune = b0, .size = 1 };
    }

    // 2-byte sequence: 110xxxxx 10xxxxxx
    if (b0 >= t2 and b0 < t3) {
        if (p.len < 2) return .{ .rune = RuneError, .size = 1 };
        const b1 = p[1];
        if (b1 < tx or b1 >= t2) return .{ .rune = RuneError, .size = 1 };

        const r: u21 = (@as(u21, b0 & mask2) << 6) | @as(u21, b1 & maskx);
        if (r <= rune1_max) return .{ .rune = RuneError, .size = 1 }; // non-shortest
        return .{ .rune = r, .size = 2 };
    }

    // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
    if (b0 >= t3 and b0 < t4) {
        if (p.len < 3) {
            // If second byte is already known to be invalid, report error size 1
            return .{ .rune = RuneError, .size = 1 };
        }
        const b1 = p[1];
        const b2 = p[2];
        if (b1 < tx or b1 >= t2 or b2 < tx or b2 >= t2) return .{ .rune = RuneError, .size = 1 };

        const r: u21 = (@as(u21, b0 & mask3) << 12) |
            (@as(u21, b1 & maskx) << 6) | @as(u21, b2 & maskx);
        if (r <= rune2_max) return .{ .rune = RuneError, .size = 1 }; // non-shortest
        // surrogate
        if (r >= surrogate_min and r <= surrogate_max) {
            return .{ .rune = RuneError, .size = 1 };
        }
        return .{ .rune = r, .size = 3 };
    }

    // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if (b0 >= t4 and b0 < t5) {
        if (p.len < 4) return .{ .rune = RuneError, .size = 1 };
        const b1 = p[1];
        const b2 = p[2];
        const b3 = p[3];
        if (b1 < tx or b1 >= t2 or b2 < tx or b2 >= t2 or b3 < tx or b3 >= t2) {
            return .{ .rune = RuneError, .size = 1 };
        }

        const r: u21 = (@as(u21, b0 & mask4) << 18) |
            (@as(u21, b1 & maskx) << 12) |
            (@as(u21, b2 & maskx) << 6) |
            @as(u21, b3 & maskx);
        if (r <= rune3_max) return .{ .rune = RuneError, .size = 1 }; // non-shortest
        if (r > MaxRune) return .{ .rune = RuneError, .size = 1 }; // beyond Unicode limit
        return .{ .rune = r, .size = 4 };
    }

    return .{ .rune = RuneError, .size = 1 };
}

/// decodeRuneInString is like decodeRune but its input is a string.
pub fn decodeRuneInString(s: []const u8) Decoded {
    return decodeRune(s);
}

/// decodeLastRune unpacks the last UTF-8 encoding in p and returns the rune and
/// its width in bytes. If p is empty it returns { RuneError, 0 }. Otherwise, if
/// the encoding is invalid, it returns { RuneError, 1 }.
pub fn decodeLastRune(p: []const u8) Decoded {
    if (p.len == 0) return .{ .rune = RuneError, .size = 0 };

    var start: usize = p.len - 1;
    // Walk back at most UTFMax bytes to locate sequence start
    const limit = if (p.len > UTFMax) p.len - UTFMax else 0;
    while (start > limit and (p[start] >= tx and p[start] < t2)) : (start -= 1) {}

    const decoded = decodeRune(p[start..]);
    if (start + decoded.size == p.len) {
        return decoded;
    }
    return .{ .rune = RuneError, .size = 1 };
}

/// decodeLastRuneInString is like decodeLastRune but its input is a string.
pub fn decodeLastRuneInString(s: []const u8) Decoded {
    return decodeLastRune(s);
}

/// runeLen returns the number of bytes in the UTF-8 encoding of the rune.
/// It returns null if the rune is not a valid value to encode in UTF-8.
pub fn runeLen(r: u21) ?usize {
    if (r < 0 or r > MaxRune) return null;
    if (r >= surrogate_min and r <= surrogate_max) return null;

    if (r <= rune1_max) return 1;
    if (r <= rune2_max) return 2;
    if (r <= rune3_max) return 3;
    return 4;
}

/// encodeRune writes into p (which must be large enough, at least UTFMax bytes)
/// the UTF-8 encoding of the rune. It returns the number of bytes written.
/// If the rune is out of range, it writes the encoding of RuneError.
pub fn encodeRune(p: []u8, r_in: u21) usize {
    var r = r_in;
    if (r > MaxRune or (r >= surrogate_min and r <= surrogate_max)) {
        r = RuneError;
    }

    if (r <= rune1_max) {
        p[0] = @truncate(r);
        return 1;
    } else if (r <= rune2_max) {
        p[0] = t2 | @as(u8, @truncate(r >> 6));
        p[1] = tx | (@as(u8, @truncate(r)) & maskx);
        return 2;
    } else if (r <= rune3_max) {
        p[0] = t3 | @as(u8, @truncate(r >> 12));
        p[1] = tx | (@as(u8, @truncate(r >> 6)) & maskx);
        p[2] = tx | (@as(u8, @truncate(r)) & maskx);
        return 3;
    } else {
        p[0] = t4 | @as(u8, @truncate(r >> 18));
        p[1] = tx | (@as(u8, @truncate(r >> 12)) & maskx);
        p[2] = tx | (@as(u8, @truncate(r >> 6)) & maskx);
        p[3] = tx | (@as(u8, @truncate(r)) & maskx);
        return 4;
    }
}

/// runeCount returns the number of runes in p. Erroneous and short
/// encodings are treated as single runes of width 1 byte.
pub fn runeCount(p: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] < RuneSelf) {
            i += 1;
        } else {
            const d = decodeRune(p[i..]);
            i += d.size;
        }
        count += 1;
    }
    return count;
}

/// runeCountInString is like runeCount but its input is a string.
pub fn runeCountInString(s: []const u8) usize {
    return runeCount(s);
}

/// validRune reports whether r can be legally encoded as UTF-8.
pub fn validRune(r: u21) bool {
    if (r > MaxRune) return false;
    if (r >= surrogate_min and r <= surrogate_max) return false;
    return true;
}

/// valid reports whether p consists entirely of valid UTF-8-encoded runes.
pub fn valid(p: []const u8) bool {
    var i: usize = 0;
    while (i < p.len) {
        const b = p[i];
        if (b < RuneSelf) {
            i += 1;
            continue;
        }
        const d = decodeRune(p[i..]);
        if (d.rune == RuneError and d.size == 1) {
            return false;
        }
        i += d.size;
    }
    return true;
}

/// validString reports whether s consists entirely of valid UTF-8-encoded runes.
pub fn validString(s: []const u8) bool {
    return valid(s);
}

// -------------------------------------------------------------------------
// Unit Tests conforming to official Go unicode/utf8 test suite
// -------------------------------------------------------------------------

test "unicode.utf8: decodeRune and encodeRune" {
    const testing = std.testing;

    const cases = [_]struct {
        r: u21,
        bytes: []const u8,
    }{
        .{ .r = 0, .bytes = "\x00" },
        .{ .r = 'a', .bytes = "a" },
        .{ .r = 0x7F, .bytes = "\x7F" },
        .{ .r = 0x80, .bytes = "\xC2\x80" },
        .{ .r = 0xFF, .bytes = "\xC3\xBF" },
        .{ .r = 0x100, .bytes = "\xC4\x80" },
        .{ .r = 0x4E2D, .bytes = "中" },
        .{ .r = 0x6587, .bytes = "文" },
        .{ .r = 0x1F600, .bytes = "😀" },
        .{ .r = MaxRune, .bytes = "\xF4\x8F\xBF\xBF" },
    };

    for (cases) |c| {
        // Decode
        const dec = decodeRune(c.bytes);
        try testing.expectEqual(c.r, dec.rune);
        try testing.expectEqual(c.bytes.len, dec.size);

        // Encode
        var buf: [UTFMax]u8 = undefined;
        const n = encodeRune(&buf, c.r);
        try testing.expectEqual(c.bytes.len, n);
        try testing.expectEqualSlices(u8, c.bytes, buf[0..n]);

        // RuneLen
        try testing.expectEqual(@as(?usize, c.bytes.len), runeLen(c.r));
    }
}

test "unicode.utf8: decodeLastRune" {
    const testing = std.testing;

    const s = "Hello, 世界😀";
    const last = decodeLastRune(s);
    try testing.expectEqual(@as(u21, 0x1F600), last.rune);
    try testing.expectEqual(@as(usize, 4), last.size);

    const prev = decodeLastRune(s[0 .. s.len - last.size]);
    try testing.expectEqual(@as(u21, 0x754C), prev.rune); // 界
    try testing.expectEqual(@as(usize, 3), prev.size);
}

test "unicode.utf8: runeCount and runeCountInString" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), runeCountInString(""));
    try testing.expectEqual(@as(usize, 5), runeCountInString("Hello"));
    try testing.expectEqual(@as(usize, 2), runeCountInString("世界"));
    try testing.expectEqual(@as(usize, 9), runeCountInString("Hello, 世界"));
    try testing.expectEqual(@as(usize, 10), runeCountInString("Hello, 世界😀"));
}

test "unicode.utf8: valid and validString" {
    const testing = std.testing;

    try testing.expect(validString(""));
    try testing.expect(validString("a"));
    try testing.expect(validString("Hello, 世界!"));
    try testing.expect(validString("😀🎉"));

    // Invalid sequences:
    try testing.expect(!valid(&[_]u8{0xFF})); // invalid lead byte
    try testing.expect(!valid(&[_]u8{ 0xC0, 0x80 })); // non-shortest representation of 0x00
    try testing.expect(!valid(&[_]u8{ 0xED, 0xA0, 0x80 })); // surrogate 0xD800
    try testing.expect(!valid(&[_]u8{ 0xF4, 0x90, 0x80, 0x80 })); // beyond MaxRune (0x110000)
    try testing.expect(!valid(&[_]u8{ 0xE4, 0xB8 })); // truncated 3-byte sequence
}

test "unicode.utf8: fullRune" {
    const testing = std.testing;

    try testing.expect(!fullRune(&.{}));
    try testing.expect(fullRune("a"));
    try testing.expect(!fullRune("中"[0..2])); // truncated 3-byte
    try testing.expect(fullRune("中"));
    try testing.expect(!fullRune("😀"[0..3])); // truncated 4-byte
    try testing.expect(fullRune("😀"));
}
