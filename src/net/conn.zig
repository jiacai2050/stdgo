//! Generic network connection abstraction conforming to Go's net.Conn, net.Listener, and net.Dialer interfaces.
const std = @import("std");
const io_mod = @import("../io.zig");
const time_mod = @import("../time.zig");
const Duration = time_mod.Duration;
const hostport = @import("hostport.zig");
const connect_mod = @import("connect.zig");
const socket_io = @import("io_util.zig");

/// Conn represents a generic stream-oriented network connection,
/// equivalent to Go's net.Conn interface.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
        readDeadline: ?*const fn (ctx: *anyopaque, buf: []u8, deadline: io_mod.Deadline) anyerror!usize = null,
        writeDeadline: ?*const fn (ctx: *anyopaque, bytes: []const u8, deadline: io_mod.Deadline) anyerror!usize = null,
        localAddr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
        remoteAddr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    pub fn read(self: Conn, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn write(self: Conn, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn readDeadline(self: Conn, buf: []u8, deadline: io_mod.Deadline) anyerror!usize {
        try deadline.validate();
        if (self.vtable.readDeadline) |read_deadline| return read_deadline(self.ptr, buf, deadline);
        if (!deadline.isNone()) return error.DeadlineUnsupported;
        return self.read(buf);
    }

    /// A failed write may have sent a prefix of bytes before the error.
    pub fn writeDeadline(self: Conn, bytes: []const u8, deadline: io_mod.Deadline) anyerror!usize {
        try deadline.validate();
        if (self.vtable.writeDeadline) |write_deadline| return write_deadline(self.ptr, bytes, deadline);
        if (!deadline.isNone()) return error.DeadlineUnsupported;
        return self.write(bytes);
    }

    pub fn close(self: Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn localAddr(self: Conn) ?[]const u8 {
        if (self.vtable.localAddr) |f| return f(self.ptr);
        return null;
    }

    pub fn remoteAddr(self: Conn) ?[]const u8 {
        if (self.vtable.remoteAddr) |f| return f(self.ptr);
        return null;
    }
};

/// Listener represents a generic stream listener, equivalent to Go's net.Listener interface.
pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (ctx: *anyopaque) anyerror!Conn,
        close: *const fn (ctx: *anyopaque) void,
        addr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
        port: ?*const fn (ctx: *anyopaque) u16 = null,
    };

    pub fn accept(self: Listener) anyerror!Conn {
        return self.vtable.accept(self.ptr);
    }

    pub fn close(self: Listener) void {
        self.vtable.close(self.ptr);
    }

    pub fn addr(self: Listener) ?[]const u8 {
        if (self.vtable.addr) |f| return f(self.ptr);
        return null;
    }

    pub fn port(self: Listener) ?u16 {
        if (self.vtable.port) |f| return f(self.ptr);
        return null;
    }
};

/// StreamConn is a concrete implementation of net.Conn backed by std.Io.net.Stream.
pub const StreamConn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    remote_addr_buf: [64]u8 = undefined,
    remote_addr_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io_inst: std.Io, stream: std.Io.net.Stream, remote_addr_str: ?[]const u8) !*StreamConn {
        const sc = try allocator.create(StreamConn);
        sc.* = .{
            .allocator = allocator,
            .io = io_inst,
            .stream = stream,
        };
        if (remote_addr_str) |s| {
            const copy_len = @min(s.len, sc.remote_addr_buf.len);
            @memcpy(sc.remote_addr_buf[0..copy_len], s[0..copy_len]);
            sc.remote_addr_len = copy_len;
        }

        return sc;
    }

    pub fn conn(self: *StreamConn) Conn {
        return .{
            .ptr = self,
            .vtable = &stream_conn_vtable,
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readDeadlineImpl(ctx, buf, .none);
    }

    fn readDeadlineImpl(ctx: *anyopaque, buf: []u8, deadline: io_mod.Deadline) anyerror!usize {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        try self.io.checkCancel();
        try deadline.check(self.io);
        if (buf.len == 0) return 0;
        var vectors: [1][]u8 = .{buf};
        const result = try socket_io.operate(self.io, .{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &vectors,
        } }, deadline);
        return (try result.net_read).data_len;
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        return writeDeadlineImpl(ctx, bytes, .none);
    }

    fn writeDeadlineImpl(ctx: *anyopaque, bytes: []const u8, deadline: io_mod.Deadline) anyerror!usize {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        try self.io.checkCancel();
        try deadline.check(self.io);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const vectors = [_][]const u8{bytes[offset..]};
            const result = try socket_io.operate(self.io, .{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &vectors,
            } }, deadline);
            const written = try result.net_write;
            if (written == 0) return error.WriteFailed;
            offset += written;
        }
        return bytes.len;
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn remoteAddrImpl(ctx: *anyopaque) ?[]const u8 {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        if (self.remote_addr_len > 0) {
            return self.remote_addr_buf[0..self.remote_addr_len];
        }
        return null;
    }

    const stream_conn_vtable: Conn.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .readDeadline = readDeadlineImpl,
        .writeDeadline = writeDeadlineImpl,
        .close = closeImpl,
        .remoteAddr = remoteAddrImpl,
    };
};

/// TCPListener is a concrete implementation of net.Listener backed by std.Io.net.Server.
pub const TCPListener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    addr_buf: [64]u8 = undefined,
    addr_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, server: std.Io.net.Server) !*TCPListener {
        const self = try allocator.create(TCPListener);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
        };
        const p = self.port();
        const formatted = std.fmt.bufPrint(&self.addr_buf, "127.0.0.1:{d}", .{p}) catch "";
        self.addr_len = formatted.len;
        return self;
    }

    pub fn port(self: *const TCPListener) u16 {
        return self.server.socket.address.ip4.port;
    }

    pub fn listener(self: *TCPListener) Listener {
        return .{
            .ptr = self,
            .vtable = &tcp_listener_vtable,
        };
    }

    fn acceptImpl(ctx: *anyopaque) anyerror!Conn {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);

        const sc = try StreamConn.init(self.allocator, self.io, stream, null);
        return sc.conn();
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        self.server.deinit(self.io);
        self.allocator.destroy(self);
    }

    fn addrImpl(ctx: *anyopaque) ?[]const u8 {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        if (self.addr_len > 0) return self.addr_buf[0..self.addr_len];
        return null;
    }

    fn portImpl(ctx: *anyopaque) u16 {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        return self.port();
    }

    const tcp_listener_vtable: Listener.VTable = .{
        .accept = acceptImpl,
        .close = closeImpl,
        .addr = addrImpl,
        .port = portImpl,
    };
};

/// Listen announces on the local network address.
pub fn listen(allocator: std.mem.Allocator, io: std.Io, network: []const u8, address: []const u8) !Listener {
    if (!std.mem.startsWith(u8, network, "tcp")) {
        return error.UnknownNetwork;
    }

    const hp = try hostport.splitHostPort(address);
    const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
    const bind_host = if (hp.host.len == 0 or std.mem.eql(u8, hp.host, "0.0.0.0")) "0.0.0.0" else hp.host;

    const bind_ip = try std.Io.net.IpAddress.parse(bind_host, port);
    const server = try bind_ip.listen(io, .{ .reuse_address = true });
    const tl = try TCPListener.init(allocator, io, server);
    return tl.listener();
}

/// Dialer contains options for connecting to an address.
pub const Dialer = struct {
    timeout: ?Duration = null,
    deadline: io_mod.Deadline = .none,
    local_addr: ?[]const u8 = null,
    keep_alive: ?Duration = null,

    pub fn dial(
        self: Dialer,
        allocator: std.mem.Allocator,
        io: std.Io,
        network: []const u8,
        address: []const u8,
        deadline: io_mod.Deadline,
    ) !Conn {
        try deadline.validate();
        try self.deadline.validate();
        var effective_deadline = deadline.earlier(self.deadline);
        if (self.timeout) |duration| {
            if (duration.nanoseconds() > 0) {
                effective_deadline = effective_deadline.earlier(
                    .after(io, .{ .nanoseconds = duration.nanoseconds() }),
                );
            }
        }
        try io.checkCancel();

        if (!std.mem.startsWith(u8, network, "tcp")) {
            return error.UnknownNetwork;
        }

        const hp = try hostport.splitHostPort(address);
        const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;

        var stream = try connect_mod.connect(io, hp.host, port, effective_deadline);
        errdefer stream.close(io);

        try io.checkCancel();

        const sc = try StreamConn.init(allocator, io, stream, address);
        return sc.conn();
    }
};

/// Dial connects to the address on the named network.
pub fn dial(
    allocator: std.mem.Allocator,
    io: std.Io,
    network: []const u8,
    address: []const u8,
    deadline: io_mod.Deadline,
) !Conn {
    const d = Dialer{};
    return d.dial(allocator, io, network, address, deadline);
}

test "TCP connection deadlines bound reads and preserve later use" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    const concrete = StreamConn.init(testing.allocator, io, stream, null) catch |err| {
        stream.close(io);
        return err;
    };
    const connection = concrete.conn();
    defer connection.close();
    var peer = try server.accept(io);
    defer peer.close(io);

    var buf: [16]u8 = undefined;
    try testing.expectError(error.Timeout, connection.readDeadline(
        &buf,
        .after(io, .fromMilliseconds(30)),
    ));
    var writer_buf: [16]u8 = undefined;
    var writer = peer.writer(io, &writer_buf);
    try writer.interface.writeAll("hello");
    try writer.interface.flush();
    const count = try connection.readDeadline(&buf, .after(io, .fromSeconds(1)));
    try testing.expectEqualStrings("hello", buf[0..count]);
    try testing.expectError(error.Timeout, connection.writeDeadline("x", .after(io, .zero)));
    try testing.expectEqual(@as(usize, 2), try connection.writeDeadline("ok", .after(io, .fromSeconds(1))));
    var peer_buf: [16]u8 = undefined;
    var reader = peer.reader(io, &peer_buf);
    try reader.interface.fillMore();
    try testing.expectEqualStrings("ok", reader.interface.buffered());
    const large_payload = try testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer testing.allocator.free(large_payload);
    @memset(large_payload, 'x');
    try testing.expectError(error.Timeout, connection.writeDeadline(
        large_payload,
        .after(io, .fromMilliseconds(50)),
    ));
}

// -------------------------------------------------------------------------
// In-Memory Bidirectional Pipe (Go net.Pipe())
// -------------------------------------------------------------------------

const Mutex = @import("../sync/mutex.zig").Mutex;

const PipeQueue = struct {
    buf: [4096]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,
    mutex: Mutex = .{},

    fn write(self: *PipeQueue, io: std.Io, data: []const u8, deadline: io_mod.Deadline) anyerror!usize {
        try deadline.check(io);
        try io.checkCancel();
        var written: usize = 0;
        while (written < data.len) {
            try deadline.check(io);
            try io.checkCancel();
            self.mutex.lock();
            deadline.check(io) catch |err| {
                self.mutex.unlock();
                return err;
            };
            if (self.closed) {
                self.mutex.unlock();
                return error.BrokenPipe;
            }
            if (self.count == self.buf.len) {
                self.mutex.unlock();
                std.Thread.yield() catch {};
                continue;
            }
            const avail = self.buf.len - self.count;
            const chunk = @min(data.len - written, avail);
            for (0..chunk) |i| {
                self.buf[self.tail] = data[written + i];
                self.tail = (self.tail + 1) % self.buf.len;
            }
            self.count += chunk;
            written += chunk;
            self.mutex.unlock();
        }
        return written;
    }

    fn read(self: *PipeQueue, io: std.Io, out: []u8, deadline: io_mod.Deadline) anyerror!usize {
        try deadline.check(io);
        try io.checkCancel();
        if (out.len == 0) return 0;
        while (true) {
            try deadline.check(io);
            try io.checkCancel();
            self.mutex.lock();
            deadline.check(io) catch |err| {
                self.mutex.unlock();
                return err;
            };
            if (self.count > 0) {
                const chunk = @min(out.len, self.count);
                for (0..chunk) |i| {
                    out[i] = self.buf[self.head];
                    self.head = (self.head + 1) % self.buf.len;
                }
                self.count -= chunk;
                self.mutex.unlock();
                return chunk;
            }
            if (self.closed) {
                self.mutex.unlock();
                return 0; // EOF
            }
            self.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }

    fn close(self: *PipeQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
    }
};

const PipeState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    q12: PipeQueue = .{},
    q21: PipeQueue = .{},
    refcount: usize = 2,
    state_mutex: Mutex = .{},

    fn destroyIfDone(self: *PipeState) void {
        self.state_mutex.lock();
        self.refcount -= 1;
        const is_zero = (self.refcount == 0);
        self.state_mutex.unlock();
        if (is_zero) {
            self.allocator.destroy(self);
        }
    }
};

const PipeEndpoint = struct {
    state: *PipeState,
    in_q: *PipeQueue,
    out_q: *PipeQueue,

    fn conn(self: *PipeEndpoint) Conn {
        return .{
            .ptr = self,
            .vtable = &endpoint_vtable,
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readDeadlineImpl(ctx, buf, .none);
    }

    fn readDeadlineImpl(ctx: *anyopaque, buf: []u8, deadline: io_mod.Deadline) anyerror!usize {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        return self.in_q.read(self.state.io, buf, deadline);
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!usize {
        return writeDeadlineImpl(ctx, data, .none);
    }

    fn writeDeadlineImpl(ctx: *anyopaque, data: []const u8, deadline: io_mod.Deadline) anyerror!usize {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        return self.out_q.write(self.state.io, data, deadline);
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        self.out_q.close();
        self.in_q.close();
        const st = self.state;
        const alloc = st.allocator;
        alloc.destroy(self);
        st.destroyIfDone();
    }

    const endpoint_vtable: Conn.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .readDeadline = readDeadlineImpl,
        .writeDeadline = writeDeadlineImpl,
        .close = closeImpl,
    };
};

pub const PipePair = struct {
    conn1: Conn,
    conn2: Conn,
};

/// Pipe creates a synchronous, in-memory full-duplex network connection;
/// both ends implement the Conn interface.
/// Reads on one end are matched with writes on the other.
/// The injected io must outlive both endpoints.
pub fn pipe(allocator: std.mem.Allocator, io: std.Io) !PipePair {
    const st = try allocator.create(PipeState);
    errdefer allocator.destroy(st);
    st.* = .{
        .allocator = allocator,
        .io = io,
    };

    const ep1 = try allocator.create(PipeEndpoint);
    errdefer allocator.destroy(ep1);
    ep1.* = .{
        .state = st,
        .in_q = &st.q21,
        .out_q = &st.q12,
    };

    const ep2 = try allocator.create(PipeEndpoint);
    errdefer allocator.destroy(ep2);
    ep2.* = .{
        .state = st,
        .in_q = &st.q12,
        .out_q = &st.q21,
    };

    return .{
        .conn1 = ep1.conn(),
        .conn2 = ep2.conn(),
    };
}

test "pipe deadlines interrupt blocked reads and writes" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pair = try pipe(testing.allocator, io);
    defer pair.conn1.close();
    defer pair.conn2.close();
    var buffer: [4096]u8 = @splat(1);
    try testing.expectError(error.Timeout, pair.conn1.readDeadline(&buffer, .after(io, .fromMilliseconds(20))));
    try testing.expectEqual(buffer.len, try pair.conn1.write(&buffer));
    try testing.expectError(error.Timeout, pair.conn1.writeDeadline("x", .after(io, .fromMilliseconds(20))));
    try testing.expectEqual(buffer.len, try pair.conn2.read(&buffer));
    try testing.expectEqual(@as(usize, 1), try pair.conn1.writeDeadline("x", .after(io, .fromSeconds(1))));
    try testing.expectEqual(@as(usize, 1), try pair.conn2.readDeadline(&buffer, .after(io, .fromSeconds(1))));
    try testing.expectEqual(@as(u8, 'x'), buffer[0]);
}
