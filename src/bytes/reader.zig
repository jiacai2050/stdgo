const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;

pub const Reader = struct {
    r: std.Io.Reader,
    orig_len: usize,

    pub fn init(b: []const u8) Reader {
        return .{
            .r = std.Io.Reader.fixed(b),
            .orig_len = b.len,
        };
    }

    /// Returns the number of bytes of the unread portion of the slice.
    pub fn len(self: *const Reader) usize {
        return self.r.end - self.r.seek;
    }

    /// Returns the slice of unread buffered bytes.
    pub fn buffered(self: *Reader) []const u8 {
        return self.r.buffered();
    }

    /// Size returns the original length of the underlying byte slice.
    pub fn size(self: *const Reader) i64 {
        return @intCast(self.orig_len);
    }

    pub fn reset(self: *Reader, b: []const u8) void {
        self.r = std.Io.Reader.fixed(b);
        self.orig_len = b.len;
    }

    pub fn read(self: *Reader, b: []u8) io.Error!usize {
        const n = try self.r.readSliceShort(b);
        if (n == 0 and b.len > 0) return io.Error.EndOfStream;
        return n;
    }

    pub fn readByte(self: *Reader) io.Error!u8 {
        return self.r.takeByte() catch io.Error.EndOfStream;
    }

    pub fn unreadByte(self: *Reader) error{InvalidUnread}!void {
        if (self.r.seek == 0) return error.InvalidUnread;
        self.r.seek -= 1;
    }

    pub fn seek(self: *Reader, offset: i64, whence: io.SeekWhence) io.Error!u64 {
        var abs_offset: i64 = 0;
        switch (whence) {
            .start => {
                abs_offset = offset;
            },
            .current => {
                abs_offset = @as(i64, @intCast(self.r.seek)) + offset;
            },
            .end => {
                abs_offset = @as(i64, @intCast(self.r.end)) + offset;
            },
        }
        if (abs_offset < 0 or abs_offset > @as(i64, @intCast(self.r.end))) {
            return io.Error.SeekBeforeStart;
        }
        self.r.seek = @intCast(abs_offset);
        return @intCast(abs_offset);
    }

    pub fn writeTo(self: *Reader, w: *std.Io.Writer) anyerror!u64 {
        const remaining = self.len();
        if (remaining == 0) return 0;
        const count = try self.r.stream(w, .unlimited);
        return @intCast(count);
    }

    pub fn reader(self: *Reader) *std.Io.Reader {
        return &self.r;
    }
};

test "bytes.Reader basic reading and seeking" {
    const data = "hello world";
    var r = Reader.init(data);

    try std.testing.expectEqual(@as(usize, 11), r.len());
    try std.testing.expectEqual(@as(i64, 11), r.size());

    var buf: [5]u8 = undefined;
    const n = try r.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", &buf);
    try std.testing.expectEqual(@as(usize, 6), r.len());

    const b = try r.readByte();
    try std.testing.expectEqual(@as(u8, ' '), b);

    try r.unreadByte();
    const b2 = try r.readByte();
    try std.testing.expectEqual(@as(u8, ' '), b2);

    const pos = try r.seek(0, .start);
    try std.testing.expectEqual(@as(u64, 0), pos);
    try std.testing.expectEqual(@as(usize, 11), r.len());

    var out_alloc = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer std.testing.allocator.free(out_alloc.writer.buffer);

    const written = try r.writeTo(&out_alloc.writer);
    try std.testing.expectEqual(@as(u64, 11), written);
    try std.testing.expectEqualStrings("hello world", out_alloc.writer.buffer[0..out_alloc.writer.end]);
}
