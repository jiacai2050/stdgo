//! Package bufio/scanner provides a convenient interface for reading data
//! such as a file of newline-delimited lines of text.
//!
//! Successive calls to the Scan method will step through the 'tokens' of a file,
//! skipping the bytes between the tokens. The specification of a token is
//! defined by a split function of type SplitFunc; the default split function
//! breaks the input into lines with run-length newline stripping.
//!
//! The Scanning stops unrecoverably at EOF, the first I/O error, or a token too
//! large to fit in the buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../io.zig");

pub const Error = error{
    TokenTooLong,
    NegativeAdvance,
    AdvanceTooFar,
    BadReadCount,
    InvalidUtf8,
};

/// SplitResult is the return value of a SplitFunc.
pub const SplitResult = struct {
    /// Number of bytes to advance the input cursor in the buffer.
    advance: usize,
    /// The token to return to the user, or null if more data is needed.
    token: ?[]const u8,
};

/// SplitFunc is the signature of the split function used to tokenize the input.
/// The arguments are an initial substring of the remaining unprocessed data
/// and a flag, at_eof, that reports whether the Reader has no more data to give.
pub const SplitFunc = *const fn (data: []const u8, at_eof: bool) anyerror!SplitResult;

/// Scanner provides a convenient interface for reading tokenized data from an io.Reader.
pub const Scanner = struct {
    allocator: ?Allocator = null,
    r: *std.Io.Reader,
    split_fn: SplitFunc = scanLines,

    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    token_slice: ?[]const u8 = null,
    err_val: ?anyerror = null,
    empties: usize = 0,
    scan_called: bool = false,
    done: bool = false,
    max_token_size: usize = 64 * 1024,
    allocated_buf: bool = true,

    pub const default_max_token_size = 64 * 1024;
    pub const start_buf_size = 4096;
    const max_consecutive_empty_reads = 100;

    /// Initializes a new Scanner reading from r with default buffer settings.
    pub fn init(allocator: Allocator, r: *std.Io.Reader) !Scanner {
        const buf = try allocator.alloc(u8, start_buf_size);
        return .{
            .allocator = allocator,
            .r = r,
            .split_fn = scanLines,
            .buf = buf,
            .start = 0,
            .end = 0,
            .token_slice = null,
            .err_val = null,
            .empties = 0,
            .scan_called = false,
            .done = false,
            .max_token_size = default_max_token_size,
            .allocated_buf = true,
        };
    }

    /// Initializes a new Scanner reading from r using caller-provided buffer.
    /// Does not allocate heap memory and avoids allocations when scanning.
    pub fn initWithBuffer(r: *std.Io.Reader, buf: []u8, max_size: usize) Scanner {
        return .{
            .allocator = null,
            .r = r,
            .split_fn = scanLines,
            .buf = buf,
            .start = 0,
            .end = 0,
            .token_slice = null,
            .err_val = null,
            .empties = 0,
            .scan_called = false,
            .done = false,
            .max_token_size = max_size,
            .allocated_buf = false,
        };
    }

    /// Releases resources allocated by the Scanner.
    pub fn deinit(self: *Scanner) void {
        if (self.allocated_buf and self.buf.len > 0) {
            if (self.allocator) |alloc| {
                alloc.free(self.buf);
            }
            self.buf = &.{};
        }
    }

    /// Sets the split function for the Scanner. Defaults to scanLines.
    /// Split panics if called after scanning has started.
    pub fn split(self: *Scanner, fn_ptr: SplitFunc) void {
        std.debug.assert(!self.scan_called);
        self.split_fn = fn_ptr;
    }

    /// Sets the maximum token size the scanner can produce.
    /// Buffer panics if called after scanning has started.
    pub fn setMaxTokenSize(self: *Scanner, max: usize) void {
        std.debug.assert(!self.scan_called);
        self.max_token_size = max;
    }

    /// Advances the Scanner to the next token, which will then be available through
    /// the bytes or text method. It returns false when the scan stops, either by
    /// reaching the end of the input or an error.
    pub fn scan(self: *Scanner) bool {
        self.scan_called = true;

        while (true) {
            // 1. Check if we have unconsumed data in the buffer to tokenize
            if (self.end > self.start or self.done) {
                const data = self.buf[self.start..self.end];
                const res = self.split_fn(data, self.done) catch |e| {
                    self.setErr(e);
                    return false;
                };

                if (res.advance > data.len) {
                    self.setErr(Error.AdvanceTooFar);
                    return false;
                }

                self.start += res.advance;

                if (res.token) |tok| {
                    if (tok.len > self.max_token_size) {
                        self.setErr(Error.TokenTooLong);
                        return false;
                    }
                    self.token_slice = tok;
                    return true;
                }

                if (self.done) {
                    if (self.start < self.end) {
                        // EOF reached, but split function consumed bytes without token
                        continue;
                    }
                    // EOF and no more tokens
                    return false;
                }
            }

            // 2. Need more data from the reader
            if (self.done) {
                return false;
            }

            // 3. Shift remaining bytes to beginning of buffer
            if (self.start > 0) {
                const remaining = self.end - self.start;
                if (remaining > 0) {
                    @memcpy(self.buf[0..remaining], self.buf[self.start..self.end]);
                }
                self.end = remaining;
                self.start = 0;
            }

            // 4. If buffer is full, reallocate up to max_token_size
            if (self.end == self.buf.len) {
                if (!self.allocated_buf or self.allocator == null or
                    self.buf.len >= self.max_token_size)
                {
                    self.setErr(Error.TokenTooLong);
                    return false;
                }

                const new_size = @min(self.buf.len * 2, self.max_token_size);
                const new_buf = self.allocator.?.realloc(self.buf, new_size) catch |e| {
                    self.setErr(e);
                    return false;
                };
                self.buf = new_buf;
            }

            // 5. Read new bytes from underlying reader
            const dest = self.buf[self.end..];
            const n = self.r.readSliceShort(dest) catch |e| {
                if (e == error.EndOfStream or e == io.Error.EndOfStream) {
                    self.done = true;
                    continue;
                }
                self.setErr(e);
                return false;
            };

            if (n == 0) {
                self.empties += 1;
                if (self.empties > max_consecutive_empty_reads) {
                    self.setErr(io.Error.NoProgress);
                    return false;
                }
                self.done = true;
                continue;
            }

            self.empties = 0;
            self.end += n;
        }
    }

    /// Returns the most recent token generated by a call to scan as a byte slice.
    /// The underlying array may point to data that will be overwritten by a subsequent
    /// call to scan.
    pub fn bytes(self: *const Scanner) []const u8 {
        return self.token_slice orelse &.{};
    }

    /// Returns the most recent token generated by a call to scan as a string.
    pub fn text(self: *const Scanner) []const u8 {
        return self.bytes();
    }

    /// Returns the first non-EOF error that was encountered by the Scanner.
    pub fn err(self: *const Scanner) ?anyerror {
        return self.err_val;
    }

    fn setErr(self: *Scanner, e: anyerror) void {
        if (self.err_val == null) {
            self.err_val = e;
        }
    }
};

/// scanLines is a split function for a Scanner that returns each line of
/// text, stripped of any trailing end-of-line marker. The returned line may
/// be empty. The end-of-line marker is one optional carriage return followed
/// by one mandatory newline. In regular expression notation, it is `\r?\n`.
/// The last non-empty line of input will be returned even if it has no
/// newline.
pub fn scanLines(data: []const u8, at_eof: bool) anyerror!SplitResult {
    if (at_eof and data.len == 0) {
        return .{ .advance = 0, .token = null };
    }

    if (std.mem.indexOfScalar(u8, data, '\n')) |i| {
        // We have a full newline-terminated line
        var line_len = i;
        if (line_len > 0 and data[line_len - 1] == '\r') {
            line_len -= 1;
        }
        return .{
            .advance = i + 1,
            .token = data[0..line_len],
        };
    }

    // If we're at EOF, we have a final, non-terminated line. Return it.
    if (at_eof) {
        var line_len = data.len;
        if (line_len > 0 and data[line_len - 1] == '\r') {
            line_len -= 1;
        }
        return .{
            .advance = data.len,
            .token = data[0..line_len],
        };
    }

    // Request more data.
    return .{ .advance = 0, .token = null };
}

/// scanWords is a split function for a Scanner that returns each
/// space-separated word of text, with surrounding spaces deleted. It will
/// never return an empty string. The definition of space is set by
/// std.ascii.isWhitespace.
pub fn scanWords(data: []const u8, at_eof: bool) anyerror!SplitResult {
    // Skip leading spaces
    var start: usize = 0;
    while (start < data.len and std.ascii.isWhitespace(data[start])) {
        start += 1;
    }

    // Scan until space, marking end of word
    var i = start;
    while (i < data.len and !std.ascii.isWhitespace(data[i])) {
        i += 1;
    }

    if (i > start) {
        return .{
            .advance = i,
            .token = data[start..i],
        };
    }

    if (at_eof) {
        return .{
            .advance = data.len,
            .token = null,
        };
    }

    return .{
        .advance = start,
        .token = null,
    };
}

/// scanBytes is a split function for a Scanner that returns each byte
/// as a token.
pub fn scanBytes(data: []const u8, at_eof: bool) anyerror!SplitResult {
    if (data.len == 0) {
        return .{ .advance = 0, .token = null };
    }
    _ = at_eof;
    return .{
        .advance = 1,
        .token = data[0..1],
    };
}

/// scanRunes is a split function for a Scanner that returns each
/// UTF-8-encoded code point as a token.
pub fn scanRunes(data: []const u8, at_eof: bool) anyerror!SplitResult {
    if (data.len == 0) {
        return .{ .advance = 0, .token = null };
    }

    const first_byte = data[0];
    const seq_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
        // Invalid leading byte: consume 1 byte
        return .{ .advance = 1, .token = data[0..1] };
    };

    if (data.len < seq_len) {
        if (at_eof) {
            // Incomplete UTF-8 sequence at EOF: consume 1 byte
            return .{ .advance = 1, .token = data[0..1] };
        }
        // Need more data
        return .{ .advance = 0, .token = null };
    }

    return .{
        .advance = seq_len,
        .token = data[0..seq_len],
    };
}

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "Scanner: scanLines with various line endings" {
    const testing = std.testing;
    const input = "line 1\nline 2\r\nline 3\n\nline 5 without newline";
    var r = stdgo_bytes_reader(input);

    var scanner = try Scanner.init(testing.allocator, r.reader());
    defer scanner.deinit();

    const expected = [_][]const u8{
        "line 1",
        "line 2",
        "line 3",
        "",
        "line 5 without newline",
    };

    var count: usize = 0;
    while (scanner.scan()) {
        try testing.expectEqualStrings(expected[count], scanner.text());
        count += 1;
    }

    try testing.expectEqual(expected.len, count);
    try testing.expect(scanner.err() == null);
}

test "Scanner: scanWords" {
    const testing = std.testing;
    const input = "  The   quick brown\nfox jumps\tover\r\nthe lazy dog  ";
    var r = stdgo_bytes_reader(input);

    var scanner = try Scanner.init(testing.allocator, r.reader());
    defer scanner.deinit();
    scanner.split(scanWords);

    const expected = [_][]const u8{
        "The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog",
    };

    var count: usize = 0;
    while (scanner.scan()) {
        try testing.expectEqualStrings(expected[count], scanner.text());
        count += 1;
    }

    try testing.expectEqual(expected.len, count);
    try testing.expect(scanner.err() == null);
}

test "Scanner: scanBytes and scanRunes" {
    const testing = std.testing;
    const input = "Hi 世界";
    var r1 = stdgo_bytes_reader(input);

    var s1 = try Scanner.init(testing.allocator, r1.reader());
    defer s1.deinit();
    s1.split(scanBytes);

    var byte_count: usize = 0;
    while (s1.scan()) {
        byte_count += 1;
    }
    try testing.expectEqual(input.len, byte_count);

    var r2 = stdgo_bytes_reader(input);
    var s2 = try Scanner.init(testing.allocator, r2.reader());
    defer s2.deinit();
    s2.split(scanRunes);

    const runes_expected = [_][]const u8{ "H", "i", " ", "世", "界" };
    var rune_count: usize = 0;
    while (s2.scan()) {
        try testing.expectEqualStrings(runes_expected[rune_count], s2.text());
        rune_count += 1;
    }
    try testing.expectEqual(runes_expected.len, rune_count);
}

test "Scanner: token too long error" {
    const testing = std.testing;
    const long_line: [200]u8 = @splat('A');
    var r = stdgo_bytes_reader(&long_line);

    var scanner = try Scanner.init(testing.allocator, r.reader());
    defer scanner.deinit();
    scanner.setMaxTokenSize(64); // Less than 200

    try testing.expect(!scanner.scan());
    try testing.expectEqual(error.TokenTooLong, scanner.err().?);
}

test "Scanner: initWithBuffer zero allocation" {
    const testing = std.testing;
    const input = "alpha\nbeta\ngamma";
    var r = stdgo_bytes_reader(input);

    var buf: [64]u8 = undefined;
    var scanner = Scanner.initWithBuffer(r.reader(), &buf, 64);
    defer scanner.deinit();

    const expected = [_][]const u8{ "alpha", "beta", "gamma" };
    var count: usize = 0;
    while (scanner.scan()) {
        try testing.expectEqualStrings(expected[count], scanner.text());
        count += 1;
    }
    try testing.expectEqual(expected.len, count);
    try testing.expect(scanner.err() == null);
}

fn stdgo_bytes_reader(str: []const u8) @import("../bytes/reader.zig").Reader {
    return @import("../bytes/reader.zig").Reader.init(str);
}
