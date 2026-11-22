//! Package html/template (stdgo.html.template) implements data-driven templates for
//! generating HTML output safe against code injection.
//!
//! It provides the same interface as package text/template but only should be used
//! for HTML output. It automatically secures HTML output against Cross-Site
//! Scripting (XSS) attacks by inspecting the lexical context of actions and
//! applying context-sensitive escaping filters:
//!
//! - **HTML Body Text**: Special characters (`&`, `<`, `>`, `"`, `'`) are entity-escaped.
//! - **HTML Attributes**: Attribute values are escaped appropriately depending on whether
//!   they are unquoted, single-quoted, or double-quoted.
//! - **URLs (`href`, `src`, `action`)**: Dangerous schemes (such as `javascript:`,
//!   `vbscript:`, or arbitrary data URIs) are sanitized to `#ZgotmplZ`.
//! - **JavaScript (`<script>`)**: Dynamic content inserted into JavaScript is encoded as
//!   safe JS literals, escaping quotes, control characters, and `</script>` tags to
//!   prevent script escape attacks.
//! - **CSS (`<style>`)**: CSS content is sanitized against expression and url injection.
//! - **Comments (`<!-- ... -->`)**: Comments are protected against closing delimiter injection.
//!
//! # Safe Content Types
//!
//! When you know that content is already safe and does not need escaping, you can
//! wrap it in one of the safe content types:
//! - `HTML`: Untrusted HTML that has already been sanitized or trusted markup.
//! - `JS`: Trusted JavaScript code.
//! - `CSS`: Trusted CSS stylesheets.
//! - `URL`: Trusted URLs.
//! - `HTMLAttr`: Trusted HTML attribute name/value pairs.

const std = @import("std");
const io = @import("../io.zig");
const text_pkg = @import("../text/template.zig");
const Allocator = std.mem.Allocator;

pub const Value = text_pkg.Value;
pub const FuncFn = text_pkg.FuncFn;
pub const FuncMap = text_pkg.FuncMap;
pub const Node = text_pkg.Node;
pub const Scope = text_pkg.Scope;

/// Safe HTML snippet that skips HTML entity escaping.
pub const HTML = struct {
    data: []const u8,
    pub const _is_safe_string = true;
    pub const _safe_kind = text_pkg.SafeKind.html;
};

/// Safe JavaScript snippet that skips JS string/literal escaping.
pub const JS = struct {
    data: []const u8,
    pub const _is_safe_string = true;
    pub const _safe_kind = text_pkg.SafeKind.js;
};

/// Safe CSS snippet that skips stylesheet escaping.
pub const CSS = struct {
    data: []const u8,
    pub const _is_safe_string = true;
    pub const _safe_kind = text_pkg.SafeKind.css;
};

/// Safe URL that skips protocol sanitization.
pub const URL = struct {
    data: []const u8,
    pub const _is_safe_string = true;
    pub const _safe_kind = text_pkg.SafeKind.url;
};

/// Safe HTML attribute that skips attribute escaping.
pub const HTMLAttr = struct {
    data: []const u8,
    pub const _is_safe_string = true;
    pub const _safe_kind = text_pkg.SafeKind.attr;
};

pub const ContextState = enum {
    text,
    tag,
    attr_value_unquoted,
    attr_value_single_quoted,
    attr_value_double_quoted,
    url_attr_unquoted,
    url_attr_single_quoted,
    url_attr_double_quoted,
    js_attr_single_quoted,
    js_attr_double_quoted,
    script_data,
    style_data,
    comment,
};

pub const Escaper = struct {
    state: ContextState = .text,
    in_tag: bool = false,
    in_tag_name: bool = false,
    tag_name: [32]u8 = undefined,
    tag_len: usize = 0,
    attr_name: [32]u8 = undefined,
    attr_len: usize = 0,
    is_url_attr: bool = false,
    is_js_attr: bool = false,
    has_space_after_attr: bool = false,

    fn resetAttr(self: *Escaper) void {
        self.attr_len = 0;
        self.is_url_attr = false;
        self.is_js_attr = false;
        self.has_space_after_attr = false;
    }

    fn checkAttr(self: *Escaper) void {
        const name = self.attr_name[0..self.attr_len];
        if (std.ascii.eqlIgnoreCase(name, "href") or
            std.ascii.eqlIgnoreCase(name, "src") or
            std.ascii.eqlIgnoreCase(name, "action") or
            std.ascii.eqlIgnoreCase(name, "formaction") or
            std.ascii.eqlIgnoreCase(name, "cite") or
            std.ascii.eqlIgnoreCase(name, "data") or
            std.ascii.eqlIgnoreCase(name, "poster"))
        {
            self.is_url_attr = true;
            self.is_js_attr = false;
        } else if (std.ascii.startsWithIgnoreCase(name, "on")) {
            self.is_js_attr = true;
            self.is_url_attr = false;
        } else {
            self.is_url_attr = false;
            self.is_js_attr = false;
        }
    }

    pub fn processText(self: *Escaper, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            switch (self.state) {
                .text => {
                    if (c == '<') {
                        if (std.mem.startsWith(u8, text[i..], "<!--")) {
                            self.state = .comment;
                            i += 3;
                            continue;
                        }
                        self.state = .tag;
                        self.in_tag = true;
                        self.in_tag_name = true;
                        self.tag_len = 0;
                        self.resetAttr();
                    }
                },
                .comment => {
                    if (std.mem.startsWith(u8, text[i..], "-->")) {
                        self.state = .text;
                        i += 2;
                        continue;
                    }
                },
                .tag => {
                    if (c == '>') {
                        const tag = self.tag_name[0..self.tag_len];
                        if (std.ascii.eqlIgnoreCase(tag, "script")) {
                            self.state = .script_data;
                        } else if (std.ascii.eqlIgnoreCase(tag, "style")) {
                            self.state = .style_data;
                        } else {
                            self.state = .text;
                        }
                        self.in_tag = false;
                        self.in_tag_name = false;
                        self.tag_len = 0;
                        self.resetAttr();
                    } else if (c == '=') {
                        self.has_space_after_attr = false;
                        self.checkAttr();
                        var j = i + 1;
                        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
                        if (j < text.len) {
                            if (text[j] == '"') {
                                self.state = if (self.is_url_attr)
                                    .url_attr_double_quoted
                                else if (self.is_js_attr)
                                    .js_attr_double_quoted
                                else
                                    .attr_value_double_quoted;
                                i = j;
                            } else if (text[j] == '\'') {
                                self.state = if (self.is_url_attr)
                                    .url_attr_single_quoted
                                else if (self.is_js_attr)
                                    .js_attr_single_quoted
                                else
                                    .attr_value_single_quoted;
                                i = j;
                            } else {
                                self.state = if (self.is_url_attr)
                                    .url_attr_unquoted
                                else
                                    .attr_value_unquoted;
                                i = j - 1;
                            }
                        } else {
                            self.state = if (self.is_url_attr)
                                .url_attr_unquoted
                            else
                                .attr_value_unquoted;
                        }
                    } else if (std.ascii.isWhitespace(c)) {
                        if (self.in_tag_name) {
                            self.in_tag_name = false;
                        } else if (self.attr_len > 0) {
                            self.has_space_after_attr = true;
                        }
                    } else if (c == '/') {
                        self.in_tag_name = false;
                    } else {
                        if (self.in_tag_name) {
                            const is_tag_char = std.ascii.isAlphanumeric(c) or
                                c == '-' or c == '_';
                            if (self.tag_len < self.tag_name.len and is_tag_char) {
                                self.tag_name[self.tag_len] = c;
                                self.tag_len += 1;
                            }
                        } else {
                            if (self.has_space_after_attr) {
                                self.resetAttr();
                            }
                            const is_valid_attr_char = c != '<' and c != '"' and c != '\'';
                            if (self.attr_len < self.attr_name.len and is_valid_attr_char) {
                                self.attr_name[self.attr_len] = c;
                                self.attr_len += 1;
                            }
                        }
                    }
                },
                .attr_value_double_quoted, .url_attr_double_quoted, .js_attr_double_quoted => {
                    if (c == '"') {
                        self.state = .tag;
                        self.resetAttr();
                    }
                },
                .attr_value_single_quoted, .url_attr_single_quoted, .js_attr_single_quoted => {
                    if (c == '\'') {
                        self.state = .tag;
                        self.resetAttr();
                    }
                },
                .attr_value_unquoted, .url_attr_unquoted => {
                    if (std.ascii.isWhitespace(c) or c == '>') {
                        self.state = if (c == '>') .text else .tag;
                        self.resetAttr();
                    }
                },
                .script_data => {
                    if (std.ascii.startsWithIgnoreCase(text[i..], "</script")) {
                        self.state = .tag;
                        i += 7;
                        continue;
                    }
                },
                .style_data => {
                    if (std.ascii.startsWithIgnoreCase(text[i..], "</style")) {
                        self.state = .tag;
                        i += 6;
                        continue;
                    }
                },
            }
        }
    }
};

// -------------------------------------------------------------------------
// Escaping filter functions registered into the inner template
// -------------------------------------------------------------------------

pub const Filters = struct {
    pub fn htmlEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        if (arg == .safe_string and arg.safe_string.kind == .html) {
            return Value{ .string = arg.safe_string.data };
        }
        const s = try valueToString(allocator, arg);
        var needed = false;
        for (s) |c| {
            if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'') {
                needed = true;
                break;
            }
        }
        if (!needed) return Value{ .string = s };

        var out = std.ArrayList(u8).empty;
        for (s) |c| {
            switch (c) {
                '&' => try out.appendSlice(allocator, "&amp;"),
                '<' => try out.appendSlice(allocator, "&lt;"),
                '>' => try out.appendSlice(allocator, "&gt;"),
                '"' => try out.appendSlice(allocator, "&#34;"),
                '\'' => try out.appendSlice(allocator, "&#39;"),
                else => try out.append(allocator, c),
            }
        }
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }

    pub fn attrEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        const is_safe_attr = arg == .safe_string and
            (arg.safe_string.kind == .attr or arg.safe_string.kind == .html);
        if (is_safe_attr) {
            return Value{ .string = arg.safe_string.data };
        }
        const s = try valueToString(allocator, arg);
        var needed = false;
        for (s) |c| {
            if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'' or c == '`') {
                needed = true;
                break;
            }
        }
        if (!needed) return Value{ .string = s };

        var out = std.ArrayList(u8).empty;
        for (s) |c| {
            switch (c) {
                '&' => try out.appendSlice(allocator, "&amp;"),
                '<' => try out.appendSlice(allocator, "&lt;"),
                '>' => try out.appendSlice(allocator, "&gt;"),
                '"' => try out.appendSlice(allocator, "&#34;"),
                '\'' => try out.appendSlice(allocator, "&#39;"),
                '`' => try out.appendSlice(allocator, "&#96;"),
                else => try out.append(allocator, c),
            }
        }
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }

    pub fn unquotedAttrEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        const is_safe_attr = arg == .safe_string and
            (arg.safe_string.kind == .attr or arg.safe_string.kind == .html);
        if (is_safe_attr) {
            return Value{ .string = arg.safe_string.data };
        }
        const s = try valueToString(allocator, arg);
        var needed = false;
        for (s) |c| {
            if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'' or c == '`' or
                c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '=')
            {
                needed = true;
                break;
            }
        }
        if (!needed) return Value{ .string = s };

        var out = std.ArrayList(u8).empty;
        for (s) |c| {
            switch (c) {
                '&' => try out.appendSlice(allocator, "&amp;"),
                '<' => try out.appendSlice(allocator, "&lt;"),
                '>' => try out.appendSlice(allocator, "&gt;"),
                '"' => try out.appendSlice(allocator, "&#34;"),
                '\'' => try out.appendSlice(allocator, "&#39;"),
                '`' => try out.appendSlice(allocator, "&#96;"),
                ' ' => try out.appendSlice(allocator, "&#32;"),
                '\t' => try out.appendSlice(allocator, "&#9;"),
                '\n' => try out.appendSlice(allocator, "&#10;"),
                '\r' => try out.appendSlice(allocator, "&#13;"),
                '=' => try out.appendSlice(allocator, "&#61;"),
                else => try out.append(allocator, c),
            }
        }
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }

    pub fn urlEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        if (arg == .safe_string and arg.safe_string.kind == .url) {
            return Value{ .string = arg.safe_string.data };
        }
        const s = try valueToString(allocator, arg);
        const trimmed = std.mem.trim(u8, s, " \t\r\n");

        // Inspect protocol scheme: intercept dangerous javascript/vbscript/data injection
        if (std.ascii.startsWithIgnoreCase(trimmed, "javascript:") or
            std.ascii.startsWithIgnoreCase(trimmed, "vbscript:") or
            std.ascii.startsWithIgnoreCase(trimmed, "data:"))
        {
            // Go standard library replaces unsafe schemes with "#ZgotmplZ"
            return Value{ .string = "#ZgotmplZ" };
        }

        // Percent-encode any dangerous characters
        var out = std.ArrayList(u8).empty;
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or
                c == '-' or c == '_' or c == '.' or c == '~' or
                c == '/' or c == '?' or c == '#' or c == '&' or
                c == '=' or c == ':' or c == '+' or c == '@')
            {
                try out.append(allocator, c);
            } else {
                try out.append(allocator, '%');
                const hex_digits = "0123456789ABCDEF";
                try out.append(allocator, hex_digits[(c >> 4) & 0x0F]);
                try out.append(allocator, hex_digits[c & 0x0F]);
            }
        }
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }

    pub fn jsEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "\"\"" };
        const arg = args[0];
        if (arg == .safe_string and arg.safe_string.kind == .js) {
            return Value{ .string = arg.safe_string.data };
        }
        switch (arg) {
            .int, .float, .bool => return arg,
            .null => return Value{ .string = "null" },
            else => {},
        }
        const s = try valueToString(allocator, arg);
        var out = std.ArrayList(u8).empty;
        try out.append(allocator, '"');
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            switch (c) {
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '"' => try out.appendSlice(allocator, "\\\""),
                '\'' => try out.appendSlice(allocator, "\\'"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                '<' => {
                    // Prevent closing </script> tags or <!-- comments from escaping JS string
                    if (i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '!')) {
                        try out.appendSlice(allocator, "\\x3c");
                    } else {
                        try out.append(allocator, '<');
                    }
                },
                '>' => try out.appendSlice(allocator, "\\x3e"),
                '&' => try out.appendSlice(allocator, "\\x26"),
                else => try out.append(allocator, c),
            }
        }
        try out.append(allocator, '"');
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }

    pub fn cssEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        if (arg == .safe_string and arg.safe_string.kind == .css) {
            return Value{ .string = arg.safe_string.data };
        }
        const s = try valueToString(allocator, arg);
        // Intercept javascript url or expression calls
        if (indexOfIgnoreCase(s, "javascript:") != null or
            indexOfIgnoreCase(s, "expression(") != null)
        {
            return Value{ .string = "/*ZgotmplZ*/" };
        }
        return Value{ .string = s };
    }

    pub fn commentEscaper(allocator: Allocator, args: []const Value) anyerror!Value {
        if (args.len == 0) return Value{ .string = "" };
        const arg = args[0];
        const s = try valueToString(allocator, arg);
        if (std.mem.indexOf(u8, s, "--") == null) return Value{ .string = s };
        var out = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (i + 1 < s.len and s[i] == '-' and s[i + 1] == '-') {
                try out.appendSlice(allocator, "- -");
                i += 1;
            } else {
                try out.append(allocator, s[i]);
            }
        }
        return Value{ .string = try out.toOwnedSlice(allocator) };
    }
};

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn valueToString(allocator: Allocator, val: Value) anyerror![]const u8 {
    return switch (val) {
        .string => |s| s,
        .safe_string => |s| s.data,
        else => {
            const bytes = @import("../bytes.zig");
            var buf = bytes.Buffer.init(allocator);
            try val.format(buf.writer());
            return buf.string();
        },
    };
}

// -------------------------------------------------------------------------
// AST Contextual Auto-Escape Rewriter
// -------------------------------------------------------------------------

pub fn escapeNodes(
    allocator: Allocator,
    nodes: []const Node,
    escaper: *Escaper,
) anyerror![]const Node {
    var out = std.ArrayList(Node).empty;

    for (nodes) |node| {
        switch (node) {
            .text => |t| {
                escaper.processText(t);
                try out.append(allocator, node);
            },
            .action => |pipeline| {
                // Determine appropriate escaping filter based on current context state
                const filter_name: []const u8 = switch (escaper.state) {
                    .text => "_html_esc",
                    .attr_value_unquoted => "_unquoted_attr_esc",
                    .attr_value_single_quoted,
                    .attr_value_double_quoted,
                    .tag,
                    => "_attr_esc",
                    .url_attr_unquoted,
                    .url_attr_single_quoted,
                    .url_attr_double_quoted,
                    => "_url_esc",
                    .script_data,
                    .js_attr_single_quoted,
                    .js_attr_double_quoted,
                    => "_js_esc",
                    .style_data => "_css_esc",
                    .comment => "_comment_esc",
                };

                // Append the filter to the pipeline
                var new_pipe = try allocator.alloc([]const u8, pipeline.len + 1);
                @memcpy(new_pipe[0..pipeline.len], pipeline);
                new_pipe[pipeline.len] = filter_name;

                try out.append(allocator, .{ .action = new_pipe });
            },
            .@"if" => |if_node| {
                const escaped_then = try escapeNodes(allocator, if_node.then_branch, escaper);
                var escaped_else: ?[]const Node = null;
                if (if_node.else_branch) |eb| {
                    escaped_else = try escapeNodes(allocator, eb, escaper);
                }
                try out.append(allocator, .{
                    .@"if" = .{
                        .condition = if_node.condition,
                        .then_branch = escaped_then,
                        .else_branch = escaped_else,
                    },
                });
            },
            .with => |with_node| {
                const escaped_body = try escapeNodes(allocator, with_node.body_branch, escaper);
                var escaped_else: ?[]const Node = null;
                if (with_node.else_branch) |eb| {
                    escaped_else = try escapeNodes(allocator, eb, escaper);
                }
                try out.append(allocator, .{
                    .with = .{
                        .target = with_node.target,
                        .body_branch = escaped_body,
                        .else_branch = escaped_else,
                    },
                });
            },
            .range => |range_node| {
                const escaped_body = try escapeNodes(allocator, range_node.body_branch, escaper);
                var escaped_else: ?[]const Node = null;
                if (range_node.else_branch) |eb| {
                    escaped_else = try escapeNodes(allocator, eb, escaper);
                }
                try out.append(allocator, .{
                    .range = .{
                        .target = range_node.target,
                        .item_capture = range_node.item_capture,
                        .index_capture = range_node.index_capture,
                        .body_branch = escaped_body,
                        .else_branch = escaped_else,
                    },
                });
            },
            .assign, .template_call => {
                try out.append(allocator, node);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

// -------------------------------------------------------------------------
// Template Struct
// -------------------------------------------------------------------------

pub const Template = struct {
    allocator: Allocator,
    inner: *text_pkg.Template,

    pub fn new(allocator: Allocator, name: []const u8) !*Template {
        const tmpl = try allocator.create(Template);
        errdefer allocator.destroy(tmpl);
        const inner = try text_pkg.Template.new(allocator, name);
        errdefer inner.deinit();

        // Register internal escape filters
        try inner.funcs.put("_html_esc", Filters.htmlEscaper);
        try inner.funcs.put("_attr_esc", Filters.attrEscaper);
        try inner.funcs.put("_unquoted_attr_esc", Filters.unquotedAttrEscaper);
        try inner.funcs.put("_url_esc", Filters.urlEscaper);
        try inner.funcs.put("_js_esc", Filters.jsEscaper);
        try inner.funcs.put("_css_esc", Filters.cssEscaper);
        try inner.funcs.put("_comment_esc", Filters.commentEscaper);

        tmpl.* = .{
            .allocator = allocator,
            .inner = inner,
        };
        return tmpl;
    }

    pub fn deinit(self: *Template) void {
        self.inner.deinit();
        self.allocator.destroy(self);
    }

    pub fn addFunc(self: *Template, name: []const u8, func: FuncFn) !*Template {
        _ = try self.inner.addFunc(name, func);
        return self;
    }

    pub fn funcMap(self: *Template, funcs: FuncMap) !*Template {
        _ = try self.inner.funcMap(funcs);
        return self;
    }

    pub fn lookup(self: *const Template, name: []const u8) ?[]const Node {
        return self.inner.lookup(name);
    }

    pub fn parse(self: *Template, text: []const u8) !*Template {
        _ = try self.inner.parse(text);

        // Escape root nodes
        var escaper = Escaper{};
        const escaped_roots = try escapeNodes(
            self.inner.arena.allocator(),
            self.inner.root_nodes,
            &escaper,
        );
        self.inner.root_nodes = escaped_roots;

        // Also escape all registered sub-templates (defined via {{ define "..." }})
        var it = self.inner.templates.iterator();
        while (it.next()) |entry| {
            var sub_escaper = Escaper{};
            const escaped_sub = try escapeNodes(
                self.inner.arena.allocator(),
                entry.value_ptr.*,
                &sub_escaper,
            );
            entry.value_ptr.* = escaped_sub;
        }

        return self;
    }

    pub fn execute(self: *Template, w: *io.Writer, data: anytype) !void {
        try self.inner.execute(w, data);
    }

    pub fn executeTemplate(self: *Template, w: *io.Writer, name: []const u8, data: anytype) !void {
        try self.inner.executeTemplate(w, name, data);
    }
};

pub fn Must(tmpl: anyerror!*Template) *Template {
    return tmpl catch |err| @panic(@errorName(err));
}

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "html.template: basic HTML entity escaping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "xss_test");
    defer tmpl.deinit();

    _ = try tmpl.parse("<div>Hello, {{ .Name }}!</div>");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .Name = "<script>alert('xss & pwned')</script>",
    });

    const expected = "<div>Hello, &lt;script&gt;alert(" ++
        "&#39;xss &amp; pwned&#39;)&lt;/script&gt;!</div>";
    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: attribute context escaping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "attr_test");
    defer tmpl.deinit();

    _ = try tmpl.parse("<input type=\"text\" value=\"{{ .Input }}\" title='{{ .Title }}'>");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .Input = "foo\" onfocus=\"alert(1)",
        .Title = "bar' onmouseover='alert(2)",
    });

    const expected = "<input type=\"text\" value=\"foo&#34; onfocus=&#34;alert(1)\" " ++
        "title='bar&#39; onmouseover=&#39;alert(2)'>";
    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: URL context protocol sanitization" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "url_test");
    defer tmpl.deinit();

    _ = try tmpl.parse("<a href=\"{{ .BadURL }}\">Bad</a> | <a href=\"{{ .GoodURL }}\">Good</a>");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .BadURL = "javascript:alert('malicious')",
        .GoodURL = "https://example.com/search?q=zig lang",
    });

    const expected = "<a href=\"#ZgotmplZ\">Bad</a> | " ++
        "<a href=\"https://example.com/search?q=zig%20lang\">Good</a>";
    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: script context JavaScript string escaping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "js_test");
    defer tmpl.deinit();

    _ = try tmpl.parse("<script>var msg = {{ .Msg }};</script>");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .Msg = "Hello </script><script>alert('pwn')</script>",
    });

    const expected = "<script>var msg = \"Hello \\x3c/script\\x3e" ++
        "<script\\x3ealert(\\'pwn\\')\\x3c/script\\x3e\";</script>";
    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: safe types bypass escaping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "safe_types_test");
    defer tmpl.deinit();

    const tmpl_src = "<div>{{ .TrustedHTML }}</div>" ++
        "<script>var x = {{ .TrustedJS }};</script>" ++
        "<a href=\"{{ .TrustedURL }}\">Link</a>";
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .TrustedHTML = HTML{ .data = "<b>Bold & Beautiful</b>" },
        .TrustedJS = JS{ .data = "{ count: 42, active: true }" },
        .TrustedURL = URL{ .data = "javascript:void(0)" },
    });

    const expected = "<div><b>Bold & Beautiful</b></div>" ++
        "<script>var x = { count: 42, active: true };</script>" ++
        "<a href=\"javascript:void(0)\">Link</a>";
    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: sub-templates and composition with escaping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const src =
        \\{{- define "item" -}}
        \\<li>{{ .Text }}</li>
        \\{{- end -}}
        \\<ul>
        \\{{- for .Items |item| }}
        \\{{ template "item" item }}
        \\{{- end }}
        \\</ul>
    ;

    var tmpl = try Template.new(testing.allocator, "list_tmpl");
    defer tmpl.deinit();

    _ = try tmpl.parse(src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .Items = &.{
            .{ .Text = "First & Main" },
            .{ .Text = "<bad>" },
        },
    });

    const expected =
        \\<ul>
        \\<li>First &amp; Main</li>
        \\<li>&lt;bad&gt;</li>
        \\</ul>
    ;

    try testing.expectEqualStrings(expected, buf.string());
}

test "html.template: unquoted attribute escaping and multi-attribute parsing" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "unquoted_test");
    defer tmpl.deinit();

    _ = try tmpl.parse("<div id={{ .ID }} disabled class=\"{{ .Class }}\"></div>");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{
        .ID = "a b=c",
        .Class = "container",
    });

    const expected = "<div id=a&#32;b&#61;c disabled class=\"container\"></div>";
    try testing.expectEqualStrings(expected, buf.string());
}
