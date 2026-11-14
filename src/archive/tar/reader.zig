const std = @import("std");
const io = @import("../../io.zig");
const header_mod = @import("header.zig");
const Header = header_mod.Header;
const block_size = header_mod.block_size;

pub const Reader = struct {
    r: *std.Io.Reader,
    curr_header: ?Header = null,
    curr_remaining: u64 = 0,
    name_scratch: [100]u8 = undefined,
    reader_inst: std.Io.Reader = undefined,
    reader_buffer: [512]u8 = undefined,

    pub fn init(r: *std.Io.Reader) Reader {
        return .{
            .r = r,
            .curr_header = null,
            .curr_remaining = 0,
        };
    }

    pub fn reader(self: *Reader) *io.Reader {
        self.reader_inst = .{
            .buffer = &self.reader_buffer,
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = streamImpl,
            },
        };
        return &self.reader_inst;
    }

    fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("reader_inst", r));
        var total: usize = 0;
        var buf: [512]u8 = undefined;
        const max_bytes = @backingInt(limit);
        while (total < max_bytes) {
            const want = @min(buf.len, max_bytes - total);
            const n = self.read(buf[0..want]) catch |err| {
                if (err == io.Error.EndOfStream) break;
                return error.ReadFailed;
            };
            if (n == 0) break;
            w.writeAll(buf[0..n]) catch return error.WriteFailed;
            total += n;
        }
        if (total == 0) return error.EndOfStream;
        return total;
    }

    /// Next advances to the next entry in the tar archive.
    pub fn next(self: *Reader) anyerror!?Header {
        // Skip remaining bytes of previous file + padding to 512 block
        if (self.curr_remaining > 0) {
            try self.skipBytes(self.curr_remaining);
            self.curr_remaining = 0;
        }

        while (true) {
            const block = self.r.take(block_size) catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };

            if (Header.parseBlock(block[0..block_size], &self.name_scratch)) |hdr| {
                self.curr_header = hdr;
                self.curr_remaining = hdr.size;
                return hdr;
            } else {
                // All zeroes block (end of archive or trailer)
                return null;
            }
        }
    }

    /// Read reads from the current file in the tar archive.
    pub fn read(self: *Reader, buf: []u8) anyerror!usize {
        if (self.curr_remaining == 0) {
            return io.Error.EndOfStream;
        }

        const max_to_read = @min(buf.len, @as(usize, @intCast(self.curr_remaining)));
        const nr = try self.r.readSliceShort(buf[0..max_to_read]);
        if (nr == 0) return io.Error.EndOfStream;

        self.curr_remaining -= nr;
        if (self.curr_remaining == 0) {
            // Need to skip block alignment pad on subsequent next()
            const rem = self.curr_header.?.size % block_size;
            if (rem != 0) {
                const pad = block_size - rem;
                try self.skipBytes(pad);
            }
        }
        return nr;
    }

    fn skipBytes(self: *Reader, count: u64) anyerror!void {
        try self.r.discardAll(count);
    }
};

test "archive.tar write and read roundtrip" {
    const testing = std.testing;
    const bytes = @import("../../bytes.zig");
    const writer_mod = @import("writer.zig");

    var tar_buf = bytes.Buffer.init(testing.allocator);
    defer tar_buf.deinit();

    var tar_w = writer_mod.Writer.init(tar_buf.writer());

    // 1. Write file 1
    const file1_content = "Hello, Tar World! This is file 1 content.";
    var hdr1 = Header{
        .name = "file1.txt",
        .mode = 0o644,
        .uid = 1000,
        .gid = 1000,
        .size = file1_content.len,
        .mtime = 1700000000,
        .typeflag = .reg,
    };
    try tar_w.writeHeader(&hdr1);
    _ = try tar_w.write(file1_content);

    // 2. Write file 2
    const file2_content = "Short text";
    var hdr2 = Header{
        .name = "sub/file2.txt",
        .mode = 0o755,
        .uid = 0,
        .gid = 0,
        .size = file2_content.len,
        .mtime = 1700000500,
        .typeflag = .reg,
    };
    try tar_w.writeHeader(&hdr2);
    _ = try tar_w.write(file2_content);

    try tar_w.close();

    // 3. Read back
    var tar_reader = tar_buf.reader();
    var tar_r = Reader.init(&tar_reader);

    // Next 1
    const read_hdr1 = (try tar_r.next()).?;
    try testing.expectEqualStrings("file1.txt", read_hdr1.name);
    try testing.expectEqual(@as(u64, file1_content.len), read_hdr1.size);
    var content1_buf: [64]u8 = undefined;
    const n1 = try tar_r.read(&content1_buf);
    try testing.expectEqualStrings(file1_content, content1_buf[0..n1]);

    // Next 2
    const read_hdr2 = (try tar_r.next()).?;
    try testing.expectEqualStrings("sub/file2.txt", read_hdr2.name);
    try testing.expectEqual(@as(u64, file2_content.len), read_hdr2.size);
    var content2_buf: [64]u8 = undefined;
    const n2 = try tar_r.read(&content2_buf);
    try testing.expectEqualStrings(file2_content, content2_buf[0..n2]);

    // Trailer EOF
    try testing.expectEqual(@as(?Header, null), try tar_r.next());
}
