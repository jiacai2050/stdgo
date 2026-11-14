const std = @import("std");
const io = @import("../../io.zig");
const encoding = @import("../../encoding.zig");
const binary = encoding.binary;
const zip_struct = @import("struct.zig");
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    allocator: Allocator,
    w: *io.Writer,
    offset: u32 = 0,
    files: std.ArrayList(zip_struct.FileHeader),

    pub fn init(allocator: Allocator, w: *io.Writer) Writer {
        return .{
            .allocator = allocator,
            .w = w,
            .offset = 0,
            .files = std.ArrayList(zip_struct.FileHeader).empty,
        };
    }

    pub fn deinit(self: *Writer) void {
        for (self.files.items) |header| {
            self.allocator.free(header.name);
            if (header.comment.len > 0) {
                self.allocator.free(header.comment);
            }
        }
        self.files.deinit(self.allocator);
    }

    /// WriteFile stores a file directly into the ZIP archive.
    pub fn writeFile(self: *Writer, name: []const u8, data: []const u8, method: zip_struct.Method) anyerror!void {
        const local_offset = self.offset;
        const crc = std.hash.Crc32.hash(data);

        if (method != .store) {
            return error.UnsupportedMethod;
        }

        const final_data = data;
        const comp_method = method;

        const uncomp_size: u32 = @intCast(data.len);
        const comp_size: u32 = @intCast(final_data.len);

        // Write Local File Header (30 bytes)
        var hdr: [30]u8 = undefined;
        try binary.LittleEndian.writeU32(hdr[0..4], zip_struct.file_header_signature);
        try binary.LittleEndian.writeU16(hdr[4..6], 20); // version needed
        try binary.LittleEndian.writeU16(hdr[6..8], 0); // flags
        try binary.LittleEndian.writeU16(hdr[8..10], @intFromEnum(comp_method));
        try binary.LittleEndian.writeU16(hdr[10..12], 0); // mod time
        try binary.LittleEndian.writeU16(hdr[12..14], 0); // mod date
        try binary.LittleEndian.writeU32(hdr[14..18], crc);
        try binary.LittleEndian.writeU32(hdr[18..22], comp_size);
        try binary.LittleEndian.writeU32(hdr[22..26], uncomp_size);
        try binary.LittleEndian.writeU16(hdr[26..28], @intCast(name.len));
        try binary.LittleEndian.writeU16(hdr[28..30], 0); // extra len

        try self.w.writeAll(&hdr);
        try self.w.writeAll(name);
        try self.w.writeAll(final_data);

        self.offset += @intCast(30 + name.len + final_data.len);

        const header = zip_struct.FileHeader{
            .name = try self.allocator.dupe(u8, name),
            .method = comp_method,
            .crc32 = crc,
            .compressed_size = comp_size,
            .uncompressed_size = uncomp_size,
            .offset = local_offset,
        };
        try self.files.append(self.allocator, header);
    }

    /// Close writes the Central Directory and End of Central Directory record.
    pub fn close(self: *Writer) anyerror!void {
        const cd_start = self.offset;

        // Write Central Directory Headers (46 bytes + name)
        for (self.files.items) |header| {
            var cdh: [46]u8 = undefined;
            try binary.LittleEndian.writeU32(cdh[0..4], zip_struct.directory_header_signature);
            try binary.LittleEndian.writeU16(cdh[4..6], 20); // version made by
            try binary.LittleEndian.writeU16(cdh[6..8], 20); // version needed
            try binary.LittleEndian.writeU16(cdh[8..10], 0); // flags
            try binary.LittleEndian.writeU16(cdh[10..12], @intFromEnum(header.method));
            try binary.LittleEndian.writeU16(cdh[12..14], 0); // mod time
            try binary.LittleEndian.writeU16(cdh[14..16], 0); // mod date
            try binary.LittleEndian.writeU32(cdh[16..20], header.crc32);
            try binary.LittleEndian.writeU32(cdh[20..24], header.compressed_size);
            try binary.LittleEndian.writeU32(cdh[24..28], header.uncompressed_size);
            try binary.LittleEndian.writeU16(cdh[28..30], @intCast(header.name.len));
            try binary.LittleEndian.writeU16(cdh[30..32], 0); // extra len
            try binary.LittleEndian.writeU16(cdh[32..34], 0); // comment len
            try binary.LittleEndian.writeU16(cdh[34..36], 0); // disk start
            try binary.LittleEndian.writeU16(cdh[36..38], 0); // internal attr
            try binary.LittleEndian.writeU32(cdh[38..42], 0); // external attr
            try binary.LittleEndian.writeU32(cdh[42..46], header.offset);

            try self.w.writeAll(&cdh);
            try self.w.writeAll(header.name);
            self.offset += @intCast(46 + header.name.len);
        }

        const cd_size = self.offset - cd_start;

        // Write EOCD (22 bytes)
        var eocd: [22]u8 = undefined;
        try binary.LittleEndian.writeU32(eocd[0..4], zip_struct.directory_end_signature);
        try binary.LittleEndian.writeU16(eocd[4..6], 0); // disk num
        try binary.LittleEndian.writeU16(eocd[6..8], 0); // start disk
        try binary.LittleEndian.writeU16(eocd[8..10], @intCast(self.files.items.len));
        try binary.LittleEndian.writeU16(eocd[10..12], @intCast(self.files.items.len));
        try binary.LittleEndian.writeU32(eocd[12..16], cd_size);
        try binary.LittleEndian.writeU32(eocd[16..20], cd_start);
        try binary.LittleEndian.writeU16(eocd[20..22], 0); // comment len

        try self.w.writeAll(&eocd);
        self.offset += 22;
        try self.w.flush();
    }
};
