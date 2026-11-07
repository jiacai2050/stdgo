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
/// Returns the number of bytes copied.
pub fn copy(dst: Writer, src: Reader, buffer: []u8) anyerror!u64 {
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
