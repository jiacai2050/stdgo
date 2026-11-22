const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MediaType = struct {
    media_type: []const u8,
    params: std.StringHashMap([]const u8),

    pub fn deinit(self: *MediaType, allocator: Allocator) void {
        allocator.free(self.media_type);
        var it = self.params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }
};

pub const ParseError = error{
    InvalidMediaType,
} || Allocator.Error;

/// ParseMediaType parses a media type value and any optional parameters, per RFC 1521.
/// Media types are the value in Content-Type and Content-Disposition headers (RFC 2183).
/// On success, returns the lowercased media_type and a hash map of parameters.
pub fn parseMediaType(allocator: Allocator, v_in: []const u8) ParseError!MediaType {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (v.len == 0) return ParseError.InvalidMediaType;

    // Find the end of the base media type (up to ';' or end)
    var semi_idx: ?usize = null;
    for (v, 0..) |c, i| {
        if (c == ';') {
            semi_idx = i;
            break;
        }
    }

    const raw_type = if (semi_idx) |idx| std.mem.trim(u8, v[0..idx], " \t\r\n") else v;
    if (raw_type.len == 0) return ParseError.InvalidMediaType;

    // Verify raw_type has valid token / token structure (e.g. "type/subtype" or "form-data")
    for (raw_type) |c| {
        if (c <= ' ' or c >= 127) return ParseError.InvalidMediaType;
    }

    const lower_type = try std.ascii.allocLowerString(allocator, raw_type);
    errdefer allocator.free(lower_type);

    var params = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    if (semi_idx == null) {
        return .{
            .media_type = lower_type,
            .params = params,
        };
    }

    var rest = v[semi_idx.? + 1 ..];
    while (rest.len > 0) {
        rest = std.mem.trim(u8, rest, " \t\r\n;");
        if (rest.len == 0) break;

        // Parse key
        const eq_idx = std.mem.indexOfScalar(u8, rest, '=') orelse {
            return ParseError.InvalidMediaType;
        };
        const key_raw = std.mem.trim(u8, rest[0..eq_idx], " \t\r\n");
        if (key_raw.len == 0) return ParseError.InvalidMediaType;

        const lower_key = try std.ascii.allocLowerString(allocator, key_raw);
        errdefer allocator.free(lower_key);

        rest = std.mem.trimStart(u8, rest[eq_idx + 1 ..], " \t\r\n");

        // Parse value (quoted or unquoted token)
        var val: []u8 = undefined;
        if (rest.len > 0 and rest[0] == '"') {
            // Quoted string
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(allocator);

            var i: usize = 1;
            var closed = false;
            while (i < rest.len) {
                const c = rest[i];
                if (c == '\\' and i + 1 < rest.len) {
                    try list.append(allocator, rest[i + 1]);
                    i += 2;
                } else if (c == '"') {
                    closed = true;
                    i += 1;
                    break;
                } else {
                    try list.append(allocator, c);
                    i += 1;
                }
            }
            if (!closed) return ParseError.InvalidMediaType;
            val = try list.toOwnedSlice(allocator);
            rest = rest[i..];
        } else {
            // Unquoted token
            var end_idx = rest.len;
            for (rest, 0..) |c, idx| {
                if (c == ';' or c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                    end_idx = idx;
                    break;
                }
            }
            const token = rest[0..end_idx];
            val = try allocator.dupe(u8, token);
            rest = rest[end_idx..];
        }

        try params.put(lower_key, val);
    }

    return .{
        .media_type = lower_type,
        .params = params,
    };
}

/// FormatMediaType serializes mediatype and params into a canonical string.
pub fn formatMediaType(
    allocator: Allocator,
    media_type: []const u8,
    params: *const std.StringHashMap([]const u8),
) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, media_type);

    var it = params.iterator();
    while (it.next()) |entry| {
        try list.appendSlice(allocator, "; ");
        try list.appendSlice(allocator, entry.key_ptr.*);
        try list.append(allocator, '=');

        const val = entry.value_ptr.*;
        var needs_quote = false;
        if (val.len == 0) {
            needs_quote = true;
        } else {
            for (val) |c| {
                if (c <= ' ' or c >= 127 or c == ';' or c == '=' or c == '"') {
                    needs_quote = true;
                    break;
                }
            }
        }

        if (needs_quote) {
            try list.append(allocator, '"');
            for (val) |c| {
                if (c == '"' or c == '\\') {
                    try list.append(allocator, '\\');
                }
                try list.append(allocator, c);
            }
            try list.append(allocator, '"');
        } else {
            try list.appendSlice(allocator, val);
        }
    }

    return list.toOwnedSlice(allocator);
}

const Entry = struct {
    ext: []const u8,
    typ: []const u8,
};

const mime_types = [_]Entry{
    .{ .ext = ".html", .typ = "text/html; charset=utf-8" },
    .{ .ext = ".htm", .typ = "text/html; charset=utf-8" },
    .{ .ext = ".css", .typ = "text/css; charset=utf-8" },
    .{ .ext = ".js", .typ = "application/javascript" },
    .{ .ext = ".mjs", .typ = "application/javascript" },
    .{ .ext = ".json", .typ = "application/json" },
    .{ .ext = ".xml", .typ = "application/xml" },
    .{ .ext = ".pdf", .typ = "application/pdf" },
    .{ .ext = ".zip", .typ = "application/zip" },
    .{ .ext = ".tar", .typ = "application/x-tar" },
    .{ .ext = ".gz", .typ = "application/gzip" },
    .{ .ext = ".wasm", .typ = "application/wasm" },
    .{ .ext = ".png", .typ = "image/png" },
    .{ .ext = ".jpg", .typ = "image/jpeg" },
    .{ .ext = ".jpeg", .typ = "image/jpeg" },
    .{ .ext = ".gif", .typ = "image/gif" },
    .{ .ext = ".svg", .typ = "image/svg+xml" },
    .{ .ext = ".webp", .typ = "image/webp" },
    .{ .ext = ".ico", .typ = "image/x-icon" },
    .{ .ext = ".txt", .typ = "text/plain; charset=utf-8" },
    .{ .ext = ".csv", .typ = "text/csv; charset=utf-8" },
    .{ .ext = ".mp4", .typ = "video/mp4" },
    .{ .ext = ".webm", .typ = "video/webm" },
    .{ .ext = ".mp3", .typ = "audio/mpeg" },
    .{ .ext = ".wav", .typ = "audio/wav" },
    .{ .ext = ".woff", .typ = "font/woff" },
    .{ .ext = ".woff2", .typ = "font/woff2" },
};

/// TypeByExtension returns the MIME type associated with the extension ext.
/// The extension ext should begin with a leading dot, as in ".html".
/// When ext has no leading dot, TypeByExtension still matches it cleanly.
pub fn typeByExtension(ext_in: []const u8) ?[]const u8 {
    var ext = ext_in;
    var ext_buf: [32]u8 = undefined;
    if (ext.len > 0 and ext[0] != '.') {
        if (ext.len + 1 > ext_buf.len) return null;
        ext_buf[0] = '.';
        @memcpy(ext_buf[1 .. ext.len + 1], ext);
        ext = ext_buf[0 .. ext.len + 1];
    }

    for (mime_types) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.ext, ext)) {
            return entry.typ;
        }
    }
    return null;
}

/// ExtensionsByType returns the extensions known to be associated with the MIME type typ.
/// The returned extensions each begin with a leading dot.
pub fn extensionsByType(
    allocator: Allocator,
    typ_in: []const u8,
) Allocator.Error![]const []const u8 {
    var base_typ = typ_in;
    if (std.mem.indexOfScalar(u8, base_typ, ';')) |idx| {
        base_typ = std.mem.trim(u8, base_typ[0..idx], " \t\r\n");
    }

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (mime_types) |entry| {
        var entry_base = entry.typ;
        if (std.mem.indexOfScalar(u8, entry_base, ';')) |idx| {
            entry_base = std.mem.trim(u8, entry_base[0..idx], " \t\r\n");
        }
        if (std.ascii.eqlIgnoreCase(entry_base, base_typ)) {
            try list.append(allocator, entry.ext);
        }
    }

    return list.toOwnedSlice(allocator);
}

test "parseMediaType basic and parameters" {
    const testing = std.testing;

    // 1. Basic Content-Type with charset
    var mt1 = try parseMediaType(testing.allocator, "text/html; charset=utf-8");
    defer mt1.deinit(testing.allocator);
    try testing.expectEqualStrings("text/html", mt1.media_type);
    try testing.expectEqualStrings("utf-8", mt1.params.get("charset").?);

    // 2. Quoted parameters and case-insensitivity
    const input2 = "application/JSON; Charset=\"utf-8\"; Key=\"val;with;semi\"";
    var mt2 = try parseMediaType(testing.allocator, input2);
    defer mt2.deinit(testing.allocator);
    try testing.expectEqualStrings("application/json", mt2.media_type);
    try testing.expectEqualStrings("utf-8", mt2.params.get("charset").?);
    try testing.expectEqualStrings("val;with;semi", mt2.params.get("key").?);

    // 3. Content-Disposition with escapes
    const input3 = "form-data; name=\"upload\"; filename=\"foo\\\"bar.txt\"";
    var mt3 = try parseMediaType(testing.allocator, input3);
    defer mt3.deinit(testing.allocator);
    try testing.expectEqualStrings("form-data", mt3.media_type);
    try testing.expectEqualStrings("upload", mt3.params.get("name").?);
    try testing.expectEqualStrings("foo\"bar.txt", mt3.params.get("filename").?);
}

test "typeByExtension and extensionsByType" {
    const testing = std.testing;

    try testing.expectEqualStrings("image/png", typeByExtension(".png").?);
    try testing.expectEqualStrings("image/png", typeByExtension(".PNG").?);
    try testing.expectEqualStrings("image/png", typeByExtension("png").?);
    try testing.expectEqualStrings("application/json", typeByExtension(".json").?);
    try testing.expect(typeByExtension(".unknown_format") == null);

    const exts = try extensionsByType(testing.allocator, "image/jpeg");
    defer testing.allocator.free(exts);
    try testing.expectEqual(@as(usize, 2), exts.len);
    try testing.expectEqualStrings(".jpg", exts[0]);
    try testing.expectEqualStrings(".jpeg", exts[1]);
}

test "formatMediaType" {
    const testing = std.testing;

    var params = std.StringHashMap([]const u8).init(testing.allocator);
    defer params.deinit();
    try params.put("charset", "utf-8");

    const formatted = try formatMediaType(testing.allocator, "text/html", &params);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("text/html; charset=utf-8", formatted);
}
