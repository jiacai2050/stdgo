//! Port of Go's `compress/flate` package to Zig 0.17.
//!
//! Implements RFC 1951 DEFLATE compressed data format wrapping native `std.Io` streams.

const std = @import("std");
const flate_impl = std.compress.flate;
const io = @import("../io.zig");
const Allocator = std.mem.Allocator;

pub const NoCompression: i32 = 0;
pub const BestSpeed: i32 = 1;
pub const BestCompression: i32 = 9;
pub const DefaultCompression: i32 = -1;
pub const HuffmanOnly: i32 = -2;

pub const Error = error{
    BadHeader,
    ChecksumMismatch,
    InvalidCompressionLevel,
    UnexpectedEndOfStream,
} || flate_impl.Container.Error || Allocator.Error || std.Io.Writer.Error;

pub const Writer = struct {
    allocator: Allocator,
    underlying: *io.Writer,
    window_buf: []u8,
    out_buf: []u8,
    out_writer: std.Io.Writer = undefined,
    mode: Mode = undefined,
    closed: bool = false,

    const Mode = union(enum) {
        normal: flate_impl.Compress,
        raw: flate_impl.Compress.Raw,
        huffman: flate_impl.Compress.Huffman,
    };

    const out_vtable: std.Io.Writer.VTable = .{
        .drain = outDrain,
        .flush = outFlush,
    };

    fn outDrain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("out_writer", w));
        if (w.end > 0) {
            self.underlying.writeAll(w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.underlying.writeAll(slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.underlying.writeAll(pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }

    fn outFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Writer = @alignCast(@fieldParentPtr("out_writer", w));
        try self.outFlushInternal();
    }

    fn outFlushInternal(self: *Writer) std.Io.Writer.Error!void {
        if (self.out_writer.end > 0) {
            const buf = self.out_writer.buffer[0..self.out_writer.end];
            self.underlying.writeAll(buf) catch return error.WriteFailed;
            self.out_writer.end = 0;
        }
        self.underlying.flush() catch return error.WriteFailed;
    }

    pub fn deinit(self: *Writer) void {
        self.allocator.free(self.window_buf);
        self.allocator.free(self.out_buf);
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Writer returns the stream to write uncompressed bytes to.
    pub fn writer(self: *Writer) *io.Writer {
        return switch (self.mode) {
            .normal => |*c| &c.writer,
            .raw => |*r| &r.writer,
            .huffman => |*h| &h.writer,
        };
    }

    /// Flush flushes any pending compressed data to the underlying writer.
    pub fn flush(self: *Writer) !void {
        try self.writer().flush();
        try self.outFlushInternal();
    }

    /// Close closes the writer, writing final blocks.
    pub fn close(self: *Writer) !void {
        if (self.closed) return;
        self.closed = true;

        switch (self.mode) {
            .normal => |*c| try c.finish(),
            .raw => |*r| try r.finish(),
            .huffman => |*h| try h.finish(),
        }
        try self.outFlushInternal();
    }
};

pub const Reader = struct {
    allocator: Allocator,
    window_buf: []u8,
    decompress: flate_impl.Decompress,

    pub fn reader(self: *Reader) *io.Reader {
        return &self.decompress.reader;
    }

    pub fn close(self: *Reader) void {
        _ = self;
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.window_buf);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

/// NewWriter returns a new Writer compressing data at the given level.
pub fn newWriter(allocator: Allocator, w: *io.Writer, level: i32) Error!*Writer {
    const self = try allocator.create(Writer);
    errdefer allocator.destroy(self);

    const window_buf = try allocator.alloc(u8, flate_impl.max_window_len);
    errdefer allocator.free(window_buf);

    const out_buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(out_buf);

    self.* = .{
        .allocator = allocator,
        .underlying = w,
        .window_buf = window_buf,
        .out_buf = out_buf,
        .out_writer = .{
            .vtable = &Writer.out_vtable,
            .buffer = out_buf,
            .end = 0,
        },
        .closed = false,
    };

    if (level == NoCompression) {
        const r = try flate_impl.Compress.Raw.init(&self.out_writer, window_buf, .raw);
        self.mode = .{ .raw = r };
    } else if (level == HuffmanOnly) {
        const h = try flate_impl.Compress.Huffman.init(&self.out_writer, window_buf, .raw);
        self.mode = .{ .huffman = h };
    } else {
        const opts: flate_impl.Compress.Options = switch (level) {
            1 => flate_impl.Compress.Options.level_1,
            2 => flate_impl.Compress.Options.level_2,
            3 => flate_impl.Compress.Options.level_3,
            4 => flate_impl.Compress.Options.level_4,
            5 => flate_impl.Compress.Options.level_5,
            DefaultCompression, 6 => flate_impl.Compress.Options.level_6,
            7 => flate_impl.Compress.Options.level_7,
            8 => flate_impl.Compress.Options.level_8,
            9 => flate_impl.Compress.Options.level_9,
            else => return Error.InvalidCompressionLevel,
        };
        const n = try flate_impl.Compress.init(&self.out_writer, window_buf, .raw, opts);
        self.mode = .{ .normal = n };
    }

    return self;
}

/// NewReader returns a new Reader decompressing data from r.
pub fn newReader(allocator: Allocator, r: *io.Reader) Error!*Reader {
    const self = try allocator.create(Reader);
    errdefer allocator.destroy(self);

    const window_buf = try allocator.alloc(u8, flate_impl.max_window_len);
    errdefer allocator.free(window_buf);

    self.* = .{
        .allocator = allocator,
        .window_buf = window_buf,
        .decompress = flate_impl.Decompress.init(r, .raw, window_buf),
    };
    return self;
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "compress.flate: raw deflate round-trip" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const original_text =
        "Raw RFC 1951 Deflate bitstream in Zig 0.17! Repeating pattern: " ++
        "abcdefg 1234567 abcdefg 1234567";

    var comp_buf = bytes.Buffer.init(testing.allocator);
    defer comp_buf.deinit();

    // 1. Compress
    var fw = try newWriter(testing.allocator, comp_buf.writer(), DefaultCompression);
    defer fw.deinit();

    try fw.writer().writeAll(original_text);
    try fw.close();

    try testing.expect(comp_buf.len() > 0);

    // 2. Decompress
    var r = bytes.Reader.init(comp_buf.bytes());
    var fr = try newReader(testing.allocator, r.reader());
    defer fr.deinit();

    var decomp_buf = bytes.Buffer.init(testing.allocator);
    defer decomp_buf.deinit();

    _ = try io.copy(decomp_buf.writer(), fr.reader());

    try testing.expectEqualStrings(original_text, decomp_buf.string());
}

test "compress.flate: reader readSliceShort and takeByte" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const original = "Hello flate window buffer test! Repeating: abcdefghij abcdefghij";
    var comp_buf = bytes.Buffer.init(testing.allocator);
    defer comp_buf.deinit();

    var fw = try newWriter(testing.allocator, comp_buf.writer(), DefaultCompression);
    defer fw.deinit();
    try fw.writer().writeAll(original);
    try fw.close();

    var r = bytes.Reader.init(comp_buf.bytes());
    var fr = try newReader(testing.allocator, r.reader());
    defer fr.deinit();

    const first = try fr.reader().takeByte();
    try testing.expectEqual(@as(u8, 'H'), first);

    var out: [128]u8 = undefined;
    out[0] = first;
    var total: usize = 1;
    while (total < out.len) {
        const n = try fr.reader().readSliceShort(out[total..]);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqualStrings(original, out[0..total]);
}
