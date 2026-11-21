//! HTTP/HTTPS Transport executing round trips over TCP / TLS streams.
const std = @import("std");
const Request = @import("request.zig").Request;
const parseUrlTarget = @import("request.zig").parseUrlTarget;
const Response = @import("response.zig").Response;
const ResponseBodyReader = @import("response.zig").ResponseBodyReader;
const parseResponseHead = @import("response_parser.zig").parseResponseHead;
const ConnPool = @import("pool.zig").ConnPool;
const HttpConn = @import("conn.zig").HttpConn;
const io_util = @import("../io_util.zig");
const proxy_mod = @import("proxy.zig");
const socks5 = @import("socks5.zig");
const time_mod = @import("../../time.zig");
const deadline_mod = @import("../../io/deadline.zig");
const connect_mod = @import("../connect.zig");

fn durationDeadline(io: std.Io, duration: ?time_mod.Duration) deadline_mod.Deadline {
    const ns = if (duration) |value| value.nanoseconds() else return .none;
    if (ns <= 0) return .none;
    return .after(io, .{ .nanoseconds = ns });
}

/// RoundTripper is an interface representing the ability to execute a
/// single HTTP transaction, obtaining the Response for a given Request.
pub const RoundTripper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        roundTrip: *const fn (ctx: *anyopaque, req: *Request, deadline: deadline_mod.Deadline) anyerror!Response,
        closeIdleConnections: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn roundTrip(self: RoundTripper, req: *Request, deadline: deadline_mod.Deadline) anyerror!Response {
        return self.vtable.roundTrip(self.ptr, req, deadline);
    }

    pub fn closeIdleConnections(self: RoundTripper) void {
        if (self.vtable.closeIdleConnections) |closeFn| {
            closeFn(self.ptr);
        }
    }
};

pub const TransportOptions = struct {
    proxy_url: ?[]const u8 = null,
    proxy_from_env: bool = true,
    /// Explicit environment map (e.g. from init.environ_map in main).
    environ_map: ?*const std.process.Environ.Map = null,
    /// Custom environment lookup function. If set, takes precedence over environ_map.
    env_lookup: ?*const fn (key: []const u8) ?[]const u8 = null,
    /// Total round-trip and body-read budget.
    /// Note: On Windows (Zig 0.17.0), socket deadline cancellation may encounter an upstream panic in std.Io.Threaded.
    timeout_ns: ?u64 = null,
    timeout: ?time_mod.Duration = null,
    tls_handshake_timeout: ?time_mod.Duration = null,
    response_header_timeout: ?time_mod.Duration = null,
    /// Time to wait for 100 Continue before sending the request body.
    expect_continue_timeout: ?time_mod.Duration = null,
    /// Connections are closed proactively after this long in the idle pool.
    idle_conn_timeout: ?time_mod.Duration = null,
    max_idle_conns_per_host: usize = 2,
    insecure_skip_verify: bool = false,
    disable_compression: bool = false,
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
};

/// Keep at a stable address after the first request when idle expiration is enabled.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: TransportOptions,
    pool: ConnPool,
    ca_bundle: ?std.crypto.Certificate.Bundle = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: TransportOptions) Transport {
        var opts = options;
        if (opts.timeout) |d| {
            if (opts.timeout_ns == null) {
                if (d.nanoseconds() > 0) opts.timeout_ns = @intCast(d.nanoseconds());
            }
        }
        var pool = ConnPool.init(allocator, options.max_idle_conns_per_host);
        if (options.idle_conn_timeout) |duration| {
            if (duration.nanoseconds() > 0) {
                pool.idle_timeout = .{ .nanoseconds = duration.nanoseconds() };
            }
        }
        return .{
            .allocator = allocator,
            .io = io,
            .options = opts,
            .pool = pool,
            .ca_bundle = null,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.pool.deinit(self.io);
        if (self.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
            self.ca_bundle = null;
        }
    }

    /// closeIdleConnections closes any connections which were previously
    /// connected from previous requests but are now sitting idle in
    /// a "keep-alive" state.
    pub fn closeIdleConnections(self: *Transport) void {
        self.pool.closeIdleConnections(self.io);
    }

    pub fn roundTripper(self: *Transport) RoundTripper {
        return .{
            .ptr = self,
            .vtable = &transport_vtable,
        };
    }

    const transport_vtable: RoundTripper.VTable = .{
        .roundTrip = vtableRoundTrip,
        .closeIdleConnections = vtableCloseIdleConnections,
    };

    fn vtableRoundTrip(ctx: *anyopaque, req: *Request, deadline: deadline_mod.Deadline) anyerror!Response {
        const self: *Transport = @ptrCast(@alignCast(ctx));
        return self.roundTrip(req, deadline);
    }

    fn vtableCloseIdleConnections(ctx: *anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(ctx));
        self.closeIdleConnections();
    }

    fn connectStream(io: std.Io, host: []const u8, port: u16, deadline: deadline_mod.Deadline) !std.Io.net.Stream {
        return connect_mod.connectOrdered(io, host, port, deadline);
    }

    fn readResponseHeader(self: *Transport, conn: *HttpConn) ![]u8 {
        const reader = conn.reader();
        while (true) {
            try conn.checkDeadline();
            const buffered = reader.buffered();
            if (std.mem.indexOf(u8, buffered, "\r\n\r\n")) |index| {
                const length = index + 4;
                const header = try self.allocator.dupe(u8, buffered[0..length]);
                reader.toss(length);
                return header;
            }
            if (buffered.len >= 16 * 1024) return error.ResponseHeaderTooLarge;
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return if (buffered.len == 0)
                    error.EmptyResponse
                else
                    error.ConnectionClosedPrematurely,
                else => |e| return conn.ioError(e),
            };
        }
    }

    fn expectsContinue(req: *const Request) bool {
        const value = req.header.get("Expect") orelse return false;
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |token| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "100-continue")) return true;
        }
        return false;
    }

    fn establishConnectTunnel(io: std.Io, stream: std.Io.net.Stream, host: []const u8, port: u16, auth: ?[]const u8, deadline: deadline_mod.Deadline) !void {
        var write_buf: [512]u8 = undefined;
        var stream_w: io_util.SocketWriter = .init(io, stream, &write_buf, deadline);
        const w = &stream_w.interface;

        var req_buf: [512]u8 = undefined;
        const req_str = if (auth) |a|
            try std.fmt.bufPrint(
                &req_buf,
                "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: curl/8.7.1\r\nProxy-Connection: Keep-Alive\r\nProxy-Authorization: {s}\r\n\r\n",
                .{ host, port, host, port, a },
            )
        else
            try std.fmt.bufPrint(
                &req_buf,
                "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: curl/8.7.1\r\nProxy-Connection: Keep-Alive\r\n\r\n",
                .{ host, port, host, port },
            );
        w.writeAll(req_str) catch |err| return stream_w.err orelse err;
        w.flush() catch |err| return stream_w.err orelse err;

        var read_buf: [1024]u8 = undefined;
        var stream_r: io_util.SocketReader = .init(io, stream, &read_buf, deadline);
        const r = &stream_r.interface;

        const proxy_head_bytes_max = read_buf.len;
        while (true) {
            const buffered = r.buffered();
            if (std.mem.indexOf(u8, buffered, "\r\n\r\n")) |idx| {
                const head = buffered[0..idx];
                if (std.mem.indexOf(u8, head, " 200") == null) {
                    return error.ProxyConnectionRefused;
                }
                r.toss(idx + 4);
                break;
            }
            if (buffered.len >= proxy_head_bytes_max) {
                return error.ProxyResponseTooLarge;
            }
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosedPrematurely,
                else => |e| return stream_r.err orelse e,
            };
        }
    }

    pub fn roundTrip(self: *Transport, req: *Request, deadline: deadline_mod.Deadline) !Response {
        try deadline.validate();
        return self.roundTripWithBudget(req, deadline);
    }

    pub fn roundTripWithBudget(self: *Transport, req: *Request, client_deadline: deadline_mod.Deadline) !Response {
        try client_deadline.validate();
        const deadline = io_util.earlier(client_deadline, io_util.fromTimeout(self.io, self.options.timeout_ns));
        try deadline.check(self.io);
        try self.io.checkCancel();
        try self.pool.start(self.io);

        const target = try parseUrlTarget(req.url);

        var resolved_proxy_to_free: ?[]const u8 = null;
        defer if (resolved_proxy_to_free) |p| self.allocator.free(p);

        var effective_proxy_url: ?[]const u8 = self.options.proxy_url;
        if (effective_proxy_url == null and self.options.proxy_from_env) {
            if (self.options.env_lookup) |lookup| {
                if (try proxy_mod.proxyFromEnvWithLookup(self.allocator, target.scheme, target.host, lookup)) |p| {
                    resolved_proxy_to_free = p;
                    effective_proxy_url = p;
                }
            } else if (self.options.environ_map) |env_map| {
                if (try proxy_mod.proxyFromEnvWithMap(self.allocator, target.scheme, target.host, env_map)) |p| {
                    resolved_proxy_to_free = p;
                    effective_proxy_url = p;
                }
            } else {
                if (try proxy_mod.proxyFromEnvironment(self.allocator, target.scheme, target.host)) |p| {
                    resolved_proxy_to_free = p;
                    effective_proxy_url = p;
                }
            }
        }
        const use_proxy = effective_proxy_url != null;

        var proxy_auth_header: ?[]const u8 = null;
        var proxy_clean_url_to_free: ?[]const u8 = null;
        var is_socks_proxy = false;
        var socks_user_to_free: ?[]const u8 = null;
        var socks_pass_to_free: ?[]const u8 = null;
        defer if (proxy_clean_url_to_free) |u| self.allocator.free(u);
        defer if (proxy_auth_header) |a| self.allocator.free(a);
        defer if (socks_user_to_free) |u| self.allocator.free(u);
        defer if (socks_pass_to_free) |p| self.allocator.free(p);

        var proxy_connect_url: ?[]const u8 = null;
        if (effective_proxy_url) |raw_proxy| {
            const details = try proxy_mod.parseProxyDetails(self.allocator, raw_proxy);
            proxy_clean_url_to_free = details.clean_proxy_url;
            proxy_auth_header = details.proxy_auth;
            proxy_connect_url = details.clean_proxy_url;
            is_socks_proxy = details.is_socks5;
            socks_user_to_free = details.socks_user;
            socks_pass_to_free = details.socks_pass;
        }

        var allow_pool = true;
        while (true) {
            const pooled = if (!use_proxy and allow_pool) self.pool.acquire(target.host, target.port, target.is_tls) else null;
            var conn: *HttpConn = if (pooled) |c|
                c
            else blk: {
                if (proxy_connect_url) |proxy_url| {
                    const proxy_target = try parseUrlTarget(proxy_url);
                    var stream = try connectStream(self.io, proxy_target.host, proxy_target.port, deadline);
                    errdefer stream.close(self.io);
                    try deadline.check(self.io);

                    if (is_socks_proxy) {
                        var read_buf: [512]u8 = undefined;
                        var write_buf: [512]u8 = undefined;
                        var reader: io_util.SocketReader = .init(self.io, stream, &read_buf, deadline);
                        var writer: io_util.SocketWriter = .init(self.io, stream, &write_buf, deadline);
                        socks5.establishWithReaderWriter(
                            &reader.interface,
                            &writer.interface,
                            target.host,
                            target.port,
                            if (socks_user_to_free != null) .{
                                .username = socks_user_to_free,
                                .password = socks_pass_to_free,
                            } else null,
                        ) catch |err| {
                            if (reader.err) |read_err| return read_err;
                            if (writer.err) |write_err| return write_err;
                            return err;
                        };
                        if (target.is_tls) {
                            const tls_deadline = deadline.earlier(durationDeadline(self.io, self.options.tls_handshake_timeout));
                            break :blk try HttpConn.initTls(
                                self.allocator,
                                self.io,
                                stream,
                                target.host,
                                self.options.ca_bundle,
                                self.options.insecure_skip_verify,
                                tls_deadline,
                            );
                        } else {
                            break :blk try HttpConn.initPlain(self.allocator, self.io, stream, deadline);
                        }
                    } else if (target.is_tls) {
                        try establishConnectTunnel(self.io, stream, target.host, target.port, proxy_auth_header, deadline);
                        const tls_deadline = deadline.earlier(durationDeadline(self.io, self.options.tls_handshake_timeout));
                        break :blk try HttpConn.initTls(
                            self.allocator,
                            self.io,
                            stream,
                            target.host,
                            self.options.ca_bundle,
                            self.options.insecure_skip_verify,
                            tls_deadline,
                        );
                    } else {
                        break :blk try HttpConn.initPlain(self.allocator, self.io, stream, deadline);
                    }
                } else {
                    var stream = try connectStream(self.io, target.host, target.port, deadline);
                    errdefer stream.close(self.io);
                    try deadline.check(self.io);

                    if (target.is_tls) {
                        const tls_deadline = deadline.earlier(durationDeadline(self.io, self.options.tls_handshake_timeout));
                        break :blk try HttpConn.initTls(
                            self.allocator,
                            self.io,
                            stream,
                            target.host,
                            self.options.ca_bundle,
                            self.options.insecure_skip_verify,
                            tls_deadline,
                        );
                    } else {
                        break :blk try HttpConn.initPlain(self.allocator, self.io, stream, deadline);
                    }
                }
            };
            errdefer {
                conn.close(self.io);
                self.allocator.destroy(conn);
            }
            conn.setDeadline(deadline);
            try conn.checkDeadline();

            // Serialize HTTP/1.1 request
            var req_buf = std.ArrayListUnmanaged(u8).empty;
            defer req_buf.deinit(self.allocator);

            try req_buf.appendSlice(self.allocator, req.method.asString());
            try req_buf.append(self.allocator, ' ');
            if (use_proxy and !target.is_tls and !is_socks_proxy) {
                // Forward proxy plain HTTP request uses absolute URI
                if (std.mem.startsWith(u8, req.url, "http://") or std.mem.startsWith(u8, req.url, "https://")) {
                    try req_buf.appendSlice(self.allocator, req.url);
                } else {
                    try req_buf.appendSlice(self.allocator, "http://");
                    try req_buf.appendSlice(self.allocator, req.url);
                }
            } else {
                if (!std.mem.startsWith(u8, target.request_target, "/")) {
                    try req_buf.append(self.allocator, '/');
                }
                try req_buf.appendSlice(self.allocator, target.request_target);
            }
            try req_buf.appendSlice(self.allocator, " HTTP/1.1\r\n");

            if (req.header.get("Host") == null) {
                try req_buf.appendSlice(self.allocator, "Host: ");
                try req_buf.appendSlice(self.allocator, target.host);
                const is_default_port = (!target.is_tls and target.port == 80) or (target.is_tls and target.port == 443);
                if (!is_default_port) {
                    var port_buf: [8]u8 = undefined;
                    const port_str = try std.fmt.bufPrint(&port_buf, ":{d}", .{target.port});
                    try req_buf.appendSlice(self.allocator, port_str);
                }
                try req_buf.appendSlice(self.allocator, "\r\n");
            }

            if (use_proxy and !target.is_tls and !is_socks_proxy) {
                if (req.header.get("Proxy-Connection") == null) {
                    try req_buf.appendSlice(self.allocator, "Proxy-Connection: Keep-Alive\r\n");
                }
                if (proxy_auth_header) |auth| {
                    if (req.header.get("Proxy-Authorization") == null) {
                        try req_buf.appendSlice(self.allocator, "Proxy-Authorization: ");
                        try req_buf.appendSlice(self.allocator, auth);
                        try req_buf.appendSlice(self.allocator, "\r\n");
                    }
                }
            }

            if (req.header.get("User-Agent") == null) {
                try req_buf.appendSlice(self.allocator, "User-Agent: curl/8.7.1\r\n");
            }
            if (req.header.get("Accept") == null) {
                try req_buf.appendSlice(self.allocator, "Accept: */*\r\n");
            }
            if (!self.options.disable_compression and req.header.get("Accept-Encoding") == null) {
                try req_buf.appendSlice(self.allocator, "Accept-Encoding: gzip\r\n");
            }
            if (req.header.get("Connection") == null) {
                if (self.options.max_idle_conns_per_host > 0) {
                    try req_buf.appendSlice(self.allocator, "Connection: keep-alive\r\n");
                } else {
                    try req_buf.appendSlice(self.allocator, "Connection: close\r\n");
                }
            }

            if (req.body) |b| {
                if (req.header.get("Content-Length") == null and req.header.get("Transfer-Encoding") == null) {
                    var cl_buf: [32]u8 = undefined;
                    const cl_str = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}\r\n", .{b.len});
                    try req_buf.appendSlice(self.allocator, cl_str);
                }
            } else if (req.body_reader != null) {
                if (req.content_length) |len| {
                    if (req.header.get("Content-Length") == null and req.header.get("Transfer-Encoding") == null) {
                        var cl_buf: [32]u8 = undefined;
                        const cl_str = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}\r\n", .{len});
                        try req_buf.appendSlice(self.allocator, cl_str);
                    }
                } else {
                    if (req.header.get("Transfer-Encoding") == null) {
                        try req_buf.appendSlice(self.allocator, "Transfer-Encoding: chunked\r\n");
                    }
                }
            }

            for (req.header.entries.items) |entry| {
                try req_buf.appendSlice(self.allocator, entry.name);
                try req_buf.appendSlice(self.allocator, ": ");
                try req_buf.appendSlice(self.allocator, entry.value);
                try req_buf.appendSlice(self.allocator, "\r\n");
            }
            try req_buf.appendSlice(self.allocator, "\r\n");

            const write_res = conn.writeAll(req_buf.items);
            if (write_res) |_| {} else |err| {
                if (pooled != null and req.body_reader == null and err != error.Timeout and err != error.Canceled) {
                    conn.close(self.io);
                    self.allocator.destroy(conn);
                    allow_pool = false;
                    continue;
                }
                return err;
            }

            var early_header: ?[]u8 = null;
            var informational_count: usize = 0;
            var continue_retry = false;
            const has_body = if (req.body) |body| body.len != 0 else req.body_reader != null;
            const continue_deadline = durationDeadline(self.io, self.options.expect_continue_timeout);
            if (has_body and expectsContinue(req) and !continue_deadline.isNone()) {
                conn.setDeadline(deadline.earlier(continue_deadline));
                while (true) {
                    const raw = self.readResponseHeader(conn) catch |err| switch (err) {
                        error.Timeout => {
                            conn.stream_reader.err = null;
                            try deadline.check(self.io);
                            break;
                        },
                        error.EmptyResponse => {
                            if (pooled != null and req.body_reader == null) {
                                continue_retry = true;
                                break;
                            }
                            return error.ConnectionClosedPrematurely;
                        },
                        else => return err,
                    };
                    const interim = parseResponseHead(self.allocator, raw) catch |err| {
                        self.allocator.free(raw);
                        return err;
                    };
                    var headers = interim.headers;
                    headers.deinit();
                    if (interim.status_code == 100) {
                        self.allocator.free(raw);
                        break;
                    }
                    if (interim.status_code >= 100 and interim.status_code < 200 and interim.status_code != 101) {
                        informational_count += 1;
                        if (informational_count > 100) {
                            self.allocator.free(raw);
                            return error.TooManyInformationalResponses;
                        }
                        self.allocator.free(raw);
                        continue;
                    }
                    early_header = raw;
                    break;
                }
                conn.setDeadline(deadline);
            }
            if (continue_retry) {
                conn.close(self.io);
                self.allocator.destroy(conn);
                allow_pool = false;
                continue;
            }
            const sent_body = early_header == null;
            errdefer if (early_header) |raw| self.allocator.free(raw);

            if (early_header == null) if (req.body) |b| {
                const body_res = conn.writeAll(b);
                if (body_res) |_| {} else |err| {
                    if (pooled != null and req.body_reader == null and err != error.Timeout and err != error.Canceled) {
                        conn.close(self.io);
                        self.allocator.destroy(conn);
                        allow_pool = false;
                        continue;
                    }
                    return err;
                }
            } else if (req.body_reader) |r| {
                var buf: [4096]u8 = undefined;
                if (req.content_length != null) {
                    var remaining = req.content_length.?;
                    while (remaining > 0) {
                        const to_read = @min(buf.len, remaining);
                        const n = try io_util.readBody(self.io, r, buf[0..to_read], deadline);
                        if (n == 0) break;
                        try conn.writeAll(buf[0..n]);
                        remaining -= n;
                    }
                } else {
                    // chunked streaming upload
                    while (true) {
                        const n = try io_util.readBody(self.io, r, &buf, deadline);
                        if (n == 0) break;
                        var hex_buf: [16]u8 = undefined;
                        const hex_str = try std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{n});
                        try conn.writeAll(hex_str);
                        try conn.writeAll(buf[0..n]);
                        try conn.writeAll("\r\n");
                    }
                    try conn.writeAll("0\r\n\r\n");
                }
            };

            if (early_header == null) {
                conn.setDeadline(deadline.earlier(durationDeadline(self.io, self.options.response_header_timeout)));
            }
            var header_retry = false;
            var raw_head: []u8 = undefined;
            while (true) {
                raw_head = early_header orelse self.readResponseHeader(conn) catch |err| switch (err) {
                    error.EmptyResponse => {
                        if (pooled != null and req.body_reader == null) {
                            header_retry = true;
                            break;
                        }
                        return error.ConnectionClosedPrematurely;
                    },
                    else => |e| return e,
                };
                early_header = null;
                const interim = parseResponseHead(self.allocator, raw_head) catch |err| {
                    self.allocator.free(raw_head);
                    return err;
                };
                var headers = interim.headers;
                headers.deinit();
                if (interim.status_code >= 100 and interim.status_code < 200 and interim.status_code != 101) {
                    informational_count += 1;
                    if (informational_count > 100) {
                        self.allocator.free(raw_head);
                        return error.TooManyInformationalResponses;
                    }
                    self.allocator.free(raw_head);
                    continue;
                }
                break;
            }

            if (header_retry) {
                conn.close(self.io);
                self.allocator.destroy(conn);
                allow_pool = false;
                continue;
            }

            conn.setDeadline(deadline);
            errdefer self.allocator.free(raw_head);

            var head = try parseResponseHead(self.allocator, raw_head);
            errdefer head.headers.deinit();

            var mode: @import("response.zig").BodyMode = .close_eof;
            var content_length: u64 = 0;
            var can_keep_alive = sent_body;

            if (head.headers.get("Transfer-Encoding")) |te| {
                if (std.mem.indexOf(u8, te, "chunked") != null) {
                    mode = .chunked;
                }
            } else if (head.headers.get("Content-Length")) |cl| {
                content_length = std.fmt.parseInt(u64, cl, 10) catch return error.InvalidContentLength;
                mode = .fixed;
            }

            if (head.headers.get("Connection")) |conn_hdr| {
                if (std.ascii.eqlIgnoreCase(conn_hdr, "close")) {
                    can_keep_alive = false;
                }
            }

            const leftover: []const u8 = &.{};

            const host_copy = try self.allocator.dupe(u8, target.host);
            errdefer self.allocator.free(host_copy);

            const body_ptr = try self.allocator.create(ResponseBodyReader);
            errdefer self.allocator.destroy(body_ptr);
            body_ptr.* = ResponseBodyReader.init(self.io, conn, mode, content_length, leftover);

            var resp = Response{
                .allocator = self.allocator,
                .status = head.status,
                .status_code = head.status_code,
                .proto = head.proto,
                .header = head.headers,
                .body = body_ptr,
                .conn = conn,
                .pool = if (use_proxy) null else &self.pool,
                .pool_host = host_copy,
                .pool_port = target.port,
                .can_keep_alive = if (use_proxy) false else can_keep_alive,
                .closed = false,
                .raw_head = raw_head,
                .uncompressed = false,
            };

            if (!self.options.disable_compression and req.method != .HEAD) {
                if (resp.header.get("Content-Encoding")) |enc| {
                    if (std.ascii.eqlIgnoreCase(enc, "gzip")) {
                        try resp.body.enableGzip(self.allocator);
                        resp.uncompressed = true;
                        resp.header.del("Content-Encoding");
                        resp.header.del("Content-Length");
                    }
                }
            }

            return resp;
        }
    }
};
