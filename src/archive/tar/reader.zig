const std = @import("std");
const io = @import("../../io.zig");
const header_mod = @import("header.zig");
const Header = header_mod.Header;
const block_size = header_mod.block_size;

pub const Reader = struct {
    r: io.Reader,
    curr_header: ?Header = null,
    curr_remaining: u64 = 0,
    name_scratch: [100]u8 = undefined,

    pub fn init(r: io.Reader) Reader {
        return .{
            .r = r,
            .curr_header = null,
            .curr_remaining = 0,
        };
    }

    /// Next advances to the next entry in the tar archive.
    pub fn next(self: *Reader) anyerror!?Header {
        // Skip remaining bytes of previous file + padding to 512 block
        if (self.curr_remaining > 0) {
            try self.skipBytes(self.curr_remaining);
            self.curr_remaining = 0;
        }

        while (true) {
            var block: [block_size]u8 = undefined;
            const n = self.r.readAll(&block) catch |err| {
                if (err == io.Error.EndOfStream) return null;
                return err;
            };
            if (n < block_size) return null;

            if (Header.parseBlock(&block, &self.name_scratch)) |hdr| {
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
        const nr = try self.r.read(buf[0..max_to_read]);
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
        var scratch: [block_size]u8 = undefined;
        var left = count;
        while (left > 0) {
            const chunk = @min(left, block_size);
            _ = try io.readFull(self.r, scratch[0..@intCast(chunk)]);
            left -= chunk;
        }
    }

    pub fn reader(self: *Reader) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = readImpl,
            },
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }
};

test "archive.tar write and read roundtrip" {
    const testing = std.testing;
    const bytes = @import("../../bytes.zig");
    const writer_mod = @import("writer.zig");

    var tar_buf = bytes.Buffer.init(testing.allocator);
    defer tar_buf.deinit();

    // 1. Write TAR
    var tw = writer_mod.Writer.init(tar_buf.writer());
    const file1_content = "hello tar archive from zig stdgo!";
    const hdr1 = Header{
        .name = "test.txt",
        .size = file1_content.len,
        .mode = 0o644,
    };
    try tw.writeHeader(&hdr1);
    _ = try tw.write(file1_content);

    const file2_content = "another short file";
    const hdr2 = Header{
        .name = "sub/info.md",
        .size = file2_content.len,
        .mode = 0o755,
    };
    try tw.writeHeader(&hdr2);
    _ = try tw.write(file2_content);
    try tw.close();

    // 2. Read TAR
    var r = bytes.Reader.init(tar_buf.bytes());
    var tr = Reader.init(r.reader());

    // File 1
    const ent1 = (try tr.next()).?;
    try testing.expectEqualStrings("test.txt", ent1.name);
    try testing.expectEqual(@as(u64, file1_content.len), ent1.size);

    var read_buf: [64]u8 = undefined;
    const n1 = try tr.read(&read_buf);
    try testing.expectEqualStrings(file1_content, read_buf[0..n1]);

    // File 2
    const ent2 = (try tr.next()).?;
    try testing.expectEqualStrings("sub/info.md", ent2.name);
    try testing.expectEqual(@as(u64, file2_content.len), ent2.size);

    const n2 = try tr.read(&read_buf);
    try testing.expectEqualStrings(file2_content, read_buf[0..n2]);

    // End of archive
    try testing.expectEqual(@as(?Header, null), try tr.next());
}
