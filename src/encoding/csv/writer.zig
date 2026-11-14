const std = @import("std");
const io = @import("../../io.zig");
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    w: *std.Io.Writer,
    comma: u8 = ',',
    use_crlf: bool = false,

    pub fn init(w: *std.Io.Writer) Writer {
        return .{
            .w = w,
            .comma = ',',
            .use_crlf = false,
        };
    }

    /// Flush flushes any buffered data to the underlying io.Writer.
    pub fn flush(self: *Writer) !void {
        try self.w.flush();
    }

    /// Write writes a single CSV record along with the newline terminator.
    pub fn write(self: *Writer, record: []const []const u8) anyerror!void {
        for (record, 0..) |field, n| {
            if (n > 0) {
                try self.w.writeByte(self.comma);
            }
            if (self.fieldNeedsQuotes(field)) {
                try self.w.writeByte('"');
                for (field) |b| {
                    if (b == '"') {
                        try self.w.writeAll("\"\"");
                    } else {
                        try self.w.writeByte(b);
                    }
                }
                try self.w.writeByte('"');
            } else {
                try self.w.writeAll(field);
            }
        }

        if (self.use_crlf) {
            try self.w.writeAll("\r\n");
        } else {
            try self.w.writeAll("\n");
        }
    }

    /// WriteAll writes multiple CSV records to the output.
    pub fn writeAll(self: *Writer, records: []const []const []const u8) anyerror!void {
        for (records) |record| {
            try self.write(record);
        }
    }

    fn fieldNeedsQuotes(self: *const Writer, field: []const u8) bool {
        if (field.len == 0) return false;
        for (field) |c| {
            if (c == '\n' or c == '\r' or c == '"' or c == self.comma) {
                return true;
            }
        }
        return false;
    }
};

test "csv.Writer quote escaping and records" {
    const testing = std.testing;
    const bytes = @import("../../bytes.zig");

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    var writer = Writer.init(buf.writer());
    const row1 = [_][]const u8{ "first", "last", "id" };
    const row2 = [_][]const u8{ "Rob", "Pike, Jr.", "rob" };
    const row3 = [_][]const u8{ "Quoted \"word\"", "line1\nline2", "3" };

    try writer.write(&row1);
    try writer.write(&row2);
    try writer.write(&row3);
    try writer.flush();

    const expected =
        "first,last,id\n" ++
        "Rob,\"Pike, Jr.\",rob\n" ++
        "\"Quoted \"\"word\"\"\",\"line1\nline2\",3\n";

    try testing.expectEqualStrings(expected, buf.string());
}
