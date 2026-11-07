const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    BadPattern,
};

/// Match reports whether name matches the shell file name pattern.
/// The pattern syntax is:
///
/// pattern:
///     { term }
/// term:
///     '*'         matches any sequence of non-/ characters
///     '?'         matches any single non-/ character
///     '[' [ '^' ] { character-range } ']'
///                 character class (must be non-empty)
///     c           matches character c (c != '*', '?', '\\', '[')
///     '\\' c      matches character c
///
/// character-range:
///     c           matches character c (c != '\\', '-', ']')
///     '\\' c      matches character c
///     lo '-' hi   matches character c for lo <= c <= hi
///
/// Match requires pattern to match all of name, not just a substring.
pub fn match(pattern_in: []const u8, name_in: []const u8) Error!bool {
    var pattern = pattern_in;
    var name = name_in;

    pattern_loop: while (pattern.len > 0) {
        const chunk_res = scanChunk(pattern);
        const star = chunk_res.star;
        const chunk = chunk_res.chunk;
        pattern = chunk_res.rest;

        if (star and chunk.len == 0) {
            // Trailing * matches rest of string unless it has a '/'.
            return std.mem.indexOfScalar(u8, name, '/') == null;
        }

        // Look for match at current position.
        const m_res = try matchChunk(chunk, name);
        if (m_res.ok and (m_res.rest.len == 0 or pattern.len > 0)) {
            name = m_res.rest;
            continue;
        }

        if (star) {
            // Look for match skipping i+1 bytes. Cannot skip '/'.
            var i: usize = 0;
            while (i < name.len and name[i] != '/') : (i += 1) {
                const sub_res = try matchChunk(chunk, name[i + 1 ..]);
                if (sub_res.ok) {
                    if (pattern.len == 0 and sub_res.rest.len > 0) {
                        continue;
                    }
                    name = sub_res.rest;
                    continue :pattern_loop;
                }
            }
        }

        // Before returning false with no error,
        // check that the remainder of the pattern is syntactically valid.
        var rest_pat = pattern;
        while (rest_pat.len > 0) {
            const next_c = scanChunk(rest_pat);
            rest_pat = next_c.rest;
            _ = try matchChunk(next_c.chunk, "");
        }
        return false;
    }

    return name.len == 0;
}

const ScanChunkResult = struct {
    star: bool,
    chunk: []const u8,
    rest: []const u8,
};

fn scanChunk(pattern_in: []const u8) ScanChunkResult {
    var pattern = pattern_in;
    var star = false;
    while (pattern.len > 0 and pattern[0] == '*') {
        pattern = pattern[1..];
        star = true;
    }
    var in_range = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => {
                if (i + 1 < pattern.len) {
                    i += 1;
                }
            },
            '[' => in_range = true,
            ']' => in_range = false,
            '*' => {
                if (!in_range) {
                    return .{ .star = star, .chunk = pattern[0..i], .rest = pattern[i..] };
                }
            },
            else => {},
        }
    }
    return .{ .star = star, .chunk = pattern, .rest = "" };
}

const MatchChunkResult = struct {
    rest: []const u8,
    ok: bool,
};

fn matchChunk(chunk_in: []const u8, s_in: []const u8) Error!MatchChunkResult {
    var chunk = chunk_in;
    var s = s_in;
    var failed = false;

    while (chunk.len > 0) {
        failed = failed or s.len == 0;
        switch (chunk[0]) {
            '[' => {
                var r: u21 = 0;
                if (!failed) {
                    const utf8_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
                    if (s.len >= utf8_len) {
                        r = std.unicode.utf8Decode(s[0..utf8_len]) catch s[0];
                        s = s[utf8_len..];
                    } else {
                        r = s[0];
                        s = s[1..];
                    }
                }
                chunk = chunk[1..];
                var negated = false;
                if (chunk.len > 0 and chunk[0] == '^') {
                    negated = true;
                    chunk = chunk[1..];
                }

                var matched = false;
                var nrange: usize = 0;
                while (true) {
                    if (chunk.len > 0 and chunk[0] == ']' and nrange > 0) {
                        chunk = chunk[1..];
                        break;
                    }
                    const esc1 = try getEsc(chunk);
                    const lo = esc1.r;
                    chunk = esc1.rest;
                    var hi = lo;
                    if (chunk.len > 0 and chunk[0] == '-') {
                        const esc2 = try getEsc(chunk[1..]);
                        hi = esc2.r;
                        chunk = esc2.rest;
                    }
                    if (lo <= r and r <= hi) {
                        matched = true;
                    }
                    nrange += 1;
                }
                failed = failed or (matched == negated);
            },
            '?' => {
                if (!failed) {
                    failed = (s[0] == '/');
                    const utf8_len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
                    if (s.len >= utf8_len) {
                        s = s[utf8_len..];
                    } else {
                        s = s[1..];
                    }
                }
                chunk = chunk[1..];
            },
            '\\' => {
                chunk = chunk[1..];
                if (chunk.len == 0) return Error.BadPattern;
                if (!failed) {
                    failed = (chunk[0] != s[0]);
                    s = s[1..];
                }
                chunk = chunk[1..];
            },
            else => {
                if (!failed) {
                    failed = (chunk[0] != s[0]);
                    s = s[1..];
                }
                chunk = chunk[1..];
            },
        }
    }

    if (failed) {
        return .{ .rest = "", .ok = false };
    }
    return .{ .rest = s, .ok = true };
}

const EscResult = struct {
    r: u21,
    rest: []const u8,
};

fn getEsc(chunk_in: []const u8) Error!EscResult {
    var chunk = chunk_in;
    if (chunk.len == 0 or chunk[0] == '-' or chunk[0] == ']') {
        return Error.BadPattern;
    }
    if (chunk[0] == '\\') {
        chunk = chunk[1..];
        if (chunk.len == 0) return Error.BadPattern;
    }
    const utf8_len = std.unicode.utf8ByteSequenceLength(chunk[0]) catch 1;
    if (chunk.len < utf8_len) return Error.BadPattern;
    const r = std.unicode.utf8Decode(chunk[0..utf8_len]) catch return Error.BadPattern;
    return .{ .r = r, .rest = chunk[utf8_len..] };
}

test "path.match Go official table tests" {
    const testing = std.testing;

    const MatchTest = struct {
        pattern: []const u8,
        s: []const u8,
        matched: bool,
        expected_err: ?Error = null,
    };

    const cases = [_]MatchTest{
        .{ .pattern = "abc", .s = "abc", .matched = true },
        .{ .pattern = "*", .s = "abc", .matched = true },
        .{ .pattern = "*c", .s = "abc", .matched = true },
        .{ .pattern = "a*", .s = "a", .matched = true },
        .{ .pattern = "a*", .s = "abc", .matched = true },
        .{ .pattern = "a*", .s = "ab/c", .matched = false },
        .{ .pattern = "a*/b", .s = "abc/b", .matched = true },
        .{ .pattern = "a*/b", .s = "a/c/b", .matched = false },
        .{ .pattern = "a*b*c*d*e*/f", .s = "axbxcxdxe/f", .matched = true },
        .{ .pattern = "a*b*c*d*e*/f", .s = "axbxcxdxexxx/f", .matched = true },
        .{ .pattern = "a*b*c*d*e*/f", .s = "axbxcxdxe/xxx/f", .matched = false },
        .{ .pattern = "a*b*c*d*e*/f", .s = "axbxcxdxexxx/fff", .matched = false },
        .{ .pattern = "a*b?c*x", .s = "abxbbxdbxebxczzx", .matched = true },
        .{ .pattern = "a*b?c*x", .s = "abxbbxdbxebxczzy", .matched = false },
        .{ .pattern = "ab[c]", .s = "abc", .matched = true },
        .{ .pattern = "ab[b-d]", .s = "abc", .matched = true },
        .{ .pattern = "ab[e-g]", .s = "abc", .matched = false },
        .{ .pattern = "ab[^c]", .s = "abc", .matched = false },
        .{ .pattern = "ab[^b-d]", .s = "abc", .matched = false },
        .{ .pattern = "ab[^e-g]", .s = "abc", .matched = true },
        .{ .pattern = "a\\*b", .s = "a*b", .matched = true },
        .{ .pattern = "a\\*b", .s = "ab", .matched = false },
        .{ .pattern = "a?b", .s = "a☺b", .matched = true },
        .{ .pattern = "a[^a]b", .s = "a☺b", .matched = true },
        .{ .pattern = "a???b", .s = "a☺b", .matched = false },
        .{ .pattern = "a[^a][^a][^a]b", .s = "a☺b", .matched = false },
        .{ .pattern = "[a-ζ]*", .s = "α", .matched = true },
        .{ .pattern = "*[a-ζ]", .s = "A", .matched = false },
        .{ .pattern = "a?b", .s = "a/b", .matched = false },
        .{ .pattern = "a*b", .s = "a/b", .matched = false },
        .{ .pattern = "[\\]a]", .s = "]", .matched = true },
        .{ .pattern = "[\\-]", .s = "-", .matched = true },
        .{ .pattern = "[x\\-]", .s = "x", .matched = true },
        .{ .pattern = "[x\\-]", .s = "-", .matched = true },
        .{ .pattern = "[x\\-]", .s = "z", .matched = false },
        .{ .pattern = "[\\-x]", .s = "x", .matched = true },
        .{ .pattern = "[\\-x]", .s = "-", .matched = true },
        .{ .pattern = "[\\-x]", .s = "a", .matched = false },
        .{ .pattern = "[]a]", .s = "]", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[-]", .s = "-", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[x-]", .s = "x", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[x-]", .s = "-", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[x-]", .s = "z", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[-x]", .s = "x", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[-x]", .s = "-", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[-x]", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "\\", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[a-b-c]", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[^", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "[^bc", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "a[", .s = "a", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "a[", .s = "ab", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "a[", .s = "x", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "a/b[", .s = "x", .matched = false, .expected_err = Error.BadPattern },
        .{ .pattern = "*x", .s = "xxx", .matched = true },
    };

    for (cases) |c| {
        if (c.expected_err) |expected_e| {
            try testing.expectError(expected_e, match(c.pattern, c.s));
        } else {
            const actual = try match(c.pattern, c.s);
            try testing.expectEqual(c.matched, actual);
        }
    }
}
