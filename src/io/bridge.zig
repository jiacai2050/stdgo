const std = @import("std");
const io = @import("io.zig");

/// FromZigReader adapts Zig 0.17's standard `std.Io.Reader` into a Go-style `stdgo.io.Reader`.
pub const FromZigReader = struct {
    zig_reader: *std.Io.Reader,

    pub fn init(zig_reader: *std.Io.Reader) FromZigReader {
        return .{ .zig_reader = zig_reader };
    }

    pub fn reader(self: *FromZigReader) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *FromZigReader = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return 0;
        const n = self.zig_reader.readSliceShort(buf) catch |err| switch (err) {
            error.EndOfStream => return io.Error.EndOfStream,
            else => return err,
        };
        if (n == 0) return io.Error.EndOfStream;
        return n;
    }
};

/// FromZigWriter adapts Zig 0.17's standard `std.Io.Writer` into a Go-style `stdgo.io.Writer`.
pub const FromZigWriter = struct {
    zig_writer: *std.Io.Writer,

    pub fn init(zig_writer: *std.Io.Writer) FromZigWriter {
        return .{ .zig_writer = zig_writer };
    }

    pub fn writer(self: *FromZigWriter) io.Writer {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeImpl,
            },
        };
    }

    pub fn flush(self: *FromZigWriter) anyerror!void {
        return self.zig_writer.flush();
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *FromZigWriter = @ptrCast(@alignCast(ctx));
        return self.zig_writer.write(bytes);
    }
};

/// ToZigReader bridges a Go-style `stdgo.io.Reader` into a Zig 0.17 `std.Io.Reader`.
pub const ToZigReader = struct {
    reader: std.Io.Reader,
    src: io.Reader,

    pub const vtable: std.Io.Reader.VTable = .{
        .stream = streamImpl,
    };

    pub fn init(src: io.Reader, buffer: []u8) ToZigReader {
        return .{
            .reader = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .src = src,
        };
    }

    fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ToZigReader = @fieldParentPtr("reader", r);
        var tmp: [4096]u8 = undefined;
        const max_len = if (limit == .unlimited) tmp.len else @min(tmp.len, @backingInt(limit));
        if (max_len == 0) return 0;

        const n = self.src.read(tmp[0..max_len]) catch |err| switch (err) {
            io.Error.EndOfStream => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        w.writeAll(tmp[0..n]) catch return error.WriteFailed;
        return n;
    }
};

/// ToZigWriter bridges a Go-style `stdgo.io.Writer` into a Zig 0.17 `std.Io.Writer`.
pub const ToZigWriter = struct {
    writer: std.Io.Writer,
    dst: io.Writer,

    pub const vtable: std.Io.Writer.VTable = .{
        .drain = drainImpl,
    };

    pub fn init(dst: io.Writer, buffer: []u8) ToZigWriter {
        return .{
            .writer = .{
                .vtable = &vtable,
                .buffer = buffer,
                .end = 0,
            },
            .dst = dst,
        };
    }

    fn drainImpl(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ToZigWriter = @fieldParentPtr("writer", w);
        if (w.end > 0) {
            self.dst.writeAll(w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var total: usize = 0;
        for (data) |slice| {
            if (slice.len > 0) {
                self.dst.writeAll(slice) catch return error.WriteFailed;
                total += slice.len;
            }
        }
        if (splat > 0 and data.len > 0) {
            const last = data[data.len - 1];
            if (last.len > 0) {
                const pad_byte = last[last.len - 1];
                var i: usize = 0;
                while (i < splat) : (i += 1) {
                    self.dst.writeByte(pad_byte) catch return error.WriteFailed;
                }
            }
        }
        return total;
    }
};

pub fn fromZigReader(r: *std.Io.Reader) FromZigReader {
    return FromZigReader.init(r);
}

pub fn fromZigWriter(w: *std.Io.Writer) FromZigWriter {
    return FromZigWriter.init(w);
}

pub fn toZigReader(r: io.Reader, buffer: []u8) ToZigReader {
    return ToZigReader.init(r, buffer);
}

pub fn toZigWriter(w: io.Writer, buffer: []u8) ToZigWriter {
    return ToZigWriter.init(w, buffer);
}

test "bridge fromZigReader" {
    var fixed = std.Io.Reader.fixed("Hello from Zig 0.17");
    var bridge = fromZigReader(&fixed);
    const r = bridge.reader();

    var buf: [32]u8 = undefined;
    const n = try r.read(&buf);
    try std.testing.expectEqualStrings("Hello from Zig 0.17", buf[0..n]);

    const res = r.read(&buf);
    try std.testing.expectError(io.Error.EndOfStream, res);
}

test "bridge toZigReader and fromZigWriter" {
    // Custom mock go reader
    const MockGoReader = struct {
        data: []const u8,
        pos: usize = 0,

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.pos >= self.data.len) return io.Error.EndOfStream;
            const available = self.data.len - self.pos;
            const n = @min(available, buf.len);
            @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }

        fn reader(self: *@This()) io.Reader {
            return .{
                .ptr = self,
                .vtable = &.{ .read = read },
            };
        }
    };

    var mock_r = MockGoReader{ .data = "Bridge Data Testing" };
    var r_buf: [64]u8 = undefined;
    var to_zig_r = toZigReader(mock_r.reader(), &r_buf);

    var out_buf: [64]u8 = undefined;
    const n = try to_zig_r.reader.readSliceShort(&out_buf);
    try std.testing.expectEqualStrings("Bridge Data Testing", out_buf[0..n]);
}

test "bridge toZigWriter" {
    const bytes = @import("../bytes.zig");
    var b = bytes.Buffer.init(std.testing.allocator);
    defer b.deinit();

    var writer_buf: [32]u8 = undefined;
    var to_zig_w = toZigWriter(b.writer(), &writer_buf);

    try to_zig_w.writer.writeAll("Streamed through Zig Writer");
    try to_zig_w.writer.flush();

    try std.testing.expectEqualStrings("Streamed through Zig Writer", b.string());
}
