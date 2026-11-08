//! Example demonstrating stdgo regexp package:
//! 1. regexp.compile & mustCompile: Thompson NFA linear-time regex engine
//! 2. matchString: pattern matching
//! 3. findString: substring extraction
//! 4. replaceAllString: string substitution

const std = @import("std");
const stdgo = @import("stdgo");
const regexp = stdgo.regexp;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: regexp Regular Expressions Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Email pattern matching
    // -------------------------------------------------------------
    std.debug.print("1. Matching Email Addresses:\n", .{});
    var email_re = regexp.mustCompile(gpa, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
    defer email_re.deinit();

    const emails = [_][]const u8{
        "alice@stdgo.dev",
        "invalid-email-address",
        "team_support+urgent@corp.example.com",
    };

    for (emails) |em| {
        const ok = email_re.matchString(em);
        std.debug.print("   email: \"{s}\" -> valid: {any}\n", .{ em, ok });
    }

    // -------------------------------------------------------------
    // 2. Extracting URLs from text
    // -------------------------------------------------------------
    std.debug.print("\n2. Extracting First URL from Text:\n", .{});
    var url_re = regexp.mustCompile(gpa, "https?://[a-zA-Z0-9./-]+");
    defer url_re.deinit();

    const post = "Check out the repo at https://github.com/jiacai/stdgo for Zig library code!";
    if (url_re.findString(post)) |matched_url| {
        std.debug.print("   Found URL: \"{s}\"\n", .{matched_url});
    }

    // -------------------------------------------------------------
    // 3. Replace pattern in text
    // -------------------------------------------------------------
    std.debug.print("\n3. Replacing Patterns with replaceAllString:\n", .{});
    var phone_re = regexp.mustCompile(gpa, "\\d{3}-\\d{4}");
    defer phone_re.deinit();

    const confidential = "Direct contact lines: Alice 555-0199, Bob 555-0288.";
    const redacted = try phone_re.replaceAllString(gpa, confidential, "[REDACTED]");
    defer gpa.free(redacted);

    std.debug.print("   Original: \"{s}\"\n", .{confidential});
    std.debug.print("   Redacted: \"{s}\"\n", .{redacted});

    std.debug.print("\n=== regexp demo completed successfully! ===\n", .{});
}
