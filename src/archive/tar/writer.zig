const std = @import("std");
const io = @import("../../io.zig");
const header_mod = @import("header.zig");
const Header = header_mod.Header;
const block_size = header_mod.block_size;

pub const Writer = struct {
    w: io.Writer,
    curr_file_size: u64 = 0,
    written_in_file: u64 = 0,
    closed: bool = false,

    pub fn init(w: io.Writer) Writer {
        return .{
            .w = w,
            .curr_file_size = 0,
            .written_in_file = 0,
            .closed = false,
        };
    }

    /// WriteHeader writes hdr and prepares to accept the file's contents.
    pub fn writeHeader(self: *Writer, hdr: *const Header) anyerror!void {
        try self.padPrevious();

        var block: [block_size]u8 = undefined;
        hdr.formatBlock(&block);
        try self.w.writeAll(&block);

        self.curr_file_size = hdr.size;
        self.written_in_file = 0;
    }

    /// Write writes to the current file in the tar archive.
    pub fn write(self: *Writer, data: []const u8) anyerror!usize {
        const remaining = self.curr_file_size - self.written_in_file;
        const to_write = @min(data.len, @as(usize, @intCast(remaining)));
        if (to_write > 0) {
            try self.w.writeAll(data[0..to_write]);
            self.written_in_file += to_write;
        }
        return to_write;
    }

    fn padPrevious(self: *Writer) anyerror!void {
        if (self.curr_file_size > 0 and self.written_in_file < self.curr_file_size) {
            // Fill remainder of unfinished file
            const gap = self.curr_file_size - self.written_in_file;
            try self.writeZeroes(gap);
            self.written_in_file = self.curr_file_size;
        }

        // Align to 512 bytes block
        const rem = self.written_in_file % block_size;
        if (rem != 0) {
            const pad = block_size - rem;
            try self.writeZeroes(pad);
        }
    }

    fn writeZeroes(self: *Writer, count: u64) anyerror!void {
        const zeros: [block_size]u8 = @splat(0);
        var left = count;
        while (left > 0) {
            const chunk = @min(left, block_size);
            try self.w.writeAll(zeros[0..@intCast(chunk)]);
            left -= chunk;
        }
    }

    /// Close closes the tar archive by writing the padding and two 512-byte zero blocks.
    pub fn close(self: *Writer) anyerror!void {
        if (self.closed) return;
        try self.padPrevious();
        // Write two 512-byte zero blocks
        try self.writeZeroes(block_size * 2);
        self.closed = true;
    }
};
