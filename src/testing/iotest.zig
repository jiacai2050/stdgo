//! Package testing/iotest implements Readers and Writers useful mainly for testing.
//!
//! Provides fault injection, byte-by-byte chunking, timeout simulation,
//! and truncation wrappers around standard stream abstractions.

const std = @import("std");
pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;

/// ErrReader returns an io.Reader that always returns ReadFailed (simulating an I/O read failure).
pub const ErrReader = struct {
    err: anyerror,
    reader_inst: std.Io.Reader = undefined,

    /// Initializes a new ErrReader that always fails with the given error.
    pub fn init(err: anyerror) ErrReader {
        return .{ .err = err };
    }

    /// Reader returns the underlying std.Io.Reader interface.
    pub fn reader(self: *ErrReader) *Reader {
        self.reader_inst = .{
            .buffer = &.{},
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = streamImpl,
            },
        };
        return &self.reader_inst;
    }

    fn streamImpl(
        _: *std.Io.Reader,
        _: *std.Io.Writer,
        _: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        return error.ReadFailed;
    }
};

/// OneByteReader returns a Reader that reads at most 1 byte per call from r,
/// forcing callers to loop rather than assuming large contiguous reads.
pub const OneByteReader = struct {
    r: *Reader,
    reader_inst: std.Io.Reader = undefined,

    /// Initializes a new OneByteReader wrapping r.
    pub fn init(r: *Reader) OneByteReader {
        return .{ .r = r };
    }

    /// Reader returns the underlying std.Io.Reader interface.
    pub fn reader(self: *OneByteReader) *Reader {
        self.reader_inst = .{
            .buffer = &.{},
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = streamImpl,
            },
        };
        return &self.reader_inst;
    }

    fn streamImpl(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        _: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *OneByteReader = @alignCast(@fieldParentPtr("reader_inst", r));
        return try self.r.stream(w, .limited(1));
    }
};

/// HalfReader returns a Reader that reads at most half of the requested bytes per call.
pub const HalfReader = struct {
    r: *Reader,
    reader_inst: std.Io.Reader = undefined,

    /// Initializes a new HalfReader wrapping r.
    pub fn init(r: *Reader) HalfReader {
        return .{ .r = r };
    }

    /// Reader returns the underlying std.Io.Reader interface.
    pub fn reader(self: *HalfReader) *Reader {
        self.reader_inst = .{
            .buffer = &.{},
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = streamImpl,
            },
        };
        return &self.reader_inst;
    }

    fn streamImpl(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *HalfReader = @alignCast(@fieldParentPtr("reader_inst", r));
        const max_bytes = @backingInt(limit);
        const half = if (max_bytes <= 1) 1 else max_bytes / 2;
        return try self.r.stream(w, .limited(half));
    }
};

/// TimeoutReader returns a Reader that returns ReadFailed (timeout) on the second read call,
/// testing client resilience to interrupted or timed-out network streams.
pub const TimeoutReader = struct {
    r: *Reader,
    count: usize = 0,
    timed_out: bool = false,
    reader_inst: std.Io.Reader = undefined,

    /// Initializes a new TimeoutReader wrapping r.
    pub fn init(r: *Reader) TimeoutReader {
        return .{ .r = r };
    }

    /// Reader returns the underlying std.Io.Reader interface.
    pub fn reader(self: *TimeoutReader) *Reader {
        self.reader_inst = .{
            .buffer = &.{},
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = streamImpl,
            },
        };
        return &self.reader_inst;
    }

    fn streamImpl(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *TimeoutReader = @alignCast(@fieldParentPtr("reader_inst", r));
        self.count += 1;
        if (self.count >= 2) {
            self.timed_out = true;
            return error.ReadFailed;
        }
        return try self.r.stream(w, limit);
    }
};

/// TruncateWriter returns a Writer that writes at most n bytes to w before silently
/// discarding the rest.
pub const TruncateWriter = struct {
    w: *Writer,
    remaining: usize,
    writer_inst: std.Io.Writer = undefined,

    /// Initializes a new TruncateWriter wrapping w with an n-byte cap.
    pub fn init(w: *Writer, n: usize) TruncateWriter {
        return .{ .w = w, .remaining = n };
    }

    /// Writer returns the underlying std.Io.Writer interface.
    pub fn writer(self: *TruncateWriter) *Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .end = 0,
            .vtable = &.{
                .drain = drainImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *TruncateWriter = @alignCast(@fieldParentPtr("writer_inst", w));
        var written: usize = 0;
        for (data) |chunk| {
            if (self.remaining == 0) {
                written += chunk.len; // Silently drop remainder
                continue;
            }
            const to_write = @min(self.remaining, chunk.len);
            try self.w.writeAll(chunk[0..to_write]);
            self.remaining -= to_write;
            written += chunk.len;
        }
        return written;
    }
};

test "iotest ErrReader" {
    const testing = std.testing;

    var er = ErrReader.init(error.DiskFailure);
    var r = er.reader();
    var buf: [16]u8 = undefined;
    const res = r.readSliceShort(&buf);
    try testing.expectError(error.ReadFailed, res);
}

test "iotest OneByteReader and HalfReader" {
    const testing = std.testing;

    const msg = "ABCDEFGHIJ"; // 10 bytes
    var src = std.Io.Reader.fixed(msg);
    var one_byte = OneByteReader.init(&src);
    var obr = one_byte.reader();

    var buf: [16]u8 = undefined;
    var dst = std.Io.Writer.fixed(&buf);
    const n1 = try obr.stream(&dst, .unlimited);
    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqual(@as(u8, 'A'), buf[0]);

    // Test HalfReader
    var src2 = std.Io.Reader.fixed(msg);
    var half = HalfReader.init(&src2);
    var hr = half.reader();

    var buf2: [16]u8 = undefined;
    var dst2 = std.Io.Writer.fixed(&buf2);
    // Requesting up to 8 bytes, HalfReader should transfer at most 4 bytes
    const n2 = try hr.stream(&dst2, .limited(8));
    try testing.expect(n2 <= 4);
    try testing.expectEqualStrings(msg[0..n2], buf2[0..n2]);
}

test "iotest TimeoutReader and TruncateWriter" {
    const testing = std.testing;

    const msg = "hello world";
    var src = std.Io.Reader.fixed(msg);
    var tr = TimeoutReader.init(&src);
    var r = tr.reader();

    var buf: [4]u8 = undefined;
    const n1 = try r.readSliceShort(&buf);
    try testing.expectEqual(@as(usize, 4), n1);

    // Second read must return error.ReadFailed and set timed_out flag
    const res = r.readSliceShort(&buf);
    try testing.expectError(error.ReadFailed, res);
    try testing.expect(tr.timed_out);

    // TruncateWriter test
    var out_buf: [32]u8 = undefined;
    var dst = std.Io.Writer.fixed(&out_buf);
    var tw = TruncateWriter.init(&dst, 5);
    var w = tw.writer();

    try w.writeAll("hello world");
    try testing.expectEqualStrings("hello", dst.buffered());
}
