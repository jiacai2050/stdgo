//! Port of Go's `text/template` package to Zig 0.17 with native Zig-style extensions.
//!
//! Provides a high-performance, data-driven text templating engine with streaming execution
//! directly onto `*stdgo.io.Writer` (aliased to Zig 0.17's native `std.Io.Writer`).
//!
//! # Architecture & Safety
//! - **Zero Memory Leaks**: Uses a dual-arena memory model. Template AST nodes and static strings
//!   are managed by the `Template` instance arena, while dynamic evaluation contexts and
//!   intermediate values are scoped within an execution arena automatically freed when
//!   `execute` returns.
//! - **Compile-Time Reflection**: Automatically translates native Zig structs, slices, arrays,
//!   optionals, maps, and primitives into dynamic template values via comptime `@typeInfo`.
//! - **Streaming Output**: Never buffers rendered templates entirely into RAM unless requested;
//!   renders directly through user-provided stream writers.
//!
//! ---
//!
//! # Complete Syntax Guide
//!
//! ## 1. Context and Field Interpolation
//! - `{{ . }}`: Evaluates to the current root context object.
//! - `{{ .Field }}`: Accesses a field/key on the current context object.
//! - `{{ .User.Profile.Email }}`: Traverses nested struct fields or map keys.
//! - `{{ .@"content-type" }}`: Zig-style quoted identifiers for keywords, hyphens, or special
//!   chars. Even handles dots inside quotes without splitting paths
//!   (e.g. `{{ .@"app.kubernetes.io/name" }}`).
//! - Literals:
//!   - Strings: `"hello world"`
//!   - Integers: `42`, `-10`
//!   - Floats: `3.14159`
//!   - Booleans: `true`, `false`
//!   - Null / Nil: `null`, `nil`
//!
//! ## 2. Pipelines and Function Calls
//! - Command Pipeline: Passes the result of the left-hand command as the **last** argument to the
//!   next:
//!   `{{ .Name | upper }}`
//!   `{{ .Count | printf "Total: %04d items" }}`
//! - Prefix Function Invocation:
//!   `{{ len .Roles }}`
//!   `{{ printf "ID: %d, Name: %s" .ID .Name }}`
//! - Parenthesized Sub-expressions:
//!   `{{ if and (gt .Age 18) (lt .Age 65) }} Working Age {{ end }}`
//!
//! ## 3. Built-in Function Reference
//! - **Formatting & Output**:
//!   - `printf fmt args...`: Formats string with specifiers
//!     (`%s`, `%d`, `%f`, `%v`, width/padding `%04d`).
//!   - `print args...`: Concatenates arguments without spaces.
//!   - `println args...`: Concatenates arguments with spaces, appended with newline `\n`.
//! - **Comparison**:
//!   - `eq a b [c...]`: Returns true if `a == b` (or `a == c`).
//!   - `ne a b`: Returns true if `a != b`.
//!   - `lt a b`: Returns true if `a < b`.
//!   - `le a b`: Returns true if `a <= b`.
//!   - `gt a b`: Returns true if `a > b`.
//!   - `ge a b`: Returns true if `a >= b`.
//! - **Boolean Logic**:
//!   - `and a b...`: Short-circuiting or truthy evaluation (returns first falsy or last truthy
//!     value).
//!   - `or a b...`: Short-circuiting evaluation (returns first truthy or last falsy value).
//!   - `not a`: Inverts truthiness of `a`.
//! - **Collections & Slices**:
//!   - `len container`: Returns item count of strings, slices, or maps.
//!   - `index container key...`: Accesses map key or slice index (e.g. `index .Tags 0`).
//!   - `slice list start [end]`: Extracts sub-slice from index `start` to `end`.
//! - **Strings**:
//!   - `upper str`: Converts string to uppercase.
//!   - `lower str`: Converts string to lowercase.
//! - **Arithmetic**:
//!   - `add a b`: Returns `a + b`.
//!   - `sub a b`: Returns `a - b`.
//!   - `mul a b`: Returns `a * b`.
//!
//! ## 4. Control Flow
//! - **Conditionals**:
//!   ```gotemplate
//!   {{ if eq .Role "admin" }}
//!     Administrator Access
//!   {{ else if ge .Level 5 }}
//!     Moderator Access
//!   {{ else }}
//!     Standard User
//!   {{ end }}
//!   ```
//! - **Context Re-scoping (`with`)**:
//!   Sets dot `.` to the value of pipeline if non-empty/truthy:
//!   ```gotemplate
//!   {{ with .Profile }}
//!     User: {{ .Username }} (Bio: {{ .Bio }})
//!   {{ else }}
//!     No profile available.
//!   {{ end }}
//!   ```
//! - **Loops and Iteration (`for` / `range`)**:
//!   Supports standard Go `range` as well as Zig-style payload capture `|item, idx|`:
//!   ```gotemplate
//!   {{ for .Members |member, idx| }}
//!     {{ add idx 1 }}. {{ member.Name }}
//!   {{ else }}
//!     No members found.
//!   {{ end }}
//!   ```
//!
//! ## 5. Zig-style Variable Bindings
//! - **Immutable Constant**:
//!   `{{ const title = .Title | upper }}`
//!   (Attempting to reassign `title` yields `error.CannotAssignToConstant`).
//! - **Mutable Variable & Reassignment**:
//!   `{{ var counter = 10 }}`
//!   `{{ counter = add counter 5 }}`
//! - **Lexical Scoping**: Variables declared inside `if`, `with`, or `for` blocks
//!   are local to that block and automatically discarded upon block exit (`{{ end }}`).
//!
//! ## 6. Whitespace Trimming
//! - `{{-`: Trims all trailing whitespace (`" \t\r\n"`) from the preceding text node.
//! - `-}}`: Trims all leading whitespace (`" \t\r\n"`) from the following text node.
//! Example:
//! ```gotemplate
//! <div>
//!   {{- if true -}}
//!     <span>Inline Content</span>
//!   {{- end -}}
//! </div>
//! ```
//! Produces: `<div><span>Inline Content</span></div>`
//!
//! ## 7. Comments
//! - `{{/* This is a comment and will be completely omitted from output */}}`
//!
//! ## 8. Cross-Template Composition & Inheritance
//! - **Named Template Definition (`define`)**:
//!   ```gotemplate
//!   {{- define "header" -}}
//!     <header><h1>{{ .Title }}</h1></header>
//!   {{- end -}}
//!   ```
//! - **Template Invocation (`template`)**:
//!   Invokes a named template with either current context or an explicit pipeline data object:
//!   `{{ template "header" . }}`
//!   `{{ template "user_card" .User }}`
//! - **Template Overriding & Fallbacks (`block`)**:
//!   Defines a default implementation and immediately invokes it. If an earlier definition of
//!   the name exists, that override is rendered instead:
//!   ```gotemplate
//!   {{ block "footer" . }}
//!     <footer>Default Copyright © 2026</footer>
//!   {{ end }}
//!   ```
//! - **Direct Execution (`executeTemplate`)**:
//!   Render any named sub-template directly to an output stream:
//!   `try tmpl.executeTemplate(writer, "header", data);`
//!
//! ---
//!
//! # Basic Usage Example
//!
//! ```zig
//! const std = @import("std");
//! const stdgo = @import("stdgo");
//! const template = stdgo.text.template;
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     const tmpl_src =
//!         \\Hello, {{ .name | upper }}!
//!         \\Status: {{ if .is_admin }}Admin{{ else }}Member{{ end }}
//!         \\Roles:
//!         \\{{- for .roles |role, i| }}
//!         \\  {{ add i 1 }}. {{ role }}
//!         \\{{- end }}
//!     ;
//!
//!     var tmpl = try template.Template.new(allocator, "demo").parse(tmpl_src);
//!     defer tmpl.deinit();
//!
//!     var buf = stdgo.bytes.Buffer.init(allocator);
//!     defer buf.deinit();
//!
//!     const data = .{
//!         .name = "gopher",
//!         .is_admin = true,
//!         .roles = &.{ "dev", "ops" },
//!     };
//!
//!     try tmpl.execute(buf.writer(), data);
//!     std.debug.print("{s}\n", .{buf.string()});
//! }
//! ```

const std = @import("std");
const io = @import("../io.zig");
const Allocator = std.mem.Allocator;

pub const SafeKind = enum {
    html,
    js,
    css,
    url,
    attr,
};

pub const Value = union(enum) {
    string: []const u8,
    safe_string: struct {
        kind: SafeKind,
        data: []const u8,
    },
    int: i64,
    float: f64,
    bool: bool,
    null,
    list: []const Value,
    map: std.StringHashMap(Value),

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .bool => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .safe_string => |s| s.data.len > 0,
            .list => |l| l.len > 0,
            .map => |m| m.count() > 0,
            .null => false,
        };
    }

    pub fn format(self: Value, writer: *io.Writer) !void {
        switch (self) {
            .string => |s| try writer.writeAll(s),
            .safe_string => |s| try writer.writeAll(s.data),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => {},
            .list => |l| {
                try writer.writeByte('[');
                for (l, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format(writer);
                }
                try writer.writeByte(']');
            },
            .map => |m| {
                try writer.writeAll("map[");
                var it = m.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeByte(' ');
                    first = false;
                    try writer.print("{s}:", .{entry.key_ptr.*});
                    try entry.value_ptr.format(writer);
                }
                try writer.writeByte(']');
            },
        }
    }
};

/// Helper to convert any Zig type into a template Value using the provided arena allocator.
pub fn toValue(allocator: Allocator, data: anytype) Allocator.Error!Value {
    const T = @TypeOf(data);
    switch (@typeInfo(T)) {
        .bool => return Value{ .bool = data },
        .int => return Value{ .int = @intCast(data) },
        .comptime_int => return Value{ .int = @intCast(data) },
        .float => return Value{ .float = @floatCast(data) },
        .comptime_float => return Value{ .float = @floatCast(data) },
        .null => return Value.null,
        .optional => {
            if (data) |val| {
                return toValue(allocator, val);
            } else {
                return Value.null;
            }
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => {
                if (ptr_info.child == u8) {
                    return Value{ .string = data };
                }
                var list = std.ArrayList(Value).empty;
                for (data) |item| {
                    try list.append(allocator, try toValue(allocator, item));
                }
                return Value{ .list = try list.toOwnedSlice(allocator) };
            },
            .one => {
                const is_u8_array = @typeInfo(ptr_info.child) == .array and
                    @typeInfo(ptr_info.child).array.child == u8;
                if (is_u8_array) {
                    return Value{ .string = data[0..] };
                }
                return toValue(allocator, data.*);
            },
            else => return Value.null,
        },
        .array => |arr_info| {
            if (arr_info.child == u8) {
                return Value{ .string = data[0..] };
            }
            var list = std.ArrayList(Value).empty;
            for (data) |item| {
                try list.append(allocator, try toValue(allocator, item));
            }
            return Value{ .list = try list.toOwnedSlice(allocator) };
        },
        .@"struct" => |s_info| {
            if (@hasDecl(T, "_is_safe_string")) {
                return Value{
                    .safe_string = .{
                        .kind = T._safe_kind,
                        .data = data.data,
                    },
                };
            }
            if (s_info.is_tuple) {
                var list = std.ArrayList(Value).empty;
                inline for (s_info.field_names) |f_name| {
                    try list.append(allocator, try toValue(allocator, @field(data, f_name)));
                }
                return Value{ .list = try list.toOwnedSlice(allocator) };
            }
            var map = std.StringHashMap(Value).init(allocator);
            inline for (s_info.field_names) |f_name| {
                const val = try toValue(allocator, @field(data, f_name));
                try map.put(f_name, val);
            }
            return Value{ .map = map };
        },
        else => return Value.null,
    }
}

pub const FuncFn = *const fn (allocator: Allocator, args: []const Value) anyerror!Value;
pub const FuncMap = std.StringHashMap(FuncFn);

pub const Scope = struct {
    parent: ?*Scope = null,
    vars: std.StringHashMap(Value),
    is_const_map: std.StringHashMap(bool),

    pub fn init(allocator: Allocator, parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .vars = std.StringHashMap(Value).init(allocator),
            .is_const_map = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn declare(self: *Scope, name: []const u8, val: Value, is_const: bool) !void {
        try self.vars.put(name, val);
        try self.is_const_map.put(name, is_const);
    }

    pub fn assign(self: *Scope, name: []const u8, val: Value) !void {
        if (self.vars.contains(name)) {
            if (self.is_const_map.get(name) orelse false) {
                return error.CannotAssignToConstant;
            }
            try self.vars.put(name, val);
            return;
        }
        if (self.parent) |p| {
            return p.assign(name, val);
        }
        return error.UndefinedVariable;
    }

    pub fn get(self: *const Scope, name: []const u8) ?Value {
        if (self.vars.get(name)) |v| {
            return v;
        }
        if (self.parent) |p| {
            return p.get(name);
        }
        return null;
    }
};

pub const Node = union(enum) {
    text: []const u8,
    action: []const []const u8, // e.g. [".Name", "upper"]
    assign: struct {
        name: []const u8,
        is_const: bool,
        is_declaration: bool,
        pipeline: []const []const u8,
    },
    @"if": struct {
        condition: []const u8,
        then_branch: []const Node,
        else_branch: ?[]const Node = null,
    },
    with: struct {
        target: []const u8,
        body_branch: []const Node,
        else_branch: ?[]const Node = null,
    },
    range: struct {
        target: []const u8,
        item_capture: ?[]const u8 = null,
        index_capture: ?[]const u8 = null,
        body_branch: []const Node,
        else_branch: ?[]const Node = null,
    },
    template_call: struct {
        name: []const u8,
        pipeline: ?[]const []const u8 = null,
    },
};

pub const Template = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    root_nodes: []const Node = &.{},
    funcs: FuncMap,
    templates: std.StringHashMap([]const Node),

    pub fn new(allocator: Allocator, name: []const u8) !*Template {
        const tmpl = try allocator.create(Template);
        errdefer allocator.destroy(tmpl);

        tmpl.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .name = name,
            .root_nodes = &.{},
            .funcs = FuncMap.init(allocator),
            .templates = std.StringHashMap([]const Node).init(allocator),
        };
        errdefer {
            tmpl.arena.deinit();
            tmpl.funcs.deinit();
            tmpl.templates.deinit();
        }
        try tmpl.registerDefaultFuncs();
        return tmpl;
    }

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
        self.funcs.deinit();
        self.templates.deinit();
        self.allocator.destroy(self);
    }

    pub fn funcMap(self: *Template, funcs: FuncMap) !*Template {
        var it = funcs.iterator();
        while (it.next()) |e| {
            try self.funcs.put(e.key_ptr.*, e.value_ptr.*);
        }
        return self;
    }

    pub fn addFunc(self: *Template, name: []const u8, func: FuncFn) !*Template {
        try self.funcs.put(name, func);
        return self;
    }

    pub fn lookup(self: *const Template, name: []const u8) ?[]const Node {
        if (self.templates.get(name)) |nodes| {
            return nodes;
        }
        if (std.mem.eql(u8, self.name, name)) {
            return self.root_nodes;
        }
        return null;
    }

    /// Parse parses text as a template body.
    pub fn parse(self: *Template, text: []const u8) !*Template {
        var parser = Parser{
            .allocator = self.arena.allocator(),
            .input = text,
            .pos = 0,
            .template = self,
        };
        self.root_nodes = try parser.parseNodes(null);
        if (self.name.len > 0) {
            try self.templates.put(self.name, self.root_nodes);
        }
        return self;
    }

    /// Execute applies a parsed template to the specified data object,
    /// and writes the output to w.
    pub fn execute(self: *Template, w: *io.Writer, data: anytype) !void {
        var exec_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer exec_arena.deinit();
        const eval_alloc = exec_arena.allocator();

        const root_val = try toValue(eval_alloc, data);
        var root_scope = Scope.init(eval_alloc, null);
        try self.executeNodes(eval_alloc, w, self.root_nodes, root_val, &root_scope);
    }

    /// ExecuteTemplate applies the template associated with t that has the given name
    /// to the specified data object and writes the output to w.
    pub fn executeTemplate(self: *Template, w: *io.Writer, name: []const u8, data: anytype) !void {
        const sub_nodes = self.lookup(name) orelse return error.TemplateNotFound;

        var exec_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer exec_arena.deinit();
        const eval_alloc = exec_arena.allocator();

        const root_val = try toValue(eval_alloc, data);
        var root_scope = Scope.init(eval_alloc, null);
        try self.executeNodes(eval_alloc, w, sub_nodes, root_val, &root_scope);
    }

    fn executeNodes(
        self: *Template,
        eval_alloc: Allocator,
        w: *io.Writer,
        nodes: []const Node,
        ctx: Value,
        scope: *Scope,
    ) anyerror!void {
        for (nodes) |node| {
            switch (node) {
                .text => |t| try w.writeAll(t),
                .assign => |assign_node| {
                    const val = try self.evalPipeline(eval_alloc, assign_node.pipeline, ctx, scope);
                    if (assign_node.is_declaration) {
                        try scope.declare(assign_node.name, val, assign_node.is_const);
                    } else {
                        try scope.assign(assign_node.name, val);
                    }
                },
                .action => |pipeline| {
                    const res = try self.evalPipeline(eval_alloc, pipeline, ctx, scope);
                    try res.format(w);
                },
                .@"if" => |if_node| {
                    const cond_val = try self.evalCommand(
                        eval_alloc,
                        if_node.condition,
                        ctx,
                        null,
                        scope,
                    );
                    if (cond_val.isTruthy()) {
                        var child_scope = Scope.init(eval_alloc, scope);
                        try self.executeNodes(
                            eval_alloc,
                            w,
                            if_node.then_branch,
                            ctx,
                            &child_scope,
                        );
                    } else if (if_node.else_branch) |else_branch| {
                        var child_scope = Scope.init(eval_alloc, scope);
                        try self.executeNodes(eval_alloc, w, else_branch, ctx, &child_scope);
                    }
                },
                .with => |with_node| {
                    const val = try self.evalCommand(
                        eval_alloc,
                        with_node.target,
                        ctx,
                        null,
                        scope,
                    );
                    if (val.isTruthy()) {
                        var child_scope = Scope.init(eval_alloc, scope);
                        try self.executeNodes(
                            eval_alloc,
                            w,
                            with_node.body_branch,
                            val,
                            &child_scope,
                        );
                    } else if (with_node.else_branch) |eb| {
                        var child_scope = Scope.init(eval_alloc, scope);
                        try self.executeNodes(eval_alloc, w, eb, ctx, &child_scope);
                    }
                },
                .range => |range_node| {
                    const target_val = try self.evalCommand(
                        eval_alloc,
                        range_node.target,
                        ctx,
                        null,
                        scope,
                    );
                    switch (target_val) {
                        .list => |items| {
                            if (items.len == 0) {
                                if (range_node.else_branch) |eb| {
                                    var child_scope = Scope.init(eval_alloc, scope);
                                    try self.executeNodes(eval_alloc, w, eb, ctx, &child_scope);
                                }
                            } else {
                                for (items, 0..) |item, idx| {
                                    var loop_scope = Scope.init(eval_alloc, scope);
                                    if (range_node.item_capture) |item_name| {
                                        try loop_scope.declare(item_name, item, true);
                                    }
                                    if (range_node.index_capture) |idx_name| {
                                        const idx_val = Value{ .int = @intCast(idx) };
                                        try loop_scope.declare(idx_name, idx_val, true);
                                    }
                                    try self.executeNodes(
                                        eval_alloc,
                                        w,
                                        range_node.body_branch,
                                        item,
                                        &loop_scope,
                                    );
                                }
                            }
                        },
                        else => {
                            if (range_node.else_branch) |eb| {
                                var child_scope = Scope.init(eval_alloc, scope);
                                try self.executeNodes(eval_alloc, w, eb, ctx, &child_scope);
                            }
                        },
                    }
                },
                .template_call => |call| {
                    const sub_ctx = if (call.pipeline) |pl|
                        try self.evalPipeline(eval_alloc, pl, ctx, scope)
                    else
                        ctx;

                    const sub_nodes = self.lookup(call.name) orelse return error.TemplateNotFound;
                    var child_scope = Scope.init(eval_alloc, scope);
                    try self.executeNodes(eval_alloc, w, sub_nodes, sub_ctx, &child_scope);
                },
            }
        }
    }

    fn evalPipeline(
        self: *Template,
        eval_alloc: Allocator,
        pipeline: []const []const u8,
        ctx: Value,
        scope: *Scope,
    ) anyerror!Value {
        if (pipeline.len == 0) return Value.null;

        var current: ?Value = null;
        for (pipeline) |cmd_str| {
            current = try self.evalCommand(eval_alloc, cmd_str, ctx, current, scope);
        }
        return current orelse Value.null;
    }

    fn evalCommand(
        self: *Template,
        eval_alloc: Allocator,
        cmd_str: []const u8,
        ctx: Value,
        pipelined_arg: ?Value,
        scope: *Scope,
    ) anyerror!Value {
        const tokens = try tokenizeCommand(eval_alloc, cmd_str);
        if (tokens.len == 0) {
            return pipelined_arg orelse Value.null;
        }

        const head = tokens[0];

        // 1. If head is a local variable in scope AND tokens.len == 1, return it directly!
        if (tokens.len == 1) {
            if (scope.get(head)) |v| {
                return v;
            }
        }

        // 2. Check if head is a registered function
        if (self.funcs.get(head)) |func| {
            var args = std.ArrayList(Value).empty;
            for (tokens[1..]) |tok| {
                const v = try self.resolveSingleValue(eval_alloc, tok, ctx, scope);
                try args.append(eval_alloc, v);
            }
            if (pipelined_arg) |p_arg| {
                // In Go templates, the pipelined value is passed as the last argument
                try args.append(eval_alloc, p_arg);
            }
            return try func(eval_alloc, args.items);
        }

        // 3. If not a function, tokens.len must be 1 (resolve head directly)
        if (tokens.len == 1) {
            const val = try self.resolveSingleValue(eval_alloc, head, ctx, scope);
            return val;
        }

        return Value.null;
    }

    fn resolveSingleValue(
        self: *Template,
        eval_alloc: Allocator,
        ident_str: []const u8,
        ctx: Value,
        scope: *Scope,
    ) anyerror!Value {
        const ident = std.mem.trim(u8, ident_str, " \t\r\n");
        if (ident.len == 0) return Value.null;

        // Parenthesized command e.g. (gt .Age 18)
        if (ident.len >= 2 and ident[0] == '(' and ident[ident.len - 1] == ')') {
            const inner = std.mem.trim(u8, ident[1 .. ident.len - 1], " \t\r\n");
            return try self.evalCommand(eval_alloc, inner, ctx, null, scope);
        }

        if (std.mem.eql(u8, ident, ".")) {
            return ctx;
        }

        if (std.mem.eql(u8, ident, "true")) return Value{ .bool = true };
        if (std.mem.eql(u8, ident, "false")) return Value{ .bool = false };
        if (std.mem.eql(u8, ident, "nil") or std.mem.eql(u8, ident, "null")) return Value.null;

        // Integer literal
        if (std.fmt.parseInt(i64, ident, 10)) |num| {
            return Value{ .int = num };
        } else |_| {}

        // Float literal (e.g. 3.14)
        if (std.mem.indexOfScalar(u8, ident, '.') != null and ident[0] != '.') {
            if (std.fmt.parseFloat(f64, ident)) |flt| {
                return Value{ .float = flt };
            } else |_| {}
        }

        // String literal e.g. "constant"
        if (ident.len >= 2 and ident[0] == '"' and ident[ident.len - 1] == '"') {
            return Value{ .string = ident[1 .. ident.len - 1] };
        }

        // Variable or field access
        // Case 1: Dot-prefixed context lookup (.Name or .@"content-type" or .User.@"profile.email")
        if (ident[0] == '.') {
            return resolvePath(ctx, ident[1..]);
        }

        // Case 2: Variable in scope, e.g. "x", "user.name", "user.@"content-type"", @"special"
        var base_ident = ident;
        var rest_path: ?[]const u8 = null;

        if (ident[0] == '@' and ident.len >= 3 and ident[1] == '"') {
            const content_start: usize = 2;
            var j: usize = 2;
            while (j < ident.len and ident[j] != '"') : (j += 1) {
                if (ident[j] == '\\' and j + 1 < ident.len) j += 1;
            }
            base_ident = ident[content_start..j];
            if (j + 1 < ident.len and ident[j + 1] == '.') {
                rest_path = ident[j + 2 ..];
            }
        } else if (std.mem.indexOfScalar(u8, ident, '.')) |dot_idx| {
            base_ident = ident[0..dot_idx];
            rest_path = ident[dot_idx + 1 ..];
        }

        if (scope.get(base_ident)) |v| {
            if (rest_path) |p| {
                return resolvePath(v, p);
            }
            return v;
        }

        return Value.null;
    }

    fn resolvePath(root: Value, path: []const u8) Value {
        var curr = root;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '.') {
                i += 1;
                continue;
            }

            var part: []const u8 = "";
            if (path[i] == '@' and i + 1 < path.len and path[i + 1] == '"') {
                const content_start = i + 2;
                i += 2;
                while (i < path.len and path[i] != '"') : (i += 1) {
                    if (path[i] == '\\' and i + 1 < path.len) i += 1;
                }
                part = path[content_start..i];
                if (i < path.len and path[i] == '"') i += 1;
            } else {
                const start = i;
                while (i < path.len and path[i] != '.') : (i += 1) {}
                part = path[start..i];
            }

            if (part.len == 0) continue;

            switch (curr) {
                .map => |m| {
                    curr = m.get(part) orelse return Value.null;
                },
                else => return Value.null,
            }
        }
        return curr;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }

    fn tokenizeCommand(allocator: Allocator, s: []const u8) ![]const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        var i: usize = 0;
        while (i < s.len) {
            while (i < s.len and isSpace(s[i])) : (i += 1) {}
            if (i >= s.len) break;
            if (s[i] == '"') {
                const start = i;
                i += 1;
                while (i < s.len and s[i] != '"') : (i += 1) {
                    if (s[i] == '\\' and i + 1 < s.len) i += 1;
                }
                if (i < s.len) i += 1;
                try list.append(allocator, s[start..i]);
            } else if (s[i] == '(') {
                const start = i;
                var depth: usize = 1;
                i += 1;
                while (i < s.len and depth > 0) : (i += 1) {
                    if (s[i] == '(') {
                        depth += 1;
                    } else if (s[i] == ')') {
                        depth -= 1;
                    } else if (s[i] == '"') {
                        i += 1;
                        while (i < s.len and s[i] != '"') : (i += 1) {
                            if (s[i] == '\\' and i + 1 < s.len) i += 1;
                        }
                    }
                }
                try list.append(allocator, s[start..i]);
            } else {
                const start = i;
                while (i < s.len and !isSpace(s[i])) : (i += 1) {
                    if (s[i] == '"') {
                        i += 1;
                        while (i < s.len and s[i] != '"') : (i += 1) {
                            if (s[i] == '\\' and i + 1 < s.len) i += 1;
                        }
                    }
                }
                try list.append(allocator, s[start..i]);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    fn registerDefaultFuncs(self: *Template) !void {
        const DefaultFuncs = struct {
            fn upper(allocator: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value.null;
                if (args[0] != .string) return args[0];
                const str = args[0].string;
                const out = try allocator.alloc(u8, str.len);
                for (str, 0..) |c, i| {
                    out[i] = std.ascii.toUpper(c);
                }
                return Value{ .string = out };
            }

            fn lower(allocator: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value.null;
                if (args[0] != .string) return args[0];
                const str = args[0].string;
                const out = try allocator.alloc(u8, str.len);
                for (str, 0..) |c, i| {
                    out[i] = std.ascii.toLower(c);
                }
                return Value{ .string = out };
            }

            fn len(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value{ .int = 0 };
                return switch (args[0]) {
                    .string => |s| Value{ .int = @intCast(s.len) },
                    .list => |l| Value{ .int = @intCast(l.len) },
                    .map => |m| Value{ .int = @intCast(m.count()) },
                    else => Value{ .int = 0 },
                };
            }

            fn not(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value{ .bool = true };
                return Value{ .bool = !args[0].isTruthy() };
            }

            fn eq(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                const first = args[0];
                for (args[1..]) |arg| {
                    if (compareValues(first, arg)) |ord| {
                        if (ord == .eq) return Value{ .bool = true };
                    }
                }
                return Value{ .bool = false };
            }

            fn ne(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                if (compareValues(args[0], args[1])) |ord| {
                    return Value{ .bool = ord != .eq };
                }
                return Value{ .bool = true };
            }

            fn lt(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                if (compareValues(args[0], args[1])) |ord| {
                    return Value{ .bool = ord == .lt };
                }
                return Value{ .bool = false };
            }

            fn le(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                if (compareValues(args[0], args[1])) |ord| {
                    return Value{ .bool = ord == .lt or ord == .eq };
                }
                return Value{ .bool = false };
            }

            fn gt(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                if (compareValues(args[0], args[1])) |ord| {
                    return Value{ .bool = ord == .gt };
                }
                return Value{ .bool = false };
            }

            fn ge(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .bool = false };
                if (compareValues(args[0], args[1])) |ord| {
                    return Value{ .bool = ord == .gt or ord == .eq };
                }
                return Value{ .bool = false };
            }

            fn andFn(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value{ .bool = true };
                for (args) |arg| {
                    if (!arg.isTruthy()) return arg;
                }
                return args[args.len - 1];
            }

            fn orFn(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value{ .bool = false };
                for (args) |arg| {
                    if (arg.isTruthy()) return arg;
                }
                return args[args.len - 1];
            }

            fn print(allocator: Allocator, args: []const Value) anyerror!Value {
                var out = std.ArrayList(u8).empty;
                for (args) |arg| {
                    const s = try valueToString(allocator, arg);
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                }
                return Value{ .string = try out.toOwnedSlice(allocator) };
            }

            fn println(allocator: Allocator, args: []const Value) anyerror!Value {
                var out = std.ArrayList(u8).empty;
                for (args, 0..) |arg, i| {
                    if (i > 0) try out.append(allocator, ' ');
                    const s = try valueToString(allocator, arg);
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                }
                try out.append(allocator, '\n');
                return Value{ .string = try out.toOwnedSlice(allocator) };
            }

            fn printf(allocator: Allocator, args: []const Value) anyerror!Value {
                if (args.len == 0) return Value{ .string = "" };
                if (args[0] != .string) return Value{ .string = "" };

                const fmt_str = args[0].string;
                var out = std.ArrayList(u8).empty;
                var arg_idx: usize = 1;

                var i: usize = 0;
                while (i < fmt_str.len) {
                    if (fmt_str[i] == '%' and i + 1 < fmt_str.len) {
                        var j = i + 1;
                        if (j < fmt_str.len and fmt_str[j] == '%') {
                            try out.append(allocator, '%');
                            i += 2;
                            continue;
                        }

                        var pad_zero = false;
                        if (j < fmt_str.len and fmt_str[j] == '0') {
                            pad_zero = true;
                            j += 1;
                        }

                        var width: ?usize = null;
                        const width_start = j;
                        while (j < fmt_str.len and
                            fmt_str[j] >= '0' and
                            fmt_str[j] <= '9') : (j += 1)
                        {}
                        if (j > width_start) {
                            width = std.fmt.parseInt(usize, fmt_str[width_start..j], 10) catch null;
                        }

                        if (j < fmt_str.len and arg_idx < args.len) {
                            const spec = fmt_str[j];
                            const arg = args[arg_idx];
                            arg_idx += 1;
                            switch (spec) {
                                's' => {
                                    var to_free: ?[]const u8 = null;
                                    defer if (to_free) |f| allocator.free(f);
                                    const s = switch (arg) {
                                        .string => |str| str,
                                        else => blk: {
                                            const res = try valueToString(allocator, arg);
                                            to_free = res;
                                            break :blk res;
                                        },
                                    };
                                    if (width) |w| {
                                        if (s.len < w) {
                                            for (0..w - s.len) |_| try out.append(allocator, ' ');
                                        }
                                    }
                                    try out.appendSlice(allocator, s);
                                },
                                'd' => {
                                    var num_buf: [32]u8 = undefined;
                                    const val_i64: i64 = switch (arg) {
                                        .int => |v| v,
                                        .float => |v| @intFromFloat(v),
                                        else => 0,
                                    };
                                    const s = std.fmt.bufPrint(
                                        &num_buf,
                                        "{d}",
                                        .{val_i64},
                                    ) catch "";
                                    if (width) |w| {
                                        if (s.len < w) {
                                            const fill: u8 = if (pad_zero) '0' else ' ';
                                            for (0..w - s.len) |_| try out.append(allocator, fill);
                                        }
                                    }
                                    try out.appendSlice(allocator, s);
                                },
                                'f' => {
                                    var num_buf: [64]u8 = undefined;
                                    const val_f64: f64 = switch (arg) {
                                        .float => |v| v,
                                        .int => |v| @floatFromInt(v),
                                        else => 0.0,
                                    };
                                    const s = std.fmt.bufPrint(
                                        &num_buf,
                                        "{d:.6}",
                                        .{val_f64},
                                    ) catch "";
                                    if (width) |w| {
                                        if (s.len < w) {
                                            for (0..w - s.len) |_| try out.append(allocator, ' ');
                                        }
                                    }
                                    try out.appendSlice(allocator, s);
                                },
                                'v' => {
                                    const s = try valueToString(allocator, arg);
                                    defer allocator.free(s);
                                    try out.appendSlice(allocator, s);
                                },
                                else => {
                                    try out.appendSlice(allocator, fmt_str[i .. j + 1]);
                                },
                            }
                            i = j + 1;
                        } else {
                            try out.append(allocator, fmt_str[i]);
                            i += 1;
                        }
                    } else {
                        try out.append(allocator, fmt_str[i]);
                        i += 1;
                    }
                }

                return Value{ .string = try out.toOwnedSlice(allocator) };
            }

            fn index(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value.null;
                var curr = args[0];
                for (args[1..]) |key| {
                    switch (curr) {
                        .map => |m| {
                            if (key == .string) {
                                curr = m.get(key.string) orelse Value.null;
                            } else {
                                return Value.null;
                            }
                        },
                        .list => |l| {
                            if (key == .int and key.int >= 0 and key.int < l.len) {
                                curr = l[@intCast(key.int)];
                            } else {
                                return Value.null;
                            }
                        },
                        else => return Value.null,
                    }
                }
                return curr;
            }

            fn slice(allocator: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value.null;
                if (args[0] != .list) return Value.null;
                const l = args[0].list;
                const start_idx: usize = if (args[1] == .int and args[1].int >= 0)
                    @min(@as(usize, @intCast(args[1].int)), l.len)
                else
                    0;
                const end_idx: usize = if (args.len >= 3 and args[2] == .int and args[2].int >= 0)
                    @min(@as(usize, @intCast(args[2].int)), l.len)
                else
                    l.len;
                if (start_idx > end_idx) return Value.null;

                const sub_slice = try allocator.alloc(Value, end_idx - start_idx);
                @memcpy(sub_slice, l[start_idx..end_idx]);
                return Value{ .list = sub_slice };
            }

            fn add(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .int = 0 };
                if (args[0] == .float or args[1] == .float) {
                    const a: f64 = if (args[0] == .float)
                        args[0].float
                    else
                        @floatFromInt(args[0].int);
                    const b: f64 = if (args[1] == .float)
                        args[1].float
                    else
                        @floatFromInt(args[1].int);
                    return Value{ .float = a + b };
                }
                const a: i64 = if (args[0] == .int) args[0].int else 0;
                const b: i64 = if (args[1] == .int) args[1].int else 0;
                return Value{ .int = a + b };
            }

            fn sub(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .int = 0 };
                if (args[0] == .float or args[1] == .float) {
                    const a: f64 = if (args[0] == .float)
                        args[0].float
                    else
                        @floatFromInt(args[0].int);
                    const b: f64 = if (args[1] == .float)
                        args[1].float
                    else
                        @floatFromInt(args[1].int);
                    return Value{ .float = a - b };
                }
                const a: i64 = if (args[0] == .int) args[0].int else 0;
                const b: i64 = if (args[1] == .int) args[1].int else 0;
                return Value{ .int = a - b };
            }

            fn mul(_: Allocator, args: []const Value) anyerror!Value {
                if (args.len < 2) return Value{ .int = 0 };
                if (args[0] == .float or args[1] == .float) {
                    const a: f64 = if (args[0] == .float)
                        args[0].float
                    else
                        @floatFromInt(args[0].int);
                    const b: f64 = if (args[1] == .float)
                        args[1].float
                    else
                        @floatFromInt(args[1].int);
                    return Value{ .float = a * b };
                }
                const a: i64 = if (args[0] == .int) args[0].int else 0;
                const b: i64 = if (args[1] == .int) args[1].int else 0;
                return Value{ .int = a * b };
            }
        };

        try self.funcs.put("upper", DefaultFuncs.upper);
        try self.funcs.put("lower", DefaultFuncs.lower);
        try self.funcs.put("len", DefaultFuncs.len);
        try self.funcs.put("not", DefaultFuncs.not);
        try self.funcs.put("eq", DefaultFuncs.eq);
        try self.funcs.put("ne", DefaultFuncs.ne);
        try self.funcs.put("lt", DefaultFuncs.lt);
        try self.funcs.put("le", DefaultFuncs.le);
        try self.funcs.put("gt", DefaultFuncs.gt);
        try self.funcs.put("ge", DefaultFuncs.ge);
        try self.funcs.put("and", DefaultFuncs.andFn);
        try self.funcs.put("or", DefaultFuncs.orFn);
        try self.funcs.put("print", DefaultFuncs.print);
        try self.funcs.put("println", DefaultFuncs.println);
        try self.funcs.put("printf", DefaultFuncs.printf);
        try self.funcs.put("index", DefaultFuncs.index);
        try self.funcs.put("slice", DefaultFuncs.slice);
        try self.funcs.put("add", DefaultFuncs.add);
        try self.funcs.put("sub", DefaultFuncs.sub);
        try self.funcs.put("mul", DefaultFuncs.mul);
    }
};

fn compareValues(a: Value, b: Value) ?std.math.Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    if (a == .float and b == .float) {
        if (a.float < b.float) return .lt;
        if (a.float > b.float) return .gt;
        return .eq;
    }
    if (a == .int and b == .float) {
        const af: f64 = @floatFromInt(a.int);
        if (af < b.float) return .lt;
        if (af > b.float) return .gt;
        return .eq;
    }
    if (a == .float and b == .int) {
        const bf: f64 = @floatFromInt(b.int);
        if (a.float < bf) return .lt;
        if (a.float > bf) return .gt;
        return .eq;
    }
    if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
    if (a == .safe_string and b == .safe_string) {
        return std.mem.order(u8, a.safe_string.data, b.safe_string.data);
    }
    if (a == .string and b == .safe_string) return std.mem.order(u8, a.string, b.safe_string.data);
    if (a == .safe_string and b == .string) return std.mem.order(u8, a.safe_string.data, b.string);
    if (a == .bool and b == .bool) {
        if (a.bool == b.bool) return .eq;
        return if (!a.bool and b.bool) .lt else .gt;
    }
    if (a == .null and b == .null) return .eq;
    return null;
}

fn valueToString(allocator: Allocator, val: Value) anyerror![]const u8 {
    const bytes = @import("../bytes.zig");
    var buf = bytes.Buffer.init(allocator);
    defer buf.deinit();
    try val.format(buf.writer());
    return try buf.toOwnedSlice();
}

/// Must is a helper that wraps a call to a function returning (*Template, error)
/// and panics if the error is non-null. It is intended for use in variable initializations.
pub fn Must(tmpl: anyerror!*Template) *Template {
    return tmpl catch |err| @panic(@errorName(err));
}

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    template: *Template,
    last_stop_tag: ?[]const u8 = null,

    const HeaderInfo = struct {
        name: []const u8,
        pipeline_str: ?[]const u8,
    };

    fn parseTemplateHeader(header: []const u8) HeaderInfo {
        const trimmed = std.mem.trim(u8, header, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '"') {
            var i: usize = 1;
            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {
                if (trimmed[i] == '\\' and i + 1 < trimmed.len) i += 1;
            }
            const name = trimmed[1..i];
            const rest = if (i + 1 < trimmed.len)
                std.mem.trim(u8, trimmed[i + 1 ..], " \t\r\n")
            else
                "";
            return .{
                .name = name,
                .pipeline_str = if (rest.len > 0) rest else null,
            };
        } else {
            if (std.mem.indexOfAny(u8, trimmed, " \t\r\n")) |sp| {
                return .{
                    .name = trimmed[0..sp],
                    .pipeline_str = std.mem.trim(u8, trimmed[sp + 1 ..], " \t\r\n"),
                };
            } else {
                return .{
                    .name = trimmed,
                    .pipeline_str = null,
                };
            }
        }
    }

    fn parseNodes(self: *Parser, until_tag: ?[]const u8) anyerror![]const Node {
        var nodes = std.ArrayList(Node).empty;

        while (self.pos < self.input.len) {
            const open_tag = std.mem.indexOfPos(u8, self.input, self.pos, "{{");
            if (open_tag == null) {
                // Remainder is plain text
                const rem = self.input[self.pos..];
                if (rem.len > 0) {
                    try nodes.append(self.allocator, .{ .text = rem });
                }
                self.pos = self.input.len;
                break;
            }

            const ot = open_tag.?;
            const has_left_trim = (ot + 2 < self.input.len and self.input[ot + 2] == '-');

            var pre_text = self.input[self.pos..ot];
            if (has_left_trim) {
                pre_text = std.mem.trimEnd(u8, pre_text, " \t\r\n");
                if (nodes.items.len > 0) {
                    var last = &nodes.items[nodes.items.len - 1];
                    if (last.* == .text) {
                        last.text = std.mem.trimEnd(u8, last.text, " \t\r\n");
                    }
                }
            }
            if (pre_text.len > 0) {
                try nodes.append(self.allocator, .{ .text = pre_text });
            }

            const close_tag = std.mem.indexOfPos(u8, self.input, ot + 2, "}}") orelse {
                return error.UnclosedTemplateTag;
            };

            const has_right_trim = (close_tag > ot + 2 and self.input[close_tag - 1] == '-');

            const tag_start = if (has_left_trim) ot + 3 else ot + 2;
            const tag_end = if (has_right_trim) close_tag - 1 else close_tag;
            const inner = std.mem.trim(u8, self.input[tag_start..tag_end], " \t\r\n");
            self.pos = close_tag + 2;
            if (has_right_trim) {
                while (self.pos < self.input.len and
                    std.ascii.isWhitespace(self.input[self.pos])) : (self.pos += 1)
                {}
            }

            // Comment {{/* ... */}}
            if (std.mem.startsWith(u8, inner, "/*") and std.mem.endsWith(u8, inner, "*/")) {
                continue;
            }

            // Check if matches until_tag
            if (until_tag) |target| {
                if (std.mem.startsWith(u8, inner, target)) {
                    self.last_stop_tag = inner;
                    return try nodes.toOwnedSlice(self.allocator);
                }
            }

            if (std.mem.startsWith(u8, inner, "end")) {
                self.last_stop_tag = inner;
                return try nodes.toOwnedSlice(self.allocator);
            }

            if (std.mem.startsWith(u8, inner, "define ")) {
                const header = std.mem.trim(u8, inner[7..], " \t\r\n");
                const parsed = parseTemplateHeader(header);
                const sub_nodes = try self.parseNodes("end");
                try self.template.templates.put(parsed.name, sub_nodes);
                continue;
            }

            if (std.mem.startsWith(u8, inner, "template ")) {
                const header = std.mem.trim(u8, inner[9..], " \t\r\n");
                const parsed = parseTemplateHeader(header);
                var pipeline: ?[]const []const u8 = null;
                if (parsed.pipeline_str) |p_str| {
                    pipeline = try self.splitPipeline(p_str);
                }
                try nodes.append(self.allocator, .{
                    .template_call = .{
                        .name = parsed.name,
                        .pipeline = pipeline,
                    },
                });
                continue;
            }

            if (std.mem.startsWith(u8, inner, "block ")) {
                const header = std.mem.trim(u8, inner[6..], " \t\r\n");
                const parsed = parseTemplateHeader(header);
                const sub_nodes = try self.parseNodes("end");
                if (!self.template.templates.contains(parsed.name)) {
                    try self.template.templates.put(parsed.name, sub_nodes);
                }
                var pipeline: ?[]const []const u8 = null;
                if (parsed.pipeline_str) |p_str| {
                    pipeline = try self.splitPipeline(p_str);
                }
                try nodes.append(self.allocator, .{
                    .template_call = .{
                        .name = parsed.name,
                        .pipeline = pipeline,
                    },
                });
                continue;
            }

            if (std.mem.startsWith(u8, inner, "if ")) {
                const cond = std.mem.trim(u8, inner[3..], " \t\r\n");
                const if_node = try self.parseIf(cond);
                try nodes.append(self.allocator, if_node);
                continue;
            }

            if (std.mem.startsWith(u8, inner, "with ")) {
                const target = std.mem.trim(u8, inner[5..], " \t\r\n");
                const body_branch = try self.parseNodes("else");
                var else_branch: ?[]const Node = null;
                if (self.last_stop_tag) |tag| {
                    if (std.mem.eql(u8, tag, "else") or std.mem.startsWith(u8, tag, "else ")) {
                        else_branch = try self.parseNodes("end");
                    }
                }
                try nodes.append(self.allocator, .{
                    .with = .{
                        .target = target,
                        .body_branch = body_branch,
                        .else_branch = else_branch,
                    },
                });
                continue;
            }

            if (std.mem.startsWith(u8, inner, "const ")) {
                const rest = std.mem.trim(u8, inner[6..], " \t\r\n");
                if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
                    const var_name = std.mem.trim(u8, rest[0..eq_pos], " \t\r\n");
                    const expr_str = std.mem.trim(u8, rest[eq_pos + 1 ..], " \t\r\n");
                    const pipeline = try self.splitPipeline(expr_str);
                    try nodes.append(self.allocator, .{
                        .assign = .{
                            .name = var_name,
                            .is_const = true,
                            .is_declaration = true,
                            .pipeline = pipeline,
                        },
                    });
                    continue;
                }
            }

            if (std.mem.startsWith(u8, inner, "var ")) {
                const rest = std.mem.trim(u8, inner[4..], " \t\r\n");
                if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
                    const var_name = std.mem.trim(u8, rest[0..eq_pos], " \t\r\n");
                    const expr_str = std.mem.trim(u8, rest[eq_pos + 1 ..], " \t\r\n");
                    const pipeline = try self.splitPipeline(expr_str);
                    try nodes.append(self.allocator, .{
                        .assign = .{
                            .name = var_name,
                            .is_const = false,
                            .is_declaration = true,
                            .pipeline = pipeline,
                        },
                    });
                    continue;
                }
            }

            if (std.mem.startsWith(u8, inner, "range ") or std.mem.startsWith(u8, inner, "for ")) {
                const header = if (std.mem.startsWith(u8, inner, "range "))
                    std.mem.trim(u8, inner[6..], " \t\r\n")
                else
                    std.mem.trim(u8, inner[4..], " \t\r\n");

                var target = header;
                var item_capture: ?[]const u8 = null;
                var index_capture: ?[]const u8 = null;

                const pipe_start = std.mem.indexOfScalar(u8, header, '|');
                const pipe_end = std.mem.lastIndexOfScalar(u8, header, '|');
                if (pipe_start != null and pipe_end != null and pipe_end.? > pipe_start.?) {
                    target = std.mem.trim(u8, header[0..pipe_start.?], " \t\r\n");
                    const cap_slice = header[pipe_start.? + 1 .. pipe_end.?];
                    const captures_str = std.mem.trim(u8, cap_slice, " \t\r\n");
                    var it_cap = std.mem.splitScalar(u8, captures_str, ',');
                    if (it_cap.next()) |p1| {
                        const c1 = std.mem.trim(u8, p1, " \t\r\n");
                        if (c1.len > 0) item_capture = c1;
                    }
                    if (it_cap.next()) |p2| {
                        const c2 = std.mem.trim(u8, p2, " \t\r\n");
                        if (c2.len > 0) index_capture = c2;
                    }
                }

                const body_branch = try self.parseNodes("else");
                var else_branch: ?[]const Node = null;
                if (self.last_stop_tag) |tag| {
                    if (std.mem.eql(u8, tag, "else") or std.mem.startsWith(u8, tag, "else ")) {
                        else_branch = try self.parseNodes("end");
                    }
                }
                try nodes.append(self.allocator, .{
                    .range = .{
                        .target = target,
                        .item_capture = item_capture,
                        .index_capture = index_capture,
                        .body_branch = body_branch,
                        .else_branch = else_branch,
                    },
                });
                continue;
            }

            // Variable reassignment: name = expr
            if (std.mem.indexOfScalar(u8, inner, '=')) |eq_pos| {
                const before = inner[0..eq_pos];
                const after = inner[eq_pos + 1 ..];
                const has_prev_op = eq_pos > 0 and (inner[eq_pos - 1] == '!' or
                    inner[eq_pos - 1] == '<' or
                    inner[eq_pos - 1] == '>' or
                    inner[eq_pos - 1] == '=');
                const has_next_eq = after.len > 0 and after[0] == '=';
                const is_cmp = has_prev_op or has_next_eq;
                if (!is_cmp) {
                    const var_name = std.mem.trim(u8, before, " \t\r\n");
                    const has_invalid_char = std.mem.indexOfAny(u8, var_name, " \t\r\n()|") != null;
                    if (var_name.len > 0 and !has_invalid_char) {
                        const expr_str = std.mem.trim(u8, after, " \t\r\n");
                        const pipeline = try self.splitPipeline(expr_str);
                        try nodes.append(self.allocator, .{
                            .assign = .{
                                .name = var_name,
                                .is_const = false,
                                .is_declaration = false,
                                .pipeline = pipeline,
                            },
                        });
                        continue;
                    }
                }
            }

            // Normal action / pipeline: split by '|'
            const pipeline = try self.splitPipeline(inner);
            try nodes.append(self.allocator, .{
                .action = pipeline,
            });
        }

        return try nodes.toOwnedSlice(self.allocator);
    }

    fn parseIf(self: *Parser, cond: []const u8) anyerror!Node {
        const then_branch = try self.parseNodes("else");
        var else_branch: ?[]const Node = null;

        if (self.last_stop_tag) |tag| {
            if (std.mem.startsWith(u8, tag, "else if ")) {
                const next_cond = std.mem.trim(u8, tag[8..], " \t\r\n");
                const nested_if = try self.parseIf(next_cond);
                const nested_slice = try self.allocator.alloc(Node, 1);
                nested_slice[0] = nested_if;
                else_branch = nested_slice;
            } else if (std.mem.eql(u8, tag, "else") or std.mem.startsWith(u8, tag, "else ")) {
                else_branch = try self.parseNodes("end");
            }
        }

        return Node{
            .@"if" = .{
                .condition = cond,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        };
    }

    fn splitPipeline(self: *Parser, expr: []const u8) ![]const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len > 0) {
                try list.append(self.allocator, trimmed);
            }
        }
        return list.toOwnedSlice(self.allocator);
    }
};

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "text.template: simple field interpolation and function pipeline" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src = "Hello, {{ .Name | upper }}! Welcome to {{ .Platform }}.";
    var tmpl = try Template.new(testing.allocator, "greeting");
    defer tmpl.deinit();

    _ = try tmpl.parse(tmpl_src);

    const data = .{
        .Name = "gopher",
        .Platform = "Zig 0.17",
    };

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), data);

    try testing.expectEqualStrings("Hello, GOPHER! Welcome to Zig 0.17.", buf.string());
}

test "text.template: if-else conditional evaluation" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src = "{{ if .IsAdmin }}Admin access granted{{ else }}Access restricted{{ end }}";
    var tmpl = try Template.new(testing.allocator, "auth");
    defer tmpl.deinit();

    _ = try tmpl.parse(tmpl_src);

    // 1. True branch
    var buf1 = bytes.Buffer.init(testing.allocator);
    defer buf1.deinit();
    try tmpl.execute(buf1.writer(), .{ .IsAdmin = true });
    try testing.expectEqualStrings("Admin access granted", buf1.string());

    // 2. False branch
    var buf2 = bytes.Buffer.init(testing.allocator);
    defer buf2.deinit();
    try tmpl.execute(buf2.writer(), .{ .IsAdmin = false });
    try testing.expectEqualStrings("Access restricted", buf2.string());
}

test "text.template: range loop iteration" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src = "Items: {{ range .Items }}[{{ . }}] {{ else }}No items{{ end }}";
    var tmpl = try Template.new(testing.allocator, "loop");
    defer tmpl.deinit();

    _ = try tmpl.parse(tmpl_src);

    // 1. Non-empty range
    const items = [_][]const u8{ "alpha", "beta", "gamma" };
    var buf1 = bytes.Buffer.init(testing.allocator);
    defer buf1.deinit();
    try tmpl.execute(buf1.writer(), .{ .Items = &items });
    try testing.expectEqualStrings("Items: [alpha] [beta] [gamma] ", buf1.string());

    // 2. Empty range (else branch)
    const empty = [_][]const u8{};
    var buf2 = bytes.Buffer.init(testing.allocator);
    defer buf2.deinit();
    try tmpl.execute(buf2.writer(), .{ .Items = &empty });
    try testing.expectEqualStrings("Items: No items", buf2.string());
}

test "text.template: whitespace trimming {{- and -}}" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src = "Hello,   {{- .Name -}}   !";
    var tmpl = try Template.new(testing.allocator, "trim");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{ .Name = "World" });
    try testing.expectEqualStrings("Hello,World!", buf.string());
}

test "text.template: else if multi-branch ladder" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ if eq .Score 100 }}Perfect
        \\{{- else if ge .Score 90 }}Grade A
        \\{{- else if ge .Score 80 }}Grade B
        \\{{- else if ge .Score 60 }}Pass
        \\{{- else }}Fail
        \\{{- end }}
    ;

    var tmpl = try Template.new(testing.allocator, "ladder");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    // Score 100
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .Score = 100 });
        try testing.expectEqualStrings("Perfect", buf.string());
    }

    // Score 95
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .Score = 95 });
        try testing.expectEqualStrings("Grade A", buf.string());
    }

    // Score 85
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .Score = 85 });
        try testing.expectEqualStrings("Grade B", buf.string());
    }

    // Score 50
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .Score = 50 });
        try testing.expectEqualStrings("Fail", buf.string());
    }
}

test "text.template: with pipeline re-scoping and else" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ with .User }}User: {{ .Name }} ({{ .Role }}){{ else }}Anonymous Guest{{ end }}
    ;

    var tmpl = try Template.new(testing.allocator, "with_test");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    // With user present
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{
            .User = .{ .Name = "Alice", .Role = "Admin" },
        });
        try testing.expectEqualStrings("User: Alice (Admin)", buf.string());
    }

    // With user null/absent (else branch)
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .User = null });
        try testing.expectEqualStrings("Anonymous Guest", buf.string());
    }
}

test "text.template: comparison builtins (eq, ne, lt, le, gt, ge)" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ if eq .A .B }}A==B {{ end }}
        \\{{- if ne .A .B }}A!=B {{ end }}
        \\{{- if lt .A .B }}A<B {{ end }}
        \\{{- if le .A .B }}A<=B {{ end }}
        \\{{- if gt .B .A }}B>A {{ end }}
        \\{{- if ge .B .A }}B>=A {{ end }}
    ;

    var tmpl = try Template.new(testing.allocator, "compare");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{ .A = 10, .B = 20 });
    try testing.expectEqualStrings("A!=B A<B A<=B B>A B>=A ", buf.string());
}

test "text.template: boolean logic and parenthesized expressions (and, or, not)" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ if and .IsAdmin (gt .Age 18) }}Eligible Admin{{ else }}Not Eligible{{ end }}
    ;

    var tmpl = try Template.new(testing.allocator, "bool_logic");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    // Both true
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .IsAdmin = true, .Age = 25 });
        try testing.expectEqualStrings("Eligible Admin", buf.string());
    }

    // Underage
    {
        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();
        try tmpl.execute(buf.writer(), .{ .IsAdmin = true, .Age = 16 });
        try testing.expectEqualStrings("Not Eligible", buf.string());
    }
}

test "text.template: printf, print, println format builtins" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ printf "ID: %04d, Name: %s" .ID .Name }} | {{ print "A" "B" "C" }}
    ;

    var tmpl = try Template.new(testing.allocator, "fmt_test");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{ .ID = 42, .Name = "Gopher" });
    try testing.expectEqualStrings("ID: 0042, Name: Gopher | ABC", buf.string());
}

test "text.template: index and slice builtins" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\First: {{ index .Items 0 }} | Sub: {{ slice .Items 1 3 }}
    ;

    var tmpl = try Template.new(testing.allocator, "index_slice");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    const items = [_][]const u8{ "zero", "one", "two", "three" };
    try tmpl.execute(buf.writer(), .{ .Items = &items });
    try testing.expectEqualStrings("First: zero | Sub: [one, two]", buf.string());
}

test "text.template: Zig-style const declaration and expression pipeline" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ const greeting = .Message | upper -}}
        \\Greeting: {{ greeting }}!
    ;

    var tmpl = try Template.new(testing.allocator, "const_demo");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{ .Message = "hello from zig" });
    try testing.expectEqualStrings("Greeting: HELLO FROM ZIG!", buf.string());
}

test "text.template: Zig-style var declaration and mutation" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ var count = 10 -}}
        \\Initial: {{ count }}
        \\{{- count = add count 5 }}
        \\After: {{ count }}
    ;

    var tmpl = try Template.new(testing.allocator, "var_demo");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{});
    try testing.expectEqualStrings("Initial: 10\nAfter: 15", buf.string());
}

test "text.template: Zig-style const re-assignment error" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ const fixed = 42 }}
        \\{{ fixed = 100 }}
    ;

    var tmpl = try Template.new(testing.allocator, "const_err");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try testing.expectError(error.CannotAssignToConstant, tmpl.execute(buf.writer(), .{}));
}

test "text.template: Zig-style for loop payload capture |item, idx|" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ for .Items |item, idx| -}}
        \\[{{ idx }}: {{ item }}]
        \\{{- end }}
    ;

    var tmpl = try Template.new(testing.allocator, "for_capture");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    const items = [_][]const u8{ "alpha", "beta", "gamma" };
    try tmpl.execute(buf.writer(), .{ .Items = &items });
    try testing.expectEqualStrings("[0: alpha][1: beta][2: gamma]", buf.string());
}

test "text.template: Zig-style variable lexical scoping" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{ const x = "outer" -}}
        \\{{- if true -}}
        \\  {{ const x = "inner" -}}
        \\  In: {{ x }}
        \\{{- end }}
        \\Out: {{ x }}
    ;

    var tmpl = try Template.new(testing.allocator, "scope_demo");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{});
    try testing.expectEqualStrings("In: inner\nOut: outer", buf.string());
}

test "text.template: Zig-style @\"...\" quoted identifier fields" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const Header = struct {
        @"content-type": []const u8,
        @"x-request-id": []const u8,
        type: []const u8,
        @"app.kubernetes.io/name": []const u8,
    };

    const tmpl_src =
        \\Type: {{ .@"type" }}
        \\Content: {{ .@"content-type" | upper }}
        \\ReqID: {{ .@"x-request-id" }}
        \\App: {{ .@"app.kubernetes.io/name" }}
        \\{{ const ct = .@"content-type" -}}
        \\Const: {{ ct }}
    ;

    var tmpl = try Template.new(testing.allocator, "quoted_idents");
    defer tmpl.deinit();
    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    const data = Header{
        .@"content-type" = "application/json",
        .@"x-request-id" = "req_12345",
        .type = "api_event",
        .@"app.kubernetes.io/name" = "stdgo-service",
    };

    try tmpl.execute(buf.writer(), data);

    const expected =
        \\Type: api_event
        \\Content: APPLICATION/JSON
        \\ReqID: req_12345
        \\App: stdgo-service
        \\Const: application/json
    ;

    try testing.expectEqualStrings(expected, buf.string());
}

test "text.template: custom functions via addFunc and funcMap" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const Helpers = struct {
        fn repeat(allocator: Allocator, args: []const Value) anyerror!Value {
            if (args.len < 2 or args[0] != .string or args[1] != .int) return Value.null;
            const str = args[0].string;
            const n: usize = if (args[1].int > 0) @intCast(args[1].int) else 0;
            var out = std.ArrayList(u8).empty;
            for (0..n) |_| try out.appendSlice(allocator, str);
            return Value{ .string = try out.toOwnedSlice(allocator) };
        }

        fn exclaim(allocator: Allocator, args: []const Value) anyerror!Value {
            if (args.len == 0 or args[0] != .string) return Value.null;
            const res = try std.fmt.allocPrint(allocator, "[{s}!]", .{args[0].string});
            return Value{ .string = res };
        }
    };

    var tmpl = try Template.new(testing.allocator, "custom_func_demo");
    defer tmpl.deinit();

    _ = try tmpl.addFunc("repeat", Helpers.repeat);
    _ = try tmpl.addFunc("exclaim", Helpers.exclaim);

    _ = try tmpl.parse("Piped: {{ .Word | exclaim }} | Call: {{ repeat .Word 3 }}");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    try tmpl.execute(buf.writer(), .{ .Word = "Zig" });
    try testing.expectEqualStrings("Piped: [Zig!] | Call: ZigZigZig", buf.string());

    // Test funcMap with batch function registration
    var f_map = FuncMap.init(testing.allocator);
    defer f_map.deinit();
    try f_map.put("exclaim", Helpers.exclaim);

    var tmpl2 = try Template.new(testing.allocator, "func_map_demo");
    defer tmpl2.deinit();
    _ = try tmpl2.funcMap(f_map);
    _ = try tmpl2.parse("{{ .Word | exclaim }}");

    var buf2 = bytes.Buffer.init(testing.allocator);
    defer buf2.deinit();
    try tmpl2.execute(buf2.writer(), .{ .Word = "Hi" });
    try testing.expectEqualStrings("[Hi!]", buf2.string());
}

test "text.template: define and template basic composition" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{- define "header" -}}
        \\=== {{ .Title | upper }} ===
        \\{{- end -}}
        \\{{- define "user_card" -}}
        \\User: {{ .Name }} ({{ .Role }})
        \\{{- end -}}
        \\{{ template "header" . }}
        \\{{ template "user_card" .User }}
    ;

    var tmpl = try Template.new(testing.allocator, "main");
    defer tmpl.deinit();

    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    const data = .{
        .Title = "Dashboard",
        .User = .{
            .Name = "Alice",
            .Role = "Admin",
        },
    };

    try tmpl.execute(buf.writer(), data);
    const expected =
        \\=== DASHBOARD ===
        \\User: Alice (Admin)
    ;
    try testing.expectEqualStrings(expected, buf.string());
}

test "text.template: executeTemplate directly" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var tmpl = try Template.new(testing.allocator, "multi");
    defer tmpl.deinit();

    _ = try tmpl.parse(
        \\{{- define "row" -}}Row: {{ .Id }} -> {{ .Label }}{{- end -}}
        \\Main Content: {{ .Summary }}
    );

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    // 1. Execute "row" directly
    try tmpl.executeTemplate(buf.writer(), "row", .{ .Id = 42, .Label = "Active" });
    try testing.expectEqualStrings("Row: 42 -> Active", buf.string());

    // 2. Execute main (by tmpl.name)
    buf.reset();
    try tmpl.executeTemplate(buf.writer(), "multi", .{ .Summary = "All systems green" });
    try testing.expectEqualStrings("Main Content: All systems green", buf.string());

    // 3. Unknown template
    buf.reset();
    try testing.expectError(
        error.TemplateNotFound,
        tmpl.executeTemplate(buf.writer(), "non_existent", .{}),
    );
}

test "text.template: block statement default and override" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    // Case 1: Default fallback when block is not overridden
    {
        var tmpl = try Template.new(testing.allocator, "page_default");
        defer tmpl.deinit();

        _ = try tmpl.parse("Page: [{{ block \"content\" . }}Default Content: {{ .Msg }}{{ end }}]");

        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{ .Msg = "hello" });
        try testing.expectEqualStrings("Page: [Default Content: hello]", buf.string());
    }

    // Case 2: Override when defined prior to block
    {
        var tmpl = try Template.new(testing.allocator, "page_override");
        defer tmpl.deinit();

        _ = try tmpl.parse(
            \\{{- define "content" -}}Customized Content: {{ .Msg | upper }}{{- end -}}
            \\Page: [{{ block "content" . }}Default Content: {{ .Msg }}{{ end }}]
        );

        var buf = bytes.Buffer.init(testing.allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{ .Msg = "hello" });
        try testing.expectEqualStrings("Page: [Customized Content: HELLO]", buf.string());
    }
}

test "text.template: recursive template calls for tree structures" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const tmpl_src =
        \\{{- define "node" -}}
        \\({{ .Name }}
        \\{{- if .Children -}}
        \\: [
        \\{{- for .Children |c| -}}
        \\{{ template "node" c }}
        \\{{- end -}}
        \\]
        \\{{- end -}}
        \\)
        \\{{- end -}}
        \\Tree: {{ template "node" . }}
    ;

    var tmpl = try Template.new(testing.allocator, "tree");
    defer tmpl.deinit();

    _ = try tmpl.parse(tmpl_src);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    const data = .{
        .Name = "root",
        .Children = &.{
            .{ .Name = "child_a", .Children = &.{
                .{ .Name = "leaf_1", .Children = &[0]u8{} },
            } },
            .{ .Name = "child_b", .Children = &[0]u8{} },
        },
    };

    try tmpl.execute(buf.writer(), data);
    try testing.expectEqualStrings("Tree: (root: [(child_a: [(leaf_1)])(child_b)])", buf.string());
}
