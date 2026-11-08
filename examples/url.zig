//! Example demonstrating stdgo net.url package:
//! 1. url.parse: RFC 3986 URL parsing into components (scheme, host, path, query, fragment)
//! 2. url.queryEscape & url.queryUnescape
//! 3. url.Values: Multi-value query parameter creation, manipulation, and encoding

const std = @import("std");
const stdgo = @import("stdgo");
const url = stdgo.net.url;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: net.url RFC 3986 URL Parsing & Values Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. url.parse
    // -------------------------------------------------------------
    const raw_url = "https://api.github.com:443/repos/jiacai/stdgo/issues?state=open&sort=created&tag=zig#discussion";
    std.debug.print("1. Parsing Raw URL:\n   \"{s}\"\n\n", .{raw_url});

    const parsed = try url.parse(raw_url);
    std.debug.print("   Scheme:    \"{s}\"\n", .{parsed.scheme});
    std.debug.print("   Host:      \"{s}\"\n", .{parsed.host});
    std.debug.print("   Path:      \"{s}\"\n", .{parsed.path});
    std.debug.print("   RawQuery:  \"{s}\"\n", .{parsed.raw_query});
    std.debug.print("   Fragment:  \"{s}\"\n\n", .{parsed.fragment});

    // -------------------------------------------------------------
    // 2. url.Values: Query parameter decoding and manipulation
    // -------------------------------------------------------------
    std.debug.print("2. Parsing Query Parameters (url.Values):\n", .{});
    var query_params = try parsed.query(gpa);
    defer query_params.deinit();

    std.debug.print("   get(\"state\"): {?s}\n", .{query_params.get("state")});
    std.debug.print("   get(\"sort\"):  {?s}\n", .{query_params.get("sort")});
    std.debug.print("   get(\"tag\"):   {?s}\n\n", .{query_params.get("tag")});

    // Adding dynamic parameters
    try query_params.add("filter", "is:open label:good-first-issue");
    try query_params.add("page", "2");

    const encoded_query = try query_params.encode(gpa);
    defer gpa.free(encoded_query);
    std.debug.print("   Re-encoded Query String with escapes:\n   \"{s}\"\n\n", .{encoded_query});

    // -------------------------------------------------------------
    // 3. url.queryEscape & queryUnescape
    // -------------------------------------------------------------
    std.debug.print("3. Query Escape / Unescape:\n", .{});
    const complex_input = "search term with / & spaces + special % characters";
    const escaped = try url.queryEscape(gpa, complex_input);
    defer gpa.free(escaped);
    std.debug.print("   Original: \"{s}\"\n", .{complex_input});
    std.debug.print("   Escaped:  \"{s}\"\n", .{escaped});

    const unescaped = try url.queryUnescape(gpa, escaped);
    defer gpa.free(unescaped);
    std.debug.print("   Unescaped: \"{s}\"\n", .{unescaped});
    std.debug.print("   Matched:   {any}\n", .{std.mem.eql(u8, complex_input, unescaped)});

    std.debug.print("\n=== url demo completed successfully! ===\n", .{});
}
