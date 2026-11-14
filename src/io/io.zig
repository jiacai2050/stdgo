const std = @import("std");
const assert = std.debug.assert;

pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;
pub const Limit = std.Io.Limit;

pub const Error = error{
    EndOfStream,
    UnexpectedEndOfStream,
    ShortWrite,
    ShortBuffer,
    InvalidWriteResult,
    NoProgress,
    SeekBeforeStart,
    ReadFailed,
};

pub const SeekWhence = enum(u8) {
    start = 0,
    current = 1,
    end = 2,
};

pub const Closer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn close(self: Closer) anyerror!void {
        return self.vtable.close(self.ptr);
    }
};

pub const Seeker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        seek: *const fn (ctx: *anyopaque, offset: i64, whence: SeekWhence) anyerror!u64,
    };

    pub fn seek(self: Seeker, offset: i64, whence: SeekWhence) anyerror!u64 {
        return self.vtable.seek(self.ptr, offset, whence);
    }
};

/// Reads from r into buf until it has read at least min bytes.
pub fn readAtLeast(r: *Reader, buf: []u8, min: usize) anyerror!usize {
    if (buf.len < min) return Error.ShortBuffer;
    var n: usize = 0;
    while (n < min) {
        const read_count = r.readSliceShort(buf[n..]) catch |err| {
            if (err == error.EndOfStream) {
                if (n >= min) return n;
                if (n > 0) return Error.UnexpectedEndOfStream;
                return Error.EndOfStream;
            }
            return err;
        };
        if (read_count == 0) {
            if (n >= min) return n;
            if (n > 0) return Error.UnexpectedEndOfStream;
            return Error.EndOfStream;
        }
        n += read_count;
    }
    return n;
}

/// Reads exactly buf.len bytes from r into buf.
pub fn readFull(r: *Reader, buf: []u8) anyerror!usize {
    return readAtLeast(r, buf, buf.len);
}

/// Copies from src to dst until EOF is reached on src.
pub fn copy(dst: *Writer, src: *Reader) anyerror!u64 {
    const bytes = try src.stream(dst, .unlimited);
    return @intCast(bytes);
}

/// copyBuffer is identical to copy.
pub fn copyBuffer(dst: *Writer, src: *Reader, buf: ?[]u8) anyerror!u64 {
    _ = buf;
    return copy(dst, src);
}

/// copyN copies n bytes (or until an error) from src to dst.
pub fn copyN(dst: *Writer, src: *Reader, n: i64) anyerror!u64 {
    if (n <= 0) return 0;
    const count = try src.stream(dst, .limited(@intCast(n)));
    if (count < @as(usize, @intCast(n))) return Error.UnexpectedEndOfStream;
    return @intCast(count);
}

/// LimitReader returns a Reader that reads from r but stops with EndOfStream after n bytes.
pub const LimitReader = struct {
    r: *Reader,
    n: i64,
    reader_inst: std.Io.Reader = undefined,

    pub fn init(r: *Reader, n: i64) LimitReader {
        return .{ .r = r, .n = n };
    }

    pub fn reader(self: *LimitReader) *Reader {
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

    pub fn readSliceShort(self: *LimitReader, buf: []u8) anyerror!usize {
        return self.reader().readSliceShort(buf);
    }

    fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *LimitReader = @alignCast(@fieldParentPtr("reader_inst", r));
        if (self.n <= 0) return error.EndOfStream;
        const bounded = @min(@backingInt(limit), @as(usize, @intCast(self.n)));
        if (bounded == 0) return 0;
        const count = self.r.stream(w, .limited(bounded)) catch |err| return err;
        self.n -= @intCast(count);
        if (count == 0) return error.EndOfStream;
        return count;
    }
};

/// TeeReader returns a Reader that writes to w what it reads from r.
pub const TeeReader = struct {
    r: *Reader,
    w: *Writer,
    reader_inst: std.Io.Reader = undefined,
    buf: [512]u8 = undefined,

    pub fn init(r: *Reader, w: *Writer) TeeReader {
        return .{ .r = r, .w = w };
    }

    pub fn reader(self: *TeeReader) *Reader {
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

    pub fn readSliceShort(self: *TeeReader, buf: []u8) anyerror!usize {
        return self.reader().readSliceShort(buf);
    }

    fn streamImpl(r: *std.Io.Reader, dst: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TeeReader = @alignCast(@fieldParentPtr("reader_inst", r));
        const max_bytes = @backingInt(limit);
        if (max_bytes == 0) return 0;
        const want = @min(self.buf.len, max_bytes);
        const n = self.r.readSliceShort(self.buf[0..want]) catch |err| {
            if (err == error.EndOfStream) return error.EndOfStream;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        dst.writeAll(self.buf[0..n]) catch return error.WriteFailed;
        self.w.writeAll(self.buf[0..n]) catch return error.WriteFailed;
        return n;
    }
};

test "io.copy and readFull via native std.Io" {
    const testing = std.testing;

    const data = "hello world from native std.Io";
    var src = std.Io.Reader.fixed(data);

    var dst_alloc = std.Io.Writer.Allocating.init(testing.allocator);
    defer testing.allocator.free(dst_alloc.writer.buffer);

    const copied = try copy(&dst_alloc.writer, &src);
    try testing.expectEqual(@as(u64, data.len), copied);
    try testing.expectEqualStrings(data, dst_alloc.writer.buffer[0..dst_alloc.writer.end]);
}
