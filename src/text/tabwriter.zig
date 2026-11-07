const std = @import("std");
const io = @import("../io.zig");
const bytes = @import("../bytes.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const AlignRight: u32 = 1 << 0;
pub const Debug: u32 = 1 << 1;

pub const Writer = struct {
    allocator: Allocator,
    output: io.Writer,
    minwidth: usize = 0,
    tabwidth: usize = 8,
    padding: usize = 1,
    padchar: u8 = ' ',
    flags: u32 = 0,

    current_line: std.ArrayList([]const u8),
    current_cell: bytes.Buffer,
    rows: std.ArrayList(std.ArrayList([]const u8)),

    pub fn init(
        allocator: Allocator,
        output: io.Writer,
        minwidth: usize,
        tabwidth: usize,
        padding: usize,
        padchar: u8,
        flags: u32,
    ) Writer {
        return .{
            .allocator = allocator,
            .output = output,
            .minwidth = minwidth,
            .tabwidth = tabwidth,
            .padding = padding,
            .padchar = padchar,
            .flags = flags,
            .current_line = std.ArrayList([]const u8).empty,
            .current_cell = bytes.Buffer.init(allocator),
            .rows = std.ArrayList(std.ArrayList([]const u8)).empty,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.clearRows();
        self.rows.deinit(self.allocator);
        self.current_cell.deinit();
        self.current_line.deinit(self.allocator);
    }

    fn clearRows(self: *Writer) void {
        for (self.rows.items) |*row| {
            for (row.items) |cell| {
                self.allocator.free(cell);
            }
            row.deinit(self.allocator);
        }
        self.rows.clearRetainingCapacity();

        for (self.current_line.items) |cell| {
            self.allocator.free(cell);
        }
        self.current_line.clearRetainingCapacity();
    }

    pub fn write(self: *Writer, p: []const u8) anyerror!usize {
        for (p) |b| {
            if (b == '\t') {
                const cell_str = try self.allocator.dupe(u8, self.current_cell.bytes());
                try self.current_line.append(self.allocator, cell_str);
                self.current_cell.reset();
            } else if (b == '\n') {
                const cell_str = try self.allocator.dupe(u8, self.current_cell.bytes());
                try self.current_line.append(self.allocator, cell_str);
                self.current_cell.reset();

                try self.rows.append(self.allocator, self.current_line);
                self.current_line = std.ArrayList([]const u8).empty;
            } else {
                try self.current_cell.writeByte(b);
            }
        }
        return p.len;
    }

    /// Flush calculates elastic tabstops and outputs the aligned columns.
    pub fn flush(self: *Writer) anyerror!void {
        // If there is an unfinished line or cell, commit it
        if (self.current_cell.len() > 0 or self.current_line.items.len > 0) {
            const cell_str = try self.allocator.dupe(u8, self.current_cell.bytes());
            try self.current_line.append(self.allocator, cell_str);
            self.current_cell.reset();

            try self.rows.append(self.allocator, self.current_line);
            self.current_line = std.ArrayList([]const u8).empty;
        }

        if (self.rows.items.len == 0) return;

        // Calculate max width for each column
        var col_widths = std.ArrayList(usize).empty;
        defer col_widths.deinit(self.allocator);

        for (self.rows.items) |row| {
            for (row.items, 0..) |cell, col| {
                const w = @max(cell.len, self.minwidth);
                if (col >= col_widths.items.len) {
                    try col_widths.append(self.allocator, w);
                } else if (w > col_widths.items[col]) {
                    col_widths.items[col] = w;
                }
            }
        }

        // Print aligned rows
        for (self.rows.items) |row| {
            for (row.items, 0..) |cell, col| {
                const is_last = (col + 1 == row.items.len);
                if (is_last) {
                    try self.output.writeAll(cell);
                } else {
                    const target_width = col_widths.items[col] + self.padding;
                    const pad_count = if (target_width > cell.len) target_width - cell.len else 0;

                    if ((self.flags & AlignRight) != 0) {
                        try self.writePadding(pad_count);
                        try self.output.writeAll(cell);
                    } else {
                        try self.output.writeAll(cell);
                        try self.writePadding(pad_count);
                    }

                    if ((self.flags & Debug) != 0) {
                        try self.output.writeAll("|");
                    }
                }
            }
            try self.output.writeByte('\n');
        }

        self.clearRows();
    }

    fn writePadding(self: *Writer, count: usize) anyerror!void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.output.writeByte(self.padchar);
        }
    }

    pub fn writer(self: *Writer) io.Writer {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = writeImpl,
            },
        };
    }

    fn writeImpl(ctx: *anyopaque, p: []const u8) anyerror!usize {
        const self: *Writer = @ptrCast(@alignCast(ctx));
        return self.write(p);
    }
};

test "tabwriter basic alignment" {
    const testing = std.testing;

    var out_buf = bytes.Buffer.init(testing.allocator);
    defer out_buf.deinit();

    var tw = Writer.init(testing.allocator, out_buf.writer(), 0, 8, 2, ' ', 0);
    defer tw.deinit();

    _ = try tw.write("NAME\tAGE\tCITY\n");
    _ = try tw.write("Alice\t24\tNew York\n");
    _ = try tw.write("Bob\t30\tSF\n");
    try tw.flush();

    const expected =
        "NAME   AGE  CITY\n" ++
        "Alice  24   New York\n" ++
        "Bob    30   SF\n";

    try testing.expectEqualStrings(expected, out_buf.string());
}

test "tabwriter debug vertical bars and right align" {
    const testing = std.testing;

    var out_buf = bytes.Buffer.init(testing.allocator);
    defer out_buf.deinit();

    var tw = Writer.init(testing.allocator, out_buf.writer(), 0, 8, 1, ' ', Debug);
    defer tw.deinit();

    _ = try tw.write("a\tb\n");
    _ = try tw.write("123\t456\n");
    try tw.flush();

    const expected =
        "a   |b\n" ++
        "123 |456\n";

    try testing.expectEqualStrings(expected, out_buf.string());
}
