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
        const off = self.header.offset;
        if (off + 30 > self.zip_data.len) return Error.FormatError;

        const sig = try binary.LittleEndian.readU32(self.zip_data[off .. off + 4]);
        if (sig != zip_struct.file_header_signature) return Error.FormatError;

        const name_len = try binary.LittleEndian.readU16(self.zip_data[off + 26 .. off + 28]);
        const extra_len = try binary.LittleEndian.readU16(self.zip_data[off + 28 .. off + 30]);

        const data_start = off + 30 + name_len + extra_len;
        const data_end = data_start + self.header.compressed_size;
        if (data_end > self.zip_data.len) return Error.FormatError;

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
        const cd_size = try binary.LittleEndian.readU32(zip_bytes[eocd + 12 .. eocd + 16]);
        const cd_offset = try binary.LittleEndian.readU32(zip_bytes[eocd + 16 .. eocd + 20]);

        if (cd_offset + cd_size > zip_bytes.len) {
            return Error.FormatError;
        }

        var entries = std.ArrayList(File).empty;
        errdefer {
            for (entries.items) |f| {
                allocator.free(f.header.name);
            }
            entries.deinit(allocator);
        }

        var cur = cd_offset;
        var entry: usize = 0;
        while (entry < total_entries) : (entry += 1) {
            if (cur + 46 > zip_bytes.len) return Error.FormatError;
            const sig = try binary.LittleEndian.readU32(zip_bytes[cur .. cur + 4]);
            if (sig != zip_struct.directory_header_signature) return Error.FormatError;

            const method_raw = try binary.LittleEndian.readU16(zip_bytes[cur + 10 .. cur + 12]);
            const crc32 = try binary.LittleEndian.readU32(zip_bytes[cur + 16 .. cur + 20]);
            const comp_sz = try binary.LittleEndian.readU32(zip_bytes[cur + 20 .. cur + 24]);
            const uncomp_sz = try binary.LittleEndian.readU32(zip_bytes[cur + 24 .. cur + 28]);
            const name_len = try binary.LittleEndian.readU16(zip_bytes[cur + 28 .. cur + 30]);
            const extra_len = try binary.LittleEndian.readU16(zip_bytes[cur + 30 .. cur + 32]);
            const comment_len = try binary.LittleEndian.readU16(zip_bytes[cur + 32 .. cur + 34]);
            const local_hdr_off = try binary.LittleEndian.readU32(zip_bytes[cur + 42 .. cur + 46]);

            cur += 46;
            if (cur + name_len > zip_bytes.len) return Error.FormatError;
            const file_name = try allocator.dupe(u8, zip_bytes[cur .. cur + name_len]);
            cur += name_len + extra_len + comment_len;

            const method: zip_struct.Method = switch (method_raw) {
                0 => .store,
                8 => .deflate,
                else => .store,
            };

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
