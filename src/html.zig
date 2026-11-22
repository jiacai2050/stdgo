//! Package html provides functions for escaping and unescaping HTML text,
//! conforming to Go's standard html package.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const template = @import("html/template.zig");

/// EscapeString escapes special characters like "<" to become "&lt;". It
/// escapes only five characters: <, >, &, ', and ".
/// In accordance with Go's html.EscapeString:
/// - '&' -> "&amp;"
/// - '\'' -> "&#39;"
/// - '<' -> "&lt;"
/// - '>' -> "&gt;"
/// - '"' -> "&#34;"
pub fn escapeString(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&#34;"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

const NamedEntity = struct {
    name: []const u8,
    replacement: []const u8,
};

const named_entities = [_]NamedEntity{
    .{ .name = "amp;", .replacement = "&" },
    .{ .name = "lt;", .replacement = "<" },
    .{ .name = "gt;", .replacement = ">" },
    .{ .name = "quot;", .replacement = "\"" },
    .{ .name = "apos;", .replacement = "'" },
    .{ .name = "nbsp;", .replacement = "\u{00A0}" },
    .{ .name = "copy;", .replacement = "\u{00A9}" },
    .{ .name = "reg;", .replacement = "\u{00AE}" },
    .{ .name = "trade;", .replacement = "\u{2122}" },
    .{ .name = "cent;", .replacement = "\u{00A2}" },
    .{ .name = "pound;", .replacement = "\u{00A3}" },
    .{ .name = "yen;", .replacement = "\u{00A5}" },
    .{ .name = "euro;", .replacement = "\u{20AC}" },
};

/// UnescapeString unescapes HTML entities like "&lt;" to become "<".
/// It unescapes a larger range of entities than EscapeString escapes,
/// including numeric character references (such as "&#39;" or "&#x27;")
/// and common named character entities.
pub fn unescapeString(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        }

        // Entity candidate starting at '&'
        const rem = s[i + 1 ..];
        if (rem.len == 0) {
            try out.append(allocator, '&');
            i += 1;
            continue;
        }

        // Check for numeric entity: "&#..." or "&#x..."
        if (rem[0] == '#') {
            const num_part = rem[1..];
            if (num_part.len > 0 and (num_part[0] == 'x' or num_part[0] == 'X')) {
                // Hexadecimal numeric entity: &#x...;
                const hex_part = num_part[1..];
                if (mem.indexOfScalar(u8, hex_part, ';')) |semi| {
                    const hex_digits = hex_part[0..semi];
                    if (hex_digits.len > 0 and hex_digits.len <= 8) {
                        if (std.fmt.parseInt(u32, hex_digits, 16)) |code_point| {
                            var utf8_buf: [4]u8 = undefined;
                            const valid_cp: u21 = if (code_point <= 0x10FFFF)
                                @intCast(code_point)
                            else
                                0xFFFD;
                            const n = std.unicode.utf8Encode(valid_cp, &utf8_buf) catch 0;
                            if (n > 0) {
                                try out.appendSlice(allocator, utf8_buf[0..n]);
                                i += 1 + 1 + 1 + semi + 1; // '&' + '#' + 'x' + semi + ';'
                                continue;
                            }
                        } else |_| {}
                    }
                }
            } else {
                // Decimal numeric entity: &#...;
                if (mem.indexOfScalar(u8, num_part, ';')) |semi| {
                    const dec_digits = num_part[0..semi];
                    if (dec_digits.len > 0 and dec_digits.len <= 10) {
                        if (std.fmt.parseInt(u32, dec_digits, 10)) |code_point| {
                            var utf8_buf: [4]u8 = undefined;
                            const valid_cp: u21 = if (code_point <= 0x10FFFF)
                                @intCast(code_point)
                            else
                                0xFFFD;
                            const n = std.unicode.utf8Encode(valid_cp, &utf8_buf) catch 0;
                            if (n > 0) {
                                try out.appendSlice(allocator, utf8_buf[0..n]);
                                i += 1 + 1 + semi + 1; // '&' + '#' + semi + ';'
                                continue;
                            }
                        } else |_| {}
                    }
                }
            }
        }

        // Check named entities
        var matched = false;
        for (named_entities) |ne| {
            if (mem.startsWith(u8, rem, ne.name)) {
                try out.appendSlice(allocator, ne.replacement);
                i += 1 + ne.name.len;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        // No entity matched; append '&' verbatim
        try out.append(allocator, '&');
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = template;
}

test "html escapeString basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw = "<b>Hello & 'World' \"123\"</b>";
    const escaped = try escapeString(allocator, raw);
    defer allocator.free(escaped);

    const expected = "&lt;b&gt;Hello &amp; &#39;World&#39; &#34;123&#34;&lt;/b&gt;";
    try testing.expectEqualStrings(expected, escaped);
}

test "html unescapeString basic and numeric entities" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const escaped = "&lt;b&gt;Hello &amp; &#39;World&#39; &#34;123&#34;&lt;/b&gt;";
    const unescaped = try unescapeString(allocator, escaped);
    defer allocator.free(unescaped);

    try testing.expectEqualStrings("<b>Hello & 'World' \"123\"</b>", unescaped);

    // Named entities &copy;, &euro;, &nbsp;
    const entities = "&copy; 2026 stdgo &euro;50 &nbsp; done";
    const unescaped_ent = try unescapeString(allocator, entities);
    defer allocator.free(unescaped_ent);

    try testing.expectEqualStrings("\u{00A9} 2026 stdgo \u{20AC}50 \u{00A0} done", unescaped_ent);

    // Hex numeric entity &#x4e2d; ('中')
    const hex_ent = "Chinese: &#x4E2D;&#x6587;";
    const unescaped_hex = try unescapeString(allocator, hex_ent);
    defer allocator.free(unescaped_hex);

    try testing.expectEqualStrings("Chinese: 中文", unescaped_hex);
}

test "html unescapeString malformed or unclosed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw = "A & B &&lt; &#xyz; &#;";
    const unescaped = try unescapeString(allocator, raw);
    defer allocator.free(unescaped);

    try testing.expectEqualStrings("A & B &< &#xyz; &#;", unescaped);
}
