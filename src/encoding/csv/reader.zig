const std = @import("std");
const io = @import("../../io.zig");
const bytes = @import("../../bytes.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    TrailingComma,
    BareQuote,
    Quote,
    FieldCount,
    InvalidDelim,
};

pub const Reader = struct {
    r: *std.Io.Reader,
    comma: u8 = ',',
    comment: ?u8 = null,
    fields_per_record: i32 = 0,
    lazy_quotes: bool = false,
    trim_leading_space: bool = false,

    line_number: usize = 0,
    num_fields: ?usize = null,

    pub fn init(rd: *std.Io.Reader) Reader {
        return .{
            .r = rd,
            .comma = ',',
            .comment = null,
            .fields_per_record = 0,
            .lazy_quotes = false,
            .trim_leading_space = false,
            .line_number = 0,
            .num_fields = null,
        };
    }

    pub fn deinit(_: *Reader) void {}

    /// Read reads one record (a slice of fields) from the CSV reader.
    /// Caller owns the returned record and must call `freeRecord(allocator, record)`.
    pub fn read(self: *Reader, allocator: Allocator) anyerror!?[]const []const u8 {
        while (true) {
            const raw_line = self.readLine(allocator) catch |err| {
                if (err == error.EndOfStream or err == io.Error.EndOfStream) return null;
                return err;
            };
            defer allocator.free(raw_line);

            self.line_number += 1;

            // Check comment
            if (self.comment) |com| {
                if (raw_line.len > 0 and raw_line[0] == com) {
                    continue;
                }
            }

            // Skip empty lines
            if (raw_line.len == 0 or (raw_line.len == 1 and (raw_line[0] == '\r' or raw_line[0] == '\n'))) {
                continue;
            }

            const record = try self.parseRecord(allocator, raw_line);
            if (self.fields_per_record > 0) {
                if (record.len != @as(usize, @intCast(self.fields_per_record))) {
                    freeRecord(allocator, record);
                    return Error.FieldCount;
                }
            } else if (self.fields_per_record == 0) {
                if (self.num_fields) |expected| {
                    if (record.len != expected) {
                        freeRecord(allocator, record);
                        return Error.FieldCount;
                    }
                } else {
                    self.num_fields = record.len;
                }
            }

            return record;
        }
    }

    fn readLine(self: *Reader, allocator: Allocator) anyerror![]u8 {
        var line = bytes.Buffer.init(allocator);
        errdefer line.deinit();

        var in_quotes = false;
        while (true) {
            const ch = self.r.takeByte() catch |err| {
                if (err == error.EndOfStream) {
                    if (line.len() > 0) {
                        if (in_quotes and !self.lazy_quotes) {
                            return Error.Quote;
                        }
                        return try line.toOwnedSlice();
                    }
                    return error.EndOfStream;
                }
                return err;
            };

            if (ch == '"' and !self.lazy_quotes) {
                in_quotes = !in_quotes;
            }

            try line.writeByte(ch);

            if (!in_quotes and ch == '\n') {
                break;
            }
        }

        return try line.toOwnedSlice();
    }

    fn parseRecord(self: *Reader, allocator: Allocator, raw: []const u8) anyerror![]const []const u8 {
        var fields = std.ArrayList([]const u8).empty;
        errdefer {
            for (fields.items) |f| allocator.free(f);
            fields.deinit(allocator);
        }

        var i: usize = 0;
        var src = raw;
        // Strip trailing \r\n or \n
        if (src.len > 0 and src[src.len - 1] == '\n') src = src[0 .. src.len - 1];
        if (src.len > 0 and src[src.len - 1] == '\r') src = src[0 .. src.len - 1];

        while (i <= src.len) {
            var field_start = i;
            if (self.trim_leading_space) {
                while (field_start < src.len and (src[field_start] == ' ' or src[field_start] == '\t')) {
                    field_start += 1;
                }
            }

            if (field_start < src.len and src[field_start] == '"') {
                // Quoted field
                var field_buf = bytes.Buffer.init(allocator);
                errdefer field_buf.deinit();

                var j = field_start + 1;
                var inside = true;
                while (j < src.len) {
                    if (src[j] == '"') {
                        if (j + 1 < src.len and src[j + 1] == '"') {
                            // Escaped double quote
                            try field_buf.writeByte('"');
                            j += 2;
                        } else {
                            inside = false;
                            j += 1;
                            break;
                        }
                    } else {
                        try field_buf.writeByte(src[j]);
                        j += 1;
                    }
                }
                if (inside and !self.lazy_quotes) {
                    field_buf.deinit();
                    return Error.Quote;
                }
                // Skip to comma or end
                while (j < src.len and src[j] != self.comma) {
                    j += 1;
                }
                i = j + 1;
                const field_str = try field_buf.toOwnedSlice();
                try fields.append(allocator, field_str);
            } else {
                // Unquoted field: zero intermediate buffer allocation!
                var j = field_start;
                while (j < src.len and src[j] != self.comma) {
                    j += 1;
                }
                const field_str = try allocator.dupe(u8, src[field_start..j]);
                i = j + 1;
                try fields.append(allocator, field_str);
            }
        }

        return try fields.toOwnedSlice(allocator);
    }
};

pub fn freeRecord(allocator: Allocator, record: []const []const u8) void {
    for (record) |f| {
        allocator.free(f);
    }
    allocator.free(record);
}

test "csv.Reader basic and quoted records" {
    const testing = std.testing;

    const input =
        \\first_name,last_name,username
        \\"Rob","Pike",rob
        \\Ken,Thompson,ken
        \\"Dennis","Ritchie","dmr"
        \\"Multi
        \\line",field2,field3
    ;
    var br = bytes.Reader.init(input);
    var reader = Reader.init(br.reader());
    defer reader.deinit();

    // 1st row
    const row1 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, row1);
    try testing.expectEqual(@as(usize, 3), row1.len);
    try testing.expectEqualStrings("first_name", row1[0]);
    try testing.expectEqualStrings("last_name", row1[1]);
    try testing.expectEqualStrings("username", row1[2]);

    // 2nd row (quoted)
    const row2 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, row2);
    try testing.expectEqualStrings("Rob", row2[0]);
    try testing.expectEqualStrings("Pike", row2[1]);
    try testing.expectEqualStrings("rob", row2[2]);

    // 3rd row
    const row3 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, row3);
    try testing.expectEqualStrings("Ken", row3[0]);

    // 4th row
    const row4 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, row4);
    try testing.expectEqualStrings("dmr", row4[2]);

    // 5th row (multi-line quoted)
    const row5 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, row5);
    try testing.expectEqualStrings("Multi\nline", row5[0]);

    // EOF
    try testing.expectEqual(@as(?[]const []const u8, null), try reader.read(testing.allocator));
}

test "csv.Reader custom comma, comments and trailing comma" {
    const testing = std.testing;

    const input =
        \\# this is a comment line
        \\val1;val2;
        \\# another comment
        \\val3;val4;val5
    ;
    var br = bytes.Reader.init(input);
    var reader = Reader.init(br.reader());
    defer reader.deinit();
    reader.comma = ';';
    reader.comment = '#';

    // Row 1
    const r1 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, r1);
    try testing.expectEqual(@as(usize, 3), r1.len);
    try testing.expectEqualStrings("val1", r1[0]);
    try testing.expectEqualStrings("val2", r1[1]);
    try testing.expectEqualStrings("", r1[2]);

    // Row 2
    const r2 = (try reader.read(testing.allocator)).?;
    defer freeRecord(testing.allocator, r2);
    try testing.expectEqual(@as(usize, 3), r2.len);
    try testing.expectEqualStrings("val3", r2[0]);
    try testing.expectEqualStrings("val4", r2[1]);
    try testing.expectEqualStrings("val5", r2[2]);

    // EOF
    try testing.expectEqual(@as(?[]const []const u8, null), try reader.read(testing.allocator));
}
