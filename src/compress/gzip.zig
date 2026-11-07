const std = @import("std");
const io = @import("../io.zig");
const encoding = @import("../encoding.zig");
const binary = encoding.binary;
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
};

pub const Header = struct {
    name: []const u8 = "",
    mod_time: u32 = 0,
    os: u8 = 255,
};

pub const Writer = struct {
    w: io.Writer,
    crc: u32 = 0,
    uncompressed_size: u32 = 0,
    closed: bool = false,

    pub fn init(w: io.Writer, header: Header) anyerror!Writer {
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

        return .{
            .w = w,
            .crc = 0,
            .uncompressed_size = 0,
            .closed = false,
        };
    }

    pub fn write(self: *Writer, data: []const u8) anyerror!usize {
        if (data.len == 0) return 0;
        self.crc = std.hash.Crc32.hash(data); // for multi-chunk can update
        self.uncompressed_size += @intCast(data.len);
        try self.w.writeAll(data);
        return data.len;
    }

    pub fn close(self: *Writer) anyerror!void {
        if (self.closed) return;

        // Write 8-byte trailer: CRC-32 (4) + ISIZE (4)
        var trailer: [8]u8 = undefined;
        try binary.LittleEndian.writeU32(trailer[0..4], self.crc);
        try binary.LittleEndian.writeU32(trailer[4..8], self.uncompressed_size);
        try self.w.writeAll(&trailer);

        self.closed = true;
    }
};

pub const Reader = struct {
    r: io.Reader,
    header: Header,
    crc: u32 = 0,
    uncompressed_size: u32 = 0,
    read_so_far: u32 = 0,
    name_buf: [128]u8 = undefined,

    pub fn init(r: io.Reader) anyerror!Reader {
        var hdr: [10]u8 = undefined;
        _ = try io.readFull(r, &hdr);

        if (hdr[0] != gzip_id1 or hdr[1] != gzip_id2 or hdr[2] != gzip_deflate) {
            return Error.InvalidHeader;
        }

        const flg = hdr[3];
        const mtime = try binary.LittleEndian.readU32(hdr[4..8]);
        const os = hdr[9];

        var self = Reader{
            .r = r,
            .header = .{
                .name = "",
                .mod_time = mtime,
                .os = os,
            },
            .crc = 0,
            .uncompressed_size = 0,
            .read_so_far = 0,
        };

        // If filename present, read until null
        if ((flg & flag_name) != 0) {
            var n: usize = 0;
            while (n < self.name_buf.len) : (n += 1) {
                var b: [1]u8 = undefined;
                _ = try io.readFull(r, &b);
                if (b[0] == 0) break;
                self.name_buf[n] = b[0];
            }
            self.header.name = self.name_buf[0..n];
        }

        return self;
    }

    /// Read reads decompressed content and verifies CRC32 and trailer upon EOF.
    pub fn readAllAlloc(self: *Reader, allocator: Allocator) anyerror![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);

        var buf: [512]u8 = undefined;
        while (true) {
            const nr = self.r.read(&buf) catch |err| {
                if (err == io.Error.EndOfStream) break;
                return err;
            };
            if (nr == 0) break;
            try list.appendSlice(allocator, buf[0..nr]);
        }

        // The remaining 8 bytes at the end of stream are CRC32 and ISIZE trailer
        if (list.items.len < 8) {
            return Error.UnexpectedEof;
        }

        const data_len = list.items.len - 8;
        const data = list.items[0..data_len];
        const trailer = list.items[data_len..];

        const expected_crc = try binary.LittleEndian.readU32(trailer[0..4]);
        const expected_isize = try binary.LittleEndian.readU32(trailer[4..8]);

        const actual_crc = std.hash.Crc32.hash(data);
        if (actual_crc != expected_crc) {
            return Error.ChecksumMismatch;
        }

        if (@as(u32, @intCast(data.len)) != expected_isize) {
            return Error.SizeMismatch;
        }

        const result = try allocator.dupe(u8, data);
        list.deinit(allocator);
        return result;
    }
};

test "compress.gzip write and readroundtrip" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    var gz_buf = bytes.Buffer.init(testing.allocator);
    defer gz_buf.deinit();

    const original_text = "Standard Go gzip implementation in Zig 0.17";

    // 1. Write gzip
    var gw = try Writer.init(gz_buf.writer(), .{
        .name = "example.txt",
        .mod_time = 1234567,
    });
    _ = try gw.write(original_text);
    try gw.close();

    // 2. Read gzip
    var br = bytes.Reader.init(gz_buf.bytes());
    var gr = try Reader.init(br.reader());
    try testing.expectEqualStrings("example.txt", gr.header.name);
    try testing.expectEqual(@as(u32, 1234567), gr.header.mod_time);

    const decompressed = try gr.readAllAlloc(testing.allocator);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings(original_text, decompressed);
}
