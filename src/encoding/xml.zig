fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const bytes = @import("../bytes.zig");

pub const Name = struct {
    space: []const u8 = "",
    local: []const u8 = "",
};

pub const Attr = struct {
    name: Name,
    value: []const u8,
};

pub const StartElement = struct {
    name: Name,
    attr: []const Attr = &.{},
};

pub const EndElement = struct {
    name: Name,
};

pub const ProcInst = struct {
    target: []const u8,
    inst: []const u8,
};

pub const Token = union(enum) {
    start_element: StartElement,
    end_element: EndElement,
    char_data: []const u8,
    comment: []const u8,
    proc_inst: ProcInst,
    directive: []const u8,
};

pub const SyntaxError = error{
    InvalidToken,
    UnexpectedEOF,
    UnclosedTag,
    MismatchedClosingTag,
    InvalidEntity,
    InvalidAttribute,
};

/// Escapes standard XML characters (&, <, >, ", ')
pub fn escapeText(writer: *std.Io.Writer, s: []const u8) !void {
    var last: usize = 0;
    for (s, 0..) |c, i| {
        const replacement = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&#34;",
            '\'' => "&#39;",
            else => continue,
        };
        if (i > last) {
            try writer.writeAll(s[last..i]);
        }
        try writer.writeAll(replacement);
        last = i + 1;
    }
    if (last < s.len) {
        try writer.writeAll(s[last..]);
    }
}

/// Unescapes standard XML predefined entities and numerical character references.
pub fn unescapeText(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const semi_idx = mem.indexOfScalar(u8, s[i..], ';');
            if (semi_idx) |rel_end| {
                const entity = s[i + 1 .. i + rel_end];
                if (mem.eql(u8, entity, "amp")) {
                    try out.append(allocator, '&');
                    i += rel_end + 1;
                    continue;
                } else if (mem.eql(u8, entity, "lt")) {
                    try out.append(allocator, '<');
                    i += rel_end + 1;
                    continue;
                } else if (mem.eql(u8, entity, "gt")) {
                    try out.append(allocator, '>');
                    i += rel_end + 1;
                    continue;
                } else if (mem.eql(u8, entity, "quot") or mem.eql(u8, entity, "#34")) {
                    try out.append(allocator, '"');
                    i += rel_end + 1;
                    continue;
                } else if (mem.eql(u8, entity, "apos") or mem.eql(u8, entity, "#39")) {
                    try out.append(allocator, '\'');
                    i += rel_end + 1;
                    continue;
                } else if (entity.len > 1 and entity[0] == '#') {
                    // Numerical entity
                    var cp: u21 = 0;
                    if (entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X')) {
                        cp = std.fmt.parseInt(u21, entity[2..], 16) catch {
                            try out.append(allocator, s[i]);
                            i += 1;
                            continue;
                        };
                    } else {
                        cp = std.fmt.parseInt(u21, entity[1..], 10) catch {
                            try out.append(allocator, s[i]);
                            i += 1;
                            continue;
                        };
                    }
                    var utf8_buf: [4]u8 = undefined;
                    const encoded_len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                        try out.append(allocator, s[i]);
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(allocator, utf8_buf[0..encoded_len]);
                    i += rel_end + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub const max_xml_depth: usize = 1000;

pub const Decoder = struct {
    r: *std.Io.Reader,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    peek_buf: [8]u8 = undefined,
    peek_len: usize = 0,
    pending_end: ?EndElement,
    open_tags: std.ArrayListUnmanaged(Name),

    pub fn init(allocator: Allocator, rd: *std.Io.Reader) Decoder {
        return .{
            .r = rd,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .peek_buf = undefined,
            .peek_len = 0,
            .pending_end = null,
            .open_tags = .empty,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.open_tags.deinit(self.allocator);
        self.arena.deinit();
    }

    fn readByte(self: *Decoder) !?u8 {
        if (self.peek_len > 0) {
            self.peek_len -= 1;
            return self.peek_buf[self.peek_len];
        }

        const b = self.r.takeByte() catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };
        return b;
    }

    fn unreadByte(self: *Decoder, b: u8) void {
        std.debug.assert(self.peek_len < self.peek_buf.len);
        self.peek_buf[self.peek_len] = b;
        self.peek_len += 1;
    }

    pub fn token(self: *Decoder) !?Token {
        if (self.pending_end) |end| {
            self.pending_end = null;
            return Token{ .end_element = end };
        }

        const arena_alloc = self.arena.allocator();

        while (true) {
            const first = (try self.readByte()) orelse {
                if (self.open_tags.items.len > 0) return SyntaxError.UnclosedTag;
                return null;
            };

            if (first == '<') {
                const next_char = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;

                if (next_char == '/') {
                    // </end_element>
                    const tag_text = try self.readUntil('>');
                    const trimmed = mem.trim(u8, tag_text, " \t\r\n");
                    const name = parseName(trimmed);

                    if (self.open_tags.items.len == 0) {
                        return SyntaxError.MismatchedClosingTag;
                    }
                    const top = self.open_tags.pop().?;
                    if (!mem.eql(u8, top.local, name.local) or
                        !mem.eql(u8, top.space, name.space))
                    {
                        return SyntaxError.MismatchedClosingTag;
                    }

                    return Token{
                        .end_element = .{
                            .name = .{
                                .space = try arena_alloc.dupe(u8, name.space),
                                .local = try arena_alloc.dupe(u8, name.local),
                            },
                        },
                    };
                } else if (next_char == '!') {
                    // Could be Comment (<!--), CDATA (<![CDATA[), or Directive (<!DOCTYPE)
                    const c3 = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;
                    if (c3 == '-') {
                        const c4 = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;
                        if (c4 == '-') {
                            // <!-- Comment -->
                            const comment_text = try self.readUntilString("-->");
                            return Token{
                                .comment = try arena_alloc.dupe(u8, comment_text),
                            };
                        }
                        self.unreadByte(c4);
                        self.unreadByte(c3);
                    } else {
                        self.unreadByte(c3);
                    }

                    // Check CDATA ("<![CDATA["), stopping immediately on mismatch or '>'
                    const cdata_prefix = "[CDATA[";
                    var cdata_check: [7]u8 = undefined;
                    var read_cnt: usize = 0;
                    var match_cdata = true;
                    while (read_cnt < cdata_prefix.len) {
                        const b = (try self.readByte()) orelse {
                            match_cdata = false;
                            break;
                        };
                        if (b == '>') {
                            match_cdata = false;
                            self.unreadByte(b);
                            break;
                        }
                        cdata_check[read_cnt] = b;
                        read_cnt += 1;
                        if (b != cdata_prefix[read_cnt - 1]) {
                            match_cdata = false;
                            break;
                        }
                    }

                    if (match_cdata and read_cnt == cdata_prefix.len) {
                        const cdata_content = try self.readUntilString("]]>");
                        return Token{
                            .char_data = try arena_alloc.dupe(u8, cdata_content),
                        };
                    } else {
                        // Read remaining Directive until '>'
                        var directive_buf: std.ArrayListUnmanaged(u8) = .empty;
                        defer directive_buf.deinit(self.allocator);
                        try directive_buf.appendSlice(self.allocator, cdata_check[0..read_cnt]);
                        const rest = try self.readUntil('>');
                        try directive_buf.appendSlice(self.allocator, rest);
                        return Token{
                            .directive = try arena_alloc.dupe(u8, directive_buf.items),
                        };
                    }
                } else if (next_char == '?') {
                    // <?target inst?>
                    const proc_text = try self.readUntilString("?>");
                    const trimmed = mem.trim(u8, proc_text, " \t\r\n");
                    var target = trimmed;
                    var inst: []const u8 = "";
                    if (mem.indexOfAny(u8, trimmed, " \t\r\n")) |sp| {
                        target = trimmed[0..sp];
                        inst = mem.trimStart(u8, trimmed[sp..], " \t\r\n");
                    }
                    return Token{
                        .proc_inst = .{
                            .target = try arena_alloc.dupe(u8, target),
                            .inst = try arena_alloc.dupe(u8, inst),
                        },
                    };
                } else {
                    // StartElement: <name attr="val" ... /?>
                    self.unreadByte(next_char);
                    const raw_tag = try self.readTagContent();
                    var self_closing = false;
                    var tag_body = raw_tag;
                    if (tag_body.len > 0 and tag_body[tag_body.len - 1] == '/') {
                        self_closing = true;
                        tag_body = tag_body[0 .. tag_body.len - 1];
                    }
                    tag_body = mem.trim(u8, tag_body, " \t\r\n");

                    var tag_name_str = tag_body;
                    var attr_str: []const u8 = "";
                    if (mem.indexOfAny(u8, tag_body, " \t\r\n")) |sp| {
                        tag_name_str = tag_body[0..sp];
                        attr_str = tag_body[sp..];
                    }

                    const parsed_name = parseName(tag_name_str);
                    const name: Name = .{
                        .space = try arena_alloc.dupe(u8, parsed_name.space),
                        .local = try arena_alloc.dupe(u8, parsed_name.local),
                    };

                    const attrs = try parseAttributes(arena_alloc, attr_str);

                    if (self_closing) {
                        self.pending_end = EndElement{ .name = name };
                    } else {
                        if (self.open_tags.items.len >= max_xml_depth) {
                            return SyntaxError.InvalidToken;
                        }
                        try self.open_tags.append(self.allocator, name);
                    }

                    return Token{
                        .start_element = .{
                            .name = name,
                            .attr = attrs,
                        },
                    };
                }
            } else {
                // CharData: up until next '<'
                var text_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer text_buf.deinit(self.allocator);
                try text_buf.append(self.allocator, first);

                while (true) {
                    const b = (try self.readByte()) orelse break;
                    if (b == '<') {
                        self.unreadByte(b);
                        break;
                    }
                    try text_buf.append(self.allocator, b);
                }

                const unescaped = try unescapeText(arena_alloc, text_buf.items);
                return Token{ .char_data = unescaped };
            }
        }
    }

    /// Skips to the matching EndElement of the current start element
    pub fn skip(self: *Decoder) !void {
        var depth: usize = 1;
        while (depth > 0) {
            const tok = (try self.token()) orelse return SyntaxError.UnexpectedEOF;
            switch (tok) {
                .start_element => depth += 1,
                .end_element => depth -= 1,
                else => {},
            }
        }
    }

    fn readTagContent(self: *Decoder) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        var in_quote: ?u8 = null;
        while (true) {
            const b = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;
            if (in_quote) |q| {
                if (b == q) {
                    in_quote = null;
                }
            } else {
                if (b == '"' or b == '\'') {
                    in_quote = b;
                } else if (b == '>') {
                    break;
                }
            }
            try out.append(self.allocator, b);
        }
        return self.arena.allocator().dupe(u8, out.items);
    }

    fn readUntil(self: *Decoder, delim: u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        while (true) {
            const b = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;
            if (b == delim) break;
            try out.append(self.allocator, b);
        }
        return self.arena.allocator().dupe(u8, out.items);
    }

    fn readUntilString(self: *Decoder, terminator: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        while (true) {
            const b = (try self.readByte()) orelse return SyntaxError.UnexpectedEOF;
            try out.append(self.allocator, b);
            if (out.items.len >= terminator.len and
                mem.eql(u8, out.items[out.items.len - terminator.len ..], terminator))
            {
                const content = out.items[0 .. out.items.len - terminator.len];
                return self.arena.allocator().dupe(u8, content);
            }
        }
    }
};

fn parseName(raw: []const u8) Name {
    if (mem.indexOfScalar(u8, raw, ':')) |colon| {
        return .{
            .space = raw[0..colon],
            .local = raw[colon + 1 ..],
        };
    }
    return .{
        .space = "",
        .local = raw,
    };
}

fn parseAttributes(arena: Allocator, raw: []const u8) ![]const Attr {
    var attrs: std.ArrayListUnmanaged(Attr) = .empty;
    var i: usize = 0;
    const s = mem.trim(u8, raw, " \t\r\n");

    while (i < s.len) {
        // Skip spaces
        while (i < s.len and isSpace(s[i])) : (i += 1) {}
        if (i >= s.len) break;

        // Read attr name
        const key_start = i;
        while (i < s.len and s[i] != '=' and !isSpace(s[i])) : (i += 1) {}
        const key = s[key_start..i];

        // Skip spaces around '='
        while (i < s.len and isSpace(s[i])) : (i += 1) {}
        if (i >= s.len or s[i] != '=') return SyntaxError.InvalidAttribute;
        i += 1; // skip '='

        while (i < s.len and isSpace(s[i])) : (i += 1) {}
        if (i >= s.len) return SyntaxError.InvalidAttribute;

        const quote = s[i];
        if (quote != '"' and quote != '\'') return SyntaxError.InvalidAttribute;
        i += 1; // skip opening quote

        const val_start = i;
        while (i < s.len and s[i] != quote) : (i += 1) {}
        if (i >= s.len) return SyntaxError.InvalidAttribute;
        const raw_val = s[val_start..i];
        i += 1; // skip closing quote

        const unescaped_val = try unescapeText(arena, raw_val);
        const parsed_name = parseName(key);
        try attrs.append(arena, .{
            .name = .{
                .space = try arena.dupe(u8, parsed_name.space),
                .local = try arena.dupe(u8, parsed_name.local),
            },
            .value = unescaped_val,
        });
    }

    return attrs.toOwnedSlice(arena);
}

pub const Encoder = struct {
    w: *std.Io.Writer,
    allocator: Allocator,

    pub fn init(allocator: Allocator, writer: *std.Io.Writer) Encoder {
        return .{
            .w = writer,
            .allocator = allocator,
        };
    }

    pub fn encodeToken(self: *Encoder, t: Token) !void {
        switch (t) {
            .start_element => |se| {
                try self.w.writeByte('<');
                if (se.name.space.len > 0) {
                    try self.w.writeAll(se.name.space);
                    try self.w.writeByte(':');
                }
                try self.w.writeAll(se.name.local);
                for (se.attr) |at| {
                    try self.w.writeByte(' ');
                    if (at.name.space.len > 0) {
                        try self.w.writeAll(at.name.space);
                        try self.w.writeByte(':');
                    }
                    try self.w.writeAll(at.name.local);
                    try self.w.writeAll("=\"");
                    try escapeText(self.w, at.value);
                    try self.w.writeByte('"');
                }
                try self.w.writeByte('>');
            },
            .end_element => |ee| {
                try self.w.writeAll("</");
                if (ee.name.space.len > 0) {
                    try self.w.writeAll(ee.name.space);
                    try self.w.writeByte(':');
                }
                try self.w.writeAll(ee.name.local);
                try self.w.writeByte('>');
            },
            .char_data => |cd| {
                try escapeText(self.w, cd);
            },
            .comment => |c| {
                try self.w.writeAll("<!--");
                try self.w.writeAll(c);
                try self.w.writeAll("-->");
            },
            .proc_inst => |pi| {
                try self.w.writeAll("<?");
                try self.w.writeAll(pi.target);
                if (pi.inst.len > 0) {
                    try self.w.writeByte(' ');
                    try self.w.writeAll(pi.inst);
                }
                try self.w.writeAll("?>");
            },
            .directive => |d| {
                try self.w.writeAll("<!");
                try self.w.writeAll(d);
                try self.w.writeByte('>');
            },
        }
    }

    pub fn flush(self: *Encoder) !void {
        try self.w.flush();
    }
};

test "xml escape and unescape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = bytes.Buffer.init(alloc);
    defer buf.deinit();

    try escapeText(buf.writer(), "Rock & Roll <5 > 2 'quotes' \"double\"");
    const expected = "Rock &amp; Roll &lt;5 &gt; 2 &#39;quotes&#39; &#34;double&#34;";
    try testing.expectEqualStrings(expected, buf.string());

    const unescaped = try unescapeText(alloc, buf.string());
    defer alloc.free(unescaped);
    try testing.expectEqualStrings("Rock & Roll <5 > 2 'quotes' \"double\"", unescaped);

    // Numeric entity: &#65; -> 'A', &#x42; -> 'B'
    const num_unescaped = try unescapeText(alloc, "&#65;&#x42;");
    defer alloc.free(num_unescaped);
    try testing.expectEqualStrings("AB", num_unescaped);
}

test "xml decoder and encoder roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const xml_doc =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- Catalog database -->
        \\<catalog id="main" category="books">
        \\  <book lang="en">
        \\    <title>The Go Programming Language</title>
        \\    <price>39.99</price>
        \\  </book>
        \\  <item flag="true"/>
        \\</catalog>
    ;

    var reader = bytes.Reader.init(xml_doc);
    var dec = Decoder.init(alloc, reader.reader());
    defer dec.deinit();

    // 1. ProcInst
    const t1 = (try dec.token()).?;
    try testing.expectEqualStrings("xml", t1.proc_inst.target);
    try testing.expectEqualStrings("version=\"1.0\" encoding=\"UTF-8\"", t1.proc_inst.inst);

    // 2. CharData (newline)
    const t2 = (try dec.token()).?;
    try testing.expectEqualStrings("\n", t2.char_data);

    // 3. Comment
    const t3 = (try dec.token()).?;
    try testing.expectEqualStrings(" Catalog database ", t3.comment);

    // 4. CharData (newline)
    _ = (try dec.token()).?;

    // 5. StartElement <catalog id="main" category="books">
    const t5 = (try dec.token()).?;
    try testing.expectEqualStrings("catalog", t5.start_element.name.local);
    try testing.expectEqual(@as(usize, 2), t5.start_element.attr.len);
    try testing.expectEqualStrings("id", t5.start_element.attr[0].name.local);
    try testing.expectEqualStrings("main", t5.start_element.attr[0].value);
    try testing.expectEqualStrings("category", t5.start_element.attr[1].name.local);
    try testing.expectEqualStrings("books", t5.start_element.attr[1].value);

    // Test Encoder
    var out_buf = bytes.Buffer.init(alloc);
    defer out_buf.deinit();
    var enc = Encoder.init(alloc, out_buf.writer());

    try enc.encodeToken(Token{
        .start_element = .{
            .name = .{ .space = "ns", .local = "root" },
            .attr = &.{
                .{ .name = .{ .space = "", .local = "version" }, .value = "1.0" },
            },
        },
    });
    try enc.encodeToken(Token{ .char_data = "Hello <World> & Friends" });
    try enc.encodeToken(Token{ .end_element = .{ .name = .{ .space = "ns", .local = "root" } } });
    try enc.flush();

    const expected = "<ns:root version=\"1.0\">Hello &lt;World&gt; &amp; Friends</ns:root>";
    try testing.expectEqualStrings(expected, out_buf.string());
}

test "xml self-closing tag handling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const xml_snippet = "<item id=\"42\"/><next>val</next>";
    var reader = bytes.Reader.init(xml_snippet);
    var dec = Decoder.init(alloc, reader.reader());
    defer dec.deinit();

    // First: StartElement item
    const t1 = (try dec.token()).?;
    try testing.expectEqualStrings("item", t1.start_element.name.local);
    try testing.expectEqualStrings("42", t1.start_element.attr[0].value);

    // Second: EndElement item automatically synthesized
    const t2 = (try dec.token()).?;
    try testing.expectEqualStrings("item", t2.end_element.name.local);

    // Third: StartElement next
    const t3 = (try dec.token()).?;
    try testing.expectEqualStrings("next", t3.start_element.name.local);

    // Fourth: CharData val
    const t4 = (try dec.token()).?;
    try testing.expectEqualStrings("val", t4.char_data);

    // Fifth: EndElement next
    const t5 = (try dec.token()).?;
    try testing.expectEqualStrings("next", t5.end_element.name.local);

    // EOF
    try testing.expectEqual(@as(?Token, null), try dec.token());
}

test "xml skip subtree" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const xml_snippet = "<a><b><c>inner</c></b><d/></a>";
    var reader = bytes.Reader.init(xml_snippet);
    var dec = Decoder.init(alloc, reader.reader());
    defer dec.deinit();

    // Start 'a'
    const t1 = (try dec.token()).?;
    try testing.expectEqualStrings("a", t1.start_element.name.local);

    // Start 'b'
    const t2 = (try dec.token()).?;
    try testing.expectEqualStrings("b", t2.start_element.name.local);

    // Skip all inside 'b' including its end tag
    try dec.skip();

    // Next must be 'd'
    const t3 = (try dec.token()).?;
    try testing.expectEqualStrings("d", t3.start_element.name.local);
}

test "xml quoted > in attribute, short directives, and unclosed tag EOF" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 1. '>' inside quoted attribute value
    {
        var reader = bytes.Reader.init("<a expr=\"x > 1\">ok</a>");
        var dec = Decoder.init(alloc, reader.reader());
        defer dec.deinit();

        const t1 = (try dec.token()).?;
        try testing.expectEqualStrings("a", t1.start_element.name.local);
        try testing.expectEqual(@as(usize, 1), t1.start_element.attr.len);
        try testing.expectEqualStrings("x > 1", t1.start_element.attr[0].value);
        const t2 = (try dec.token()).?;
        try testing.expectEqualStrings("ok", t2.char_data);
        const t3 = (try dec.token()).?;
        try testing.expectEqualStrings("a", t3.end_element.name.local);
        try testing.expectEqual(@as(?Token, null), try dec.token());
    }

    // 2. Short directive <!x> and <!-x> without losing bytes
    {
        var reader = bytes.Reader.init("<!x><!-y><a/>");
        var dec = Decoder.init(alloc, reader.reader());
        defer dec.deinit();

        const d1 = (try dec.token()).?;
        try testing.expectEqualStrings("x", d1.directive);
        const d2 = (try dec.token()).?;
        try testing.expectEqualStrings("-y", d2.directive);
        const s1 = (try dec.token()).?;
        try testing.expectEqualStrings("a", s1.start_element.name.local);
        const e1 = (try dec.token()).?;
        try testing.expectEqualStrings("a", e1.end_element.name.local);
        try testing.expectEqual(@as(?Token, null), try dec.token());
    }

    // 3. Unclosed tag on EOF returns SyntaxError.UnclosedTag
    {
        var reader = bytes.Reader.init("<a><b>");
        var dec = Decoder.init(alloc, reader.reader());
        defer dec.deinit();

        _ = (try dec.token()).?;
        _ = (try dec.token()).?;
        try testing.expectError(SyntaxError.UnclosedTag, dec.token());
    }
}
