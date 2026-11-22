const std = @import("std");
const io = @import("../io.zig");
const encoding = @import("../encoding.zig");
const binary = encoding.binary;
const flate = @import("flate.zig");
const Allocator = std.mem.Allocator;

pub const gzip_id1: u8 = 0x1f;
pub const gzip_id2: u8 = 0x8b;
pub const gzip_deflate: u8 = 8;

pub const flag_text: u8 = 1 << 0;
pub const flag_hcrc: u8 = 1 << 1;
pub const flag_extra: u8 = 1 << 2;
pub const flag_name: u8 = 1 << 3;
pub const flag_comment: u8 = 1 << 4;

pub const Error = error{
    InvalidHeader,
    ChecksumMismatch,
    SizeMismatch,
    UnexpectedEof,
} || flate.Error || Allocator.Error || std.Io.Writer.Error;

pub const Header = struct {
    name: []const u8 = "",
    mod_time: u32 = 0,
    os: u8 = 255,
};

pub const Writer = struct {
    allocator: Allocator,
    underlying: *io.Writer,
    flate_writer: *flate.Writer,
    hasher: std.hash.Crc32 = std.hash.Crc32.init(),
    uncompressed_size: u32 = 0,
    closed: bool = false,

    pub fn init(allocator: Allocator, w: *io.Writer, header: Header) anyerror!Writer {
        return initWithLevel(allocator, w, header, flate.DefaultCompression);
    }

    pub fn initWithLevel(
        allocator: Allocator,
        w: *io.Writer,
        header: Header,
        level: i32,
    ) anyerror!Writer {
        // Write 10-byte fixed header
        var hdr: [10]u8 = undefined;
        hdr[0] = gzip_id1;
        hdr[1] = gzip_id2;
        hdr[2] = gzip_deflate;
        var flg: u8 = 0;
        if (header.name.len > 0) {
            flg |= flag_name;
        }
        hdr[3] = flg;
        try binary.LittleEndian.writeU32(hdr[4..8], header.mod_time);
        hdr[8] = 0; // xfl
        hdr[9] = header.os;

        try w.writeAll(&hdr);

        if (header.name.len > 0) {
            try w.writeAll(header.name);
            try w.writeByte(0); // null terminator
        }

        const fw = try flate.newWriter(allocator, w, level);

        return .{
            .allocator = allocator,
            .underlying = w,
            .flate_writer = fw,
            .hasher = std.hash.Crc32.init(),
            .uncompressed_size = 0,
            .closed = false,
        };
    }

    pub fn write(self: *Writer, data: []const u8) anyerror!usize {
        if (data.len == 0) return 0;
        self.hasher.update(data);
        self.uncompressed_size +%= @intCast(data.len);
        try self.flate_writer.writer().writeAll(data);
        return data.len;
    }

    pub fn flush(self: *Writer) anyerror!void {
        try self.flate_writer.flush();
    }

    pub fn close(self: *Writer) anyerror!void {
        if (self.closed) return;

        try self.flate_writer.close();

        // Write 8-byte trailer: CRC-32 (4) + ISIZE (4)
        var trailer: [8]u8 = undefined;
        try binary.LittleEndian.writeU32(trailer[0..4], self.hasher.final());
        try binary.LittleEndian.writeU32(trailer[4..8], self.uncompressed_size);
        try self.underlying.writeAll(&trailer);
        try self.underlying.flush();

        self.closed = true;
    }

    pub fn deinit(self: *Writer) void {
        self.flate_writer.deinit();
    }
};

pub const Reader = struct {
    allocator: Allocator,
    r: *io.Reader,
    header: Header,
    window_buf: []u8,
    decompress: std.compress.flate.Decompress,
    hasher: std.hash.Crc32 = std.hash.Crc32.init(),
    uncompressed_size: u32 = 0,
    eof: bool = false,

    pub fn init(allocator: Allocator, r: *io.Reader) anyerror!Reader {
        var hdr: [10]u8 = undefined;
        const n_hdr = try io.readFull(r, &hdr);
        if (n_hdr < hdr.len) return Error.UnexpectedEof;

        if (hdr[0] != gzip_id1 or hdr[1] != gzip_id2 or hdr[2] != gzip_deflate) {
            return Error.InvalidHeader;
        }

        const flg = hdr[3];
        const mtime = try binary.LittleEndian.readU32(hdr[4..8]);
        const os = hdr[9];

        // Skip extra field if present
        if ((flg & flag_extra) != 0) {
            var xlen_buf: [2]u8 = undefined;
            if (try io.readFull(r, &xlen_buf) < 2) return Error.UnexpectedEof;
            const xlen = try binary.LittleEndian.readU16(&xlen_buf);
            var skipped: usize = 0;
            var dummy: [64]u8 = undefined;
            while (skipped < xlen) {
                const to_read = @min(dummy.len, xlen - skipped);
                const n = try io.readFull(r, dummy[0..to_read]);
                if (n < to_read) return Error.UnexpectedEof;
                skipped += n;
            }
        }

        // If filename present, read until null
        var name_str: []const u8 = "";
        if ((flg & flag_name) != 0) {
            var name_list = std.ArrayList(u8).empty;
            errdefer name_list.deinit(allocator);
            while (true) {
                var b: [1]u8 = undefined;
                if (try io.readFull(r, &b) < 1) return Error.UnexpectedEof;
                if (b[0] == 0) break;
                try name_list.append(allocator, b[0]);
            }
            name_str = try name_list.toOwnedSlice(allocator);
        }
        errdefer if (name_str.len > 0) allocator.free(name_str);

        // Skip comment if present
        if ((flg & flag_comment) != 0) {
            while (true) {
                var b: [1]u8 = undefined;
                if (try io.readFull(r, &b) < 1) return Error.UnexpectedEof;
                if (b[0] == 0) break;
            }
        }

        // Skip header CRC16 if present
        if ((flg & flag_hcrc) != 0) {
            var hcrc: [2]u8 = undefined;
            if (try io.readFull(r, &hcrc) < 2) return Error.UnexpectedEof;
        }

        const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(window_buf);

        return Reader{
            .allocator = allocator,
            .r = r,
            .header = .{
                .name = name_str,
                .mod_time = mtime,
                .os = os,
            },
            .window_buf = window_buf,
            .decompress = std.compress.flate.Decompress.init(r, .raw, window_buf),
            .hasher = std.hash.Crc32.init(),
            .uncompressed_size = 0,
            .eof = false,
        };
    }

    pub fn read(self: *Reader, buf: []u8) anyerror!usize {
        if (self.eof or buf.len == 0) return 0;
        const n = try self.decompress.reader.readSliceShort(buf);
        if (n > 0) {
            self.hasher.update(buf[0..n]);
            self.uncompressed_size +%= @intCast(n);
            return n;
        }

        // Raw deflate stream ended, now parse and verify 8-byte trailer
        self.eof = true;
        var trailer: [8]u8 = undefined;
        const n_tr = try io.readFull(self.r, &trailer);
        if (n_tr < trailer.len) return Error.UnexpectedEof;

        const expected_crc = try binary.LittleEndian.readU32(trailer[0..4]);
        const expected_size = try binary.LittleEndian.readU32(trailer[4..8]);

        if (self.hasher.final() != expected_crc) return Error.ChecksumMismatch;
        if (self.uncompressed_size != expected_size) return Error.SizeMismatch;

        return 0;
    }

    /// Read reads decompressed content and verifies CRC32 and trailer upon EOF.
    pub fn readAllAlloc(self: *Reader, alloc: Allocator) anyerror![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(alloc);

        var buf: [4096]u8 = undefined;
        while (true) {
            const nr = try self.read(&buf);
            if (nr == 0) break;
            try list.appendSlice(alloc, buf[0..nr]);
        }

        return try list.toOwnedSlice(alloc);
    }

    pub fn deinit(self: *Reader) void {
        if (self.header.name.len > 0) {
            self.allocator.free(self.header.name);
        }
        self.allocator.free(self.window_buf);
    }
};

test "compress.gzip write and readroundtrip" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var gz_buf = bytes.Buffer.init(testing.allocator);
    defer gz_buf.deinit();

    const original_text =
        "Standard Go gzip implementation in Zig 0.17! With real DEFLATE stream compression.";

    // 1. Write gzip
    var gw = try Writer.init(testing.allocator, gz_buf.writer(), .{
        .name = "example.txt",
        .mod_time = 1234567,
    });
    defer gw.deinit();
    _ = try gw.write(original_text);
    try gw.close();

    // Verify it actually compressed and generated valid gzip header
    try testing.expect(gz_buf.len() > 18);
    try testing.expectEqual(@as(u8, gzip_id1), gz_buf.bytes()[0]);
    try testing.expectEqual(@as(u8, gzip_id2), gz_buf.bytes()[1]);
    try testing.expectEqual(@as(u8, gzip_deflate), gz_buf.bytes()[2]);

    // 2. Read gzip
    var br = bytes.Reader.init(gz_buf.bytes());
    var gr = try Reader.init(testing.allocator, br.reader());
    defer gr.deinit();

    try testing.expectEqualStrings("example.txt", gr.header.name);
    try testing.expectEqual(@as(u32, 1234567), gr.header.mod_time);

    const decompressed = try gr.readAllAlloc(testing.allocator);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings(original_text, decompressed);
}

test "compress.gzip read external standard gzip payload" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    // Standard RFC 1952 payload compressing "Hello world\n"
    const external_gzip = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, // gzip header
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate block
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00, // crc32 + isize (12 bytes: "Hello world\n")
    };

    var br = bytes.Reader.init(&external_gzip);
    var gr = try Reader.init(testing.allocator, br.reader());
    defer gr.deinit();

    const decompressed = try gr.readAllAlloc(testing.allocator);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings("Hello world\n", decompressed);
}
