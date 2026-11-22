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
    reuse_record: bool = false,

    line_number: usize = 0,
    num_fields: ?usize = null,

    line_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    record_fields: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    last_allocator: ?Allocator = null,

    pub fn init(rd: *std.Io.Reader) Reader {
        return .{
            .r = rd,
            .comma = ',',
            .comment = null,
            .fields_per_record = 0,
            .lazy_quotes = false,
            .trim_leading_space = false,
            .reuse_record = false,
            .line_number = 0,
            .num_fields = null,
            .line_buffer = std.ArrayList(u8).empty,
            .record_fields = std.ArrayList([]const u8).empty,
            .last_allocator = null,
        };
    }

    pub fn deinit(self: *Reader) void {
        if (self.last_allocator) |alloc| {
            self.line_buffer.deinit(alloc);
            self.record_fields.deinit(alloc);
        }
    }

    /// Read reads one record (a slice of fields) from the CSV reader.
    /// If reuse_record is false, caller owns the returned record and must
    /// call freeRecord(allocator, record).
    /// If reuse_record is true, the returned record slice and field slices
    /// are valid only until the next call to read() or deinit().
    pub fn read(self: *Reader, allocator: Allocator) anyerror!?[]const []const u8 {
        if (self.last_allocator) |prev_alloc| {
            if (prev_alloc.ptr != allocator.ptr or prev_alloc.vtable != allocator.vtable) {
                self.line_buffer.deinit(prev_alloc);
                self.record_fields.deinit(prev_alloc);
                self.line_buffer = std.ArrayList(u8).empty;
                self.record_fields = std.ArrayList([]const u8).empty;
            }
        }
        self.last_allocator = allocator;

        while (true) {
            self.readLine(allocator) catch |err| {
                if (err == error.EndOfStream or err == io.Error.EndOfStream) return null;
                return err;
            };

            self.line_number += 1;

            const raw_line = self.line_buffer.items;

            // Check comment
            if (self.comment) |com| {
                if (raw_line.len > 0 and raw_line[0] == com) {
                    continue;
                }
            }

            // Skip empty lines
            const is_empty = raw_line.len == 0 or
                (raw_line.len == 1 and (raw_line[0] == '\r' or raw_line[0] == '\n'));
            if (is_empty) {
                continue;
            }

            const record = try self.parseRecord(allocator, self.line_buffer.items);
            if (self.fields_per_record > 0) {
                if (record.len != @as(usize, @intCast(self.fields_per_record))) {
                    if (!self.reuse_record) freeRecord(allocator, record);
                    return Error.FieldCount;
                }
            } else if (self.fields_per_record == 0) {
                if (self.num_fields) |expected| {
                    if (record.len != expected) {
                        if (!self.reuse_record) freeRecord(allocator, record);
                        return Error.FieldCount;
                    }
                } else {
                    self.num_fields = record.len;
                }
            }

            return record;
        }
    }

    fn readLine(self: *Reader, allocator: Allocator) anyerror!void {
        self.line_buffer.clearRetainingCapacity();
        var in_quotes = false;
        while (true) {
            const ch = self.r.takeByte() catch |err| {
                if (err == error.EndOfStream or err == io.Error.EndOfStream) {
                    if (self.line_buffer.items.len > 0) {
                        if (in_quotes and !self.lazy_quotes) {
                            return Error.Quote;
                        }
                        return;
                    }
                    return error.EndOfStream;
                }
                return err;
            };

            if (ch == '"' and !self.lazy_quotes) {
                in_quotes = !in_quotes;
            }

            try self.line_buffer.append(allocator, ch);

            if (!in_quotes and ch == '\n') {
                break;
            }
        }
    }

    fn parseRecord(
        self: *Reader,
        allocator: Allocator,
        raw: []u8,
    ) anyerror![]const []const u8 {
        var fields = std.ArrayList([]const u8).empty;
        errdefer {
            for (fields.items) |f| allocator.free(f);
            fields.deinit(allocator);
        }

        if (self.reuse_record) {
            self.record_fields.clearRetainingCapacity();
        }

        var i: usize = 0;
        var src = raw;
        // Strip trailing \r\n or \n
        if (src.len > 0 and src[src.len - 1] == '\n') src = src[0 .. src.len - 1];
        if (src.len > 0 and src[src.len - 1] == '\r') src = src[0 .. src.len - 1];

        while (i <= src.len) {
            var field_start = i;
            if (self.trim_leading_space) {
                while (field_start < src.len and
                    (src[field_start] == ' ' or src[field_start] == '\t'))
                {
                    field_start += 1;
                }
            }

            const field_slice: []const u8 = if (field_start < src.len and
                src[field_start] == '"')
            blk: {
                // Quoted field: unescape in-place within src
                var j = field_start + 1;
                var dst_idx = field_start;
                var inside = true;
                while (j < src.len) {
                    if (src[j] == '"') {
                        if (j + 1 < src.len and src[j + 1] == '"') {
                            // Escaped double quote
                            src[dst_idx] = '"';
                            dst_idx += 1;
                            j += 2;
                        } else {
                            inside = false;
                            j += 1;
                            break;
                        }
                    } else {
                        src[dst_idx] = src[j];
                        dst_idx += 1;
                        j += 1;
                    }
                }
                if (inside and !self.lazy_quotes) {
                    if (self.reuse_record) {
                        self.record_fields.clearRetainingCapacity();
                    }
                    return Error.Quote;
                }
                // Skip to comma or end
                while (j < src.len and src[j] != self.comma) {
                    j += 1;
                }
                i = j + 1;
                break :blk src[field_start..dst_idx];
            } else blk: {
                // Unquoted field: direct sub-slice of line buffer
                var j = field_start;
                while (j < src.len and src[j] != self.comma) {
                    j += 1;
                }
                const slice = src[field_start..j];
                i = j + 1;
                break :blk slice;
            };

            if (self.reuse_record) {
                try self.record_fields.append(allocator, field_slice);
            } else {
                const field_str = try allocator.dupe(u8, field_slice);
                try fields.append(allocator, field_str);
            }
        }

        if (self.reuse_record) {
            return self.record_fields.items;
        } else {
            return try fields.toOwnedSlice(allocator);
        }
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

test "csv.Reader reuse_record eliminates per-field allocations" {
    const testing = std.testing;

    const input =
        \\"alpha","beta",gamma
        \\"one","two""escaped",three
        \\four,five,six
    ;
    var br = bytes.Reader.init(input);
    var reader = Reader.init(br.reader());
    defer reader.deinit();
    reader.reuse_record = true;

    // Read first row
    const row1 = (try reader.read(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 3), row1.len);
    try testing.expectEqualStrings("alpha", row1[0]);
    try testing.expectEqualStrings("beta", row1[1]);
    try testing.expectEqualStrings("gamma", row1[2]);

    // Unquoted and quoted fields point directly inside reader.line_buffer.items
    const buf1_start = @intFromPtr(reader.line_buffer.items.ptr);
    const buf1_end = buf1_start + reader.line_buffer.items.len;
    for (row1) |field| {
        const field_ptr = @intFromPtr(field.ptr);
        try testing.expect(field_ptr >= buf1_start and field_ptr < buf1_end);
    }

    const row1_slice_ptr = row1.ptr;

    // Read second row
    const row2 = (try reader.read(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 3), row2.len);
    try testing.expectEqualStrings("one", row2[0]);
    try testing.expectEqualStrings("two\"escaped", row2[1]);
    try testing.expectEqualStrings("three", row2[2]);

    // Record slice itself is reused without allocating a fresh slice
    try testing.expectEqual(row1_slice_ptr, row2.ptr);

    // Fields point inside updated line buffer
    const buf2_start = @intFromPtr(reader.line_buffer.items.ptr);
    const buf2_end = buf2_start + reader.line_buffer.items.len;
    for (row2) |field| {
        const field_ptr = @intFromPtr(field.ptr);
        try testing.expect(field_ptr >= buf2_start and field_ptr < buf2_end);
    }

    // Read third row
    const row3 = (try reader.read(testing.allocator)).?;
    try testing.expectEqualStrings("four", row3[0]);
    try testing.expectEqualStrings("five", row3[1]);
    try testing.expectEqualStrings("six", row3[2]);
    try testing.expectEqual(row1_slice_ptr, row3.ptr);

    // EOF
    try testing.expectEqual(
        @as(?[]const []const u8, null),
        try reader.read(testing.allocator),
    );
}
