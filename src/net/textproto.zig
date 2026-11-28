//! Package net/textproto implements generic support for text-based request/response
//! protocols in the style of HTTP, NNTP, and SMTP.
//!
//! Provides Reader and Writer for line-oriented protocols, MIME headers,
//! and dot-encoded multi-line body data.
//! Operates purely on stdgo.io.Reader and stdgo.io.Writer without POSIX C APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../io.zig");
const bytes = @import("../bytes.zig");

pub const Error = error{
    ShortRead,
    MalformedMIMEHeader,
    ProtocolError,
    LineTooLong,
    TooManyContinuationLines,
    TooManyHeaders,
    DotBodyTooLarge,
};

/// CanonicalMIMEHeaderKey returns the canonical format of the MIME header key s.
/// The canonicalization converts the first letter and any letter following a hyphen to
/// upper case; the rest are converted to lowercase. For example, the canonical key for
/// "accept-encoding" is "Accept-Encoding".
pub fn canonicalMIMEHeaderKey(allocator: Allocator, s: []const u8) ![]u8 {
    const res = try allocator.alloc(u8, s.len);
    var upper = true;
    for (s, 0..) |c, i| {
        if (upper) {
            res[i] = std.ascii.toUpper(c);
        } else {
            res[i] = std.ascii.toLower(c);
        }
        upper = (c == '-');
    }
    return res;
}

/// MIMEHeader represents a collection of MIME-style key-value headers.
pub const MIMEHeader = struct {
    allocator: Allocator,
    entries: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: Allocator) MIMEHeader {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *MIMEHeader) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |val| {
                self.allocator.free(val);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Adds the key, value pair to the header. It appends to any existing values
    /// associated with key.
    pub fn add(self: *MIMEHeader, key: []const u8, value: []const u8) !void {
        const c_key = try canonicalMIMEHeaderKey(self.allocator, key);
        var owns_key = true;
        errdefer if (owns_key) self.allocator.free(c_key);

        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);

        const gop = try self.entries.getOrPut(c_key);
        if (gop.found_existing) {
            self.allocator.free(c_key);
            owns_key = false;
            try gop.value_ptr.append(self.allocator, val_copy);
        } else {
            gop.value_ptr.* = std.ArrayList([]const u8).empty;
            gop.value_ptr.append(self.allocator, val_copy) catch |err| {
                _ = self.entries.remove(c_key);
                return err;
            };
            owns_key = false;
        }
    }

    /// Sets the header entries associated with key to the single element value.
    /// It replaces any existing values associated with key.
    pub fn set(self: *MIMEHeader, key: []const u8, value: []const u8) !void {
        self.del(key);
        try self.add(key, value);
    }

    /// Deletes the values associated with key.
    pub fn del(self: *MIMEHeader, key: []const u8) void {
        const c_key = canonicalMIMEHeaderKey(self.allocator, key) catch return;
        defer self.allocator.free(c_key);

        if (self.entries.fetchRemove(c_key)) |kv| {
            self.allocator.free(kv.key);
            for (kv.value.items) |val| {
                self.allocator.free(val);
            }
            var mut_val = kv.value;
            mut_val.deinit(self.allocator);
        }
    }

    /// Returns the first value associated with the given key.
    pub fn get(self: *const MIMEHeader, key: []const u8) ?[]const u8 {
        const c_key = canonicalMIMEHeaderKey(self.allocator, key) catch return null;
        defer self.allocator.free(c_key);

        if (self.entries.get(c_key)) |list| {
            if (list.items.len > 0) return list.items[0];
        }
        return null;
    }

    /// Returns all values associated with the given key.
    pub fn values(self: *const MIMEHeader, key: []const u8) []const []const u8 {
        const c_key = canonicalMIMEHeaderKey(self.allocator, key) catch return &.{};
        defer self.allocator.free(c_key);

        if (self.entries.get(c_key)) |list| {
            return list.items;
        }
        return &.{};
    }
};

/// Reader implements convenience methods for reading textproto lines, headers,
/// and dot-encoded bodies.
pub const Reader = struct {
    allocator: Allocator,
    r: *std.Io.Reader,

    pub const line_bytes_max: usize = 64 * 1024;
    pub const continued_lines_max: usize = 500;
    pub const headers_count_max: usize = 1000;
    pub const dot_bytes_max: usize = 32 * 1024 * 1024;

    pub fn init(allocator: Allocator, r: *std.Io.Reader) Reader {
        return .{
            .allocator = allocator,
            .r = r,
        };
    }

    /// Reads a single line, stripping the trailing \r\n or \n.
    /// Returns null on EOF when no bytes have been read.
    /// The caller owns the returned slice.
    pub fn readLine(self: *Reader) anyerror!?[]u8 {
        var line_buf = bytes.Buffer.init(self.allocator);
        errdefer line_buf.deinit();

        var read_any = false;
        while (line_buf.len() < line_bytes_max) {
            const b = self.r.takeByte() catch |err| {
                if (err == error.EndOfStream or err == io.Error.EndOfStream) {
                    if (read_any) {
                        if (line_buf.len() > 0 and line_buf.storage[line_buf.length - 1] == '\r') {
                            line_buf.truncate(line_buf.len() - 1);
                        }
                        return try line_buf.toOwnedSlice();
                    }
                    line_buf.deinit();
                    return null;
                }
                return err;
            };

            read_any = true;
            if (b == '\n') {
                if (line_buf.len() > 0 and line_buf.storage[line_buf.length - 1] == '\r') {
                    line_buf.truncate(line_buf.len() - 1);
                }
                return try line_buf.toOwnedSlice();
            }
            try line_buf.writeByte(b);
        } else {
            return Error.LineTooLong;
        }
    }

    /// Reads a possibly continued line from r, per RFC 822 / RFC 2822.
    /// A continued line begins with a space or tab on subsequent lines.
    /// Peeks at the byte after each line, so r must have a buffer of at least one byte.
    pub fn readContinuedLine(self: *Reader) anyerror!?[]u8 {
        const first = try self.readLine() orelse return null;
        if (first.len == 0) return first;
        var full = bytes.Buffer.init(self.allocator);
        errdefer full.deinit();
        _ = try full.write(first);
        self.allocator.free(first);

        var continuation_count: usize = 0;
        while (continuation_count < continued_lines_max) : (continuation_count += 1) {
            // Peek at next character to see if it's space or tab
            const b = self.r.peekByte() catch |err| {
                if (err == error.EndOfStream or err == io.Error.EndOfStream) break;
                return err;
            };

            if (b == ' ' or b == '\t') {
                // Continuation line: read rest of line and append with single leading space
                self.r.toss(1);
                const rest = try self.readLine() orelse "";
                defer self.allocator.free(rest);

                // Trim leading whitespace from the rest
                var start: usize = 0;
                while (start < rest.len and
                    (rest[start] == ' ' or rest[start] == '\t')) : (start += 1)
                {}

                try full.writeByte(' ');
                _ = try full.write(rest[start..]);
            } else {
                // Not a continuation line; the peeked byte stays in the reader for the next call.
                break;
            }
        } else {
            return Error.TooManyContinuationLines;
        }

        return try full.toOwnedSlice();
    }

    /// Reads a MIME-style header block from r.
    /// Stops at a blank line or EOF.
    pub fn readMIMEHeader(self: *Reader) anyerror!MIMEHeader {
        var hdr = MIMEHeader.init(self.allocator);
        errdefer hdr.deinit();

        var header_count: usize = 0;
        while (header_count < headers_count_max) : (header_count += 1) {
            const line = try self.readContinuedLine() orelse break;
            defer self.allocator.free(line);

            if (line.len == 0) {
                // Blank line ends the header section
                break;
            }

            // Key-Value separated by colon ':'
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                return Error.MalformedMIMEHeader;
            };
            const key = line[0..colon];
            var val_start = colon + 1;
            while (val_start < line.len and
                (line[val_start] == ' ' or line[val_start] == '\t')) : (val_start += 1)
            {}
            const val = line[val_start..];

            try hdr.add(key, val);
        } else {
            return Error.TooManyHeaders;
        }

        return hdr;
    }

    /// Reads a dot-encoded block as used in SMTP and NNTP.
    /// A dot-encoded block ends with a line containing only a single dot ".".
    /// Leading dots on lines are unescaped (".." -> ".").
    /// Returns the decoded body as a single string.
    pub fn readDotBytes(self: *Reader) anyerror![]u8 {
        var body = bytes.Buffer.init(self.allocator);
        errdefer body.deinit();

        while (body.len() < dot_bytes_max) {
            const line = try self.readLine() orelse return Error.ProtocolError;
            defer self.allocator.free(line);

            if (std.mem.eql(u8, line, ".")) {
                // Terminator reached
                break;
            }

            var to_write = line;
            if (line.len >= 2 and line[0] == '.' and line[1] == '.') {
                // Unescape ".." -> "."
                to_write = line[1..];
            }

            _ = try body.write(to_write);
            _ = try body.write("\n");
        } else {
            return Error.DotBodyTooLarge;
        }

        return try body.toOwnedSlice();
    }
};

/// Writer implements convenience methods for writing textproto lines and dot-encoded bodies.
pub const Writer = struct {
    w: *std.Io.Writer,

    pub fn init(w: *std.Io.Writer) Writer {
        return .{ .w = w };
    }

    /// Writes a line terminated with CRLF ("\r\n").
    pub fn writeLine(self: *Writer, line: []const u8) anyerror!void {
        try self.w.writeAll(line);
        try self.w.writeAll("\r\n");
    }

    /// Formats and writes a line terminated with CRLF.
    pub fn printfLine(self: *Writer, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeLine(msg);
    }

    /// Returns a DotWriter for writing dot-encoded bodies.
    /// Lines starting with "." are automatically escaped as "..", and a final ".\r\n"
    /// is written upon calling close().
    pub fn dotWriter(self: *Writer, allocator: Allocator) DotWriter {
        return DotWriter.init(allocator, self.w);
    }
};

/// DotWriter escapes leading dots and terminates data with ".\r\n" on close.
pub const DotWriter = struct {
    allocator: Allocator,
    w: *std.Io.Writer,
    at_line_start: bool = true,

    pub fn init(allocator: Allocator, w: *std.Io.Writer) DotWriter {
        return .{
            .allocator = allocator,
            .w = w,
            .at_line_start = true,
        };
    }

    pub fn write(self: *DotWriter, data: []const u8) anyerror!usize {
        var written: usize = 0;
        for (data) |b| {
            if (self.at_line_start and b == '.') {
                // Dot-stuffing: escape leading dot
                try self.w.writeAll(".");
            }

            try self.w.writeByte(b);
            written += 1;
            self.at_line_start = (b == '\n');
        }
        return written;
    }

    pub fn close(self: *DotWriter) anyerror!void {
        if (!self.at_line_start) {
            try self.w.writeAll("\r\n");
        }
        try self.w.writeAll(".\r\n");
    }
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "canonicalMIMEHeaderKey" {
    const testing = std.testing;
    const k1 = try canonicalMIMEHeaderKey(testing.allocator, "content-type");
    defer testing.allocator.free(k1);
    try testing.expectEqualStrings("Content-Type", k1);

    const k2 = try canonicalMIMEHeaderKey(testing.allocator, "x-FORWARDED-FOR");
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings("X-Forwarded-For", k2);
}

test "Reader: readLine and readMIMEHeader" {
    const testing = std.testing;
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain\r\n" ++
        "Content-Length: 42\r\n" ++
        "x-custom-tag: alpha\r\n" ++
        "X-Custom-Tag: beta\r\n" ++
        "\r\n" ++
        "Payload Body";

    var r = @import("../bytes/reader.zig").Reader.init(raw);
    var tp_reader = Reader.init(testing.allocator, r.reader());

    // Status Line
    const status_line = (try tp_reader.readLine()).?;
    defer testing.allocator.free(status_line);
    try testing.expectEqualStrings("HTTP/1.1 200 OK", status_line);

    // Headers
    var hdr = try tp_reader.readMIMEHeader();
    defer hdr.deinit();

    try testing.expectEqualStrings("text/plain", hdr.get("Content-Type").?);
    try testing.expectEqualStrings("42", hdr.get("content-length").?);

    const tags = hdr.values("X-Custom-Tag");
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("alpha", tags[0]);
    try testing.expectEqualStrings("beta", tags[1]);
}

test "Reader: readContinuedLine" {
    const testing = std.testing;
    const raw =
        "Subject: hello\r\n" ++
        " big\r\n" ++
        "\t  world\r\n" ++
        "Next: line\r\n";

    var r = @import("../bytes/reader.zig").Reader.init(raw);
    var tp_reader = Reader.init(testing.allocator, r.reader());

    const first = (try tp_reader.readContinuedLine()).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("Subject: hello big world", first);

    // The byte peeked after the continued line is not consumed.
    const second = (try tp_reader.readContinuedLine()).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("Next: line", second);

    try testing.expectEqual(@as(?[]u8, null), try tp_reader.readContinuedLine());
}

test "Reader: readDotBytes" {
    const testing = std.testing;
    const email =
        "Subject: Test\r\n" ++
        "\r\n" ++
        "First line\r\n" ++
        "..This line started with a dot\r\n" ++
        "Last line\r\n" ++
        ".\r\n";

    var r = @import("../bytes/reader.zig").Reader.init(email);
    var tp_reader = Reader.init(testing.allocator, r.reader());

    var hdr = try tp_reader.readMIMEHeader();
    defer hdr.deinit();
    try testing.expectEqualStrings("Test", hdr.get("Subject").?);

    const body = try tp_reader.readDotBytes();
    defer testing.allocator.free(body);

    const expected_body = "First line\n.This line started with a dot\nLast line\n";
    try testing.expectEqualStrings(expected_body, body);
}

test "Writer: writeLine and dotWriter" {
    const testing = std.testing;
    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    var tp_writer = Writer.init(buf.writer());
    try tp_writer.writeLine("220 smtp.example.com ESMTP Postfix");
    try tp_writer.printfLine("250-{s}", .{"smtp.example.com"});
    try tp_writer.writeLine("250 OK");

    const expected =
        "220 smtp.example.com ESMTP Postfix\r\n" ++
        "250-smtp.example.com\r\n" ++
        "250 OK\r\n";

    try testing.expectEqualStrings(expected, buf.string());
}

test "Reader: readMIMEHeader handles RFC 5322 folded headers" {
    const testing = std.testing;
    const raw =
        "Subject: hello\r\n" ++
        " folded\r\n" ++
        "\tvalue\r\n" ++
        "From: alice@example.com\r\n" ++
        "\r\n" ++
        " body starting with space";

    var r = @import("../bytes/reader.zig").Reader.init(raw);
    var tp_reader = Reader.init(testing.allocator, r.reader());

    var hdr = try tp_reader.readMIMEHeader();
    defer hdr.deinit();

    try testing.expectEqualStrings("hello folded value", hdr.get("Subject").?);
    try testing.expectEqualStrings("alice@example.com", hdr.get("From").?);

    // Body line starting with space must remain unread after blank line.
    const body = (try tp_reader.readLine()).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(" body starting with space", body);
}
