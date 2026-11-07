//! HTTP Response status line and headers parser.
const std = @import("std");
const Header = @import("header.zig").Header;
const isValidTokenChar = @import("header.zig").isValidTokenChar;
const Status = @import("status.zig").Status;

pub const ResponseHead = struct {
    status: Status,
    status_code: u16,
    proto: []const u8,
    headers: Header,
    head_bytes: usize,
};

pub fn parseResponseHead(allocator: std.mem.Allocator, buf: []const u8) !ResponseHead {
    const end_of_headers = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.IncompleteHeaders;
    const header_slice = buf[0..end_of_headers];

    var line_iter = std.mem.splitSequence(u8, header_slice, "\r\n");
    const status_line = line_iter.next() orelse return error.MalformedStatusLine;

    // e.g. "HTTP/1.1 200 OK"
    var part_iter = std.mem.splitScalar(u8, status_line, ' ');
    const proto = part_iter.next() orelse return error.MalformedStatusLine;
    const code_str = part_iter.next() orelse return error.MalformedStatusLine;

    const code = std.fmt.parseInt(u16, code_str, 10) catch return error.MalformedStatusCode;
    const status: Status = @enumFromInt(code);

    var headers = Header.init(allocator);
    errdefer headers.deinit();

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeaderLine;
        const name = line[0..colon];
        if (name.len == 0) return error.MalformedHeaderName;
        for (name) |c| {
            if (!isValidTokenChar(c)) return error.MalformedHeaderName;
        }

        var val_start = colon + 1;
        while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) {
            val_start += 1;
        }
        const val = line[val_start..];
        try headers.add(name, val);
    }

    return ResponseHead{
        .status = status,
        .status_code = code,
        .proto = proto,
        .headers = headers,
        .head_bytes = end_of_headers + 4,
    };
}
