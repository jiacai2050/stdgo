//! Unicode category classification, casing rules, and simple case folding
//! conforming to Go's unicode package.
const std = @import("std");

pub const MaxRune: u21 = 0x10FFFF;
pub const ReplacementChar: u21 = 0xFFFD;
pub const MaxASCII: u21 = 0x7F;
pub const MaxLatin1: u21 = 0xFF;

/// Range16 represents a range of 16-bit Unicode code points [lo, hi] with a step stride.
pub const Range16 = struct {
    lo: u16,
    hi: u16,
    stride: u16 = 1,
};

/// Range32 represents a range of Unicode code points [lo, hi] with a step stride.
pub const Range32 = struct {
    lo: u32,
    hi: u32,
    stride: u32 = 1,
};

/// RangeTable defines a set of Unicode code points by listing the ranges of code points.
pub const RangeTable = struct {
    r16: []const Range16 = &.{},
    r32: []const Range32 = &.{},
    latin_offset: i32 = 0,
};

/// Is reports whether the rune is in the specified table of ranges.
pub fn is(table: RangeTable, r: u21) bool {
    if (r <= 0xFFFF) {
        const r16: u16 = @intCast(r);
        for (table.r16) |range| {
            if (r16 < range.lo) break;
            if (r16 <= range.hi) {
                if (range.stride == 1 or (r16 - range.lo) % range.stride == 0) return true;
            }
        }
    } else {
        const r32: u32 = @intCast(r);
        for (table.r32) |range| {
            if (r32 < range.lo) break;
            if (r32 <= range.hi) {
                if (range.stride == 1 or (r32 - range.lo) % range.stride == 0) return true;
            }
        }
    }
    return false;
}

/// IsDigit reports whether the rune is a decimal digit (0-9 or fullwidth/Unicode digits).
pub fn isDigit(r: u21) bool {
    if (r <= MaxLatin1) {
        return r >= '0' and r <= '9';
    }
    // Arabic-Indic, Extended, Devanagari, Fullwidth, etc.
    return (r >= 0x0660 and r <= 0x0669) or
        (r >= 0x06F0 and r <= 0x06F9) or
        (r >= 0x0966 and r <= 0x096F) or
        (r >= 0xFF10 and r <= 0xFF19);
}

/// IsNumber reports whether the rune is a number category (digit or numeric symbol).
pub fn isNumber(r: u21) bool {
    if (isDigit(r)) return true;
    // Roman numerals, fractions, enclosed numbers
    return (r >= 0x2150 and r <= 0x218F) or
        (r >= 0x2460 and r <= 0x249B);
}

/// IsLetter reports whether the rune is a letter (category L).
pub fn isLetter(r: u21) bool {
    if (r <= MaxLatin1) {
        return (r >= 'a' and r <= 'z') or
            (r >= 'A' and r <= 'Z') or
            (r >= 0xC0 and r <= 0xD6) or
            (r >= 0xD8 and r <= 0xF6) or
            (r >= 0xF8 and r <= 0xFF);
    }
    // CJK Unified Ideographs, Cyrillic, Greek, etc.
    return (r >= 0x0100 and r <= 0x024F) or // Latin Extended
        (r >= 0x0370 and r <= 0x03FF) or // Greek
        (r >= 0x0400 and r <= 0x04FF) or // Cyrillic
        (r >= 0x4E00 and r <= 0x9FFF) or // CJK Unified Ideographs
        (r >= 0x3400 and r <= 0x4DBF) or // CJK Extension A
        (r >= 0x3040 and r <= 0x309F) or // Hiragana
        (r >= 0x30A0 and r <= 0x30FF) or // Katakana
        (r >= 0xAC00 and r <= 0xD7AF); // Hangul Syllables
}

/// IsSpace reports whether the rune is a white space character as defined by Unicode.
pub fn isSpace(r: u21) bool {
    if (r <= MaxLatin1) {
        return switch (r) {
            '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0x85, 0xA0 => true,
            else => false,
        };
    }
    return switch (r) {
        0x1680 => true, // Ogham Space Mark
        0x2000...0x200A => true, // En/Em spaces, thin space, hair space
        0x2028, 0x2029 => true, // Line/Paragraph separator
        0x202F => true, // Narrow No-Break Space
        0x205F => true, // Medium Mathematical Space
        0x3000 => true, // Ideographic Space (Fullwidth space)
        else => false,
    };
}

/// IsPunct reports whether the rune is a Unicode punctuation character.
pub fn isPunct(r: u21) bool {
    if (r <= MaxLatin1) {
        return switch (r) {
            '!',
            '"',
            '#',
            '%',
            '&',
            '\'',
            '(',
            ')',
            '*',
            ',',
            '-',
            '.',
            '/',
            ':',
            ';',
            '?',
            '@',
            '[',
            '\\',
            ']',
            '_',
            '{',
            '}',
            => true,
            0xA1, 0xA7, 0xAB, 0xB6, 0xB7, 0xBB, 0xBF => true,
            else => false,
        };
    }
    // CJK punctuation (。、“”《》 etc.) and General Punctuation (0x2000-0x206F)
    return (r >= 0x2010 and r <= 0x2027) or
        (r >= 0x2030 and r <= 0x205E) or
        (r >= 0x3001 and r <= 0x3003) or
        (r >= 0x3008 and r <= 0x301F) or
        (r >= 0xFF01 and r <= 0xFF0F) or
        (r >= 0xFF1A and r <= 0xFF20);
}

/// IsControl reports whether the rune is a control character (Cc).
pub fn isControl(r: u21) bool {
    if (r <= 0x1F or (r >= 0x7F and r <= 0x9F)) return true;
    return false;
}

/// IsUpper reports whether the rune is an upper case letter.
pub fn isUpper(r: u21) bool {
    if (r <= MaxLatin1) {
        return (r >= 'A' and r <= 'Z') or (r >= 0xC0 and r <= 0xD6) or (r >= 0xD8 and r <= 0xDE);
    }
    if (r >= 0x0100 and r <= 0x0178 and (r % 2 == 0)) return true; // Latin Extended-A pairs
    if (r >= 0x0410 and r <= 0x042F) return true; // Cyrillic Capital
    return false;
}

/// IsLower reports whether the rune is a lower case letter.
pub fn isLower(r: u21) bool {
    if (r <= MaxLatin1) {
        return (r >= 'a' and r <= 'z') or (r >= 0xDF and r <= 0xF6) or (r >= 0xF8 and r <= 0xFF);
    }
    if (r >= 0x0101 and r <= 0x017F and (r % 2 != 0)) return true; // Latin Extended-A pairs
    if (r >= 0x0430 and r <= 0x044F) return true; // Cyrillic Small
    return false;
}

/// ToUpper maps the rune to upper case.
pub fn toUpper(r: u21) u21 {
    if (r <= MaxASCII) {
        if (r >= 'a' and r <= 'z') return r - ('a' - 'A');
        return r;
    }
    if (r >= 0xE0 and r <= 0xF6) return r - 0x20;
    if (r >= 0xF8 and r <= 0xFE) return r - 0x20;
    if (r >= 0x0101 and r <= 0x017F and (r % 2 != 0)) return r - 1;
    if (r >= 0x0430 and r <= 0x044F) return r - 0x20;
    return r;
}

/// ToLower maps the rune to lower case.
pub fn toLower(r: u21) u21 {
    if (r <= MaxASCII) {
        if (r >= 'A' and r <= 'Z') return r + ('a' - 'A');
        return r;
    }
    if (r >= 0xC0 and r <= 0xD6) return r + 0x20;
    if (r >= 0xD8 and r <= 0xDE) return r + 0x20;
    if (r >= 0x0100 and r <= 0x0178 and (r % 2 == 0)) return r + 1;
    if (r >= 0x0410 and r <= 0x042F) return r + 0x20;
    return r;
}

/// SimpleFold iterates over Unicode code points equivalent under simple case folding.
/// Successive calls starting with any rune r in an equivalence class cycle through the class.
pub fn simpleFold(r: u21) u21 {
    // Special multi-rune folding cycles
    switch (r) {
        'K', 'k' => return if (r == 'K') 'k' else 0x212A, // Kelvin sign K
        0x212A => return 'K',
        'S', 's' => return if (r == 'S') 's' else 0x017F, // Latin small letter long s ſ
        0x017F => return 'S',
        0x00B5 => return 0x03BC, // Micro sign µ -> Greek small letter mu μ
        0x03BC => return 0x00B5,
        0x00C5, 0x00E5 => return if (r == 0x00C5) 0x00E5 else 0x212B, // Angstrom sign Å
        0x212B => return 0x00C5,
        else => {},
    }

    // Default two-cycle pair: Upper <-> Lower
    if (isUpper(r)) {
        const l = toLower(r);
        if (l != r) return l;
    }
    if (isLower(r)) {
        const u = toUpper(r);
        if (u != r) return u;
    }

    return r;
}
