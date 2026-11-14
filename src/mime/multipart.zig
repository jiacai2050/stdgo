const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../io.zig");
const bytes_mod = @import("../bytes.zig");
const strings_mod = @import("../strings.zig");

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Header = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(HeaderEntry) = .empty,

    pub fn init(allocator: Allocator) Header {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Header) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const Header, name: []const u8) ?[]const u8 {
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.entries.items[i].name, name)) {
                return self.entries.items[i].value;
            }
        }
        return null;
    }

    pub fn set(self: *Header, name: []const u8, value: []const u8) !void {
        var i: usize = 0;
        var replaced = false;
        while (i < self.entries.items.len) {
            if (std.ascii.eqlIgnoreCase(self.entries.items[i].name, name)) {
                if (!replaced) {
                    self.allocator.free(self.entries.items[i].name);
                    self.allocator.free(self.entries.items[i].value);
                    self.entries.items[i] = .{
                        .name = try self.allocator.dupe(u8, name),
                        .value = try self.allocator.dupe(u8, value),
                    };
                    replaced = true;
                    i += 1;
                } else {
                    self.allocator.free(self.entries.items[i].name);
                    self.allocator.free(self.entries.items[i].value);
                    _ = self.entries.swapRemove(i);
                }
            } else {
                i += 1;
            }
        }
        if (!replaced) {
            try self.entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .value = try self.allocator.dupe(u8, value),
            });
        }
    }

    pub fn add(self: *Header, name: []const u8, value: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }
};

/// Extract parameter (e.g., name="..." or filename="...") from a header value.
pub fn extractHeaderParam(header_val: []const u8, param_name: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, header_val, ';');
    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = std.mem.trim(u8, part[0..eq_idx], " \t");
        if (std.ascii.eqlIgnoreCase(key, param_name)) {
            var val = std.mem.trim(u8, part[eq_idx + 1 ..], " \t");
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }
            return val;
        }
    }
    return null;
}

/// Writer for multipart/form-data generation.
pub const Writer = struct {
    allocator: Allocator,
    w: *io.Writer,
    boundary_buf: [70]u8 = undefined,
    boundary_len: usize = 0,
    last_part_open: bool = false,
    closed: bool = false,

    pub fn init(allocator: Allocator, w: *io.Writer) Writer {
        var self = Writer{
            .allocator = allocator,
            .w = w,
        };
        self.randomBoundary();
        return self;
    }

    var boundary_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0x123456789abcdef0);

    fn randomBoundary(self: *Writer) void {
        const id = boundary_counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
        const hex = std.fmt.bytesToHex(std.mem.asBytes(&id), .lower);
        const prefix = "stdgo_boundary_";
        @memcpy(self.boundary_buf[0..prefix.len], prefix);
        @memcpy(self.boundary_buf[prefix.len .. prefix.len + 16], &hex);
        self.boundary_len = prefix.len + 16;
    }

    pub fn boundary(self: *const Writer) []const u8 {
        return self.boundary_buf[0..self.boundary_len];
    }

    pub fn setBoundary(self: *Writer, b: []const u8) !void {
        if (b.len == 0 or b.len > self.boundary_buf.len) return error.InvalidBoundary;
        @memcpy(self.boundary_buf[0..b.len], b);
        self.boundary_len = b.len;
    }

    /// FormDataContentType returns the Content-Type for this multipart form-data.
    pub fn formDataContentType(self: *const Writer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "multipart/form-data; boundary={s}", .{self.boundary()});
    }

    /// CreatePart creates a new multipart section with the provided header.
    pub fn createPart(self: *Writer, header: *const Header) !*io.Writer {
        if (self.closed) return error.WriterClosed;

        var prefix_buf: [128]u8 = undefined;
        if (self.last_part_open) {
            const p = try std.fmt.bufPrint(&prefix_buf, "\r\n--{s}\r\n", .{self.boundary()});
            try self.w.writeAll(p);
        } else {
            const p = try std.fmt.bufPrint(&prefix_buf, "--{s}\r\n", .{self.boundary()});
            try self.w.writeAll(p);
        }

        for (header.entries.items) |entry| {
            try self.w.writeAll(entry.name);
            try self.w.writeAll(": ");
            try self.w.writeAll(entry.value);
            try self.w.writeAll("\r\n");
        }
        try self.w.writeAll("\r\n");

        self.last_part_open = true;
        return self.w;
    }

    /// CreateFormField creates a new part with the provided form field name.
    pub fn createFormField(self: *Writer, fieldname: []const u8) !*io.Writer {
        var h = Header.init(self.allocator);
        defer h.deinit();

        var disp_buf: [256]u8 = undefined;
        const disp = try std.fmt.bufPrint(&disp_buf, "form-data; name=\"{s}\"", .{fieldname});
        try h.set("Content-Disposition", disp);

        return self.createPart(&h);
    }

    /// CreateFormFile creates a new part with Content-Disposition for file uploads.
    pub fn createFormFile(self: *Writer, fieldname: []const u8, filename: []const u8) !*io.Writer {
        var h = Header.init(self.allocator);
        defer h.deinit();

        var disp_buf: [512]u8 = undefined;
        const disp = try std.fmt.bufPrint(&disp_buf, "form-data; name=\"{s}\"; filename=\"{s}\"", .{ fieldname, filename });
        try h.set("Content-Disposition", disp);
        try h.set("Content-Type", "application/octet-stream");

        return self.createPart(&h);
    }

    /// WriteField writes a form field name and value directly.
    pub fn writeField(self: *Writer, fieldname: []const u8, value: []const u8) !void {
        const pw = try self.createFormField(fieldname);
        try pw.writeAll(value);
    }

    /// Close finishes the multipart message by writing the trailing boundary.
    pub fn close(self: *Writer) !void {
        if (self.closed) return;
        self.closed = true;

        var suffix_buf: [128]u8 = undefined;
        if (self.last_part_open) {
            const s = try std.fmt.bufPrint(&suffix_buf, "\r\n--{s}--\r\n", .{self.boundary()});
            try self.w.writeAll(s);
        } else {
            const s = try std.fmt.bufPrint(&suffix_buf, "--{s}--\r\n", .{self.boundary()});
            try self.w.writeAll(s);
        }
        try self.w.flush();
    }
};

/// Part represents a single section in a multipart/form-data payload.
pub const Part = struct {
    allocator: Allocator,
    header: Header,
    body: []const u8,
    read_pos: usize = 0,

    pub fn deinit(self: *Part) void {
        self.header.deinit();
        self.allocator.free(self.body);
    }

    pub fn fileName(self: *const Part) ?[]const u8 {
        const disp = self.header.get("Content-Disposition") orelse return null;
        return extractHeaderParam(disp, "filename");
    }

    pub fn formName(self: *const Part) ?[]const u8 {
        const disp = self.header.get("Content-Disposition") orelse return null;
        return extractHeaderParam(disp, "name");
    }

    pub fn read(self: *Part, dest: []u8) !usize {
        if (self.read_pos >= self.body.len or dest.len == 0) return 0;
        const n = @min(dest.len, self.body.len - self.read_pos);
        @memcpy(dest[0..n], self.body[self.read_pos .. self.read_pos + n]);
        self.read_pos += n;
        return n;
    }

    pub fn reader(self: *Part) std.Io.Reader {
        return std.Io.Reader.fixed(self.body[self.read_pos..]);
    }
};

/// Reader parses multipart/form-data streams.
pub const Reader = struct {
    allocator: Allocator,
    r: *io.Reader,
    boundary: []const u8,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    eof: bool = false,

    pub fn init(allocator: Allocator, r: *io.Reader, b: []const u8) Reader {
        return .{
            .allocator = allocator,
            .r = r,
            .boundary = b,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.allocator);
    }

    /// NextPart returns the next Part in the multipart stream, or null if EOF.
    pub fn nextPart(self: *Reader) !?Part {
        if (self.eof) return null;

        // Ensure buffer contains the initial delimiter
        var dash_boundary_buf: [128]u8 = undefined;
        const dash_boundary = try std.fmt.bufPrint(&dash_boundary_buf, "--{s}", .{self.boundary});

        while (std.mem.indexOf(u8, self.buf.items, dash_boundary) == null) {
            var temp: [1024]u8 = undefined;
            const n = try self.r.readSliceShort(&temp);
            if (n == 0) return null;
            try self.buf.appendSlice(self.allocator, temp[0..n]);
        }

        const b_idx = std.mem.indexOf(u8, self.buf.items, dash_boundary).?;
        // Check if closing boundary: "--boundary--"
        const after_b = b_idx + dash_boundary.len;
        if (after_b + 2 <= self.buf.items.len and std.mem.eql(u8, self.buf.items[after_b .. after_b + 2], "--")) {
            self.eof = true;
            return null;
        }

        // Advance past boundary and trailing \r\n
        var header_start = after_b;
        if (header_start + 2 <= self.buf.items.len and std.mem.eql(u8, self.buf.items[header_start .. header_start + 2], "\r\n")) {
            header_start += 2;
        }

        // Find end of headers (\r\n\r\n)
        while (std.mem.indexOfPos(u8, self.buf.items, header_start, "\r\n\r\n") == null) {
            var temp: [1024]u8 = undefined;
            const n = try self.r.readSliceShort(&temp);
            if (n == 0) return error.UnexpectedEOF;
            try self.buf.appendSlice(self.allocator, temp[0..n]);
        }

        const header_end = std.mem.indexOfPos(u8, self.buf.items, header_start, "\r\n\r\n").?;
        const header_bytes = self.buf.items[header_start..header_end];
        const body_start = header_end + 4;

        var header = Header.init(self.allocator);
        errdefer header.deinit();

        var line_iter = std.mem.splitSequence(u8, header_bytes, "\r\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            try header.add(name, val);
        }

        // Read body until next delimiter: \r\n--boundary
        var next_delim_buf: [128]u8 = undefined;
        const next_delim = try std.fmt.bufPrint(&next_delim_buf, "\r\n--{s}", .{self.boundary});

        while (std.mem.indexOfPos(u8, self.buf.items, body_start, next_delim) == null) {
            var temp: [1024]u8 = undefined;
            const n = try self.r.readSliceShort(&temp);
            if (n == 0) return error.UnexpectedEOF;
            try self.buf.appendSlice(self.allocator, temp[0..n]);
        }

        const body_end = std.mem.indexOfPos(u8, self.buf.items, body_start, next_delim).?;
        const body_slice = try self.allocator.dupe(u8, self.buf.items[body_start..body_end]);
        errdefer self.allocator.free(body_slice);

        // Discard processed items up to the start of the next delimiter
        const consumed = body_end + 2; // skip \r\n
        const remaining = self.buf.items.len - consumed;
        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[consumed..]);
        self.buf.shrinkRetainingCapacity(remaining);

        return Part{
            .allocator = self.allocator,
            .header = header,
            .body = body_slice,
        };
    }
};

test "mime.multipart Writer and Reader roundtrip" {
    const testing = std.testing;

    var out_buf = bytes_mod.Buffer.init(testing.allocator);
    defer out_buf.deinit();

    var w = Writer.init(testing.allocator, out_buf.writer());
    try w.setBoundary("my-custom-boundary-12345");

    var ct_buf: [128]u8 = undefined;
    const ct = try w.formDataContentType(&ct_buf);
    try testing.expectEqualStrings("multipart/form-data; boundary=my-custom-boundary-12345", ct);

    // 1. Write text field
    try w.writeField("username", "gopher");

    // 2. Write file
    const file_writer = try w.createFormFile("avatar", "profile.png");
    try file_writer.writeAll("\x89PNG\r\n\x1a\n\x00\x00\x00");

    try w.close();

    // Now parse back with Reader
    var in_r = out_buf.reader();
    var r = Reader.init(testing.allocator, &in_r, "my-custom-boundary-12345");
    defer r.deinit();

    // Part 1: username
    var part1 = (try r.nextPart()).?;
    defer part1.deinit();
    try testing.expectEqualStrings("username", part1.formName().?);
    try testing.expectEqual(@as(?[]const u8, null), part1.fileName());

    var part1_text: [64]u8 = undefined;
    const n1 = try part1.read(&part1_text);
    try testing.expectEqualStrings("gopher", part1_text[0..n1]);

    // Part 2: avatar
    var part2 = (try r.nextPart()).?;
    defer part2.deinit();
    try testing.expectEqualStrings("avatar", part2.formName().?);
    try testing.expectEqualStrings("profile.png", part2.fileName().?);

    var part2_data: [64]u8 = undefined;
    const n2 = try part2.read(&part2_data);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n\x00\x00\x00", part2_data[0..n2]);

    // Part 3: EOF
    const part3 = try r.nextPart();
    try testing.expect(part3 == null);
}
