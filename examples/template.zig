const std = @import("std");
const stdgo = @import("stdgo");
const template = stdgo.text.template;

const User = struct {
    name: []const u8,
    is_admin: bool,
    roles: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo text/template Demo ===\n\n", .{});

    // 1. Basic struct evaluation & pipelines
    {
        const tmpl_src =
            \\Hello, {{ .name | upper }}!
            \\Status: {{ if .is_admin }}Administrator (Elevated){{ else }}Standard Member{{ end }}
            \\Roles ({{ len .roles }}):
            \\{{ range .roles }}  * {{ . }}
            \\{{ end }}
        ;

        const tmpl = try template.Template.new(allocator, "user_card");
        defer tmpl.deinit();
        _ = try tmpl.parse(tmpl_src);

        const user = User{
            .name = "gopher",
            .is_admin = true,
            .roles = &.{ "developer", "reviewer", "maintainer" },
        };

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), user);

        std.debug.print("--- 1. Rendered Card ---\n{s}\n", .{buf.string()});
    }

    // 2. Conditional branches with else if
    {
        const tmpl_src =
            \\Score: {{ .score }} -> 
            \\{{- if ge .score 90 }} Grade: A (Distinction)
            \\{{- else if ge .score 80 }} Grade: B (Good)
            \\{{- else if ge .score 60 }} Grade: C (Pass)
            \\{{- else }} Grade: F (Retry)
            \\{{- end }}
        ;
        const tmpl = template.Must((try template.Template.new(allocator, "grading")).parse(tmpl_src));
        defer tmpl.deinit();

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{ .score = 88 });
        std.debug.print("--- 2. Multi-branch Ladder ---\n{s}\n\n", .{buf.string()});
    }

    // 3. Context re-scoping with 'with' and whitespace trimming
    {
        const tmpl_src =
            \\Profile:
            \\{{- with .profile }}
            \\  Owner: {{ .username }} (Bio: {{ .bio }})
            \\{{- else }}
            \\  No profile found.
            \\{{- end }}
        ;
        const tmpl = template.Must((try template.Template.new(allocator, "with_demo")).parse(tmpl_src));
        defer tmpl.deinit();

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .profile = .{ .username = "zig_fanatic", .bio = "Systems programming in Zig 0.17" },
        });
        std.debug.print("--- 3. Context Re-scoping (with) ---\n{s}\n\n", .{buf.string()});
    }

    // 4. Formatting with printf and index
    {
        const tmpl_src =
            \\Formatted: {{ printf "[#%04d] %s" .id .title }} | First Tag: {{ index .tags 0 }}
        ;
        const tmpl = template.Must((try template.Template.new(allocator, "fmt_demo")).parse(tmpl_src));
        defer tmpl.deinit();

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        const tags = [_][]const u8{ "zig", "golang", "systems" };
        try tmpl.execute(buf.writer(), .{
            .id = 42,
            .title = "stdgo template engine",
            .tags = &tags,
        });
        std.debug.print("--- 4. Formatting & Built-ins ---\n{s}\n\n", .{buf.string()});
    }

    // 5. Zig-style variable binding (const/var) and loop capture |item, idx|
    {
        const tmpl_src =
            \\{{ const title = .project | upper }}
            \\Project: {{ title }}
            \\Contributors:
            \\{{- for .members |member, idx| }}
            \\  {{ add idx 1 }}. {{ member }}
            \\{{- end }}
            \\{{ var counter = 100 -}}
            \\{{ counter = add counter 23 }}
            \\Updated Metric: {{ counter }}
        ;
        const tmpl = template.Must((try template.Template.new(allocator, "zig_style_demo")).parse(tmpl_src));
        defer tmpl.deinit();

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        const members = [_][]const u8{ "alice", "bob", "charlie" };
        try tmpl.execute(buf.writer(), .{
            .project = "stdgo",
            .members = &members,
        });
        std.debug.print("--- 5. Zig-style Variables & Loop Capture ---\n{s}\n", .{buf.string()});
    }

    // 6. Zig-style @"..." quoted identifier fields (keywords, hyphens, special chars)
    {
        const HttpHeader = struct {
            @"content-type": []const u8,
            @"x-request-id": []const u8,
            type: []const u8,
        };

        const tmpl_src =
            \\Header Content-Type: {{ .@"content-type" }}
            \\Header Request-ID:   {{ .@"x-request-id" }}
            \\Event Type:          {{ .@"type" | upper }}
        ;
        const tmpl = template.Must((try template.Template.new(allocator, "quoted_idents_demo")).parse(tmpl_src));
        defer tmpl.deinit();

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        const header = HttpHeader{
            .@"content-type" = "application/json; charset=utf-8",
            .@"x-request-id" = "req_9988aabb",
            .type = "webhook_payload",
        };
        try tmpl.execute(buf.writer(), header);
        std.debug.print("--- 6. Zig-style @\"...\" Quoted Identifier Fields ---\n{s}\n", .{buf.string()});
    }

    // 7. Custom functions via addFunc or funcMap
    {
        const CustomHelpers = struct {
            fn badge(alloc: std.mem.Allocator, args: []const template.Value) anyerror!template.Value {
                if (args.len == 0 or args[0] != .string) return template.Value.null;
                const formatted = try std.fmt.allocPrint(alloc, "[STATUS: {s}]", .{args[0].string});
                return template.Value{ .string = formatted };
            }

            fn repeat(alloc: std.mem.Allocator, args: []const template.Value) anyerror!template.Value {
                if (args.len < 2 or args[0] != .string or args[1] != .int) return template.Value.null;
                const str = args[0].string;
                const count: usize = if (args[1].int > 0) @intCast(args[1].int) else 0;
                var out = std.ArrayList(u8).empty;
                for (0..count) |_| try out.appendSlice(alloc, str);
                return template.Value{ .string = try out.toOwnedSlice(alloc) };
            }
        };

        const tmpl_src =
            \\Server Status: {{ .status | badge }}
            \\Banner:        {{ repeat .star 5 }}
        ;

        var tmpl = try template.Template.new(allocator, "custom_func_demo");
        defer tmpl.deinit();

        _ = try tmpl.addFunc("badge", CustomHelpers.badge);
        _ = try tmpl.addFunc("repeat", CustomHelpers.repeat);
        _ = try tmpl.parse(tmpl_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .status = "HEALTHY",
            .star = "*",
        });
        std.debug.print("--- 7. Custom Functions (addFunc / funcMap) ---\n{s}\n", .{buf.string()});
    }

    // 8. Cross-Template Composition (define, template, block, executeTemplate)
    {
        const page_src =
            \\{{- define "header" -}}
            \\========================================
            \\  {{ .AppTitle | upper }}
            \\========================================
            \\{{- end -}}
            \\{{- define "user_badge" -}}
            \\  * [{{ .Role }}] {{ .Name }} ({{ .Email }})
            \\{{- end -}}
            \\{{ template "header" . }}
            \\Team Roster:
            \\{{- for .Users |u| }}
            \\{{ template "user_badge" u }}
            \\{{- end }}
            \\{{ block "footer" . }}
            \\----------------------------------------
            \\Powered by stdgo text/template engine
            \\{{- end }}
        ;

        var tmpl = try template.Template.new(allocator, "page");
        defer tmpl.deinit();

        _ = try tmpl.parse(page_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        const data = .{
            .AppTitle = "DevOps Control Plane",
            .Users = &.{
                .{ .Name = "Alice", .Role = "Lead", .Email = "alice@corp.internal" },
                .{ .Name = "Bob", .Role = "SRE", .Email = "bob@corp.internal" },
            },
        };

        try tmpl.execute(buf.writer(), data);
        std.debug.print("--- 8. Cross-Template Composition ---\n{s}\n\n", .{buf.string()});

        // Sub-template can also be rendered directly via executeTemplate:
        buf.reset();
        try tmpl.executeTemplate(buf.writer(), "user_badge", .{
            .Name = "Charlie",
            .Role = "Guest",
            .Email = "charlie@partner.org",
        });
        std.debug.print("Direct Sub-Template Render (executeTemplate):\n{s}\n", .{buf.string()});
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
