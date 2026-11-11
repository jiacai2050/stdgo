const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    allocator: Allocator,
    storage: []u8,
    length: usize = 0,
    off: usize = 0,
    last_read_byte: bool = false,

    const small_buffer_size = 64;

    pub fn init(allocator: Allocator) Buffer {
        return .{
            .allocator = allocator,
            .storage = &[_]u8{},
            .length = 0,
            .off = 0,
            .last_read_byte = false,
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.storage.len > 0) {
            self.allocator.free(self.storage);
            self.storage = &[_]u8{};
        }
        self.length = 0;
        self.off = 0;
        self.last_read_byte = false;
    }

    /// Bytes returns a slice of the unread portion of the buffer.
    pub fn bytes(self: *const Buffer) []const u8 {
        return self.storage[self.off..self.length];
    }

    /// String returns the unread portion as a slice.
    pub fn string(self: *const Buffer) []const u8 {
        return self.storage[self.off..self.length];
    }

    /// Len returns the number of bytes of the unread portion of the buffer.
    pub fn len(self: *const Buffer) usize {
        return self.length - self.off;
    }

    /// Cap returns the capacity of the buffer's underlying storage.
    pub fn cap(self: *const Buffer) usize {
        return self.storage.len;
    }

    /// Reset resets the buffer to be empty.
    pub fn reset(self: *Buffer) void {
        self.length = 0;
        self.off = 0;
        self.last_read_byte = false;
    }

    /// Truncate discards all but the first n unread bytes.
    pub fn truncate(self: *Buffer, n: usize) void {
        if (n == 0) {
            self.reset();
            return;
        }
        self.last_read_byte = false;
        if (n > self.len()) return;
        self.length = self.off + n;
    }

    /// Grow grows the buffer's capacity, if necessary, to guarantee space for
    /// another n bytes.
    pub fn grow(self: *Buffer, n: usize) Allocator.Error!void {
        const m = self.len();
        // If buffer is empty, reset to recover space.
        if (m == 0 and self.off != 0) {
            self.reset();
        }

        // Try to slide unread bytes to the beginning if that makes enough room
        if (self.off > 0 and (self.storage.len - m) >= n) {
            std.mem.copyForwards(u8, self.storage[0..m], self.storage[self.off..self.length]);
            self.off = 0;
            self.length = m;
            return;
        }

        const needed = self.length + n;
        if (needed <= self.storage.len) return;

        const new_cap = @max(self.storage.len * 2 + n, small_buffer_size);
        const new_storage = try self.allocator.realloc(self.storage, new_cap);
        self.storage = new_storage;
    }

    pub fn write(self: *Buffer, p: []const u8) Allocator.Error!usize {
        self.last_read_byte = false;
        try self.grow(p.len);
        @memcpy(self.storage[self.length .. self.length + p.len], p);
        self.length += p.len;
        return p.len;
    }

    pub fn writeString(self: *Buffer, s: []const u8) Allocator.Error!usize {
        return self.write(s);
    }

    pub fn writeByte(self: *Buffer, c: u8) Allocator.Error!void {
        const arr = [1]u8{c};
        _ = try self.write(&arr);
    }

    pub fn read(self: *Buffer, p: []u8) io.Error!usize {
        self.last_read_byte = false;
        if (self.off >= self.length) {
            // Buffer is empty, reset to recover space
            self.reset();
            if (p.len == 0) return 0;
            return io.Error.EndOfStream;
        }
        const available = self.length - self.off;
        const n = @min(p.len, available);
        @memcpy(p[0..n], self.storage[self.off .. self.off + n]);
        self.off += n;
        return n;
    }

    pub fn readByte(self: *Buffer) io.Error!u8 {
        if (self.off >= self.length) {
            self.reset();
            return io.Error.EndOfStream;
        }
        const c = self.storage[self.off];
        self.off += 1;
        self.last_read_byte = true;
        return c;
    }

    pub fn unreadByte(self: *Buffer) error{InvalidUnread}!void {
        if (!self.last_read_byte or self.off == 0) {
            return error.InvalidUnread;
        }
        self.last_read_byte = false;
        self.off -= 1;
    }

    pub fn reader(self: *Buffer) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
                .writeTo = writeToImpl,
            },
        };
    }

    pub fn writer(self: *Buffer) io.Writer {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeImpl,
                .readFrom = readFromImpl,
            },
        };
    }

    /// readFrom reads data from r until EOF and appends it to the buffer, growing
    /// the buffer as needed. The return value is the number of bytes read.
    pub fn readFrom(self: *Buffer, r: io.Reader) anyerror!u64 {
        var total: u64 = 0;
        while (true) {
            const min_read = 512;
            try self.grow(min_read);
            const free_slice = self.storage[self.length..];
            const n = r.read(free_slice) catch |err| {
                if (err == io.Error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            self.length += n;
            total += n;
        }
        return total;
    }

    /// writeTo writes data to w until the buffer is drained or an error occurs.
    /// The return value is the number of bytes written.
    pub fn writeTo(self: *Buffer, w: io.Writer) anyerror!u64 {
        const remaining = self.length - self.off;
        if (remaining == 0) return 0;
        try w.writeAll(self.storage[self.off..self.length]);
        self.reset();
        return @intCast(remaining);
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Buffer = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    fn writeImpl(ctx: *anyopaque, p: []const u8) anyerror!usize {
        const self: *Buffer = @ptrCast(@alignCast(ctx));
        return self.write(p);
    }

    fn readFromImpl(ctx: *anyopaque, r: io.Reader) anyerror!u64 {
        const self: *Buffer = @ptrCast(@alignCast(ctx));
        return self.readFrom(r);
    }

    fn writeToImpl(ctx: *anyopaque, w: io.Writer) anyerror!u64 {
        const self: *Buffer = @ptrCast(@alignCast(ctx));
        return self.writeTo(w);
    }
};

test "bytes.Buffer basic write and read" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    _ = try b.write("Hello, ");
    _ = try b.writeString("World!");
    try b.writeByte('\n');

    try testing.expectEqualStrings("Hello, World!\n", b.string());
    try testing.expectEqual(@as(usize, 14), b.len());

    var out: [7]u8 = undefined;
    const n = try b.read(&out);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqualStrings("Hello, ", &out);
    try testing.expectEqualStrings("World!\n", b.string());

    const c = try b.readByte();
    try testing.expectEqual(@as(u8, 'W'), c);
    try b.unreadByte();

    const c2 = try b.readByte();
    try testing.expectEqual(@as(u8, 'W'), c2);

    b.reset();
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "bytes.Buffer readFrom and writeTo" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var src = bytes.Reader.init("Direct stream payload");
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    // 1. Test readFrom into Buffer via io.copy
    var dummy_buf: [1]u8 = undefined;
    const n1 = try io.copy(b.writer(), src.reader(), &dummy_buf);
    try testing.expectEqual(@as(u64, 21), n1);
    try testing.expectEqualStrings("Direct stream payload", b.string());

    // 2. Test writeTo from Buffer via io.copy
    var dst_b = Buffer.init(testing.allocator);
    defer dst_b.deinit();

    const n2 = try io.copy(dst_b.writer(), b.reader(), &dummy_buf);
    try testing.expectEqual(@as(u64, 21), n2);
    try testing.expectEqualStrings("Direct stream payload", dst_b.string());
    try testing.expectEqual(@as(usize, 0), b.len());
}
