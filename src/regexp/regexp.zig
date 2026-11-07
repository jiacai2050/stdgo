const std = @import("std");
const prog_mod = @import("prog.zig");
const compile_mod = @import("compile.zig");
const exec_mod = @import("exec.zig");
const bytes = @import("../bytes.zig");
const Allocator = std.mem.Allocator;

pub const Error = compile_mod.Error;

pub const Regexp = struct {
    allocator: Allocator,
    prog: prog_mod.Prog,

    pub fn compile(allocator: Allocator, expr: []const u8) anyerror!Regexp {
        const prog = try compile_mod.Compiler.compile(allocator, expr);
        return .{
            .allocator = allocator,
            .prog = prog,
        };
    }

    pub fn mustCompile(allocator: Allocator, expr: []const u8) Regexp {
        return compile(allocator, expr) catch |err| {
            std.debug.panic("regexp.mustCompile: invalid pattern '{s}', error: {any}", .{ expr, err });
        };
    }

    pub fn deinit(self: *Regexp) void {
        self.prog.deinit();
    }

    /// Match reports whether the byte slice b contains any match of the regular expression.
    pub fn match(self: *const Regexp, b: []const u8) bool {
        const vm = exec_mod.VM.init(self.allocator, &self.prog);
        return (vm.match(b) catch false);
    }

    /// MatchString reports whether the string s contains any match of the regular expression.
    pub fn matchString(self: *const Regexp, s: []const u8) bool {
        return self.match(s);
    }

    /// FindString returns a string holding the text of the leftmost match of the regular expression.
    pub fn findString(self: *const Regexp, s: []const u8) ?[]const u8 {
        const vm = exec_mod.VM.init(self.allocator, &self.prog);
        if (vm.find(s) catch null) |res| {
            return s[res.start..res.end];
        }
        return null;
    }

    /// ReplaceAllString returns a copy of src in which all matches of the Regexp
    /// have been replaced by the repl string.
    pub fn replaceAllString(self: *const Regexp, allocator: Allocator, src: []const u8, repl: []const u8) anyerror![]u8 {
        var buf = bytes.Buffer.init(allocator);
        defer buf.deinit();

        var cursor: usize = 0;
        const vm = exec_mod.VM.init(self.allocator, &self.prog);

        while (cursor <= src.len) {
            if (try vm.find(src[cursor..])) |sub_res| {
                const match_start = cursor + sub_res.start;
                const match_end = cursor + sub_res.end;

                _ = try buf.write(src[cursor..match_start]);
                _ = try buf.write(repl);

                if (match_end == cursor) {
                    // Avoid zero-length match infinite loop
                    if (cursor < src.len) {
                        try buf.writeByte(src[cursor]);
                        cursor += 1;
                    } else {
                        break;
                    }
                } else {
                    cursor = match_end;
                }
            } else {
                _ = try buf.write(src[cursor..]);
                break;
            }
        }

        return try allocator.dupe(u8, buf.bytes());
    }
};

test "regexp basic literal, wildcard, character class and alternation" {
    const testing = std.testing;

    var re1 = try Regexp.compile(testing.allocator, "a(b|c)+d");
    defer re1.deinit();

    try testing.expect(re1.matchString("abd"));
    try testing.expect(re1.matchString("acd"));
    try testing.expect(re1.matchString("abbbcd"));
    try testing.expect(!re1.matchString("ad"));
    try testing.expect(!re1.matchString("xyz"));

    // FindString
    try testing.expectEqualStrings("abbcd", re1.findString("xx abbcd yy").?);

    // Character class & digits
    var re2 = try Regexp.compile(testing.allocator, "[0-9]+");
    defer re2.deinit();
    try testing.expect(re2.matchString("12345"));
    try testing.expectEqualStrings("456", re2.findString("order: 456 item").?);

    // ReplaceAllString
    const replaced = try re2.replaceAllString(testing.allocator, "item 1 costs 99 dollars", "###");
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings("item ### costs ### dollars", replaced);
}

test "regexp anchors, optional quantifier, mustCompile" {
    const testing = std.testing;

    // Test ^ and $
    var re_anchored = try Regexp.compile(testing.allocator, "^[a-z]+$");
    defer re_anchored.deinit();
    try testing.expect(re_anchored.matchString("hello"));
    try testing.expect(!re_anchored.matchString("hello world"));
    try testing.expect(!re_anchored.matchString("123hello"));

    // Test optional ? (https?)
    var re_http = try Regexp.compile(testing.allocator, "https?://");
    defer re_http.deinit();
    try testing.expect(re_http.matchString("http://"));
    try testing.expect(re_http.matchString("https://"));
    try testing.expect(!re_http.matchString("httpp://"));

    // Test mustCompile
    var re_mc = Regexp.mustCompile(testing.allocator, "\\w+@\\w+");
    defer re_mc.deinit();
    try testing.expect(re_mc.matchString("user@domain"));
}
