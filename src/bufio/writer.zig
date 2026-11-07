const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const default_buf_size = 4096;

pub const Writer = struct {
    allocator: ?Allocator = null,
    buf: []u8,
    n: usize = 0,
    wr: io.Writer,

    pub fn initSize(allocator: Allocator, wr: io.Writer, size: usize) Allocator.Error!Writer {
        const actual_size = @max(size, 16);
        const buf = try allocator.alloc(u8, actual_size);
        return .{
            .allocator = allocator,
            .buf = buf,
            .n = 0,
            .wr = wr,
        };
    }

    pub fn init(allocator: Allocator, wr: io.Writer) Allocator.Error!Writer {
        return initSize(allocator, wr, default_buf_size);
    }

    pub fn initWithBuffer(buf: []u8, wr: io.Writer) Writer {
        assert(buf.len > 0);
        return .{
            .allocator = null,
            .buf = buf,
            .n = 0,
            .wr = wr,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.allocator) |alloc| {
            alloc.free(self.buf);
        }
        self.buf = &[_]u8{};
        self.n = 0;
    }

    pub fn reset(self: *Writer, wr: io.Writer) void {
        self.n = 0;
        self.wr = wr;
    }

    /// Flush writes any buffered data to the underlying io.Writer.
    pub fn flush(self: *Writer) anyerror!void {
        if (self.n == 0) return;
        try self.wr.writeAll(self.buf[0..self.n]);
        self.n = 0;
    }

    /// Available returns how many bytes are unused in the buffer.
    pub fn available(self: *const Writer) usize {
        return self.buf.len - self.n;
    }

    /// Buffered returns the number of bytes that have been written into the current buffer.
    pub fn buffered(self: *const Writer) usize {
        return self.n;
    }

    /// Write writes the contents of p into the buffer.
    pub fn write(self: *Writer, p: []const u8) anyerror!usize {
        var remaining = p;
        while (remaining.len > self.available()) {
            if (self.buffered() == 0) {
                // Large write directly to underlying writer
                const count = try self.wr.write(remaining);
                if (count == 0) return io.Error.ShortWrite;
                return p.len - remaining.len + count;
            }
            const can_copy = self.available();
            @memcpy(self.buf[self.n .. self.n + can_copy], remaining[0..can_copy]);
            self.n += can_copy;
            try self.flush();
            remaining = remaining[can_copy..];
        }
        @memcpy(self.buf[self.n .. self.n + remaining.len], remaining);
        self.n += remaining.len;
        return p.len;
    }

    pub fn writeString(self: *Writer, s: []const u8) anyerror!usize {
        return self.write(s);
    }

    pub fn writeByte(self: *Writer, c: u8) anyerror!void {
        if (self.available() == 0) {
            try self.flush();
        }
        self.buf[self.n] = c;
        self.n += 1;
    }

    pub fn writer(self: *Writer) io.Writer {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeImpl,
            },
        };
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Writer = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }
};

test "bufio.Writer basic buffering and flush" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var target_buf = bytes.Buffer.init(testing.allocator);
    defer target_buf.deinit();

    var bw = try Writer.initSize(testing.allocator, target_buf.writer(), 16);
    defer bw.deinit();

    _ = try bw.write("hello");
    try testing.expectEqual(@as(usize, 5), bw.buffered());
    try testing.expectEqualStrings("", target_buf.string()); // not flushed yet

    try bw.flush();
    try testing.expectEqual(@as(usize, 0), bw.buffered());
    try testing.expectEqualStrings("hello", target_buf.string());
}
