const std = @import("std");
const io = @import("../io.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    pub const small_buffer_size = 64;

    allocator: Allocator,
    bootstrap: [small_buffer_size]u8 = undefined,
    storage: []u8,
    length: usize = 0,
    off: usize = 0,
    last_read_byte: bool = false,
    writer_inst: std.Io.Writer,

    const writer_vtable: std.Io.Writer.VTable = .{
        .drain = drainImpl,
        .flush = flushImpl,
        .rebase = rebaseImpl,
    };

    inline fn isBootstrap(self: *const Buffer) bool {
        return @intFromPtr(self.storage.ptr) == @intFromPtr(&self.bootstrap);
    }

    fn commitWriter(self: *Buffer) void {
        if (self.writer_inst.end > 0) {
            self.length += self.writer_inst.end;
            self.writer_inst.end = 0;
            self.writer_inst.buffer = self.storage[self.length..];
        }
    }

    pub fn init(allocator: Allocator) Buffer {
        return .{
            .allocator = allocator,
            .bootstrap = undefined,
            .storage = &.{},
            .length = 0,
            .off = 0,
            .last_read_byte = false,
            .writer_inst = .{
                .vtable = &writer_vtable,
                .buffer = &.{},
                .end = 0,
            },
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.storage.len > 0 and !self.isBootstrap()) {
            self.allocator.free(self.storage);
        }
        self.storage = &.{};
        self.length = 0;
        self.off = 0;
        self.last_read_byte = false;
        self.writer_inst.buffer = &.{};
        self.writer_inst.end = 0;
    }

    /// Bytes returns a slice of the unread portion of the buffer.
    pub fn bytes(self: *const Buffer) []const u8 {
        const total = self.length + self.writer_inst.end;
        return self.storage[self.off..total];
    }

    /// String returns the unread portion as a slice.
    pub fn string(self: *const Buffer) []const u8 {
        const total = self.length + self.writer_inst.end;
        return self.storage[self.off..total];
    }

    /// Len returns the number of bytes of the unread portion of the buffer.
    pub fn len(self: *const Buffer) usize {
        const total = self.length + self.writer_inst.end;
        return total - self.off;
    }

    /// Cap returns the capacity of the buffer's underlying storage.
    pub fn cap(self: *const Buffer) usize {
        return self.storage.len;
    }

    /// ToOwnedSlice returns the unread portion of the buffer as an owned slice,
    /// resetting the buffer.
    pub fn toOwnedSlice(self: *Buffer) Allocator.Error![]u8 {
        const total = self.length + self.writer_inst.end;
        if (total == 0 or total <= self.off) {
            self.deinit();
            return &[_]u8{};
        }
        const unread = self.storage[self.off..total];
        if (self.off == 0 and total == self.storage.len and !self.isBootstrap()) {
            const s = self.storage;
            self.storage = &.{};
            self.length = 0;
            self.off = 0;
            self.writer_inst.buffer = &.{};
            self.writer_inst.end = 0;
            return s;
        }
        const slice = try self.allocator.dupe(u8, unread);
        self.deinit();
        return slice;
    }

    /// Reset resets the buffer to be empty.
    pub fn reset(self: *Buffer) void {
        self.length = 0;
        self.off = 0;
        self.last_read_byte = false;
        self.writer_inst.end = 0;
        self.writer_inst.buffer = self.storage;
    }

    /// Truncate discards all but the first n unread bytes.
    pub fn truncate(self: *Buffer, n: usize) void {
        self.commitWriter();
        if (n == 0) {
            self.reset();
            return;
        }
        self.last_read_byte = false;
        if (n > self.len()) return;
        self.length = self.off + n;
        self.writer_inst.buffer = self.storage[self.length..];
        self.writer_inst.end = 0;
    }

    /// Grow grows the buffer's capacity, if necessary, to guarantee space for
    /// another n bytes.
    pub fn grow(self: *Buffer, n: usize) Allocator.Error!void {
        self.commitWriter();
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
            self.writer_inst.buffer = self.storage[self.length..];
            return;
        }

        const total = self.length;
        const needed = std.math.add(usize, total, n) catch return error.OutOfMemory;
        if (needed <= self.storage.len) return;

        if (self.storage.len == 0 or self.isBootstrap()) {
            if (needed <= small_buffer_size) {
                self.storage = &self.bootstrap;
                self.writer_inst.buffer = self.storage[self.length..];
                return;
            }
            const new_cap = @max(small_buffer_size * 2 + n, small_buffer_size);
            const new_storage = try self.allocator.alloc(u8, new_cap);
            if (total > 0) {
                @memcpy(new_storage[0..total], self.storage[0..total]);
            }
            self.storage = new_storage;
            self.writer_inst.buffer = self.storage[self.length..];
            return;
        }

        const new_cap = @max(self.storage.len * 2 + n, small_buffer_size);
        const new_storage = try self.allocator.realloc(self.storage, new_cap);
        self.storage = new_storage;
        self.writer_inst.buffer = self.storage[self.length..];
    }

    pub fn write(self: *Buffer, p: []const u8) Allocator.Error!usize {
        self.last_read_byte = false;
        self.commitWriter();
        try self.grow(p.len);
        @memcpy(self.storage[self.length .. self.length + p.len], p);
        self.length += p.len;
        self.writer_inst.buffer = self.storage[self.length..];
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
        self.commitWriter();
        self.last_read_byte = false;
        if (self.off >= self.length) {
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
        self.commitWriter();
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

    pub fn reader(self: *const Buffer) std.Io.Reader {
        return std.Io.Reader.fixed(self.bytes());
    }

    pub fn writer(self: *Buffer) *std.Io.Writer {
        self.commitWriter();
        if (self.storage.len == 0) {
            self.storage = &self.bootstrap;
        }
        self.writer_inst.buffer = self.storage[self.length..];
        self.writer_inst.end = 0;
        return &self.writer_inst;
    }

    /// readFrom reads data from r until EOF and appends it to the buffer.
    pub fn readFrom(self: *Buffer, r: *std.Io.Reader) anyerror!u64 {
        self.last_read_byte = false;
        const w = self.writer();
        const count = try r.stream(w, .unlimited);
        try w.flush();
        return @intCast(count);
    }

    /// writeTo writes data to w until the buffer is drained.
    pub fn writeTo(self: *Buffer, w: *std.Io.Writer) anyerror!u64 {
        self.commitWriter();
        const remaining = self.length - self.off;
        if (remaining == 0) return 0;
        try w.writeAll(self.storage[self.off..self.length]);
        self.reset();
        return @intCast(remaining);
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Buffer = @alignCast(@fieldParentPtr("writer_inst", w));
        if (w.end > 0) {
            self.length += w.end;
            w.end = 0;
        }
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            _ = self.write(slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            _ = self.write(pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        w.buffer = self.storage[self.length..];
        return total;
    }

    fn flushImpl(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Buffer = @alignCast(@fieldParentPtr("writer_inst", w));
        if (w.end > 0) {
            self.length += w.end;
            w.end = 0;
        }
        w.buffer = self.storage[self.length..];
    }

    fn rebaseImpl(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *Buffer = @alignCast(@fieldParentPtr("writer_inst", w));
        const to_preserve = @min(preserve, w.end);
        self.grow(capacity + @max(preserve, to_preserve)) catch return error.WriteFailed;
        self.length -= to_preserve;
        w.buffer = self.storage[self.length..];
        w.end = to_preserve;
    }
};

test "bytes.Buffer basic write and read" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    _ = try b.write("hello ");
    _ = try b.writeString("world");

    try testing.expectEqualStrings("hello world", b.string());
    try testing.expectEqual(@as(usize, 11), b.len());

    var out: [5]u8 = undefined;
    const n = try b.read(&out);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("hello", &out);
    try testing.expectEqualStrings(" world", b.string());

    const byte = try b.readByte();
    try testing.expectEqual(@as(u8, ' '), byte);

    try b.unreadByte();
    const byte2 = try b.readByte();
    try testing.expectEqual(@as(u8, ' '), byte2);
}

test "bytes.Buffer writer and reader" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    const w = b.writer();
    try w.writeAll("std.Io streaming to Buffer");
    try w.flush();

    try testing.expectEqualStrings("std.Io streaming to Buffer", b.string());

    var r = b.reader();
    const data = try r.take(6);
    try testing.expectEqualStrings("std.Io", data);
}

test "bytes.Buffer bootstrap avoids heap allocation for <= 64 bytes" {
    const testing = std.testing;
    var failing_alloc = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    const no_alloc = failing_alloc.allocator();

    var b = Buffer.init(no_alloc);
    defer b.deinit();

    const data64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try testing.expectEqual(@as(usize, 64), data64.len);

    _ = try b.write(data64);
    try testing.expectEqualStrings(data64, b.string());
    try testing.expectEqual(@as(usize, 64), b.cap());
}

test "bytes.Buffer grow beyond bootstrap switches to heap" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    const data64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    _ = try b.write(data64);
    try testing.expect(b.isBootstrap());

    _ = try b.write("overflow");
    try testing.expect(!b.isBootstrap());
    try testing.expect(b.cap() >= 72);
    try testing.expectEqualStrings(data64 ++ "overflow", b.string());
}

test "bytes.Buffer toOwnedSlice from bootstrap allocates owned slice" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    _ = try b.write("short bootstrap slice");
    try testing.expect(b.isBootstrap());

    const owned = try b.toOwnedSlice();
    defer testing.allocator.free(owned);

    try testing.expectEqualStrings("short bootstrap slice", owned);
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "bytes.Buffer unflushed writer committed before read/truncate/grow/writeTo" {
    const testing = std.testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    const w = b.writer();
    try w.writeAll("hello world");
    // Read without explicit flush
    var tmp: [5]u8 = undefined;
    const n = try b.read(&tmp);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("hello", &tmp);

    // Write again via writer() without flush, then grow and readByte
    const w2 = b.writer();
    try w2.writeAll("!");
    try b.grow(32);
    try testing.expectEqualStrings(" world!", b.string());
    try testing.expectEqual(@as(u8, ' '), try b.readByte());

    // Truncate with unflushed writer bytes
    const w3 = b.writer();
    try w3.writeAll("extra");
    b.truncate(6);
    try testing.expectEqualStrings("world!", b.string());

    // writeTo with unflushed writer bytes
    const w4 = b.writer();
    try w4.writeAll("!!");
    var dst = Buffer.init(testing.allocator);
    defer dst.deinit();
    const written = try b.writeTo(dst.writer());
    try testing.expectEqual(@as(u64, 8), written);
    try testing.expectEqualStrings("world!!!", dst.string());
}
