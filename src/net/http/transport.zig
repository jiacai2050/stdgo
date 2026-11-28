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
        roundTrip: *const fn (
            ctx: *anyopaque,
            req: *Request,
            deadline: deadline_mod.Deadline,
        ) anyerror!Response,
        closeIdleConnections: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn roundTrip(
        self: RoundTripper,
        req: *Request,
        deadline: deadline_mod.Deadline,
    ) anyerror!Response {
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
    /// Note: On Windows (Zig 0.17.0), socket deadline cancellation may encounter
    /// an upstream panic in std.Io.Threaded.
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
    ca_lock: std.Io.RwLock = .init,

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
            .ca_lock = .init,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.pool.deinit(self.io);
        if (self.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
            self.ca_bundle = null;
        }
    }

    fn ensureCaBundle(self: *Transport) !*std.crypto.Certificate.Bundle {
        if (self.options.ca_bundle) |bundle| return bundle;

        try self.ca_lock.lockShared(self.io);
        if (self.ca_bundle != null) {
            self.ca_lock.unlockShared(self.io);
            return &self.ca_bundle.?;
        }
        self.ca_lock.unlockShared(self.io);

        try self.ca_lock.lock(self.io);
        defer self.ca_lock.unlock(self.io);

        if (self.ca_bundle == null) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            errdefer bundle.deinit(self.allocator);
            const now = std.Io.Timestamp.now(self.io, .real);
            try bundle.rescan(self.allocator, self.io, now);
            self.ca_bundle = bundle;
        }
        return &self.ca_bundle.?;
    }

    fn initTlsConn(
        self: *Transport,
        stream: std.Io.net.Stream,
        host: []const u8,
        deadline: deadline_mod.Deadline,
    ) !*HttpConn {
        const tls_limit = durationDeadline(
            self.io,
            self.options.tls_handshake_timeout,
        );
        const tls_deadline = deadline.earlier(tls_limit);
        if (self.options.insecure_skip_verify) {
            return HttpConn.initTls(
                self.allocator,
                self.io,
                stream,
                host,
                null,
                null,
                true,
                tls_deadline,
            );
        }
        const ca_bundle = try self.ensureCaBundle();
        return HttpConn.initTls(
            self.allocator,
            self.io,
            stream,
            host,
            ca_bundle,
            &self.ca_lock,
            false,
            tls_deadline,
        );
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

    fn vtableRoundTrip(
        ctx: *anyopaque,
        req: *Request,
        deadline: deadline_mod.Deadline,
    ) anyerror!Response {
        const self: *Transport = @ptrCast(@alignCast(ctx));
        return self.roundTrip(req, deadline);
    }

    fn vtableCloseIdleConnections(ctx: *anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(ctx));
        self.closeIdleConnections();
    }

    fn connectStream(
        io: std.Io,
        host: []const u8,
        port: u16,
        deadline: deadline_mod.Deadline,
    ) !std.Io.net.Stream {
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
            const trimmed = std.mem.trim(u8, token, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "100-continue")) return true;
        }
        return false;
    }

    fn headerHasToken(headers: *const @import("header.zig").Header, name: []const u8, token: []const u8) bool {
        for (headers.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
            var it = std.mem.splitScalar(u8, entry.value, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
            }
        }
        return false;
    }

    fn writeHostPort(w: *std.Io.Writer, host: []const u8, port: u16) !void {
        const is_ipv6 = std.mem.indexOfScalar(u8, host, ':') != null;
        if (is_ipv6) try w.writeByte('[');
        try w.writeAll(host);
        if (is_ipv6) try w.writeByte(']');
        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, ":{d}", .{port});
        try w.writeAll(port_str);
    }

    fn isConnectSuccessStatusLine(status_line: []const u8) bool {
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return false;
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return false;
        const code = parts.next() orelse return false;
        return std.mem.eql(u8, code, "200");
    }

    fn establishConnectTunnel(
        io: std.Io,
        stream: std.Io.net.Stream,
        host: []const u8,
        port: u16,
        auth: ?[]const u8,
        deadline: deadline_mod.Deadline,
    ) !void {
        var write_buf: [512]u8 = undefined;
        var stream_w: io_util.SocketWriter = .init(io, stream, &write_buf, deadline);
        const w = &stream_w.interface;

        w.writeAll("CONNECT ") catch |err| return stream_w.err orelse err;
        writeHostPort(w, host, port) catch |err| return stream_w.err orelse err;
        w.writeAll(" HTTP/1.1\r\nHost: ") catch |err| return stream_w.err orelse err;
        writeHostPort(w, host, port) catch |err| return stream_w.err orelse err;
        w.writeAll("\r\nUser-Agent: curl/8.7.1\r\nProxy-Connection: Keep-Alive\r\n") catch |err| {
            return stream_w.err orelse err;
        };
        if (auth) |a| {
            w.writeAll("Proxy-Authorization: ") catch |err| return stream_w.err orelse err;
            w.writeAll(a) catch |err| return stream_w.err orelse err;
            w.writeAll("\r\n") catch |err| return stream_w.err orelse err;
        }
        w.writeAll("\r\n") catch |err| return stream_w.err orelse err;
        w.flush() catch |err| return stream_w.err orelse err;

        var read_buf: [1024]u8 = undefined;
        var stream_r: io_util.SocketReader = .init(io, stream, &read_buf, deadline);
        const r = &stream_r.interface;

        const proxy_head_bytes_max = read_buf.len;
        while (true) {
            const buffered = r.buffered();
            if (std.mem.indexOf(u8, buffered, "\r\n\r\n")) |idx| {
                const head = buffered[0..idx];
                const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
                if (!isConnectSuccessStatusLine(head[0..first_line_end])) {
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

    fn writeRequestHead(
        conn: *HttpConn,
        req: *Request,
        target: anytype,
        use_proxy: bool,
        is_socks_proxy: bool,
        proxy_auth_header: ?[]const u8,
        options: TransportOptions,
    ) !void {
        var head_w = conn.writer();
        try head_w.writeAll(req.method.asString());
        try head_w.writeByte(' ');
        if (use_proxy and !target.is_tls and !is_socks_proxy) {
            // Forward proxy plain HTTP request uses absolute URI
            const is_abs = std.mem.startsWith(u8, req.url, "http://") or
                std.mem.startsWith(u8, req.url, "https://");
            if (is_abs) {
                try head_w.writeAll(req.url);
            } else {
                try head_w.writeAll("http://");
                try head_w.writeAll(req.url);
            }
        } else {
            if (!std.mem.startsWith(u8, target.request_target, "/")) {
                try head_w.writeByte('/');
            }
            try head_w.writeAll(target.request_target);
        }
        try head_w.writeAll(" HTTP/1.1\r\n");

        if (req.header.get("Host") == null) {
            try head_w.writeAll("Host: ");
            const is_ipv6 = std.mem.indexOfScalar(u8, target.host, ':') != null;
            if (is_ipv6) try head_w.writeByte('[');
            try head_w.writeAll(target.host);
            if (is_ipv6) try head_w.writeByte(']');
            const is_default_port = (!target.is_tls and target.port == 80) or
                (target.is_tls and target.port == 443);
            if (!is_default_port) {
                var port_buf: [8]u8 = undefined;
                const port_str = try std.fmt.bufPrint(&port_buf, ":{d}", .{target.port});
                try head_w.writeAll(port_str);
            }
            try head_w.writeAll("\r\n");
        }

        if (use_proxy and !target.is_tls and !is_socks_proxy) {
            if (req.header.get("Proxy-Connection") == null) {
                try head_w.writeAll("Proxy-Connection: Keep-Alive\r\n");
            }
            if (proxy_auth_header) |auth| {
                if (req.header.get("Proxy-Authorization") == null) {
                    try head_w.writeAll("Proxy-Authorization: ");
                    try head_w.writeAll(auth);
                    try head_w.writeAll("\r\n");
                }
            }
        }

        if (req.header.get("User-Agent") == null) {
            try head_w.writeAll("User-Agent: curl/8.7.1\r\n");
        }
        if (req.header.get("Accept") == null) {
            try head_w.writeAll("Accept: */*\r\n");
        }
        if (!options.disable_compression and req.header.get("Accept-Encoding") == null) {
            try head_w.writeAll("Accept-Encoding: gzip\r\n");
        }
        if (req.header.get("Connection") == null) {
            if (options.max_idle_conns_per_host > 0) {
                try head_w.writeAll("Connection: keep-alive\r\n");
            } else {
                try head_w.writeAll("Connection: close\r\n");
            }
        }

        if (req.body) |b| {
            const has_len = req.header.get("Content-Length") != null or
                req.header.get("Transfer-Encoding") != null;
            if (!has_len) {
                var cl_buf: [32]u8 = undefined;
                const cl_str = try std.fmt.bufPrint(
                    &cl_buf,
                    "Content-Length: {d}\r\n",
                    .{b.len},
                );
                try head_w.writeAll(cl_str);
            }
        } else if (req.body_reader != null) {
            if (req.content_length) |len| {
                const has_len = req.header.get("Content-Length") != null or
                    req.header.get("Transfer-Encoding") != null;
                if (!has_len) {
                    var cl_buf: [32]u8 = undefined;
                    const cl_str = try std.fmt.bufPrint(
                        &cl_buf,
                        "Content-Length: {d}\r\n",
                        .{len},
                    );
                    try head_w.writeAll(cl_str);
                }
            } else {
                if (req.header.get("Transfer-Encoding") == null) {
                    try head_w.writeAll("Transfer-Encoding: chunked\r\n");
                }
            }
        }

        for (req.header.entries.items) |entry| {
            try head_w.writeAll(entry.name);
            try head_w.writeAll(": ");
            try head_w.writeAll(entry.value);
            try head_w.writeAll("\r\n");
        }
        try head_w.writeAll("\r\n");

        try head_w.flush();
        try conn.flush();
    }

    pub fn roundTrip(self: *Transport, req: *Request, deadline: deadline_mod.Deadline) !Response {
        try deadline.validate();
        return self.roundTripWithBudget(req, deadline);
    }

    pub fn roundTripWithBudget(
        self: *Transport,
        req: *Request,
        client_deadline: deadline_mod.Deadline,
    ) !Response {
        try client_deadline.validate();
        const deadline = io_util.earlier(
            client_deadline,
            io_util.fromTimeout(self.io, self.options.timeout_ns),
        );
        try deadline.check(self.io);
        try self.io.checkCancel();
        try self.pool.start(self.io);

        const target = try parseUrlTarget(req.url);

        var resolved_proxy_to_free: ?[]const u8 = null;
        defer if (resolved_proxy_to_free) |p| self.allocator.free(p);

        var effective_proxy_url: ?[]const u8 = self.options.proxy_url;
        if (effective_proxy_url == null and self.options.proxy_from_env) {
            if (self.options.env_lookup) |lookup| {
                const env_res = try proxy_mod.proxyFromEnvWithLookup(
                    self.allocator,
                    target.scheme,
                    target.host,
                    lookup,
                );
                if (env_res) |p| {
                    resolved_proxy_to_free = p;
                    effective_proxy_url = p;
                }
            } else if (self.options.environ_map) |env_map| {
                const map_res = try proxy_mod.proxyFromEnvWithMap(
                    self.allocator,
                    target.scheme,
                    target.host,
                    env_map,
                );
                if (map_res) |p| {
                    resolved_proxy_to_free = p;
                    effective_proxy_url = p;
                }
            } else {
                const sys_res = try proxy_mod.proxyFromEnvironment(
                    self.allocator,
                    target.scheme,
                    target.host,
                );
                if (sys_res) |p| {
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
            const pooled = if (!use_proxy and allow_pool)
                self.pool.acquire(target.host, target.port, target.is_tls)
            else
                null;
            var conn: *HttpConn = if (pooled) |c|
                c
            else blk: {
                if (proxy_connect_url) |proxy_url| {
                    const proxy_target = try parseUrlTarget(proxy_url);
                    var stream = try connectStream(
                        self.io,
                        proxy_target.host,
                        proxy_target.port,
                        deadline,
                    );
                    errdefer stream.close(self.io);
                    try deadline.check(self.io);

                    if (is_socks_proxy) {
                        var read_buf: [512]u8 = undefined;
                        var write_buf: [512]u8 = undefined;
                        var reader: io_util.SocketReader = .init(
                            self.io,
                            stream,
                            &read_buf,
                            deadline,
                        );
                        var writer: io_util.SocketWriter = .init(
                            self.io,
                            stream,
                            &write_buf,
                            deadline,
                        );
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
                            break :blk try self.initTlsConn(stream, target.host, deadline);
                        } else {
                            break :blk try HttpConn.initPlain(
                                self.allocator,
                                self.io,
                                stream,
                                deadline,
                            );
                        }
                    } else if (target.is_tls) {
                        try establishConnectTunnel(
                            self.io,
                            stream,
                            target.host,
                            target.port,
                            proxy_auth_header,
                            deadline,
                        );
                        break :blk try self.initTlsConn(stream, target.host, deadline);
                    } else {
                        break :blk try HttpConn.initPlain(
                            self.allocator,
                            self.io,
                            stream,
                            deadline,
                        );
                    }
                } else {
                    var stream = try connectStream(self.io, target.host, target.port, deadline);
                    errdefer stream.close(self.io);
                    try deadline.check(self.io);

                    if (target.is_tls) {
                        break :blk try self.initTlsConn(stream, target.host, deadline);
                    } else {
                        break :blk try HttpConn.initPlain(
                            self.allocator,
                            self.io,
                            stream,
                            deadline,
                        );
                    }
                }
            };
            errdefer {
                conn.close(self.io);
                self.allocator.destroy(conn);
            }
            conn.setDeadline(deadline);
            try conn.checkDeadline();

            // Serialize and stream HTTP/1.1 request head directly
            const write_res = writeRequestHead(
                conn,
                req,
                target,
                use_proxy,
                is_socks_proxy,
                proxy_auth_header,
                self.options,
            );
            if (write_res) |_| {} else |raw_err| {
                const err = conn.ioError(raw_err);
                const retryable_err = err != error.Timeout and err != error.Canceled;
                if (pooled != null and req.body_reader == null and retryable_err) {
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
            const continue_limit = durationDeadline(
                self.io,
                self.options.expect_continue_timeout,
            );
            if (has_body and expectsContinue(req) and !continue_limit.isNone()) {
                conn.setDeadline(deadline.earlier(continue_limit));
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
                    const is_informational = interim.status_code >= 100 and
                        interim.status_code < 200 and
                        interim.status_code != 101;
                    if (is_informational) {
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
                    const retryable_err = err != error.Timeout and err != error.Canceled;
                    if (pooled != null and req.body_reader == null and retryable_err) {
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
                const hdr_limit = durationDeadline(self.io, self.options.response_header_timeout);
                conn.setDeadline(deadline.earlier(hdr_limit));
            }
            var header_retry = false;
            var raw_head: []u8 = undefined;
            while (true) {
                const head_res = early_header orelse self.readResponseHeader(conn);
                raw_head = head_res catch |err| switch (err) {
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
                const is_informational = interim.status_code >= 100 and
                    interim.status_code < 200 and
                    interim.status_code != 101;
                if (is_informational) {
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

            const no_body_response = req.method == .HEAD or
                head.status_code == 204 or
                head.status_code == 304 or
                (head.status_code >= 100 and head.status_code < 200);

            if (no_body_response) {
                mode = .fixed;
                content_length = 0;
            } else if (head.headers.get("Transfer-Encoding") != null) {
                if (headerHasToken(&head.headers, "Transfer-Encoding", "chunked")) {
                    mode = .chunked;
                }
            } else if (head.headers.get("Content-Length")) |cl| {
                const trimmed_cl = std.mem.trim(u8, cl, " \t");
                content_length = std.fmt.parseInt(u64, trimmed_cl, 10) catch {
                    return error.InvalidContentLength;
                };
                mode = .fixed;
            }

            if (mode == .close_eof) {
                can_keep_alive = false;
            }

            if (headerHasToken(&head.headers, "Connection", "close")) {
                can_keep_alive = false;
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

            if (!self.options.disable_compression and !no_body_response) {
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

test "Transport: CONNECT status line and header token parsing" {
    const testing = std.testing;
    try testing.expect(Transport.isConnectSuccessStatusLine("HTTP/1.1 200 Connection Established"));
    try testing.expect(Transport.isConnectSuccessStatusLine("HTTP/1.0 200 OK"));
    try testing.expect(!Transport.isConnectSuccessStatusLine("HTTP/1.1 407 Proxy Auth Required"));
    try testing.expect(!Transport.isConnectSuccessStatusLine("X-Header: 200 OK"));

    var h = @import("header.zig").Header.init(testing.allocator);
    defer h.deinit();
    try h.add("Transfer-Encoding", "gzip, CHUNKED");
    try h.add("Connection", "keep-alive, Close");
    try testing.expect(Transport.headerHasToken(&h, "Transfer-Encoding", "chunked"));
    try testing.expect(Transport.headerHasToken(&h, "Connection", "close"));
    try testing.expect(!Transport.headerHasToken(&h, "Connection", "upgrade"));
}
