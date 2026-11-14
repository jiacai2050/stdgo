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
pub const copyBuffer = io.copyBuffer;
pub const copyN = io.copyN;
pub const LimitReader = io.LimitReader;
pub const TeeReader = io.TeeReader;

const std = @import("std");

test "io.LimitReader and copy" {
    const data = "hello world";
    var src = std.Io.Reader.fixed(data);
    var limit = LimitReader.init(&src, 5);

    var buf: [16]u8 = undefined;
    const n = try limit.readSliceShort(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    const n2 = try limit.readSliceShort(&buf);
    try std.testing.expectEqual(@as(usize, 0), n2);
}
