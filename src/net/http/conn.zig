//! HTTP Connection abstraction over plain TCP and TLS streams.
const std = @import("std");
const io_util = @import("io_util.zig");

pub const HttpConn = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    is_tls: bool,
    tls_client: ?*std.crypto.tls.Client = null,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls_mem: ?[]u8 = null,

    pub fn initPlain(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) !*HttpConn {
        const buf_size = 16 * 1024;
        const mem = try allocator.alloc(u8, buf_size * 2);
        errdefer allocator.free(mem);

        const conn = try allocator.create(HttpConn);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .stream = stream,
            .is_tls = false,
            .tls_mem = mem,
            .stream_reader = stream.reader(io, mem[0..buf_size]),
            .stream_writer = stream.writer(io, mem[buf_size .. buf_size * 2]),
        };
        return conn;
    }

    pub fn initTls(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        host: []const u8,
        ca_bundle: ?*std.crypto.Certificate.Bundle,
        insecure_skip_verify: bool,
    ) !*HttpConn {
        _ = ca_bundle;
        _ = insecure_skip_verify;

        const min_buf = std.crypto.tls.Client.min_buffer_len;
        const total_mem = min_buf * 4;
        const mem = try allocator.alloc(u8, total_mem);
        errdefer allocator.free(mem);

        const socket_read_buf = mem[0..min_buf];
        const socket_write_buf = mem[min_buf .. min_buf * 2];
        const tls_read_buf = mem[min_buf * 2 .. min_buf * 3];
        const tls_write_buf = mem[min_buf * 3 .. min_buf * 4];

        const conn = try allocator.create(HttpConn);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .stream = stream,
            .is_tls = true,
            .tls_mem = mem,
            .stream_reader = stream.reader(io, socket_read_buf),
            .stream_writer = stream.writer(io, socket_write_buf),
        };

        var random_buf: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buf);

        const now = std.Io.Timestamp.now(io, .real);

        const ca_opt: std.crypto.tls.Client.Options = .{
            .host = .{ .explicit = host },
            .ca = .no_verification,
            .write_buffer = tls_write_buf,
            .read_buffer = tls_read_buf,
            .entropy = &random_buf,
            .realtime_now = now,
            .allow_truncation_attacks = true,
        };

        const client_ptr = try allocator.create(std.crypto.tls.Client);
        errdefer allocator.destroy(client_ptr);

        client_ptr.* = try std.crypto.tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            ca_opt,
        );
        conn.tls_client = client_ptr;

        return conn;
    }

    pub fn reader(self: *HttpConn) *std.Io.Reader {
        if (self.is_tls) {
            return &self.tls_client.?.reader;
        } else {
            return &self.stream_reader.interface;
        }
    }

    pub fn read(self: *HttpConn, io: std.Io, buf: []u8, timeout_ns: ?u64) !usize {
        _ = io;
        _ = timeout_ns;
        const r = self.reader();
        while (r.seek == r.end) {
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => |e| return e,
            };
        }
        const avail = r.end - r.seek;
        if (avail == 0) return 0;
        const n = @min(buf.len, avail);
        @memcpy(buf[0..n], r.buffer[r.seek .. r.seek + n]);
        r.seek += n;
        return n;
    }

    pub fn writeAll(self: *HttpConn, io: std.Io, data: []const u8, timeout_ns: ?u64) !void {
        _ = io;
        _ = timeout_ns;
        if (self.is_tls) {
            try self.tls_client.?.writer.writeAll(data);
            try self.tls_client.?.writer.flush();
            try self.stream_writer.interface.flush();
        } else {
            try self.stream_writer.interface.writeAll(data);
            try self.stream_writer.interface.flush();
        }
    }

    pub fn close(self: *HttpConn, io: std.Io) void {
        self.stream.close(io);
        if (self.tls_client) |client_ptr| {
            self.allocator.destroy(client_ptr);
            self.tls_client = null;
        }
        if (self.tls_mem) |mem| {
            self.allocator.free(mem);
            self.tls_mem = null;
        }
    }
};
