const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const SplitResult = struct {
    advance: usize,
    token: ?[]const u8,
};

pub const SplitFunc = *const fn (data: []const u8, at_eof: bool) anyerror!SplitResult;

pub const max_scan_token_size = 64 * 1024;
const start_buf_size = 4096;

pub const Scanner = struct {
    allocator: Allocator,
    r: io.Reader,
    split_fn: SplitFunc,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    token_slice: []const u8 = &[_]u8{},
    err_val: ?anyerror = null,
    done: bool = false,

    pub fn init(allocator: Allocator, r: io.Reader) Allocator.Error!Scanner {
        const buf = try allocator.alloc(u8, start_buf_size);
        return .{
            .allocator = allocator,
            .r = r,
            .split_fn = scanLines,
            .buf = buf,
            .start = 0,
            .end = 0,
            .token_slice = &[_]u8{},
            .err_val = null,
            .done = false,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.allocator.free(self.buf);
        self.buf = &[_]u8{};
        self.token_slice = &[_]u8{};
    }

    pub fn setSplit(self: *Scanner, split_fn: SplitFunc) void {
        self.split_fn = split_fn;
    }

    pub fn scan(self: *Scanner) bool {
        if (self.done) return false;

        while (true) {
            // See if we can get a token with what we already have.
            if (self.end > self.start or self.done) {
                const res = self.split_fn(self.buf[self.start..self.end], self.done) catch |e| {
                    self.setErr(e);
                    return false;
                };

                if (res.advance > 0 or res.token != null) {
                    self.start += res.advance;
                    if (res.token) |tok| {
                        self.token_slice = tok;
                        return true;
                    }
                    if (!self.done) continue;
                }
            }

            if (self.done) {
                return false;
            }

            // Need more data.
            // Slide existing data to the start if needed.
            if (self.start > 0) {
                const unread = self.end - self.start;
                if (unread > 0) {
                    std.mem.copyForwards(u8, self.buf[0..unread], self.buf[self.start..self.end]);
                }
                self.start = 0;
                self.end = unread;
            }

            // If buffer is full, grow it.
            if (self.end >= self.buf.len) {
                if (self.buf.len >= max_scan_token_size) {
                    self.setErr(error.TokenTooLong);
                    return false;
                }
                const new_cap = @min(self.buf.len * 2, max_scan_token_size);
                const new_buf = self.allocator.realloc(self.buf, new_cap) catch |e| {
                    self.setErr(e);
                    return false;
                };
                self.buf = new_buf;
            }

            // Read more data.
            const n = self.r.read(self.buf[self.end..]) catch |e| {
                if (e == io.Error.EndOfStream) {
                    self.done = true;
                    continue;
                }
                self.setErr(e);
                return false;
            };

            if (n == 0) {
                self.done = true;
            } else {
                self.end += n;
            }
        }
    }

    pub fn bytes(self: *const Scanner) []const u8 {
        return self.token_slice;
    }

    pub fn text(self: *const Scanner) []const u8 {
        return self.token_slice;
    }

    pub fn err(self: *const Scanner) ?anyerror {
        return self.err_val;
    }

    fn setErr(self: *Scanner, e: anyerror) void {
        if (self.err_val == null and e != io.Error.EndOfStream) {
            self.err_val = e;
        }
        self.done = true;
    }
};

/// scanLines is a split function for a Scanner that returns each line of
/// text, stripped of any trailing end-of-line marker.
pub fn scanLines(data: []const u8, at_eof: bool) anyerror!SplitResult {
    if (at_eof and data.len == 0) {
        return .{ .advance = 0, .token = null };
    }

    if (std.mem.indexOfScalar(u8, data, '\n')) |i| {
        // We have a full newline-terminated line.
        var line = data[0..i];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        return .{ .advance = i + 1, .token = line };
    }

    // If we're at EOF, we have a final, non-terminated line. Return it.
    if (at_eof) {
        var line = data;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        return .{ .advance = data.len, .token = line };
    }

    // Request more data.
    return .{ .advance = 0, .token = null };
}

/// scanWords is a split function for a Scanner that returns each
/// space-separated word of text, with surrounding spaces deleted.
pub fn scanWords(data: []const u8, at_eof: bool) anyerror!SplitResult {
    // Skip leading spaces.
    var start: usize = 0;
    while (start < data.len) : (start += 1) {
        const c = data[start];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }

    if (start >= data.len) {
        return .{ .advance = start, .token = null };
    }

    // Scan until space.
    var i = start;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            return .{ .advance = i + 1, .token = data[start..i] };
        }
    }

    if (at_eof) {
        return .{ .advance = data.len, .token = data[start..data.len] };
    }

    return .{ .advance = start, .token = null };
}

test "bufio.Scanner scanLines" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const input = "first line\r\nsecond line\nthird line";
    var br = bytes.Reader.init(input);

    var sc = try Scanner.init(testing.allocator, br.reader());
    defer sc.deinit();

    try testing.expect(sc.scan());
    try testing.expectEqualStrings("first line", sc.text());

    try testing.expect(sc.scan());
    try testing.expectEqualStrings("second line", sc.text());

    try testing.expect(sc.scan());
    try testing.expectEqualStrings("third line", sc.text());

    try testing.expect(!sc.scan());
    try testing.expectEqual(@as(?anyerror, null), sc.err());
}

test "bufio.Scanner scanWords" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const input = "   zig   makes  systems   programming enjoyable   ";
    var br = bytes.Reader.init(input);

    var sc = try Scanner.init(testing.allocator, br.reader());
    defer sc.deinit();
    sc.setSplit(scanWords);

    const expected = [_][]const u8{ "zig", "makes", "systems", "programming", "enjoyable" };
    var count: usize = 0;
    while (sc.scan()) {
        try testing.expectEqualStrings(expected[count], sc.text());
        count += 1;
    }
    try testing.expectEqual(expected.len, count);
}

test "bufio.Scanner empty input and lines with blank rows" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    // Empty input
    var br_empty = bytes.Reader.init("");
    var sc_empty = try Scanner.init(testing.allocator, br_empty.reader());
    defer sc_empty.deinit();
    try testing.expect(!sc_empty.scan());

    // Single line without trailing newline
    var br_single = bytes.Reader.init("no newline at end");
    var sc_single = try Scanner.init(testing.allocator, br_single.reader());
    defer sc_single.deinit();
    try testing.expect(sc_single.scan());
    try testing.expectEqualStrings("no newline at end", sc_single.text());
    try testing.expect(!sc_single.scan());

    // Empty lines preserved
    var br_lines = bytes.Reader.init("line1\n\nline3\n");
    var sc_lines = try Scanner.init(testing.allocator, br_lines.reader());
    defer sc_lines.deinit();
    try testing.expect(sc_lines.scan());
    try testing.expectEqualStrings("line1", sc_lines.text());
    try testing.expect(sc_lines.scan());
    try testing.expectEqualStrings("", sc_lines.text());
    try testing.expect(sc_lines.scan());
    try testing.expectEqualStrings("line3", sc_lines.text());
    try testing.expect(!sc_lines.scan());
}
