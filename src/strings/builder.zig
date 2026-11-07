const std = @import("std");
const bytes = @import("../bytes.zig");
const Allocator = std.mem.Allocator;

pub const Builder = struct {
    buf: bytes.Buffer,

    pub fn init(allocator: Allocator) Builder {
        return .{
            .buf = bytes.Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit();
    }

    pub fn write(self: *Builder, p: []const u8) Allocator.Error!usize {
        return self.buf.write(p);
    }

    pub fn writeString(self: *Builder, s: []const u8) Allocator.Error!usize {
        return self.buf.writeString(s);
    }

    pub fn writeByte(self: *Builder, c: u8) Allocator.Error!void {
        return self.buf.writeByte(c);
    }

    pub fn writeRune(self: *Builder, r: u21) Allocator.Error!usize {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(r, &buf) catch return 0;
        _ = try self.buf.write(buf[0..n]);
        return n;
    }

    pub fn string(self: *const Builder) []const u8 {
        return self.buf.string();
    }

    pub fn len(self: *const Builder) usize {
        return self.buf.len();
    }

    pub fn cap(self: *const Builder) usize {
        return self.buf.cap();
    }

    pub fn reset(self: *Builder) void {
        self.buf.reset();
    }

    pub fn grow(self: *Builder, n: usize) Allocator.Error!void {
        return self.buf.grow(n);
    }
};

test "strings.Builder writeString and runes" {
    const testing = std.testing;

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    _ = try b.writeString("Hello");
    try b.writeByte(' ');
    _ = try b.writeString("World!");
    _ = try b.writeRune(0x2728); // ✨ Sparkles rune

    try testing.expectEqualStrings("Hello World!✨", b.string());
    try testing.expect(b.len() > 12);

    b.reset();
    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expectEqualStrings("", b.string());
}
