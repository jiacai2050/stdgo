//! HTTP Connection abstraction over plain TCP and TLS streams.
const std = @import("std");
const io_util = @import("../io_util.zig");
const Deadline = @import("../../io/deadline.zig").Deadline;

pub const HttpConn = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    is_tls: bool,
    tls_client: ?*std.crypto.tls.Client = null,
    stream_reader: io_util.SocketReader = undefined,
    stream_writer: io_util.SocketWriter = undefined,
    tls_mem: ?[]u8 = null,

    pub fn initPlain(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        deadline: Deadline,
    ) !*HttpConn {
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
            .stream_reader = .init(io, stream, mem[0..buf_size], deadline),
            .stream_writer = .init(io, stream, mem[buf_size .. buf_size * 2], deadline),
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
        deadline: Deadline,
    ) !*HttpConn {
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
            .stream_reader = .init(io, stream, socket_read_buf, deadline),
            .stream_writer = .init(io, stream, socket_write_buf, deadline),
        };

        var random_buf: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buf);

        const now = std.Io.Timestamp.now(io, .real);

        var ca_lock: std.Io.RwLock = .init;
        const ca_opt: std.crypto.tls.Client.Options = .{
            .host = if (insecure_skip_verify) .no_verification else .{ .explicit = host },
            .ca = if (insecure_skip_verify)
                .no_verification
            else if (ca_bundle) |bundle|
                .{
                    .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &ca_lock,
                        .bundle = bundle,
                    },
                }
            else
                .no_verification,
            .write_buffer = tls_write_buf,
            .read_buffer = tls_read_buf,
            .entropy = &random_buf,
            .realtime_now = now,
            .allow_truncation_attacks = true,
        };

        const client_ptr = try allocator.create(std.crypto.tls.Client);
        errdefer allocator.destroy(client_ptr);

        client_ptr.* = std.crypto.tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            ca_opt,
        ) catch |err| return conn.ioError(err);
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

    pub fn setDeadline(self: *HttpConn, deadline: Deadline) void {
        self.stream_reader.deadline = deadline;
        self.stream_writer.deadline = deadline;
    }

    pub fn checkDeadline(self: *HttpConn) !void {
        try self.stream_reader.io.checkCancel();
        try self.stream_reader.deadline.check(self.stream_reader.io);
    }

    pub fn ioError(self: *HttpConn, err: anyerror) anyerror {
        if (err == error.ReadFailed or err == error.WriteFailed) {
            if (self.stream_reader.err) |read_err| return read_err;
            if (self.stream_writer.err) |write_err| return write_err;
        }
        return err;
    }

    pub fn read(self: *HttpConn, buf: []u8) !usize {
        try self.checkDeadline();
        const r = self.reader();
        while (r.seek == r.end) {
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => |e| return self.ioError(e),
            };
        }
        const avail = r.end - r.seek;
        if (avail == 0) return 0;
        const n = @min(buf.len, avail);
        @memcpy(buf[0..n], r.buffer[r.seek .. r.seek + n]);
        r.seek += n;
        return n;
    }

    pub fn writeAll(self: *HttpConn, data: []const u8) !void {
        try self.checkDeadline();
        if (self.is_tls) {
            self.tls_client.?.writer.writeAll(data) catch |err| return self.ioError(err);
            self.tls_client.?.writer.flush() catch |err| return self.ioError(err);
            self.stream_writer.interface.flush() catch |err| return self.ioError(err);
        } else {
            self.stream_writer.interface.writeAll(data) catch |err| return self.ioError(err);
            self.stream_writer.interface.flush() catch |err| return self.ioError(err);
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
