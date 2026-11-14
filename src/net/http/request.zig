//! HTTP Request representation conforming to Go's net/http Request.
const std = @import("std");
const Method = @import("method.zig").Method;
const Header = @import("header.zig").Header;
const io = @import("../../io.zig");
const context = @import("../../context.zig");
const Context = context.Context;

pub const ParsedTarget = struct {
    scheme: []const u8,
    is_tls: bool,
    host: []const u8,
    port: u16,
    request_target: []const u8,
};

pub fn parseUrlTarget(raw_url: []const u8) !ParsedTarget {
    var rest = raw_url;
    var is_tls = false;
    var port: u16 = 80;
    var scheme: []const u8 = "http";

    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
        is_tls = false;
        port = 80;
        scheme = "http";
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
        is_tls = true;
        port = 443;
        scheme = "https";
    } else if (std.mem.indexOf(u8, rest, "://") != null) {
        return error.UnsupportedScheme;
    } else {
        // Default to http:// when scheme is omitted (like curl)
        is_tls = false;
        port = 80;
        scheme = "http";
    }

    const delim_idx = std.mem.indexOfAny(u8, rest, "/?");
    const authority = if (delim_idx) |idx| rest[0..idx] else rest;
    const req_target = if (delim_idx) |idx| rest[idx..] else "/";

    var host: []const u8 = authority;

    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
        if (std.mem.startsWith(u8, authority, "[")) {
            if (std.mem.indexOfScalar(u8, authority, ']')) |rb| {
                if (colon_idx > rb) {
                    host = authority[0..colon_idx];
                    port = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch return error.InvalidPort;
                }
            }
        } else {
            host = authority[0..colon_idx];
            port = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch return error.InvalidPort;
        }
    }

    return .{
        .scheme = if (is_tls) "https" else "http",
        .is_tls = is_tls,
        .host = host,
        .port = port,
        .request_target = req_target,
    };
}

pub const SliceReaderState = struct {
    data: []const u8,
    cursor: usize = 0,

    pub fn read(ctx_ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
        if (self.cursor >= self.data.len) return 0;
        const avail = self.data.len - self.cursor;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.data[self.cursor .. self.cursor + n]);
        self.cursor += n;
        return n;
    }

    pub fn reader(self: *@This()) io.Reader {
        return .{
            .ptr = self,
            .vtable = &.{ .read = read },
        };
    }
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method = .GET,
    url: []const u8,
    header: Header,
    body: ?[]const u8 = null,
    body_reader: ?*io.Reader = null,
    content_length: ?u64 = null,
    get_body: ?*const fn (ctx_ptr: *anyopaque) anyerror!*io.Reader = null,
    get_body_ctx: ?*anyopaque = null,
    slice_reader: std.Io.Reader = std.Io.Reader.fixed(""),
    ctx: ?Context = null,
    cl_str: ?[]u8 = null,
    extra_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .url = url,
            .header = Header.init(allocator),
            .body = null,
            .body_reader = null,
            .content_length = null,
            .get_body = null,
            .get_body_ctx = null,
            .slice_reader = std.Io.Reader.fixed(""),
            .ctx = null,
            .cl_str = null,
            .extra_strings = .empty,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.cl_str) |s| {
            self.allocator.free(s);
            self.cl_str = null;
        }
        for (self.extra_strings.items) |s| {
            self.allocator.free(s);
        }
        self.extra_strings.deinit(self.allocator);
        self.header.deinit();
    }

    pub fn withContext(self: *Request, ctx: Context) void {
        self.ctx = ctx;
    }

    pub fn setHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.header.set(name, value);
    }

    pub fn setBody(self: *Request, body: []const u8) !void {
        self.body = body;
        self.content_length = body.len;
        self.slice_reader = std.Io.Reader.fixed(body);
        self.body_reader = &self.slice_reader;
        self.get_body_ctx = self;
        self.get_body = struct {
            fn rewind(ctx_ptr: *anyopaque) anyerror!*io.Reader {
                const s: *Request = @ptrCast(@alignCast(ctx_ptr));
                s.slice_reader.seek = 0;
                return &s.slice_reader;
            }
        }.rewind;

        if (self.cl_str) |s| {
            self.allocator.free(s);
            self.cl_str = null;
        }
        const s = try std.fmt.allocPrint(self.allocator, "{d}", .{body.len});
        self.cl_str = s;
        try self.header.set("Content-Length", s);
    }

    pub fn setBodyReader(self: *Request, r: *io.Reader, cl: ?u64) !void {
        self.body = null;
        self.body_reader = r;
        self.content_length = cl;

        if (cl) |len| {
            if (self.cl_str) |s| {
                self.allocator.free(s);
                self.cl_str = null;
            }
            const s = try std.fmt.allocPrint(self.allocator, "{d}", .{len});
            self.cl_str = s;
            try self.header.set("Content-Length", s);
        } else {
            try self.header.set("Transfer-Encoding", "chunked");
        }
    }

    pub fn setBasicAuth(self: *Request, username: []const u8, password: []const u8) !void {
        const raw = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(raw);

        const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
        const encoded = try self.allocator.alloc(u8, enc_len + 6);
        errdefer self.allocator.free(encoded);

        @memcpy(encoded[0..6], "Basic ");
        _ = std.base64.standard.Encoder.encode(encoded[6..], raw);
        try self.extra_strings.append(self.allocator, encoded);
        try self.header.set("Authorization", encoded);
    }

    pub fn addCookie(self: *Request, cookie: @import("cookie.zig").Cookie) !void {
        if (self.header.get("Cookie")) |existing| {
            const combined = try std.fmt.allocPrint(self.allocator, "{s}; {s}={s}", .{ existing, cookie.name, cookie.value });
            errdefer self.allocator.free(combined);
            try self.extra_strings.append(self.allocator, combined);
            try self.header.set("Cookie", combined);
        } else {
            const s = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ cookie.name, cookie.value });
            errdefer self.allocator.free(s);
            try self.extra_strings.append(self.allocator, s);
            try self.header.set("Cookie", s);
        }
    }
};

pub fn newRequest(allocator: std.mem.Allocator, method: Method, url: []const u8, body: ?[]const u8) !Request {
    var req = Request.init(allocator, method, url);
    errdefer req.deinit();
    if (body) |b| {
        try req.setBody(b);
    }
    return req;
}

pub fn newRequestWithReader(
    allocator: std.mem.Allocator,
    method: Method,
    url: []const u8,
    body_r: ?*io.Reader,
    content_len: ?u64,
) !Request {
    var req = Request.init(allocator, method, url);
    errdefer req.deinit();
    if (body_r) |r| {
        try req.setBodyReader(r, content_len);
    }
    return req;
}

test "parseUrlTarget with query string without slash" {
    const target = try parseUrlTarget("https://example.com?foo=bar&baz=1");
    try std.testing.expectEqualStrings("example.com", target.host);
    try std.testing.expectEqualStrings("?foo=bar&baz=1", target.request_target);
    try std.testing.expectEqual(@as(u16, 443), target.port);
    try std.testing.expect(target.is_tls);
}
