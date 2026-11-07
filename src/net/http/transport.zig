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

pub const TransportOptions = struct {
    timeout_ns: ?u64 = null,
    max_idle_conns_per_host: usize = 2,
    insecure_skip_verify: bool = false,
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
            return ip.connect(io, .{ .mode = .stream, .timeout = timeout });
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
            .family = .ip4,
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

    pub fn roundTrip(self: *Transport, req: *Request) !Response {
        const target = try parseUrlTarget(req.url);

        var conn: *HttpConn = if (self.pool.acquire(target.host, target.port, target.is_tls)) |c|
            c
        else blk: {
            const timeout = makeIoTimeout(self.options.timeout_ns);
            var stream = try connectStream(self.io, target.host, target.port, timeout);
            errdefer stream.close(self.io);

            if (target.is_tls) {
                break :blk try HttpConn.initTls(
                    self.allocator,
                    self.io,
                    stream,
                    target.host,
                    null,
                    self.options.insecure_skip_verify,
                );
            } else {
                break :blk try HttpConn.initPlain(self.allocator, self.io, stream);
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
        if (!std.mem.startsWith(u8, target.request_target, "/")) {
            try req_buf.append(self.allocator, '/');
        }
        try req_buf.appendSlice(self.allocator, target.request_target);
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

        if (req.header.get("User-Agent") == null) {
            try req_buf.appendSlice(self.allocator, "User-Agent: curl/8.7.1\r\n");
        }
        if (req.header.get("Accept") == null) {
            try req_buf.appendSlice(self.allocator, "Accept: */*\r\n");
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
        }

        for (req.header.entries.items) |entry| {
            try req_buf.appendSlice(self.allocator, entry.name);
            try req_buf.appendSlice(self.allocator, ": ");
            try req_buf.appendSlice(self.allocator, entry.value);
            try req_buf.appendSlice(self.allocator, "\r\n");
        }
        try req_buf.appendSlice(self.allocator, "\r\n");

        if (req.body) |b| {
            try req_buf.appendSlice(self.allocator, b);
        }

        try conn.writeAll(self.io, req_buf.items, self.options.timeout_ns);

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

        return Response{
            .allocator = self.allocator,
            .status = head.status,
            .status_code = head.status_code,
            .proto = head.proto,
            .header = head.headers,
            .body = ResponseBodyReader.init(self.io, conn, mode, content_length, leftover),
            .conn = conn,
            .pool = &self.pool,
            .pool_host = host_copy,
            .pool_port = target.port,
            .can_keep_alive = can_keep_alive,
            .closed = false,
            .raw_head = raw_head,
        };
    }
};
