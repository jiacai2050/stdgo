//! Package strconv implements conversions to and from string representations
//! of basic data types (integers, floating-point numbers, booleans, and quoted strings).

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Error = error{
    SyntaxError,
    RangeError,
    OutOfMemory,
};

/// ParseBool returns the boolean value represented by the string.
/// It accepts 1, t, T, TRUE, true, True, 0, f, F, FALSE, false, False.
/// Any other value returns error.SyntaxError.
pub fn parseBool(str: []const u8) error{SyntaxError}!bool {
    if (mem.eql(u8, str, "1") or mem.eql(u8, str, "t") or mem.eql(u8, str, "T") or
        mem.eql(u8, str, "true") or mem.eql(u8, str, "TRUE") or mem.eql(u8, str, "True"))
    {
        return true;
    }
    if (mem.eql(u8, str, "0") or mem.eql(u8, str, "f") or mem.eql(u8, str, "F") or
        mem.eql(u8, str, "false") or mem.eql(u8, str, "FALSE") or mem.eql(u8, str, "False"))
    {
        return false;
    }
    return error.SyntaxError;
}

/// FormatBool returns "true" or "false" according to the value of b.
pub fn formatBool(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// ParseInt interprets a string s in the given base (0, 2 to 36) and
/// bit size (0 to 64) and returns the corresponding value i.
///
/// If base == 0, the base is implied by the string's prefix:
/// 2 for "0b", 8 for "0o" or "0", 16 for "0x", and 10 otherwise.
pub fn parseInt(s: []const u8, base: u8, bit_size: u8) error{ SyntaxError, RangeError }!i64 {
    if (s.len == 0) return error.SyntaxError;

    var p = s;
    var neg = false;
    if (p[0] == '+') {
        p = p[1..];
    } else if (p[0] == '-') {
        neg = true;
        p = p[1..];
    }

    if (p.len == 0) return error.SyntaxError;

    var actual_base: u8 = base;
    if (base == 0) {
        if (p.len >= 2 and p[0] == '0') {
            switch (p[1]) {
                'x', 'X' => {
                    actual_base = 16;
                    p = p[2..];
                },
                'b', 'B' => {
                    actual_base = 2;
                    p = p[2..];
                },
                'o', 'O' => {
                    actual_base = 8;
                    p = p[2..];
                },
                else => {
                    actual_base = 8;
                    p = p[1..];
                },
            }
        } else {
            actual_base = 10;
        }
    } else if (base == 16 and p.len >= 2 and p[0] == '0' and (p[1] == 'x' or p[1] == 'X')) {
        p = p[2..];
    }

    if (p.len == 0) return error.SyntaxError;
    if (actual_base < 2 or actual_base > 36) return error.SyntaxError;

    const actual_bits: u8 = if (bit_size == 0) 64 else bit_size;
    if (actual_bits > 64) return error.RangeError;

    var val: u64 = 0;
    const cutoff: u64 = 0x7fffffffffffffff / @as(u64, actual_base);

    for (p) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            '_' => continue, // support Go 1.13+ digit separators
            else => return error.SyntaxError,
        };
        if (d >= actual_base) return error.SyntaxError;

        if (val > cutoff) return error.RangeError;
        val *= actual_base;

        const limit: u64 = if (neg) 0x8000000000000000 else 0x7fffffffffffffff;
        if (val > limit - d) return error.RangeError;
        val += d;
    }

    // Range check for smaller bit sizes
    if (actual_bits < 64) {
        const sub_term: u64 = if (neg) 0 else 1;
        const max_val: u64 = (@as(u64, 1) << @intCast(actual_bits - 1)) - sub_term;
        if (val > max_val) return error.RangeError;
    }

    if (neg) {
        if (val == 0x8000000000000000) return std.math.minInt(i64);
        return -@as(i64, @intCast(val));
    }
    return @intCast(val);
}

/// ParseUint is like ParseInt but for unsigned numbers.
/// A sign prefix is not permitted.
pub fn parseUint(s: []const u8, base: u8, bit_size: u8) error{ SyntaxError, RangeError }!u64 {
    if (s.len == 0) return error.SyntaxError;
    if (s[0] == '-' or s[0] == '+') return error.SyntaxError;

    var p = s;
    var actual_base: u8 = base;
    if (base == 0) {
        if (p.len >= 2 and p[0] == '0') {
            switch (p[1]) {
                'x', 'X' => {
                    actual_base = 16;
                    p = p[2..];
                },
                'b', 'B' => {
                    actual_base = 2;
                    p = p[2..];
                },
                'o', 'O' => {
                    actual_base = 8;
                    p = p[2..];
                },
                else => {
                    actual_base = 8;
                    p = p[1..];
                },
            }
        } else {
            actual_base = 10;
        }
    } else if (base == 16 and p.len >= 2 and p[0] == '0' and (p[1] == 'x' or p[1] == 'X')) {
        p = p[2..];
    }

    if (p.len == 0) return error.SyntaxError;
    if (actual_base < 2 or actual_base > 36) return error.SyntaxError;

    const actual_bits: u8 = if (bit_size == 0) 64 else bit_size;
    if (actual_bits > 64) return error.RangeError;

    var val: u64 = 0;
    const cutoff: u64 = 0xffffffffffffffff / @as(u64, actual_base);

    for (p) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            '_' => continue,
            else => return error.SyntaxError,
        };
        if (d >= actual_base) return error.SyntaxError;

        if (val > cutoff) return error.RangeError;
        val *= actual_base;

        if (val > 0xffffffffffffffff - @as(u64, d)) return error.RangeError;
        val += d;
    }

    if (actual_bits < 64) {
        const max_val: u64 = (@as(u64, 1) << @intCast(actual_bits)) - 1;
        if (val > max_val) return error.RangeError;
    }

    return val;
}

/// Atoi is equivalent to ParseInt(s, 10, 0), converted to type int (i64 in Zig).
pub fn atoi(s: []const u8) error{ SyntaxError, RangeError }!i64 {
    return parseInt(s, 10, 0);
}

/// Itoa is equivalent to FormatInt(int64(i), 10).
pub fn itoa(allocator: Allocator, v: i64) ![]u8 {
    return formatInt(allocator, v, 10);
}

/// FormatUint returns the string representation of i in the given base,
/// for 2 <= base <= 36.
pub fn formatUint(allocator: Allocator, v: u64, base: u8) ![]u8 {
    if (base < 2 or base > 36) return error.SyntaxError;

    var buf: [65]u8 = undefined;
    var uval = v;

    var i: usize = buf.len;
    if (uval == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        while (uval > 0) {
            i -= 1;
            buf[i] = digits[@intCast(uval % base)];
            uval /= base;
        }
    }

    return try allocator.dupe(u8, buf[i..]);
}

/// FormatInt returns the string representation of i in the given base,
/// for 2 <= base <= 36. The result uses the lower-case letters 'a' to 'z'
/// for digit values >= 10.
pub fn formatInt(allocator: Allocator, v: i64, base: u8) ![]u8 {
    if (base < 2 or base > 36) return error.SyntaxError;

    var buf: [65]u8 = undefined;
    var uval: u64 = 0;
    var neg = false;

    if (v < 0) {
        neg = true;
        uval = @intCast(-(v + 1));
        uval += 1;
    } else {
        uval = @intCast(v);
    }

    var i: usize = buf.len;
    if (uval == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        while (uval > 0) {
            i -= 1;
            buf[i] = digits[@intCast(uval % base)];
            uval /= base;
        }
    }

    if (neg) {
        i -= 1;
        buf[i] = '-';
    }

    return try allocator.dupe(u8, buf[i..]);
}

/// ParseFloat converts the string s to a floating-point number
/// with the precision specified by bit_size: 32 for float32, or 64 for float64.
pub fn parseFloat(s: []const u8, bit_size: u8) error{ SyntaxError, RangeError }!f64 {
    _ = bit_size;
    if (s.len == 0) return error.SyntaxError;

    if (mem.eql(u8, s, "NaN") or mem.eql(u8, s, "nan")) return std.math.nan(f64);
    if (mem.eql(u8, s, "+Inf") or mem.eql(u8, s, "Inf") or
        mem.eql(u8, s, "+inf") or mem.eql(u8, s, "inf"))
    {
        return std.math.inf(f64);
    }
    if (mem.eql(u8, s, "-Inf") or mem.eql(u8, s, "-inf")) return -std.math.inf(f64);

    return std.fmt.parseFloat(f64, s) catch return error.SyntaxError;
}

/// FormatFloat converts the floating-point number f to a string,
/// according to the format fmt ('f', 'e', 'E', 'g', 'G', 'x', 'X') and precision prec.
pub fn formatFloat(allocator: Allocator, v: f64, fmt: u8, prec: ?usize, bit_size: u8) ![]u8 {
    _ = bit_size;
    if (prec) |p| {
        return switch (fmt) {
            'e', 'E' => std.fmt.allocPrint(allocator, "{e:.[1]}", .{ v, p }),
            'x', 'X' => std.fmt.allocPrint(allocator, "{x:.[1]}", .{ v, p }),
            else => std.fmt.allocPrint(allocator, "{d:.[1]}", .{ v, p }),
        };
    } else {
        return switch (fmt) {
            'e', 'E' => std.fmt.allocPrint(allocator, "{e}", .{v}),
            'x', 'X' => std.fmt.allocPrint(allocator, "{x}", .{v}),
            else => std.fmt.allocPrint(allocator, "{d}", .{v}),
        };
    }
}

/// CanBackquote reports whether the string s would be safe to represent
/// unchanged as a single-line backquoted raw string without containing tabs,
/// newlines, backticks, or non-printable ASCII characters.
pub fn canBackquote(s: []const u8) bool {
    for (s) |c| {
        if (c < 32 or c == '`' or c == 127) {
            if (c != '\t') return false;
        }
    }
    return true;
}

/// Quote returns a double-quoted Go string literal representing s.
/// The returned string uses Go escape sequences (\t, \n, \", \\)
/// for control characters and non-printable characters.
pub fn quote(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x07 => try out.appendSlice(allocator, "\\a"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x0b => try out.appendSlice(allocator, "\\v"),
            else => {
                if (c >= 32 and c <= 126) {
                    try out.append(allocator, c);
                } else {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, "\\x");
                    try out.append(allocator, hex[c >> 4]);
                    try out.append(allocator, hex[c & 0x0f]);
                }
            },
        }
    }
    try out.append(allocator, '"');

    return try out.toOwnedSlice(allocator);
}

/// Unquote interprets s as a single-quoted, double-quoted,
/// or backquoted Go string literal, returning the string value
/// that s quotes.
pub fn unquote(allocator: Allocator, s: []const u8) error{ SyntaxError, OutOfMemory }![]u8 {
    if (s.len < 2) return error.SyntaxError;
    const quote_char = s[0];
    if (quote_char != s[s.len - 1]) return error.SyntaxError;

    if (quote_char == '`') {
        const inner = s[1 .. s.len - 1];
        if (mem.indexOfScalar(u8, inner, '`') != null) return error.SyntaxError;
        return try allocator.dupe(u8, inner);
    }

    if (quote_char != '"' and quote_char != '\'') return error.SyntaxError;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const inner = s[1 .. s.len - 1];
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\\') {
            if (i + 1 >= inner.len) return error.SyntaxError;
            const esc = inner[i + 1];
            switch (esc) {
                'a' => {
                    try out.append(allocator, 0x07);
                    i += 2;
                },
                'b' => {
                    try out.append(allocator, 0x08);
                    i += 2;
                },
                'f' => {
                    try out.append(allocator, 0x0c);
                    i += 2;
                },
                'n' => {
                    try out.append(allocator, '\n');
                    i += 2;
                },
                'r' => {
                    try out.append(allocator, '\r');
                    i += 2;
                },
                't' => {
                    try out.append(allocator, '\t');
                    i += 2;
                },
                'v' => {
                    try out.append(allocator, 0x0b);
                    i += 2;
                },
                '\\' => {
                    try out.append(allocator, '\\');
                    i += 2;
                },
                '\'' => {
                    try out.append(allocator, '\'');
                    i += 2;
                },
                '"' => {
                    try out.append(allocator, '"');
                    i += 2;
                },
                'x' => {
                    if (i + 3 >= inner.len) return error.SyntaxError;
                    const h1 = std.fmt.charToDigit(inner[i + 2], 16) catch return error.SyntaxError;
                    const h2 = std.fmt.charToDigit(inner[i + 3], 16) catch return error.SyntaxError;
                    try out.append(allocator, @as(u8, (h1 << 4) | h2));
                    i += 4;
                },
                else => return error.SyntaxError,
            }
        } else {
            if (c == quote_char) return error.SyntaxError;
            try out.append(allocator, c);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "strconv parseBool and formatBool" {
    const testing = std.testing;

    try testing.expect(try parseBool("1"));
    try testing.expect(try parseBool("true"));
    try testing.expect(try parseBool("True"));
    try testing.expect(try parseBool("TRUE"));
    try testing.expect(try parseBool("t"));

    try testing.expect(!try parseBool("0"));
    try testing.expect(!try parseBool("false"));
    try testing.expect(!try parseBool("False"));
    try testing.expect(!try parseBool("FALSE"));
    try testing.expect(!try parseBool("f"));

    try testing.expectError(error.SyntaxError, parseBool("yes"));
    try testing.expectError(error.SyntaxError, parseBool(""));

    try testing.expectEqualStrings("true", formatBool(true));
    try testing.expectEqualStrings("false", formatBool(false));
}

test "strconv parseInt and formatInt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    try testing.expectEqual(@as(i64, 42), try parseInt("42", 10, 64));
    try testing.expectEqual(@as(i64, -100), try parseInt("-100", 10, 64));
    try testing.expectEqual(@as(i64, 255), try parseInt("0xff", 0, 64));
    try testing.expectEqual(@as(i64, 5), try parseInt("0b101", 0, 64));
    try testing.expectEqual(@as(i64, 8), try parseInt("0o10", 0, 64));
    try testing.expectEqual(@as(i64, 1_000_000), try parseInt("1_000_000", 10, 64));

    // Range error
    try testing.expectError(error.RangeError, parseInt("128", 10, 8)); // i8 max is 127
    try testing.expectEqual(@as(i64, 127), try parseInt("127", 10, 8));

    // FormatInt
    const f1 = try formatInt(allocator, 255, 16);
    defer allocator.free(f1);
    try testing.expectEqualStrings("ff", f1);

    const f2 = try formatInt(allocator, -42, 10);
    defer allocator.free(f2);
    try testing.expectEqualStrings("-42", f2);

    // ParseUint and FormatUint
    try testing.expectEqual(@as(u64, 42), try parseUint("42", 10, 64));
    try testing.expectEqual(@as(u64, 0xff), try parseUint("0xff", 0, 64));
    try testing.expectError(error.SyntaxError, parseUint("-1", 10, 64));

    const fu = try formatUint(allocator, 255, 16);
    defer allocator.free(fu);
    try testing.expectEqualStrings("ff", fu);

    // Atoi and Itoa
    try testing.expectEqual(@as(i64, 12345), try atoi("12345"));
    const s_itoa = try itoa(allocator, 12345);
    defer allocator.free(s_itoa);
    try testing.expectEqualStrings("12345", s_itoa);
}

test "strconv parseFloat and formatFloat" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f = try parseFloat("3.14159", 64);
    try testing.expectApproxEqAbs(@as(f64, 3.14159), f, 0.00001);

    try testing.expect(std.math.isNan(try parseFloat("NaN", 64)));
    try testing.expect(std.math.isPositiveInf(try parseFloat("+Inf", 64)));

    const s = try formatFloat(allocator, 3.14159, 'f', 2, 64);
    defer allocator.free(s);
    try testing.expectEqualStrings("3.14", s);
}

test "strconv quote and unquote" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw = "Hello, \"World\"!\nLine 2\tTab";
    const quoted = try quote(allocator, raw);
    defer allocator.free(quoted);
    try testing.expectEqualStrings("\"Hello, \\\"World\\\"!\\nLine 2\\tTab\"", quoted);

    const unquoted = try unquote(allocator, quoted);
    defer allocator.free(unquoted);
    try testing.expectEqualStrings(raw, unquoted);

    // Raw backquoted string
    const raw_backquote = "`hello world`";
    const unquoted_raw = try unquote(allocator, raw_backquote);
    defer allocator.free(unquoted_raw);
    try testing.expectEqualStrings("hello world", unquoted_raw);

    try testing.expect(canBackquote("hello world"));
    try testing.expect(!canBackquote("hello ` world"));
}
