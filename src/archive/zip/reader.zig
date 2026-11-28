const std = @import("std");
const io = @import("../../io.zig");
const encoding = @import("../../encoding.zig");
const binary = encoding.binary;
const zip_struct = @import("struct.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    FormatError,
    ChecksumError,
    UnsupportedMethod,
};

pub const File = struct {
    header: zip_struct.FileHeader,
    zip_data: []const u8,

    /// Open decompresses the file and returns its content.
    /// Caller owns returned memory.
    pub fn open(self: *const File, allocator: Allocator) anyerror![]u8 {
        const off: u64 = self.header.offset;
        const hdr_end = std.math.add(u64, off, 30) catch return Error.FormatError;
        if (hdr_end > self.zip_data.len) return Error.FormatError;
        const off_usize: usize = @intCast(off);

        const sig = try binary.LittleEndian.readU32(self.zip_data[off_usize .. off_usize + 4]);
        if (sig != zip_struct.file_header_signature) return Error.FormatError;

        const name_len: u64 = try binary.LittleEndian.readU16(self.zip_data[off_usize + 26 .. off_usize + 28]);
        const extra_len: u64 = try binary.LittleEndian.readU16(self.zip_data[off_usize + 28 .. off_usize + 30]);

        const after_name = std.math.add(u64, hdr_end, name_len) catch return Error.FormatError;
        const data_start_u64 = std.math.add(u64, after_name, extra_len) catch return Error.FormatError;
        const data_end_u64 = std.math.add(u64, data_start_u64, self.header.compressed_size) catch return Error.FormatError;
        if (data_end_u64 > self.zip_data.len) return Error.FormatError;

        const data_start: usize = @intCast(data_start_u64);
        const data_end: usize = @intCast(data_end_u64);
        const comp_bytes = self.zip_data[data_start..data_end];

        if (self.header.method != .store) {
            return Error.UnsupportedMethod;
        }

        const result = try allocator.dupe(u8, comp_bytes);

        // Verify CRC32
        const crc = std.hash.Crc32.hash(result);
        if (crc != self.header.crc32) {
            allocator.free(result);
            return Error.ChecksumError;
        }

        return result;
    }
};

pub const Reader = struct {
    allocator: Allocator,
    data: []const u8,
    file_list: std.ArrayList(File),

    pub fn init(allocator: Allocator, zip_bytes: []const u8) anyerror!Reader {
        if (zip_bytes.len < zip_struct.directory_end_len) {
            return Error.FormatError;
        }

        // Find EOCD
        var eocd_pos: ?usize = null;
        var i: usize = zip_bytes.len - zip_struct.directory_end_len;
        while (true) : (i -= 1) {
            const sig = binary.LittleEndian.readU32(zip_bytes[i .. i + 4]) catch 0;
            if (sig == zip_struct.directory_end_signature) {
                eocd_pos = i;
                break;
            }
            if (i == 0) break;
        }

        const eocd = eocd_pos orelse return Error.FormatError;
        const total_entries = try binary.LittleEndian.readU16(zip_bytes[eocd + 10 .. eocd + 12]);
        const cd_size: u64 = try binary.LittleEndian.readU32(zip_bytes[eocd + 12 .. eocd + 16]);
        const cd_offset: u64 = try binary.LittleEndian.readU32(zip_bytes[eocd + 16 .. eocd + 20]);

        const cd_end = std.math.add(u64, cd_offset, cd_size) catch return Error.FormatError;
        if (cd_end > zip_bytes.len) {
            return Error.FormatError;
        }

        var entries = std.ArrayList(File).empty;
        errdefer {
            for (entries.items) |f| {
                allocator.free(f.header.name);
            }
            entries.deinit(allocator);
        }

        var cur: u64 = cd_offset;
        var entry: usize = 0;
        while (entry < total_entries) : (entry += 1) {
            const entry_hdr_end = std.math.add(u64, cur, 46) catch return Error.FormatError;
            if (entry_hdr_end > zip_bytes.len) return Error.FormatError;
            const cur_usize: usize = @intCast(cur);

            const sig = try binary.LittleEndian.readU32(zip_bytes[cur_usize .. cur_usize + 4]);
            if (sig != zip_struct.directory_header_signature) return Error.FormatError;

            const method_raw = try binary.LittleEndian.readU16(zip_bytes[cur_usize + 10 .. cur_usize + 12]);
            const crc32 = try binary.LittleEndian.readU32(zip_bytes[cur_usize + 16 .. cur_usize + 20]);
            const comp_sz = try binary.LittleEndian.readU32(zip_bytes[cur_usize + 20 .. cur_usize + 24]);
            const uncomp_sz = try binary.LittleEndian.readU32(zip_bytes[cur_usize + 24 .. cur_usize + 28]);
            const name_len: u64 = try binary.LittleEndian.readU16(zip_bytes[cur_usize + 28 .. cur_usize + 30]);
            const extra_len: u64 = try binary.LittleEndian.readU16(zip_bytes[cur_usize + 30 .. cur_usize + 32]);
            const comment_len: u64 = try binary.LittleEndian.readU16(zip_bytes[cur_usize + 32 .. cur_usize + 34]);
            const local_hdr_off = try binary.LittleEndian.readU32(zip_bytes[cur_usize + 42 .. cur_usize + 46]);

            const name_end = std.math.add(u64, entry_hdr_end, name_len) catch return Error.FormatError;
            const after_extra = std.math.add(u64, name_end, extra_len) catch return Error.FormatError;
            const next_cur = std.math.add(u64, after_extra, comment_len) catch return Error.FormatError;
            if (next_cur > zip_bytes.len) return Error.FormatError;

            const method: zip_struct.Method = switch (method_raw) {
                0 => .store,
                8 => .deflate,
                else => return Error.UnsupportedMethod,
            };

            const file_name = try allocator.dupe(u8, zip_bytes[@intCast(entry_hdr_end)..@intCast(name_end)]);
            errdefer allocator.free(file_name);
            cur = next_cur;

            const header = zip_struct.FileHeader{
                .name = file_name,
                .method = method,
                .crc32 = crc32,
                .compressed_size = comp_sz,
                .uncompressed_size = uncomp_sz,
                .offset = local_hdr_off,
            };

            try entries.append(allocator, .{ .header = header, .zip_data = zip_bytes });
        }

        return .{
            .allocator = allocator,
            .data = zip_bytes,
            .file_list = entries,
        };
    }

    pub fn deinit(self: *Reader) void {
        for (self.file_list.items) |f| {
            self.allocator.free(f.header.name);
        }
        self.file_list.deinit(self.allocator);
    }

    pub fn files(self: *const Reader) []const File {
        return self.file_list.items;
    }
};

test "archive.zip roundtrip store and extract" {
    const testing = std.testing;
    const bytes = @import("../../bytes.zig");
    const zip_writer = @import("writer.zig");

    var zip_buf = bytes.Buffer.init(testing.allocator);
    defer zip_buf.deinit();

    // 1. Create a zip archive with multiple files
    var zw = zip_writer.Writer.init(testing.allocator, zip_buf.writer());
    defer zw.deinit();

    try zw.writeFile("readme.txt", "Hello stdgo ZIP!", .store);
    try zw.writeFile("data/config.json", "{\"key\": 123}", .store);
    try zw.close();

    // 2. Open and inspect with zip.Reader
    var zr = try Reader.init(testing.allocator, zip_buf.bytes());
    defer zr.deinit();

    const all_files = zr.files();
    try testing.expectEqual(@as(usize, 2), all_files.len);

    try testing.expectEqualStrings("readme.txt", all_files[0].header.name);
    const content1 = try all_files[0].open(testing.allocator);
    defer testing.allocator.free(content1);
    try testing.expectEqualStrings("Hello stdgo ZIP!", content1);

    try testing.expectEqualStrings("data/config.json", all_files[1].header.name);
    const content2 = try all_files[1].open(testing.allocator);
    defer testing.allocator.free(content2);
    try testing.expectEqualStrings("{\"key\": 123}", content2);
}

test "archive.zip rejects unknown compression method and overflowed EOCD" {
    const testing = std.testing;
    const bytes = @import("../../bytes.zig");
    const zip_writer = @import("writer.zig");

    var zip_buf = bytes.Buffer.init(testing.allocator);
    defer zip_buf.deinit();

    var zw = zip_writer.Writer.init(testing.allocator, zip_buf.writer());
    defer zw.deinit();
    try zw.writeFile("a.txt", "hello", .store);
    try zw.close();

    // Mutate central directory compression method to 99 (unknown)
    const mutated = try testing.allocator.dupe(u8, zip_buf.bytes());
    defer testing.allocator.free(mutated);

    // Find CD header signature 0x02014b50 and patch method at +10
    const cd_sig = [_]u8{ 0x50, 0x4b, 0x01, 0x02 };
    const cd_pos = std.mem.indexOf(u8, mutated, &cd_sig).?;
    mutated[cd_pos + 10] = 99;
    mutated[cd_pos + 11] = 0;
    try testing.expectError(Error.UnsupportedMethod, Reader.init(testing.allocator, mutated));

    // Craft EOCD with overflowing cd_offset + cd_size (0xFFFFFFFF + 0xFFFFFFFF)
    var bad_eocd: [22]u8 = @splat(0);
    try binary.LittleEndian.writeU32(bad_eocd[0..4], zip_struct.directory_end_signature);
    try binary.LittleEndian.writeU16(bad_eocd[10..12], 1);
    try binary.LittleEndian.writeU32(bad_eocd[12..16], 0xFFFF_FFFF);
    try binary.LittleEndian.writeU32(bad_eocd[16..20], 0xFFFF_FFFF);
    try testing.expectError(Error.FormatError, Reader.init(testing.allocator, &bad_eocd));
}
