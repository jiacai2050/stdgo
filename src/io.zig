pub const io = @import("io/io.zig");

pub const Reader = io.Reader;
pub const Writer = io.Writer;
pub const Closer = io.Closer;
pub const Seeker = io.Seeker;
pub const SeekWhence = io.SeekWhence;
pub const Error = io.Error;

pub const readAtLeast = io.readAtLeast;
pub const readFull = io.readFull;
pub const copy = io.copy;
pub const LimitReader = io.LimitReader;
pub const TeeReader = io.TeeReader;

const std = @import("std");

test "io.LimitReader and TeeReader" {
    // Custom mock reader
    const MockReader = struct {
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

    var mock_src = MockReader{ .data = "hello world" };
    var limit = LimitReader.init(mock_src.reader(), 5);

    var buf: [16]u8 = undefined;
    const n = try limit.reader().read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    // next read should return EndOfStream
    const res = limit.reader().read(&buf);
    try std.testing.expectError(Error.EndOfStream, res);
}
