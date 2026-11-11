const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;

pub const Reader = struct {
    s: []const u8,
    i: i64 = 0,
    prev_r: i64 = -1,

    pub fn init(b: []const u8) Reader {
        return .{
            .s = b,
            .i = 0,
            .prev_r = -1,
        };
    }

    /// Returns the number of bytes of the unread portion of the slice.
    pub fn len(self: *const Reader) usize {
        if (self.i >= @as(i64, @intCast(self.s.len))) {
            return 0;
        }
        return @intCast(@as(i64, @intCast(self.s.len)) - self.i);
    }

    /// Size returns the original length of the underlying byte slice.
    pub fn size(self: *const Reader) i64 {
        return @intCast(self.s.len);
    }

    pub fn reset(self: *Reader, b: []const u8) void {
        self.s = b;
        self.i = 0;
        self.prev_r = -1;
    }

    pub fn read(self: *Reader, b: []u8) io.Error!usize {
        if (self.i >= @as(i64, @intCast(self.s.len))) {
            return io.Error.EndOfStream;
        }
        self.prev_r = self.i;
        const available: usize = @intCast(@as(i64, @intCast(self.s.len)) - self.i);
        const n = @min(available, b.len);
        const start: usize = @intCast(self.i);
        @memcpy(b[0..n], self.s[start .. start + n]);
        self.i += @intCast(n);
        return n;
    }

    pub fn readByte(self: *Reader) io.Error!u8 {
        self.prev_r = self.i;
        if (self.i >= @as(i64, @intCast(self.s.len))) {
            return io.Error.EndOfStream;
        }
        const b = self.s[@intCast(self.i)];
        self.i += 1;
        return b;
    }

    pub fn unreadByte(self: *Reader) error{InvalidUnread}!void {
        if (self.prev_r < 0) {
            return error.InvalidUnread;
        }
        self.i = self.prev_r;
        self.prev_r = -1;
    }

    pub fn seek(self: *Reader, offset: i64, whence: io.SeekWhence) io.Error!u64 {
        self.prev_r = -1;
        var abs_offset: i64 = 0;
        switch (whence) {
            .start => {
                abs_offset = offset;
            },
            .current => {
                abs_offset = self.i + offset;
            },
            .end => {
                abs_offset = @as(i64, @intCast(self.s.len)) + offset;
            },
        }
        if (abs_offset < 0) {
            return io.Error.SeekBeforeStart;
        }
        self.i = abs_offset;
        return @intCast(abs_offset);
    }

    pub fn writeTo(self: *Reader, w: io.Writer) anyerror!u64 {
        self.prev_r = -1;
        if (self.i >= @as(i64, @intCast(self.s.len))) {
            return 0;
        }
        const start: usize = @intCast(self.i);
        const slice = self.s[start..];
        try w.writeAll(slice);
        self.i = @intCast(self.s.len);
        return @intCast(slice.len);
    }

    pub fn reader(self: *Reader) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
                .writeTo = writeToImpl,
            },
        };
    }

    pub fn seeker(self: *Reader) io.Seeker {
        return .{
            .ptr = self,
            .vtable = &.{
                .seek = seekImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    fn writeToImpl(ctx: *anyopaque, w: io.Writer) anyerror!u64 {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.writeTo(w);
    }

    fn seekImpl(ctx: *anyopaque, offset: i64, whence: io.SeekWhence) anyerror!u64 {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.seek(offset, whence);
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
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 6), r.len());

    const b = try r.readByte();
    try std.testing.expectEqual(@as(u8, ' '), b);

    try r.unreadByte();
    const b2 = try r.readByte();
    try std.testing.expectEqual(@as(u8, ' '), b2);

    // Seek back to start
    const pos = try r.seek(0, .start);
    try std.testing.expectEqual(@as(u64, 0), pos);
    try std.testing.expectEqual(@as(usize, 11), r.len());

    var full_buf: [11]u8 = undefined;
    _ = try r.read(&full_buf);
    try std.testing.expectEqualStrings(data, &full_buf);

    // EOF
    try std.testing.expectError(io.Error.EndOfStream, r.read(&buf));
}
