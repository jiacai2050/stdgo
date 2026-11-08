//! HTTP/HTTPS Transport executing round trips over TCP / TLS streams.
const std = @import("std");
const Request = @import("request.zig").Request;
const parseUrlTarget = @import("request.zig").parseUrlTarget;
const Response = @import("response.zig").Response;
const ResponseBodyReader = @import("response.zig").ResponseBodyReader;
const parseResponseHead = @import("response_parser.zig").parseResponseHead;
const ConnPool = @import("pool.zig").ConnPool;
const HttpConn = @import("conn.zig").HttpConn;
const io_util = @import("io_util.zig");
const proxy_mod = @import("proxy.zig");

pub const TransportOptions = struct {
    proxy_url: ?[]const u8 = null,
    proxy_from_env: bool = true,
    timeout_ns: ?u64 = null,
    max_idle_conns_per_host: usize = 2,
    insecure_skip_verify: bool = false,
    disable_compression: bool = false,
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: TransportOptions,
    pool: ConnPool,
    ca_bundle: ?std.crypto.Certificate.Bundle = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: TransportOptions) Transport {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .pool = ConnPool.init(allocator, options.max_idle_conns_per_host),
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

    fn connectStream(io: std.Io, host: []const u8, port: u16, timeout: std.Io.Timeout) !std.Io.net.Stream {
        if (std.Io.net.IpAddress.parse(host, port)) |ip| {
            // Zig 0.17's netConnectIpPosix panics if timeout != .none
            return ip.connect(io, .{ .mode = .stream, .timeout = .none });
        } else |_| {}

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        if (host.len > host_buf.len) return error.HostNameTooLong;
        @memcpy(host_buf[0..host.len], host);
        const host_name = try std.Io.net.HostName.init(host_buf[0..host.len]);

        // Prefer IPv4 first to avoid IPv6 PMTUD / packet loss on certain ISP international anycast
        var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        var lookup_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
        var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        var lookup_future = io.async(std.Io.net.HostName.lookup, .{ host_name, io, &lookup_queue, .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buffer,
            .family = null,
        } });
        defer lookup_future.cancel(io) catch {};

        while (lookup_queue.getOne(io)) |dns_result| switch (dns_result) {
            .address => |address| {
                if (address.connect(io, .{ .mode = .stream, .timeout = timeout })) |stream| {
                    return stream;
                } else |_| continue;
            },
            .canonical_name => continue,
        } else |_| {}

        return host_name.connect(io, port, .{ .mode = .stream, .timeout = timeout });
    }

    fn makeIoTimeout(timeout_ns: ?u64) std.Io.Timeout {
        if (timeout_ns) |ns| {
            if (ns == 0) return .none;
            return .{
                .duration = .{
                    .raw = std.Io.Duration.fromNanoseconds(@intCast(ns)),
                    .clock = .boot,
                },
            };
        }
        return .none;
    }

    fn establishConnectTunnel(io: std.Io, stream: std.Io.net.Stream, host: []const u8, port: u16, auth: ?[]const u8) !void {
        var write_buf: [512]u8 = undefined;
        var stream_w = stream.writer(io, &write_buf);
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
        try w.writeAll(req_str);
        try w.flush();

        var read_buf: [1024]u8 = undefined;
        var stream_r = stream.reader(io, &read_buf);
        const r = &stream_r.interface;

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
            try r.fillMore();
        }
    }

    pub fn roundTrip(self: *Transport, req: *Request) !Response {
        if (req.ctx) |c| {
            if (c.err()) |e| return e;
        }

        const target = try parseUrlTarget(req.url);

        var resolved_proxy_to_free: ?[]const u8 = null;
        defer if (resolved_proxy_to_free) |p| self.allocator.free(p);

        var effective_proxy_url: ?[]const u8 = self.options.proxy_url;
        if (effective_proxy_url == null and self.options.proxy_from_env) {
            if (try proxy_mod.proxyFromEnvironment(self.allocator, target.scheme, target.host)) |p| {
                resolved_proxy_to_free = p;
                effective_proxy_url = p;
            }
        }
        const use_proxy = effective_proxy_url != null;

        var proxy_auth_header: ?[]const u8 = null;
        var proxy_clean_url_to_free: ?[]const u8 = null;
        defer if (proxy_clean_url_to_free) |u| self.allocator.free(u);
        defer if (proxy_auth_header) |a| self.allocator.free(a);

        var proxy_connect_url: ?[]const u8 = null;
        if (effective_proxy_url) |raw_proxy| {
            const details = try proxy_mod.parseProxyDetails(self.allocator, raw_proxy);
            proxy_clean_url_to_free = details.clean_proxy_url;
            proxy_auth_header = details.proxy_auth;
            proxy_connect_url = details.clean_proxy_url;
        }

        const pooled = if (!use_proxy) self.pool.acquire(target.host, target.port, target.is_tls) else null;
        var conn: *HttpConn = if (pooled) |c|
            c
        else blk: {
            const timeout = makeIoTimeout(self.options.timeout_ns);

            if (proxy_connect_url) |proxy_url| {
                const proxy_target = try parseUrlTarget(proxy_url);
                var stream = try connectStream(self.io, proxy_target.host, proxy_target.port, timeout);
                errdefer stream.close(self.io);

                if (target.is_tls) {
                    try establishConnectTunnel(self.io, stream, target.host, target.port, proxy_auth_header);
                    break :blk try HttpConn.initTls(
                        self.allocator,
                        self.io,
                        stream,
                        target.host,
                        self.options.ca_bundle,
                        self.options.insecure_skip_verify,
                    );
                } else {
                    break :blk try HttpConn.initPlain(self.allocator, self.io, stream);
                }
            } else {
                var stream = try connectStream(self.io, target.host, target.port, timeout);
                errdefer stream.close(self.io);

                if (target.is_tls) {
                    break :blk try HttpConn.initTls(
                        self.allocator,
                        self.io,
                        stream,
                        target.host,
                        self.options.ca_bundle,
                        self.options.insecure_skip_verify,
                    );
                } else {
                    break :blk try HttpConn.initPlain(self.allocator, self.io, stream);
                }
            }
        };
        errdefer {
            conn.close(self.io);
            self.allocator.destroy(conn);
        }

        // Serialize HTTP/1.1 request
        var req_buf = std.ArrayListUnmanaged(u8).empty;
        defer req_buf.deinit(self.allocator);

        try req_buf.appendSlice(self.allocator, req.method.asString());
        try req_buf.append(self.allocator, ' ');
        if (use_proxy and !target.is_tls) {
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

        if (use_proxy and !target.is_tls) {
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

        try conn.writeAll(self.io, req_buf.items, self.options.timeout_ns);

        if (req.body) |b| {
            try conn.writeAll(self.io, b, self.options.timeout_ns);
        } else if (req.body_reader) |r| {
            var buf: [4096]u8 = undefined;
            if (req.content_length != null) {
                var remaining = req.content_length.?;
                while (remaining > 0) {
                    const to_read = @min(buf.len, remaining);
                    const n = try r.read(buf[0..to_read]);
                    if (n == 0) break;
                    try conn.writeAll(self.io, buf[0..n], self.options.timeout_ns);
                    remaining -= n;
                }
            } else {
                // chunked streaming upload
                while (true) {
                    const n = try r.read(&buf);
                    if (n == 0) break;
                    var hex_buf: [16]u8 = undefined;
                    const hex_str = try std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{n});
                    try conn.writeAll(self.io, hex_str, self.options.timeout_ns);
                    try conn.writeAll(self.io, buf[0..n], self.options.timeout_ns);
                    try conn.writeAll(self.io, "\r\n", self.options.timeout_ns);
                }
                try conn.writeAll(self.io, "0\r\n\r\n", self.options.timeout_ns);
            }
        }

        // Read response head using standard Io.Reader buffering & toss
        const in = conn.reader();
        var head_len: usize = 0;
        const max_head_len = 16 * 1024;

        while (true) {
            const buffered = in.buffered();
            if (std.mem.indexOf(u8, buffered, "\r\n\r\n")) |idx| {
                head_len = idx + 4;
                break;
            }
            if (buffered.len >= max_head_len) return error.ResponseHeaderTooLarge;
            in.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosedPrematurely,
                else => |e| return e,
            };
        }

        const raw_head = try self.allocator.dupe(u8, in.buffered()[0..head_len]);
        errdefer self.allocator.free(raw_head);
        in.toss(head_len);

        const head = try parseResponseHead(self.allocator, raw_head);

        var mode: @import("response.zig").BodyMode = .close_eof;
        var content_length: u64 = 0;
        var can_keep_alive = true;

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
};
