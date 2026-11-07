//! HTTP Client providing high-level Get, Post, PostForm, and Do APIs.
const std = @import("std");
const Request = @import("request.zig").Request;
const newRequest = @import("request.zig").newRequest;
const parseUrlTarget = @import("request.zig").parseUrlTarget;
const Response = @import("response.zig").Response;
const Transport = @import("transport.zig").Transport;
const TransportOptions = @import("transport.zig").TransportOptions;
const CookieJar = @import("jar.zig").CookieJar;
const Status = @import("status.zig").Status;
const Method = @import("method.zig").Method;

pub const ClientOptions = struct {
    transport: ?TransportOptions = null,
    max_redirects: u8 = 10,
    jar: ?*CookieJar = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = Transport.init(allocator, io, options.transport orelse .{}),
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
    }

    pub fn do(self: *Client, req: *Request) !Response {
        var current_url = try self.allocator.dupe(u8, req.url);
        defer self.allocator.free(current_url);

        var current_method = req.method;
        var current_body = req.body;
        var redirects_followed: u8 = 0;

        while (true) {
            const target = try parseUrlTarget(current_url);

            var round_trip_req = Request.init(self.allocator, current_method, current_url);
            defer round_trip_req.deinit();

            // Copy original headers (stripping body headers if converted to GET)
            for (req.header.entries.items) |entry| {
                if (current_method == .GET and req.method != .GET) {
                    if (std.ascii.eqlIgnoreCase(entry.name, "Content-Length") or
                        std.ascii.eqlIgnoreCase(entry.name, "Content-Type"))
                    {
                        continue;
                    }
                }
                try round_trip_req.header.add(entry.name, entry.value);
            }

            var cookie_header_to_free: ?[]u8 = null;
            defer if (cookie_header_to_free) |buf| self.allocator.free(buf);

            // Inject cookies from jar
            if (self.options.jar) |jar| {
                if (try jar.formatCookieHeader(self.allocator, target.host)) |cookie_header| {
                    cookie_header_to_free = cookie_header;
                    try round_trip_req.header.set("Cookie", cookie_header);
                }
            }

            if (current_body) |b| {
                try round_trip_req.setBody(b);
            }

            var resp = try self.transport.roundTrip(&round_trip_req);

            // Collect Set-Cookie into jar
            if (self.options.jar) |jar| {
                for (resp.header.entries.items) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.name, "Set-Cookie")) {
                        try jar.setCookiesFromHeader(target.host, entry.value);
                    }
                }
            }

            const is_redirect = switch (resp.status) {
                .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
                else => false,
            };

            if (is_redirect and self.options.max_redirects > 0) {
                if (redirects_followed >= self.options.max_redirects) {
                    resp.close();
                    return error.TooManyRedirects;
                }

                const location = resp.header.get("Location") orelse {
                    return resp;
                };

                redirects_followed += 1;
                resp.close();

                var new_url: []u8 = undefined;
                if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
                    new_url = try self.allocator.dupe(u8, location);
                } else {
                    const scheme_end = std.mem.indexOf(u8, current_url, "://");
                    const host_start = if (scheme_end) |pos| pos + 3 else 0;
                    const slash_idx = std.mem.indexOfScalar(u8, current_url[host_start..], '/');
                    const base = if (slash_idx) |idx| current_url[0 .. host_start + idx] else current_url;
                    if (std.mem.startsWith(u8, location, "/")) {
                        new_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, location });
                    } else {
                        new_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, location });
                    }
                }

                self.allocator.free(current_url);
                current_url = new_url;

                switch (resp.status) {
                    .see_other => {
                        current_method = .GET;
                        current_body = null;
                    },
                    .moved_permanently, .found => {
                        if (current_method == .POST) {
                            current_method = .GET;
                            current_body = null;
                        }
                    },
                    .temporary_redirect, .permanent_redirect => {},
                    else => {},
                }

                continue;
            }

            return resp;
        }
    }

    pub fn get(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .GET, url);
        defer req.deinit();
        return self.do(&req);
    }

    pub fn head(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .HEAD, url);
        defer req.deinit();
        return self.do(&req);
    }

    pub fn post(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .POST, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req);
    }

    pub fn put(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .PUT, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req);
    }

    pub fn delete(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .DELETE, url);
        defer req.deinit();
        return self.do(&req);
    }

    pub fn patch(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .PATCH, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req);
    }

    pub fn postForm(self: *Client, url: []const u8, data: []const u8) !Response {
        return self.post(url, "application/x-www-form-urlencoded", data);
    }
};

pub fn get(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.get(url);
    resp.pool = null;
    return resp;
}

pub fn head(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.head(url);
    resp.pool = null;
    return resp;
}

pub fn post(allocator: std.mem.Allocator, io: std.Io, url: []const u8, content_type: []const u8, body: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.post(url, content_type, body);
    resp.pool = null;
    return resp;
}

pub fn put(allocator: std.mem.Allocator, io: std.Io, url: []const u8, content_type: []const u8, body: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.put(url, content_type, body);
    resp.pool = null;
    return resp;
}

pub fn delete(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.delete(url);
    resp.pool = null;
    return resp;
}

pub fn patch(allocator: std.mem.Allocator, io: std.Io, url: []const u8, content_type: []const u8, body: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.patch(url, content_type, body);
    resp.pool = null;
    return resp;
}

pub fn postForm(allocator: std.mem.Allocator, io: std.Io, url: []const u8, data: []const u8) !Response {
    var c = Client.init(allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 0 } });
    defer c.deinit();

    var resp = try c.postForm(url, data);
    resp.pool = null;
    return resp;
}

test "Client: real https comprehensive API tests on edgebin.liujiacai.net" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c = Client.init(testing.allocator, io, .{ .transport = .{ .max_idle_conns_per_host = 2 } });
    defer c.deinit();

    // 1. GET /ip
    {
        var resp = c.get("https://edgebin.liujiacai.net/ip") catch |err| {
            std.debug.print("edgebin /ip skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"origin\":") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"country\":") != null);
    }

    // 2. GET /headers with custom headers
    {
        var req = Request.init(testing.allocator, .GET, "https://edgebin.liujiacai.net/headers");
        defer req.deinit();
        try req.header.set("X-Stdgo-Test", "Zig-First-Principles");

        var resp = c.do(&req) catch |err| {
            std.debug.print("edgebin /headers skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "x-stdgo-test") != null or std.mem.indexOf(u8, body, "X-Stdgo-Test") != null);
    }

    // 3. POST /post
    {
        const payload = "{\"name\":\"stdgo\",\"first_principles\":true}";
        var resp = c.post(
            "https://edgebin.liujiacai.net/post",
            "application/json",
            payload,
        ) catch |err| {
            std.debug.print("edgebin /post skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"name\": \"stdgo\"") != null);
    }

    // 4. PUT /put
    {
        var resp = c.put(
            "https://edgebin.liujiacai.net/put",
            "text/plain",
            "update data",
        ) catch |err| {
            std.debug.print("edgebin /put skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"method\": \"PUT\"") != null);
    }

    // 5. DELETE /delete
    {
        var resp = c.delete("https://edgebin.liujiacai.net/delete") catch |err| {
            std.debug.print("edgebin /delete skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"method\": \"DELETE\"") != null);
    }

    // 6. PATCH /patch
    {
        var resp = c.patch(
            "https://edgebin.liujiacai.net/patch",
            "application/json",
            "{\"patched\":true}",
        ) catch |err| {
            std.debug.print("edgebin /patch skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"method\": \"PATCH\"") != null);
    }

    // 7. GET /status/418 (I'm a teapot)
    {
        var resp = c.get("https://edgebin.liujiacai.net/status/418") catch |err| {
            std.debug.print("edgebin /status/418 skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 418), resp.status_code);
        const body = try resp.readAllAlloc(1024);
        defer testing.allocator.free(body);
    }

    // 8. GET /status/500
    {
        var resp = c.get("https://edgebin.liujiacai.net/status/500") catch |err| {
            std.debug.print("edgebin /status/500 skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 500), resp.status_code);
        const body = try resp.readAllAlloc(1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "500") != null);
    }

    // 9. GET /bytes/64 (Binary payload)
    {
        var resp = c.get("https://edgebin.liujiacai.net/bytes/64") catch |err| {
            std.debug.print("edgebin /bytes/64 skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(1024);
        defer testing.allocator.free(body);
        try testing.expectEqual(@as(usize, 64), body.len);
    }

    // 10. GET /json (Sample JSON document)
    {
        var resp = c.get("https://edgebin.liujiacai.net/json") catch |err| {
            std.debug.print("edgebin /json skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "slideshow") != null or std.mem.indexOf(u8, body, "{") != null);
    }

    // 11. GET /qrcode?text=stdgo (SVG output)
    {
        var resp = c.get("https://edgebin.liujiacai.net/qrcode?text=stdgo") catch |err| {
            std.debug.print("edgebin /qrcode skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "<svg") != null);
    }

    // 12. POST /md2html (Markdown to HTML conversion)
    {
        var resp = c.post(
            "https://edgebin.liujiacai.net/md2html",
            "text/plain",
            "# Hello Stdgo",
        ) catch |err| {
            std.debug.print("edgebin /md2html skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(64 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "<h1>Hello Stdgo</h1>") != null);
    }

    // 13. GET /user-agent
    {
        var resp = c.get("https://edgebin.liujiacai.net/user-agent") catch |err| {
            std.debug.print("edgebin /user-agent skip: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer resp.close();
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        const body = try resp.readAllAlloc(16 * 1024);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"user-agent\":") != null);
    }
}
