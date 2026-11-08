//! HTTP Client providing high-level Get, Post, PostForm, and Do APIs.
const std = @import("std");
const Request = @import("request.zig").Request;
const newRequest = @import("request.zig").newRequest;
const newRequestWithReader = @import("request.zig").newRequestWithReader;
const parseUrlTarget = @import("request.zig").parseUrlTarget;
const Response = @import("response.zig").Response;
const Transport = @import("transport.zig").Transport;
const TransportOptions = @import("transport.zig").TransportOptions;
const CookieJar = @import("jar.zig").CookieJar;
const Status = @import("status.zig").Status;
const Method = @import("method.zig").Method;

pub const ClientOptions = struct {
    proxy_url: ?[]const u8 = null,
    proxy_from_env: bool = true,
    transport: ?TransportOptions = null,
    max_redirects: u8 = 10,
    jar: ?*CookieJar = null,
    timeout_ns: ?u64 = null,
    check_redirect: ?*const fn (ctx_ptr: ?*anyopaque, req: *Request, via: []const *const Request) anyerror!void = null,
    check_redirect_ctx: ?*anyopaque = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        var trans_opts = options.transport orelse TransportOptions{};
        if (options.proxy_url) |p| {
            trans_opts.proxy_url = p;
        }
        trans_opts.proxy_from_env = options.proxy_from_env;
        if (trans_opts.timeout_ns == null and options.timeout_ns != null) {
            trans_opts.timeout_ns = options.timeout_ns;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .transport = Transport.init(allocator, io, trans_opts),
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
    }

    pub fn do(self: *Client, req: *Request) !Response {
        const start_ns = std.Io.Clock.boot.now(self.io).nanoseconds;
        const has_timeout = self.options.timeout_ns != null;
        const timeout_ns = self.options.timeout_ns orelse 0;

        var current_url = try self.allocator.dupe(u8, req.url);
        defer self.allocator.free(current_url);

        var current_method = req.method;
        var current_body = req.body;
        var current_body_reader = req.body_reader;
        var redirects_followed: u8 = 0;

        var via = std.ArrayListUnmanaged(*const Request).empty;
        defer via.deinit(self.allocator);

        while (true) {
            if (req.ctx) |c| {
                if (c.err()) |e| return e;
            }
            if (has_timeout and (std.Io.Clock.boot.now(self.io).nanoseconds -% start_ns >= timeout_ns)) {
                return error.Timeout;
            }

            const target = try parseUrlTarget(current_url);

            var round_trip_req = Request.init(self.allocator, current_method, current_url);
            defer round_trip_req.deinit();

            // Copy original headers (stripping body headers if converted to GET)
            for (req.header.entries.items) |entry| {
                if (current_method == .GET and req.method != .GET) {
                    if (std.ascii.eqlIgnoreCase(entry.name, "Content-Length") or
                        std.ascii.eqlIgnoreCase(entry.name, "Content-Type") or
                        std.ascii.eqlIgnoreCase(entry.name, "Transfer-Encoding"))
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
            } else if (current_body_reader) |r| {
                try round_trip_req.setBodyReader(r, req.content_length);
            }
            if (req.ctx) |c| {
                round_trip_req.withContext(c);
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
                try via.append(self.allocator, &round_trip_req);

                if (self.options.check_redirect) |check_fn| {
                    try check_fn(self.options.check_redirect_ctx, req, via.items);
                } else if (redirects_followed >= self.options.max_redirects) {
                    resp.close();
                    return error.TooManyRedirects;
                }

                const location = resp.header.get("Location") orelse {
                    return resp;
                };

                redirects_followed += 1;

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

                const new_target = try parseUrlTarget(new_url);

                // Security: Strip sensitive headers on cross-origin redirects
                const is_cross_origin = !std.ascii.eqlIgnoreCase(target.host, new_target.host) or (target.is_tls and !new_target.is_tls);
                if (is_cross_origin) {
                    req.header.del("Authorization");
                    req.header.del("Proxy-Authorization");
                    req.header.del("Cookie");
                }

                self.allocator.free(current_url);
                current_url = new_url;

                switch (resp.status) {
                    .see_other => {
                        current_method = .GET;
                        current_body = null;
                        current_body_reader = null;
                    },
                    .moved_permanently, .found => {
                        if (current_method == .POST) {
                            current_method = .GET;
                            current_body = null;
                            current_body_reader = null;
                        }
                    },
                    .temporary_redirect, .permanent_redirect => {
                        if (req.get_body) |get_b| {
                            current_body_reader = try get_b(req.get_body_ctx.?);
                        }
                    },
                    else => {},
                }

                resp.close();
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

test "Client: HTTP proxy and HTTPS CONNECT tunneling via 127.0.0.1:8888" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c = Client.init(testing.allocator, io, .{
        .proxy_url = "http://127.0.0.1:8888",
    });
    defer c.deinit();

    // 1. Test curl -L -x http://127.0.0.1:8888 ip.liujiacai.net/json
    // HTTP request -> 301 Redirect -> HTTPS request via CONNECT tunnel -> 200 OK
    var resp = c.get("ip.liujiacai.net/json") catch |err| {
        std.debug.print("Proxy test skipped (proxy not running or unreachable): {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer resp.close();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    const body = try resp.readAllAlloc(16 * 1024);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"ip\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"country\":") != null);
}

test "Client: Context cancellation aborts request" {
    const testing = std.testing;
    const context_mod = @import("../../context.zig");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c = Client.init(testing.allocator, io, .{});
    defer c.deinit();

    var cancel_ctx = try context_mod.withCancel(testing.allocator, context_mod.background());
    defer testing.allocator.destroy(cancel_ctx);

    // Cancel context immediately
    cancel_ctx.cancel();

    var req = try newRequest(testing.allocator, .GET, "http://127.0.0.1:9", null);
    defer req.deinit();
    req.withContext(cancel_ctx.context());

    const res = c.do(&req);
    try testing.expectError(context_mod.Error.Canceled, res);
}

test "Client: CheckRedirect and cross-origin header stripping" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Create a mock local TCP server that returns a 302 redirect from port A to port B (cross-origin)
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server1 = try address.listen(io, .{ .reuse_address = true });
    defer server1.deinit(io);
    const p1 = server1.socket.address.ip4.port;

    var server2 = try address.listen(io, .{ .reuse_address = true });
    defer server2.deinit(io);
    const p2 = server2.socket.address.ip4.port;

    // Server 1 handler in background thread
    const S1 = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, port2: u16) !void {
            var conn = try s.accept(s_io);
            defer conn.close(s_io);

            var read_buf: [1024]u8 = undefined;
            var sr = conn.reader(s_io, &read_buf);
            while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                try sr.interface.fillMore();
            }

            var w_buf: [256]u8 = undefined;
            var sw = conn.writer(s_io, &w_buf);
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(
                &resp_buf,
                "HTTP/1.1 302 Found\r\nLocation: http://localhost:{d}/target\r\nContent-Length: 0\r\n\r\n",
                .{port2},
            );
            try sw.interface.writeAll(resp);
            try sw.interface.flush();
        }
    };

    // Server 2 handler in background thread
    const S2 = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, out_auth_present: *bool) !void {
            var conn = try s.accept(s_io);
            defer conn.close(s_io);

            var read_buf: [1024]u8 = undefined;
            var sr = conn.reader(s_io, &read_buf);
            while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                try sr.interface.fillMore();
            }

            const req_head = sr.interface.buffered();
            out_auth_present.* = std.mem.indexOf(u8, req_head, "Authorization") != null;

            var w_buf: [256]u8 = undefined;
            var sw = conn.writer(s_io, &w_buf);
            try sw.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
            try sw.interface.flush();
        }
    };

    var auth_present_on_s2 = true;
    const t1 = try std.Thread.spawn(.{}, S1.run, .{ &server1, io, p2 });
    const t2 = try std.Thread.spawn(.{}, S2.run, .{ &server2, io, &auth_present_on_s2 });

    const State = struct {
        redirect_calls: usize = 0,
        fn checkRedirect(ctx_ptr: ?*anyopaque, _: *Request, via: []const *const Request) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            self.redirect_calls += 1;
            try testing.expectEqual(@as(usize, 1), via.len);
        }
    };

    var state = State{};
    var c = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .check_redirect = State.checkRedirect,
        .check_redirect_ctx = &state,
    });
    defer c.deinit();

    const start_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/start", .{p1});
    defer testing.allocator.free(start_url);

    var req = try newRequest(testing.allocator, .GET, start_url, null);
    defer req.deinit();
    try req.setHeader("Authorization", "Bearer sensitive-token");

    var resp = try c.do(&req);
    defer resp.close();

    t1.join();
    t2.join();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expectEqual(@as(usize, 1), state.redirect_calls);
    // Crucial security check: cross-origin (127.0.0.1 -> localhost) must strip Authorization!
    try testing.expect(!auth_present_on_s2);
}

test "Client: Streaming request body with Reader and Chunked Transfer-Encoding" {
    const testing = std.testing;
    const io_mod = @import("../../io.zig");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    // Server collects uploaded chunks
    const ServerHandler = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, received: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
            var conn = try s.accept(s_io);
            defer conn.close(s_io);

            var read_buf: [1024]u8 = undefined;
            var sr = conn.reader(s_io, &read_buf);
            while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                try sr.interface.fillMore();
            }

            const header_end = std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n").?;
            const req_head = sr.interface.buffered()[0..header_end];
            try testing.expect(std.mem.indexOf(u8, req_head, "Transfer-Encoding: chunked") != null);

            sr.interface.toss(header_end + 4);

            // Read chunked body
            while (true) {
                while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n") == null) {
                    try sr.interface.fillMore();
                }
                const crlf = std.mem.indexOf(u8, sr.interface.buffered(), "\r\n").?;
                const size_str = sr.interface.buffered()[0..crlf];
                const chunk_size = try std.fmt.parseInt(usize, size_str, 16);
                sr.interface.toss(crlf + 2);

                if (chunk_size == 0) {
                    while (sr.interface.buffered().len < 2) try sr.interface.fillMore();
                    sr.interface.toss(2); // trailing \r\n
                    break;
                }

                while (sr.interface.buffered().len < chunk_size + 2) {
                    try sr.interface.fillMore();
                }
                try received.appendSlice(alloc, sr.interface.buffered()[0..chunk_size]);
                sr.interface.toss(chunk_size + 2);
            }

            var w_buf: [256]u8 = undefined;
            var sw = conn.writer(s_io, &w_buf);
            try sw.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
            try sw.interface.flush();
        }
    };

    var uploaded = std.ArrayListUnmanaged(u8).empty;
    defer uploaded.deinit(testing.allocator);

    const s_thread = try std.Thread.spawn(.{}, ServerHandler.run, .{ &server, io, &uploaded, testing.allocator });

    // Stream from custom Reader
    const StreamSource = struct {
        chunks: [3][]const u8 = .{ "first-chunk ", "second-chunk ", "third-chunk" },
        idx: usize = 0,

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.idx >= self.chunks.len) return 0;
            const src = self.chunks[self.idx];
            @memcpy(buf[0..src.len], src);
            self.idx += 1;
            return src.len;
        }

        fn reader(self: *@This()) io_mod.Reader {
            return .{
                .ptr = self,
                .vtable = &.{ .read = read },
            };
        }
    };

    var src = StreamSource{};
    const target_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/stream-upload", .{port});
    defer testing.allocator.free(target_url);

    // Create request with body_reader and unknown length (null) -> chunked
    var req = try newRequestWithReader(testing.allocator, .POST, target_url, src.reader(), null);
    defer req.deinit();

    var c = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
    });
    defer c.deinit();

    var resp = try c.do(&req);
    defer resp.close();

    s_thread.join();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expectEqualStrings("first-chunk second-chunk third-chunk", uploaded.items);
}

test "Client: Transparent response gzip decompression" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    // Gzip compressed payload of "Hello world\n"
    const gzip_payload = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, // gzip header
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate block
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00, // gzip footer
    };

    const ServerHandler = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, payload: []const u8) !void {
            var conn = try s.accept(s_io);
            defer conn.close(s_io);

            var read_buf: [1024]u8 = undefined;
            var sr = conn.reader(s_io, &read_buf);
            while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                try sr.interface.fillMore();
            }

            const req_head = sr.interface.buffered();
            // Client must have automatically sent Accept-Encoding: gzip
            try testing.expect(std.mem.indexOf(u8, req_head, "Accept-Encoding: gzip") != null);

            var w_buf: [256]u8 = undefined;
            var sw = conn.writer(s_io, &w_buf);
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(
                &resp_buf,
                "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
                .{payload.len},
            );
            try sw.interface.writeAll(resp);
            try sw.interface.writeAll(payload);
            try sw.interface.flush();
        }
    };

    const s_thread = try std.Thread.spawn(.{}, ServerHandler.run, .{ &server, io, &gzip_payload });

    var c = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
    });
    defer c.deinit();

    const target_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/gzip-test", .{port});
    defer testing.allocator.free(target_url);

    var resp = try c.get(target_url);
    defer resp.close();

    s_thread.join();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    // Verifications:
    // 1. Uncompressed flag is set
    try testing.expect(resp.uncompressed);
    // 2. Content-Encoding is stripped
    try testing.expect(resp.header.get("Content-Encoding") == null);
    // 3. Content-Length is stripped
    try testing.expect(resp.header.get("Content-Length") == null);

    // 4. Reading body automatically yields the plain decompressed text
    const body = try resp.readAllAlloc(1024);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Hello world\n", body);
}
