//! Example demonstrating stdgo.html.template:
//! Context-aware auto-escaping and XSS mitigation for web applications.

const std = @import("std");
const stdgo = @import("stdgo");
const html = stdgo.html.template;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo html/template Context-Aware Auto-Escaping Demo ===\n\n", .{});

    // 1. Basic HTML Body Escaping vs XSS Injections
    {
        const page_src =
            \\<!DOCTYPE html>
            \\<html>
            \\<body>
            \\  <h1>Welcome, {{ .Username }}</h1>
            \\  <p>User Bio: {{ .Bio }}</p>
            \\</body>
            \\</html>
        ;

        var tmpl = try html.Template.new(allocator, "body_esc");
        defer tmpl.deinit();
        _ = try tmpl.parse(page_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .Username = "Alice <admin>",
            .Bio = "Hello world! <script>alert('pwned')</script> & stay safe",
        });

        std.debug.print("--- 1. HTML Body Entity Escaping ---\n{s}\n\n", .{buf.string()});
    }

    // 2. HTML Attribute Injection Defense
    {
        const form_src =
            \\<form action="/update">
            \\  <input type="text" name="nickname" value="{{ .NickName }}">
            \\  <button title='{{ .Tooltip }}'>Save</button>
            \\</form>
        ;

        var tmpl = try html.Template.new(allocator, "attr_esc");
        defer tmpl.deinit();
        _ = try tmpl.parse(form_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .NickName = "gopher\" onfocus=\"fetch('//evil.com')",
            .Tooltip = "Click me' onmouseover='alert(1)",
        });

        std.debug.print("--- 2. HTML Attribute Escaping ---\n{s}\n\n", .{buf.string()});
    }

    // 3. URL Context: Malicious 'javascript:' protocol Sanitization
    {
        const nav_src =
            \\<nav>
            \\  <a href="{{ .SafeLink }}">Documentation</a>
            \\  <a href="{{ .EvilLink }}">Claim Prize</a>
            \\</nav>
        ;

        var tmpl = try html.Template.new(allocator, "url_esc");
        defer tmpl.deinit();
        _ = try tmpl.parse(nav_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .SafeLink = "https://pkg.go.dev/search?q=zig stdgo",
            .EvilLink = "javascript:stealCookies()",
        });

        std.debug.print("--- 3. URL Protocol Sanitization (Auto-replace with #ZgotmplZ) ---\n{s}\n\n", .{buf.string()});
    }

    // 4. Script Context: JavaScript String Escaping & Tag Escape Prevention
    {
        const script_src =
            \\<script>
            \\  const currentUser = {{ .UserJSON }};
            \\  console.log("Logged in user:", currentUser);
            \\</script>
        ;

        var tmpl = try html.Template.new(allocator, "js_esc");
        defer tmpl.deinit();
        _ = try tmpl.parse(script_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .UserJSON = "{\"id\": 101, \"note\": \"</script><script>alert('injected')</script>\"}",
        });

        std.debug.print("--- 4. Script Context Escaping ---\n{s}\n\n", .{buf.string()});
    }

    // 5. Explicit Safe Types (HTML, JS, URL)
    {
        const safe_src =
            \\<div class="rich-text">{{ .RichArticle }}</div>
            \\<script>
            \\  window.SERVER_CONFIG = {{ .ConfigObj }};
            \\</script>
        ;

        var tmpl = try html.Template.new(allocator, "safe_types");
        defer tmpl.deinit();
        _ = try tmpl.parse(safe_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            // Bypasses escaping because it is explicitly typed as trusted HTML:
            .RichArticle = html.HTML{ .data = "<h3>Sanitized Article</h3><p>Safe <b>formatting</b> preserved.</p>" },
            // Bypasses escaping because it is explicitly typed as trusted JS literal:
            .ConfigObj = html.JS{ .data = "{ version: \"1.2.0\", debug: false }" },
        });

        std.debug.print("--- 5. Explicit Safe Types (HTML, JS) ---\n{s}\n\n", .{buf.string()});
    }

    // 6. Sub-Template Component Composition with Automatic Escaping
    {
        const page_src =
            \\{{- define "comment_card" -}}
            \\  <div class="comment">
            \\    <strong>{{ .Author }}</strong>:
            \\    <span>{{ .Body }}</span>
            \\  </div>
            \\{{- end -}}
            \\<section class="comments">
            \\{{- for .Comments |c| }}
            \\{{ template "comment_card" c }}
            \\{{- end }}
            \\</section>
        ;

        var tmpl = try html.Template.new(allocator, "components");
        defer tmpl.deinit();
        _ = try tmpl.parse(page_src);

        var buf = stdgo.bytes.Buffer.init(allocator);
        defer buf.deinit();

        try tmpl.execute(buf.writer(), .{
            .Comments = &.{
                .{ .Author = "Bob", .Body = "Looks great & clean!" },
                .{ .Author = "Mallory", .Body = "<script>alert('xss')</script>" },
            },
        });

        std.debug.print("--- 6. Sub-Template Composition with Escaping ---\n{s}\n", .{buf.string()});
    }

    std.debug.print("=== Demo Complete ===\n", .{});
}
