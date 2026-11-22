//! HTTP Keep-Alive connection pool keyed by host:port:is_tls.
const std = @import("std");
const HttpConn = @import("conn.zig").HttpConn;
const Mutex = @import("../../sync/mutex.zig").Mutex;

pub const PooledConn = struct {
    host: []const u8,
    port: u16,
    is_tls: bool,
    conn: *HttpConn,
    expires: ?std.Io.Clock.Timestamp = null,
};

pub const ConnPool = struct {
    allocator: std.mem.Allocator,
    max_idle_per_host: usize,
    entries: std.ArrayListUnmanaged(PooledConn),
    mutex: Mutex = .{},
    idle_timeout: ?std.Io.Duration = null,
    wake: std.Io.Event = .unset,
    stopping: bool = false,
    worker: ?std.Io.Future(std.Io.Cancelable!void) = null,

    pub fn init(allocator: std.mem.Allocator, max_idle_per_host: usize) ConnPool {
        return .{
            .allocator = allocator,
            .max_idle_per_host = max_idle_per_host,
            .entries = .empty,
            .mutex = .{},
        };
    }

    pub fn start(self: *ConnPool, io: std.Io) !void {
        if (self.idle_timeout == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.worker == null) {
            self.worker = try io.concurrent(expireLoop, .{ self, io });
        }
    }

    fn expireLoop(self: *ConnPool, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            self.mutex.lock();
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const now = std.Io.Clock.Timestamp.now(io, .awake);
            var earliest: ?std.Io.Clock.Timestamp = null;
            var i: usize = 0;
            while (i < self.entries.items.len) {
                const entry = self.entries.items[i];
                const expires = entry.expires orelse {
                    i += 1;
                    continue;
                };
                if (expires.raw.nanoseconds <= now.raw.nanoseconds) {
                    _ = self.entries.swapRemove(i);
                    entry.conn.close(io);
                    self.allocator.destroy(entry.conn);
                    self.allocator.free(entry.host);
                    continue;
                }
                if (earliest == null or expires.raw.nanoseconds < earliest.?.raw.nanoseconds) {
                    earliest = expires;
                }
                i += 1;
            }
            self.wake.reset();
            self.mutex.unlock();
            if (earliest) |expires| {
                self.wake.waitTimeout(io, .{ .deadline = expires }) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Canceled => return error.Canceled,
                };
            } else {
                try self.wake.wait(io);
            }
        }
    }

    pub fn deinit(self: *ConnPool, io: std.Io) void {
        self.mutex.lock();
        self.stopping = true;
        self.wake.set(io);
        self.mutex.unlock();
        if (self.worker) |*worker| {
            worker.await(io) catch |err| switch (err) {
                error.Canceled => {},
            };
            self.worker = null;
        }
        self.mutex.lock();
        const to_close = self.entries.toOwnedSlice(self.allocator) catch {
            for (self.entries.items) |entry| {
                entry.conn.close(io);
                self.allocator.destroy(entry.conn);
                self.allocator.free(entry.host);
            }
            self.entries.deinit(self.allocator);
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (to_close) |entry| {
            entry.conn.close(io);
            self.allocator.destroy(entry.conn);
            self.allocator.free(entry.host);
        }
        self.allocator.free(to_close);
    }

    pub fn acquire(self: *ConnPool, host: []const u8, port: u16, is_tls: bool) ?*HttpConn {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (entry.expires) |expires| {
                const now_ns = std.Io.Clock.awake.now(entry.conn.stream_reader.io).nanoseconds;
                if (expires.raw.nanoseconds <= now_ns) {
                    self.allocator.free(entry.host);
                    _ = self.entries.swapRemove(i);
                    entry.conn.close(entry.conn.stream_reader.io);
                    self.allocator.destroy(entry.conn);
                    continue;
                }
            }
            if (entry.port == port and
                entry.is_tls == is_tls and
                std.mem.eql(u8, entry.host, host))
            {
                const conn = entry.conn;
                self.allocator.free(entry.host);
                _ = self.entries.swapRemove(i);
                return conn;
            }
        }
        return null;
    }

    pub fn release(
        self: *ConnPool,
        io: std.Io,
        host: []const u8,
        port: u16,
        is_tls: bool,
        conn: *HttpConn,
    ) void {
        self.mutex.lock();
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.port == port and
                entry.is_tls == is_tls and
                std.mem.eql(u8, entry.host, host))
            {
                count += 1;
            }
        }

        if (count >= self.max_idle_per_host) {
            self.mutex.unlock();
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        }

        const owned_host = self.allocator.dupe(u8, host) catch {
            self.mutex.unlock();
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        };

        self.entries.append(self.allocator, .{
            .host = owned_host,
            .port = port,
            .is_tls = is_tls,
            .conn = conn,
            .expires = if (self.idle_timeout) |duration| .{
                .clock = .awake,
                .raw = .{
                    .nanoseconds = std.Io.Clock.awake.now(io).nanoseconds +|
                        duration.nanoseconds,
                },
            } else null,
        }) catch {
            self.mutex.unlock();
            self.allocator.free(owned_host);
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        };
        self.wake.set(io);
        self.mutex.unlock();
    }

    /// closeIdleConnections closes and drains all idle connections currently in the pool.
    pub fn closeIdleConnections(self: *ConnPool, io: std.Io) void {
        self.mutex.lock();
        const to_close = self.entries.toOwnedSlice(self.allocator) catch {
            for (self.entries.items) |entry| {
                entry.conn.close(io);
                self.allocator.destroy(entry.conn);
                self.allocator.free(entry.host);
            }
            self.entries.clearRetainingCapacity();
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (to_close) |entry| {
            entry.conn.close(io);
            self.allocator.destroy(entry.conn);
            self.allocator.free(entry.host);
        }
        self.allocator.free(to_close);
    }
};

test "idle connections are closed without another request" {
    const testing = std.testing;
    const io = testing.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    var peer = try server.accept(io);
    defer peer.close(io);

    var pool = ConnPool.init(testing.allocator, 1);
    defer pool.deinit(io);
    pool.idle_timeout = .fromMilliseconds(50);
    try pool.start(io);
    const conn = try HttpConn.initPlain(testing.allocator, io, stream, .none);
    pool.release(io, "127.0.0.1", server.socket.address.ip4.port, false, conn);

    var closed: std.Io.Event = .unset;
    const Watch = struct {
        fn run(watch_io: std.Io, socket: std.Io.net.Stream, event: *std.Io.Event) !void {
            var buf: [16]u8 = undefined;
            var reader = socket.reader(watch_io, &buf);
            reader.interface.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    event.set(watch_io);
                    return;
                },
                error.ReadFailed => return reader.err orelse error.ReadFailed,
            };
            return error.UnexpectedData;
        }
    };
    var watcher = try io.concurrent(Watch.run, .{ io, peer, &closed });
    defer watcher.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.panic("idle connection watcher: {s}", .{@errorName(err)}),
    };
    try closed.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try watcher.await(io);
    try testing.expect(pool.acquire("127.0.0.1", server.socket.address.ip4.port, false) == null);
}
