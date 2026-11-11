const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    EndOfStream,
    UnexpectedEndOfStream,
    ShortWrite,
    ShortBuffer,
    InvalidWriteResult,
    NoProgress,
    SeekBeforeStart,
};

pub const SeekWhence = enum(u8) {
    start = 0,
    current = 1,
    end = 2,
};

pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        writeTo: ?*const fn (ctx: *anyopaque, w: Writer) anyerror!u64 = null,
    };

    pub fn read(self: Reader, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn readAll(self: Reader, buf: []u8) anyerror!usize {
        return readAtLeast(self, buf, buf.len);
    }
};

pub const Writer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        readFrom: ?*const fn (ctx: *anyopaque, r: Reader) anyerror!u64 = null,
    };

    pub fn write(self: Writer, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn writeAll(self: Writer, bytes: []const u8) anyerror!void {
        var index: usize = 0;
        while (index < bytes.len) {
            const n = try self.write(bytes[index..]);
            if (n == 0) return Error.ShortWrite;
            index += n;
        }
    }

    pub fn writeByte(self: Writer, byte: u8) anyerror!void {
        const arr = [1]u8{byte};
        try self.writeAll(&arr);
    }
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

/// ReaderFrom is the interface that wraps the readFrom method.
pub const ReaderFrom = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFrom: *const fn (ctx: *anyopaque, r: Reader) anyerror!u64,
    };

    pub fn readFrom(self: ReaderFrom, r: Reader) anyerror!u64 {
        return self.vtable.readFrom(self.ptr, r);
    }
};

/// WriterTo is the interface that wraps the writeTo method.
pub const WriterTo = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeTo: *const fn (ctx: *anyopaque, w: Writer) anyerror!u64,
    };

    pub fn writeTo(self: WriterTo, w: Writer) anyerror!u64 {
        return self.vtable.writeTo(self.ptr, w);
    }
};

/// Reads from r into buf until it has read at least min bytes.
/// It returns the number of bytes read and an error if fewer bytes were read.
pub fn readAtLeast(r: Reader, buf: []u8, min: usize) anyerror!usize {
    if (buf.len < min) return Error.ShortBuffer;
    var n: usize = 0;
    while (n < min) {
        const read_count = r.read(buf[n..]) catch |err| {
            if (err == Error.EndOfStream) {
                if (n >= min) {
                    return n;
                }
                if (n > 0) {
                    return Error.UnexpectedEndOfStream;
                }
                return Error.EndOfStream;
            }
            return err;
        };
        if (read_count == 0) {
            if (n >= min) return n;
            return Error.UnexpectedEndOfStream;
        }
        n += read_count;
    }
    return n;
}

/// Reads exactly buf.len bytes from r into buf.
pub fn readFull(r: Reader, buf: []u8) anyerror!usize {
    return readAtLeast(r, buf, buf.len);
}

/// Copies from src to dst until either EOF is reached on src or an error occurs.
/// It returns the number of bytes copied.
///
/// If dst implements ReaderFrom, the copy is staged using its readFrom method.
/// Otherwise, if src implements WriterTo, the copy is staged using its writeTo method.
/// Otherwise, it copies in chunks using buffer.
pub fn copy(dst: Writer, src: Reader, buffer: []u8) anyerror!u64 {
    if (dst.vtable.readFrom) |rf| {
        return rf(dst.ptr, src);
    }
    if (src.vtable.writeTo) |wt| {
        return wt(src.ptr, dst);
    }
    assert(buffer.len > 0);
    var written: u64 = 0;
    while (true) {
        const nr = src.read(buffer) catch |err| {
            if (err == Error.EndOfStream) break;
            return err;
        };
        if (nr == 0) break;
        try dst.writeAll(buffer[0..nr]);
        written += nr;
    }
    return written;
}

/// copyBuffer is identical to copy except that it stages through the provided buffer
/// (or allocates an internal stack buffer if buf is null) rather than requiring a buffer.
pub fn copyBuffer(dst: Writer, src: Reader, buf: ?[]u8) anyerror!u64 {
    if (dst.vtable.readFrom) |rf| {
        return rf(dst.ptr, src);
    }
    if (src.vtable.writeTo) |wt| {
        return wt(src.ptr, dst);
    }
    if (buf) |b| {
        return copy(dst, src, b);
    }
    var stack_buf: [32 * 1024]u8 = undefined;
    return copy(dst, src, &stack_buf);
}

/// LimitReader returns a Reader that reads from r but stops with EndOfStream after n bytes.
pub const LimitReader = struct {
    r: Reader,
    n: i64,

    pub fn init(r: Reader, n: i64) LimitReader {
        return .{ .r = r, .n = n };
    }

    pub fn reader(self: *LimitReader) Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *LimitReader = @ptrCast(@alignCast(ctx));
        if (self.n <= 0) {
            return Error.EndOfStream;
        }
        var to_read = buf;
        if (@as(i64, @intCast(to_read.len)) > self.n) {
            to_read = to_read[0..@intCast(self.n)];
        }
        const nr = try self.r.read(to_read);
        self.n -= @intCast(nr);
        return nr;
    }
};

/// TeeReader returns a Reader that writes to w what it reads from r.
pub const TeeReader = struct {
    r: Reader,
    w: Writer,

    pub fn init(r: Reader, w: Writer) TeeReader {
        return .{ .r = r, .w = w };
    }

    pub fn reader(self: *TeeReader) Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TeeReader = @ptrCast(@alignCast(ctx));
        const nr = try self.r.read(buf);
        if (nr > 0) {
            try self.w.writeAll(buf[0..nr]);
        }
        return nr;
    }
};

test "io.copy fast-path via ReaderFrom and WriterTo" {
    const testing = std.testing;

    // Fast-path tracking Writer implementing ReaderFrom
    const MockReaderFromWriter = struct {
        called: bool = false,
        bytes_copied: u64 = 0,

        fn readFrom(ctx: *anyopaque, r: Reader) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            var buf: [32]u8 = undefined;
            var total: u64 = 0;
            while (true) {
                const n = r.read(&buf) catch |err| {
                    if (err == Error.EndOfStream) break;
                    return err;
                };
                if (n == 0) break;
                total += n;
            }
            self.bytes_copied = total;
            return total;
        }

        fn writer(self: *@This()) Writer {
            return .{
                .ptr = self,
                .vtable = &.{
                    .write = struct {
                        fn w(_: *anyopaque, bytes: []const u8) anyerror!usize {
                            return bytes.len;
                        }
                    }.w,
                    .readFrom = readFrom,
                },
            };
        }
    };

    // Fast-path tracking Reader implementing WriterTo
    const MockWriterToReader = struct {
        called: bool = false,
        data: []const u8,

        fn writeTo(ctx: *anyopaque, w: Writer) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            try w.writeAll(self.data);
            return @intCast(self.data.len);
        }

        fn reader(self: *@This()) Reader {
            return .{
                .ptr = self,
                .vtable = &.{
                    .read = struct {
                        fn r(_: *anyopaque, _: []u8) anyerror!usize {
                            return Error.EndOfStream;
                        }
                    }.r,
                    .writeTo = writeTo,
                },
            };
        }
    };

    // Normal Reader
    const NormalReader = struct {
        data: []const u8,
        cursor: usize = 0,

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.cursor >= self.data.len) return Error.EndOfStream;
            const available = self.data.len - self.cursor;
            const n = @min(available, buf.len);
            @memcpy(buf[0..n], self.data[self.cursor .. self.cursor + n]);
            self.cursor += n;
            return n;
        }

        fn reader(self: *@This()) Reader {
            return .{
                .ptr = self,
                .vtable = &.{ .read = read },
            };
        }
    };

    // Normal Writer
    const NormalWriter = struct {
        written: usize = 0,

        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.written += bytes.len;
            return bytes.len;
        }

        fn writer(self: *@This()) Writer {
            return .{
                .ptr = self,
                .vtable = &.{ .write = write },
            };
        }
    };

    // 1. Test dst has readFrom
    var rf_writer = MockReaderFromWriter{};
    var normal_r = NormalReader{ .data = "hello world" };
    var copy_buf: [16]u8 = undefined;
    const n1 = try copy(rf_writer.writer(), normal_r.reader(), &copy_buf);
    try testing.expectEqual(@as(u64, 11), n1);
    try testing.expect(rf_writer.called);

    // 2. Test src has writeTo
    var normal_w = NormalWriter{};
    var wt_reader = MockWriterToReader{ .data = "fast write to" };
    const n2 = try copy(normal_w.writer(), wt_reader.reader(), &copy_buf);
    try testing.expectEqual(@as(u64, 13), n2);
    try testing.expect(wt_reader.called);
    try testing.expectEqual(@as(usize, 13), normal_w.written);

    // 3. Test copyBuffer fallback
    var normal_r2 = NormalReader{ .data = "buffered fallback" };
    var normal_w2 = NormalWriter{};
    const n3 = try copyBuffer(normal_w2.writer(), normal_r2.reader(), null);
    try testing.expectEqual(@as(u64, 17), n3);
    try testing.expectEqual(@as(usize, 17), normal_w2.written);
}
