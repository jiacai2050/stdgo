const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const default_buf_size = 4096;
const min_buf_size = 16;

pub const Error = error{
    BufferFull,
    NegativeCount,
    InvalidUnreadByte,
};

pub const Reader = struct {
    allocator: ?Allocator = null,
    buf: []u8,
    rd: io.Reader,
    r: usize = 0,
    w: usize = 0,
    last_byte: i16 = -1,

    pub fn initSize(allocator: Allocator, rd: io.Reader, size: usize) Allocator.Error!Reader {
        const actual_size = @max(size, min_buf_size);
        const buf = try allocator.alloc(u8, actual_size);
        return .{
            .allocator = allocator,
            .buf = buf,
            .rd = rd,
            .r = 0,
            .w = 0,
            .last_byte = -1,
        };
    }

    pub fn init(allocator: Allocator, rd: io.Reader) Allocator.Error!Reader {
        return initSize(allocator, rd, default_buf_size);
    }

    pub fn initWithBuffer(buf: []u8, rd: io.Reader) Reader {
        assert(buf.len >= min_buf_size);
        return .{
            .allocator = null,
            .buf = buf,
            .rd = rd,
            .r = 0,
            .w = 0,
            .last_byte = -1,
        };
    }

    pub fn deinit(self: *Reader) void {
        if (self.allocator) |alloc| {
            alloc.free(self.buf);
        }
        self.buf = &[_]u8{};
        self.r = 0;
        self.w = 0;
        self.last_byte = -1;
    }

    pub fn reset(self: *Reader, rd: io.Reader) void {
        self.rd = rd;
        self.r = 0;
        self.w = 0;
        self.last_byte = -1;
    }

    pub fn buffered(self: *const Reader) usize {
        return self.w - self.r;
    }

    /// fill reads a new chunk into the buffer from the underlying Reader.
    fn fill(self: *Reader) anyerror!void {
        // Slide existing unread bytes to the beginning of the buffer
        if (self.r > 0) {
            const unread_len = self.w - self.r;
            if (unread_len > 0) {
                std.mem.copyForwards(u8, self.buf[0..unread_len], self.buf[self.r..self.w]);
            }
            self.r = 0;
            self.w = unread_len;
        }

        if (self.w >= self.buf.len) {
            return Error.BufferFull;
        }

        const n = try self.rd.read(self.buf[self.w..]);
        if (n == 0) {
            return io.Error.EndOfStream;
        }
        self.w += n;
    }

    /// Read reads data into p. It returns the number of bytes read.
    pub fn read(self: *Reader, p: []u8) anyerror!usize {
        self.last_byte = -1;
        if (p.len == 0) return 0;

        if (self.r == self.w) {
            if (p.len >= self.buf.len) {
                // Large read directly from underlying reader
                return self.rd.read(p);
            }
            self.fill() catch |err| {
                if (err == io.Error.EndOfStream) {
                    return io.Error.EndOfStream;
                }
                return err;
            };
        }

        const available = self.w - self.r;
        const n = @min(p.len, available);
        @memcpy(p[0..n], self.buf[self.r .. self.r + n]);
        self.r += n;
        self.last_byte = @as(i16, self.buf[self.r - 1]);
        return n;
    }

    pub fn readByte(self: *Reader) anyerror!u8 {
        self.last_byte = -1;
        while (self.r == self.w) {
            try self.fill();
        }
        const b = self.buf[self.r];
        self.r += 1;
        self.last_byte = @as(i16, b);
        return b;
    }

    pub fn unreadByte(self: *Reader) Error!void {
        if (self.last_byte < 0 or (self.r == 0 and self.w > 0)) {
            return Error.InvalidUnreadByte;
        }
        if (self.r > 0) {
            self.r -= 1;
        } else {
            // Should not be reachable given the first check, but safe fallback
            return Error.InvalidUnreadByte;
        }
        self.last_byte = -1;
    }

    /// Peek returns the next n bytes without advancing the reader.
    pub fn peek(self: *Reader, n: usize) anyerror![]const u8 {
        if (n > self.buf.len) return Error.BufferFull;
        while (self.w - self.r < n) {
            self.fill() catch |err| {
                if (err == io.Error.EndOfStream) {
                    if (self.w - self.r > 0) {
                        return self.buf[self.r..self.w];
                    }
                    return io.Error.EndOfStream;
                }
                return err;
            };
        }
        return self.buf[self.r .. self.r + n];
    }

    /// Discard skips the next n bytes.
    pub fn discard(self: *Reader, n: usize) anyerror!usize {
        var remain = n;
        while (remain > 0) {
            if (self.r == self.w) {
                self.fill() catch |err| {
                    if (err == io.Error.EndOfStream) {
                        return n - remain;
                    }
                    return err;
                };
            }
            const available = self.w - self.r;
            const skip = @min(remain, available);
            self.r += skip;
            remain -= skip;
        }
        return n;
    }

    /// ReadBytes reads until the first occurrence of delim in the input.
    pub fn readBytes(self: *Reader, allocator: Allocator, delim: u8) anyerror![]u8 {
        const bytes = @import("../bytes.zig");
        var buf = bytes.Buffer.init(allocator);
        errdefer buf.deinit();

        while (true) {
            const b = self.readByte() catch |err| {
                if (err == io.Error.EndOfStream) {
                    if (buf.len() > 0) {
                        const res = try allocator.dupe(u8, buf.bytes());
                        buf.deinit();
                        return res;
                    }
                    return io.Error.EndOfStream;
                }
                return err;
            };
            try buf.writeByte(b);
            if (b == delim) {
                const res = try allocator.dupe(u8, buf.bytes());
                buf.deinit();
                return res;
            }
        }
    }

    pub fn readString(self: *Reader, allocator: Allocator, delim: u8) anyerror![]u8 {
        return self.readBytes(allocator, delim);
    }

    pub fn reader(self: *Reader) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }
};

test "bufio.Reader basic operations" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var br = bytes.Reader.init("line 1\nline 2\nline 3");
    var r = try Reader.initSize(testing.allocator, br.reader(), 16);
    defer r.deinit();

    // Test peek
    const pk = try r.peek(4);
    try testing.expectEqualStrings("line", pk);

    // Test readString
    const line1 = try r.readString(testing.allocator, '\n');
    defer testing.allocator.free(line1);
    try testing.expectEqualStrings("line 1\n", line1);

    // Test unreadByte
    const ch = try r.readByte();
    try testing.expectEqual(@as(u8, 'l'), ch);
    try r.unreadByte();
    const ch2 = try r.readByte();
    try testing.expectEqual(@as(u8, 'l'), ch2);
}
