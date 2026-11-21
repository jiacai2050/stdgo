//! HTTP Client providing high-level Get, Post, PostForm, and Do APIs.
const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const newRequest = @import("request.zig").newRequest;
const newRequestWithReader = @import("request.zig").newRequestWithReader;
const parseUrlTarget = @import("request.zig").parseUrlTarget;
const Response = @import("response.zig").Response;
const Transport = @import("transport.zig").Transport;
const TransportOptions = @import("transport.zig").TransportOptions;
const RoundTripper = @import("transport.zig").RoundTripper;
const CookieJar = @import("jar.zig").CookieJar;
const Status = @import("status.zig").Status;
const Method = @import("method.zig").Method;
const time_mod = @import("../../time.zig");
const deadline_mod = @import("../../io/deadline.zig");
const io_util = @import("../io_util.zig");

pub const ClientOptions = struct {
    proxy_url: ?[]const u8 = null,
    proxy_from_env: bool = true,
    environ_map: ?*const std.process.Environ.Map = null,
    env_lookup: ?*const fn (key: []const u8) ?[]const u8 = null,
    transport: ?TransportOptions = null,
    round_tripper: ?RoundTripper = null,
    max_redirects: u8 = 10,
    jar: ?*CookieJar = null,
    /// Total request budget, including redirects and response body reads.
    /// Custom round trippers and request body readers must cooperate with cancellation.
    ///
    /// Platform Limitation (Windows / Zig 0.17.0):
    /// On Windows, socket deadline cancellation in `std.Io.Threaded` currently has an upstream
    /// tagged union panic in `batchDrainSubmittedWindows`. Request timeout cancellation is fully
    /// supported and verified on Linux and macOS.
    timeout_ns: ?u64 = null,
    timeout: ?time_mod.Duration = null,
    check_redirect: ?*const fn (ctx_ptr: ?*anyopaque, req: *Request, via: []const *const Request) anyerror!void = null,
    check_redirect_ctx: ?*anyopaque = null,
};

/// Client is a high-level HTTP client conforming to Go's net/http Client API.
///
/// Platform Limitation (Windows / Zig 0.17.0):
/// On Windows, socket timeout and deadline cancellations in `std.Io.Threaded` may trigger an
/// upstream panic in `batchDrainSubmittedWindows`. Fully supported and stable on Linux and macOS.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    custom_round_tripper: ?RoundTripper = null,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        var trans_opts = options.transport orelse TransportOptions{};
        var effective_timeout_ns = options.timeout_ns;
        if (options.timeout) |d| {
            if (effective_timeout_ns == null) {
                if (d.nanoseconds() > 0) effective_timeout_ns = @intCast(d.nanoseconds());
            }
        }
        if (options.proxy_url) |p| {
            trans_opts.proxy_url = p;
        }
        trans_opts.proxy_from_env = options.proxy_from_env;
        if (trans_opts.environ_map == null and options.environ_map != null) {
            trans_opts.environ_map = options.environ_map;
        }
        if (trans_opts.env_lookup == null and options.env_lookup != null) {
            trans_opts.env_lookup = options.env_lookup;
        }
        var client_opts = options;
        client_opts.timeout_ns = effective_timeout_ns;

        return .{
            .allocator = allocator,
            .io = io,
            .transport = Transport.init(allocator, io, trans_opts),
            .custom_round_tripper = options.round_tripper,
            .options = client_opts,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
    }

    /// closeIdleConnections closes any connections which were previously
    /// connected from previous requests but are now sitting idle in
    /// a "keep-alive" state.
    pub fn closeIdleConnections(self: *Client) void {
        if (self.custom_round_tripper) |rt| {
            rt.closeIdleConnections();
        } else {
            self.transport.closeIdleConnections();
        }
    }

    pub fn do(self: *Client, req: *Request, deadline: deadline_mod.Deadline) !Response {
        try deadline.validate();
        try self.io.checkCancel();
        const request_deadline = deadline.earlier(io_util.fromTimeout(self.io, self.options.timeout_ns));

        var current_url = try self.allocator.dupe(u8, req.url);
        defer self.allocator.free(current_url);

        var current_method = req.method;
        var current_body = req.body;
        var current_body_reader = req.body_reader;
        var redirects_followed: u8 = 0;

        var via = std.ArrayListUnmanaged(*Request).empty;
        defer {
            for (via.items) |v_req| {
                v_req.deinit();
                self.allocator.destroy(v_req);
            }
            via.deinit(self.allocator);
        }

        while (true) {
            try self.io.checkCancel();
            try request_deadline.check(self.io);

            const target = try parseUrlTarget(current_url);

            const round_trip_req = try self.allocator.create(Request);
            round_trip_req.* = Request.init(self.allocator, current_method, current_url);
            var owned_by_via = false;
            errdefer if (!owned_by_via) {
                round_trip_req.deinit();
                self.allocator.destroy(round_trip_req);
            };

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
            var resp = if (self.custom_round_tripper) |rt|
                try rt.roundTrip(round_trip_req, request_deadline)
            else
                try self.transport.roundTripWithBudget(round_trip_req, request_deadline);
            request_deadline.check(self.io) catch |err| {
                resp.close();
                return err;
            };

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
                try via.append(self.allocator, round_trip_req);
                owned_by_via = true;

                if (self.options.check_redirect) |check_fn| {
                    const const_via: []const *const Request = @ptrCast(via.items);
                    try check_fn(self.options.check_redirect_ctx, req, const_via);
                } else if (redirects_followed >= self.options.max_redirects) {
                    resp.close();
                    return error.TooManyRedirects;
                }

                const location = resp.header.get("Location") orelse {
                    request_deadline.check(self.io) catch |err| {
                        resp.close();
                        return err;
                    };
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
                    const host_root = if (slash_idx) |idx| current_url[0 .. host_start + idx] else current_url;
                    if (std.mem.startsWith(u8, location, "/")) {
                        new_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ host_root, location });
                    } else {
                        const last_slash = std.mem.lastIndexOfScalar(u8, current_url, '/');
                        const dir_base = if (last_slash) |ls| current_url[0 .. ls + 1] else host_root;
                        new_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dir_base, location });
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

            request_deadline.check(self.io) catch |err| {
                resp.close();
                return err;
            };
            round_trip_req.deinit();
            self.allocator.destroy(round_trip_req);
            return resp;
        }
    }

    pub fn get(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .GET, url);
        defer req.deinit();
        return self.do(&req, .none);
    }

    pub fn head(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .HEAD, url);
        defer req.deinit();
        return self.do(&req, .none);
    }

    pub fn post(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .POST, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req, .none);
    }

    pub fn put(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .PUT, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req, .none);
    }

    pub fn delete(self: *Client, url: []const u8) !Response {
        var req = Request.init(self.allocator, .DELETE, url);
        defer req.deinit();
        return self.do(&req, .none);
    }

    pub fn patch(self: *Client, url: []const u8, content_type: []const u8, body: []const u8) !Response {
        var req = Request.init(self.allocator, .PATCH, url);
        defer req.deinit();
        try req.header.set("Content-Type", content_type);
        try req.setBody(body);
        return self.do(&req, .none);
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
    // Zig 0.17.0 std.Io.Threaded has an upstream union panic on Windows when socket operations cancel/timeout.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c = Client.init(testing.allocator, io, .{
        .timeout_ns = 3 * std.time.ns_per_s,
        .transport = .{ .max_idle_conns_per_host = 2 },
    });
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

        var resp = c.do(&req, .none) catch |err| {
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

test "Client: expired and invalid deadlines fail before request" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c = Client.init(testing.allocator, io, .{});
    defer c.deinit();

    var req = try newRequest(testing.allocator, .GET, "http://127.0.0.1:9", null);
    defer req.deinit();
    const deadline = deadline_mod.Deadline.after(io, .zero);
    try testing.expectError(error.Timeout, c.do(&req, deadline));
    const invalid: deadline_mod.Deadline = .{ .timestamp = .now(io, .real) };
    try testing.expectError(error.InvalidDeadline, c.do(&req, invalid));
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

    var resp = try c.do(&req, .none);
    defer resp.close();

    t1.join();
    t2.join();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expectEqual(@as(usize, 1), state.redirect_calls);
    // Crucial security check: cross-origin (127.0.0.1 -> localhost) must strip Authorization!
    try testing.expect(!auth_present_on_s2);
}

test "Client: max_redirects exceeded returns error.TooManyRedirects without double-free" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try loopback.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    const ServerHandler = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io) !void {
            for (0..2) |_| {
                var conn = try s.accept(s_io);
                defer conn.close(s_io);

                var read_buf: [512]u8 = undefined;
                var sr = conn.reader(s_io, &read_buf);
                while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                    try sr.interface.fillMore();
                }

                var w_buf: [256]u8 = undefined;
                var sw = conn.writer(s_io, &w_buf);
                // Return 302 redirecting back to itself with Connection: close to avoid keep-alive race
                const resp = "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                try sw.interface.writeAll(resp);
                try sw.interface.flush();
            }
        }
    };

    const s_thread = try std.Thread.spawn(.{}, ServerHandler.run, .{ &server, io });

    var c = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .max_redirects = 1,
    });
    defer c.deinit();

    const start_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/start", .{port});
    defer testing.allocator.free(start_url);

    var req = try newRequest(testing.allocator, .GET, start_url, null);
    defer req.deinit();

    const res = c.do(&req, .none);
    try testing.expectError(error.TooManyRedirects, res);

    s_thread.join();
}

test "Client: Streaming request body with Reader and Chunked Transfer-Encoding" {
    const testing = std.testing;

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
    var src = std.Io.Reader.fixed("first-chunk second-chunk third-chunk");
    const target_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/stream-upload", .{port});
    defer testing.allocator.free(target_url);

    // Create request with body_reader and unknown length (null) -> chunked
    var req = try newRequestWithReader(testing.allocator, .POST, target_url, &src, null);
    defer req.deinit();

    var c = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
    });
    defer c.deinit();

    var resp = try c.do(&req, .none);
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

test "Client: timeout interrupts socket reads and writes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Scenario = enum { headers, body, gzip, upload, tls, socks, connect_proxy, transport_headers, zero_timeout, tls_phase, header_phase };
    const Server = struct {
        fn run(server: *std.Io.net.Server, server_io: std.Io, scenario: Scenario) !void {
            var stream = try server.accept(server_io);
            defer stream.close(server_io);
            if (scenario == .body or scenario == .gzip or scenario == .zero_timeout) {
                var read_buf: [1024]u8 = undefined;
                var reader = stream.reader(server_io, &read_buf);
                while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                    try reader.interface.fillMore();
                }
                var write_buf: [512]u8 = undefined;
                var writer = stream.writer(server_io, &write_buf);
                if (scenario == .zero_timeout) {
                    try std.Io.sleep(server_io, .fromMilliseconds(250), .awake);
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
                } else if (scenario == .body) {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na");
                } else {
                    try writer.interface.writeAll(
                        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 30\r\n\r\n" ++
                            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03",
                    );
                }
                try writer.interface.flush();
            }
            try std.Io.sleep(server_io, .fromMilliseconds(700), .awake);
        }
    };

    for ([_]Scenario{ .headers, .body, .gzip, .upload, .tls, .socks, .connect_proxy, .transport_headers, .zero_timeout, .tls_phase, .header_phase }) |scenario| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        const url = try testing.allocator.print("{s}://127.0.0.1:{d}/", .{
            if (scenario == .tls or scenario == .connect_proxy or scenario == .tls_phase) "https" else "http",
            server.socket.address.ip4.port,
        });
        defer testing.allocator.free(url);
        const proxy = try testing.allocator.print("{s}://127.0.0.1:{d}", .{
            if (scenario == .connect_proxy) "http" else "socks5h",
            server.socket.address.ip4.port,
        });
        defer testing.allocator.free(proxy);

        var client = Client.init(testing.allocator, io, .{
            .proxy_from_env = false,
            .proxy_url = if (scenario == .socks or scenario == .connect_proxy) proxy else null,
            .transport = if (scenario == .transport_headers)
                .{ .timeout_ns = 200 * std.time.ns_per_ms }
            else if (scenario == .tls_phase)
                .{ .tls_handshake_timeout = @fromBackingInt(200 * std.time.ns_per_ms) }
            else if (scenario == .header_phase)
                .{ .response_header_timeout = @fromBackingInt(200 * std.time.ns_per_ms) }
            else
                null,
            .timeout_ns = if (scenario == .transport_headers or scenario == .tls_phase or scenario == .header_phase)
                null
            else if (scenario == .zero_timeout)
                0
            else
                200 * std.time.ns_per_ms,
        });
        defer client.deinit();
        var req = Request.init(testing.allocator, if (scenario == .upload) .POST else .GET, url);
        defer req.deinit();
        const upload = try testing.allocator.alloc(u8, if (scenario == .upload) 16 * 1024 * 1024 else 0);
        defer testing.allocator.free(upload);
        @memset(upload, 0x61);
        if (scenario == .upload) try req.setBody(upload);
        var server_task = try io.concurrent(Server.run, .{ &server, io, scenario });
        defer server_task.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
        };

        if (scenario == .zero_timeout) {
            var response = try client.do(&req, .none);
            response.close();
        } else if (scenario == .body or scenario == .gzip) {
            var response = try client.do(&req, .none);
            defer response.close();
            var bytes: [64]u8 = undefined;
            if (scenario == .body) {
                try testing.expectEqual(@as(usize, 1), try response.body.read(&bytes));
            }
            try testing.expectError(error.Timeout, response.body.read(&bytes));
            var reader_buffer: [32]u8 = undefined;
            try testing.expectError(error.ReadFailed, response.reader(&reader_buffer).takeByte());
            try testing.expectEqual(error.Timeout, response.body.read_err.?);
            response.close();
            try testing.expectEqual(@as(usize, 0), client.transport.pool.entries.items.len);
        } else {
            try testing.expectError(error.Timeout, client.do(&req, .none));
        }
    }
}

test "Client: timeout budget spans redirects" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const Server = struct {
        fn run(s: *std.Io.net.Server, server_io: std.Io) !void {
            for (0..2) |index| {
                var stream = try s.accept(server_io);
                defer stream.close(server_io);
                var read_buf: [1024]u8 = undefined;
                var reader = stream.reader(server_io, &read_buf);
                while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                    try reader.interface.fillMore();
                }
                try std.Io.sleep(server_io, .fromMilliseconds(250), .awake);
                if (index == 0) {
                    var write_buf: [256]u8 = undefined;
                    var writer = stream.writer(server_io, &write_buf);
                    try writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    try writer.interface.flush();
                }
            }
        }
    };
    const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);
    var client = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .timeout_ns = 400 * std.time.ns_per_ms,
    });
    defer client.deinit();
    var server_task = try io.concurrent(Server.run, .{ &server, io });
    defer server_task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
    };
    try testing.expectError(error.Timeout, client.get(url));
}

test "Client: body deadline remains active after headers arrive" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const Server = struct {
        fn run(s: *std.Io.net.Server, server_io: std.Io) !void {
            var stream = try s.accept(server_io);
            defer stream.close(server_io);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(server_io, &read_buf);
            while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                try reader.interface.fillMore();
            }
            var write_buf: [128]u8 = undefined;
            var writer = stream.writer(server_io, &write_buf);
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
            try writer.interface.flush();
            try std.Io.sleep(server_io, .fromMilliseconds(400), .awake);
        }
    };
    const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);
    var client = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .timeout_ns = 120 * std.time.ns_per_ms,
    });
    defer client.deinit();
    var server_task = try io.concurrent(Server.run, .{ &server, io });
    defer server_task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
    };
    var response = try client.get(url);
    defer response.close();
    try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    var bytes: [2]u8 = undefined;
    try testing.expectError(error.Timeout, response.body.read(&bytes));
}

test "Client: Expect 100-continue handles interim responses and early rejection" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Scenario = enum { accepted, partial_timeout, rejected, immediate };
    const Server = struct {
        fn run(server: *std.Io.net.Server, server_io: std.Io, scenario: Scenario) !void {
            var stream = try server.accept(server_io);
            defer stream.close(server_io);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(server_io, &read_buf);
            while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                try reader.interface.fillMore();
            }
            const end = std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n").? + 4;
            reader.interface.toss(end);
            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(server_io, &write_buf);
            switch (scenario) {
                .accepted => try writer.interface.writeAll(
                    "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n",
                ),
                .partial_timeout => try writer.interface.writeAll("HTTP/1.1 100"),
                .rejected => try writer.interface.writeAll(
                    "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
                ),
                .immediate => {},
            }
            try writer.interface.flush();
            if (scenario == .rejected) {
                try testing.expectEqual(@as(usize, 0), reader.interface.buffered().len);
                try testing.expectError(error.EndOfStream, reader.interface.fillMore());
                return;
            }
            try reader.interface.fill(3);
            try testing.expectEqualStrings("abc", reader.interface.buffered()[0..3]);
            if (scenario == .partial_timeout) {
                try writer.interface.writeAll(" Continue\r\n\r\n");
            }
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
            try writer.interface.flush();
        }
    };
    for ([_]Scenario{ .accepted, .partial_timeout, .rejected, .immediate }) |scenario| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
        defer testing.allocator.free(url);
        var client = Client.init(testing.allocator, io, .{
            .proxy_from_env = false,
            .timeout_ns = 2 * std.time.ns_per_s,
            .transport = .{
                .expect_continue_timeout = if (scenario == .immediate)
                    null
                else
                    @fromBackingInt(50 * std.time.ns_per_ms),
            },
        });
        defer client.deinit();
        var server_task = try io.concurrent(Server.run, .{ &server, io, scenario });
        defer server_task.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.debug.panic("100-continue test server: {s}", .{@errorName(err)}),
        };
        var request = Request.init(testing.allocator, .POST, url);
        defer request.deinit();
        try request.setBody("abc");
        try request.header.add("Expect", "100-continue");
        var response = try client.do(&request, .none);
        try testing.expectEqual(@as(u16, if (scenario == .rejected) 417 else 200), response.status_code);
        response.close();
        try server_task.await(io);
    }
}

test "Client: custom round tripper receives the earliest request deadline" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Custom = struct {
        received: deadline_mod.Deadline = .none,

        fn roundTrip(ctx: *anyopaque, _: *Request, deadline: deadline_mod.Deadline) anyerror!Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.received = deadline;
            return error.TestRoundTrip;
        }
    };
    var custom: Custom = .{};
    const vtable: RoundTripper.VTable = .{ .roundTrip = Custom.roundTrip };
    var client = Client.init(testing.allocator, io, .{
        .round_tripper = .{ .ptr = &custom, .vtable = &vtable },
        .timeout_ns = 30 * std.time.ns_per_s,
    });
    defer client.deinit();
    var req = Request.init(testing.allocator, .GET, "http://example.test/");
    defer req.deinit();

    const deadline = deadline_mod.Deadline.after(io, .fromSeconds(1));
    try testing.expectError(error.TestRoundTrip, client.do(&req, deadline));
    try testing.expectEqual(deadline.timestamp.?, custom.received.timestamp.?);
    try testing.expectError(error.TestRoundTrip, client.do(&req, .none));
    try testing.expect(!custom.received.isNone());
    try custom.received.check(io);
}

test "Client: cancellation interrupts a timed socket read" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var accepted: std.Io.Event = .unset;
    const Server = struct {
        fn run(s: *std.Io.net.Server, server_io: std.Io, ready: *std.Io.Event) !void {
            var stream = try s.accept(server_io);
            defer stream.close(server_io);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(server_io, &read_buf);
            while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                try reader.interface.fillMore();
            }
            ready.set(server_io);
            try std.Io.sleep(server_io, .fromMilliseconds(500), .awake);
        }
    };
    const Worker = struct {
        fn run(client: *Client, url: []const u8) !void {
            var response = try client.get(url);
            response.close();
        }
    };
    const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);
    var client = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer client.deinit();
    var server_task = try io.concurrent(Server.run, .{ &server, io, &accepted });
    defer server_task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
    };
    var future = try io.concurrent(Worker.run, .{ &client, url });
    try accepted.wait(io);
    try testing.expectError(error.Canceled, future.cancel(io));
}

test "Client: pooled connections receive a fresh request deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const Server = struct {
        fn run(s: *std.Io.net.Server, server_io: std.Io) !void {
            var stream = try s.accept(server_io);
            defer stream.close(server_io);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(server_io, &read_buf);
            var write_buf: [128]u8 = undefined;
            var writer = stream.writer(server_io, &write_buf);
            for (0..2) |_| {
                while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                    try reader.interface.fillMore();
                }

                const end = std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n").? + 4;
                reader.interface.toss(end);
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");
                try writer.interface.flush();
            }
        }
    };
    const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);
    var client = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .timeout_ns = 200 * std.time.ns_per_ms,
    });
    defer client.deinit();
    var server_task = try io.concurrent(Server.run, .{ &server, io });
    defer server_task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
    };
    var first = try client.get(url);
    const first_body = try first.readAllAlloc(2);
    defer testing.allocator.free(first_body);
    first.close();
    try testing.expectEqual(@as(usize, 1), client.transport.pool.entries.items.len);
    try std.Io.sleep(io, .fromMilliseconds(250), .awake);
    var second = try client.get(url);
    defer second.close();
    const second_body = try second.readAllAlloc(2);
    defer testing.allocator.free(second_body);
    try testing.expectEqualStrings("OK", second_body);
}

test "Client: cancellation interrupts a timed socket write" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var accepted: std.Io.Event = .unset;
    const Server = struct {
        fn run(s: *std.Io.net.Server, server_io: std.Io, ready: *std.Io.Event) !void {
            var stream = try s.accept(server_io);
            defer stream.close(server_io);
            var buffer: [1024]u8 = undefined;
            var reader = stream.reader(server_io, &buffer);
            while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                try reader.interface.fillMore();
            }
            ready.set(server_io);
            try std.Io.sleep(server_io, .fromSeconds(1), .awake);
        }
    };
    const Worker = struct {
        fn run(client: *Client, url: []const u8, payload: []const u8) !void {
            var request = Request.init(client.allocator, .POST, url);
            defer request.deinit();
            try request.setBody(payload);
            var response = try client.do(&request, .none);
            response.close();
        }
    };
    const url = try testing.allocator.print("http://127.0.0.1:{d}/", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);
    const payload = try testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 0x61);
    var client = Client.init(testing.allocator, io, .{
        .proxy_from_env = false,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer client.deinit();
    var server_task = try io.concurrent(Server.run, .{ &server, io, &accepted });
    defer server_task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("HTTP test server: {s}", .{@errorName(err)}),
    };
    var future = try io.concurrent(Worker.run, .{ &client, url, payload });
    try accepted.wait(io);
    try testing.expectError(error.Canceled, future.cancel(io));
}
