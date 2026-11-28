//! UDP datagram socket abstraction conforming to Go's net.PacketConn and net.UDPConn interfaces.
const std = @import("std");
const conn_mod = @import("conn.zig");
const addr_mod = @import("addr.zig");
const hostport = @import("hostport.zig");
const ip_mod = @import("ip.zig");
const Conn = conn_mod.Conn;
const Addr = addr_mod.Addr;
const UDPAddr = addr_mod.UDPAddr;
const Allocator = std.mem.Allocator;
const Deadline = @import("../io/deadline.zig").Deadline;

/// PacketConn is a generic packet-oriented network connection,
/// equivalent to Go's net.PacketConn interface.
pub const PacketConn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ReadFromResult = struct {
        n: usize,
        addr: UDPAddr,
    };

    pub const VTable = struct {
        readFrom: *const fn (ctx: *anyopaque, buf: []u8) anyerror!ReadFromResult,
        writeTo: *const fn (ctx: *anyopaque, bytes: []const u8, addr: UDPAddr) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
        localAddr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    pub fn readFrom(self: PacketConn, buf: []u8) anyerror!ReadFromResult {
        return self.vtable.readFrom(self.ptr, buf);
    }

    pub fn writeTo(self: PacketConn, bytes: []const u8, addr: UDPAddr) anyerror!usize {
        return self.vtable.writeTo(self.ptr, bytes, addr);
    }

    pub fn close(self: PacketConn) void {
        self.vtable.close(self.ptr);
    }

    pub fn localAddr(self: PacketConn) ?[]const u8 {
        if (self.vtable.localAddr) |f| return f(self.ptr);
        return null;
    }
};

/// UDPConn is the implementation of the Conn and PacketConn interfaces
/// for UDP network connections.
pub const UDPConn = struct {
    allocator: Allocator,
    io: std.Io,
    socket: std.Io.net.Socket,
    connected_dest: ?std.Io.net.IpAddress = null,
    local_addr_buf: [64]u8 = undefined,
    local_addr_len: usize = 0,

    /// Initializes a `UDPConn` wrapping `socket` and formats its bound local address.
    pub fn init(
        allocator: Allocator,
        io: std.Io,
        socket: std.Io.net.Socket,
        connected_dest: ?std.Io.net.IpAddress,
    ) !*UDPConn {
        const uc = try allocator.create(UDPConn);
        uc.* = .{
            .allocator = allocator,
            .io = io,
            .socket = socket,
            .connected_dest = connected_dest,
        };

        const formatted = std.fmt.bufPrint(&uc.local_addr_buf, "{f}", .{socket.address}) catch "";
        uc.local_addr_len = formatted.len;

        return uc;
    }

    pub fn packetConn(self: *UDPConn) PacketConn {
        return .{
            .ptr = self,
            .vtable = &udp_packet_conn_vtable,
        };
    }

    pub fn conn(self: *UDPConn) Conn {
        return .{
            .ptr = self,
            .vtable = &udp_conn_vtable,
        };
    }

    /// Returns the local UDP port bound by this socket (IPv4 or IPv6).
    pub fn port(self: *const UDPConn) u16 {
        return switch (self.socket.address) {
            .ip4 => |v4| v4.port,
            .ip6 => |v6| v6.port,
        };
    }

    pub fn readFrom(self: *UDPConn, buf: []u8) anyerror!PacketConn.ReadFromResult {
        return self.readFromDeadline(buf, .none);
    }

    pub fn readFromDeadline(
        self: *UDPConn,
        buf: []u8,
        deadline: Deadline,
    ) anyerror!PacketConn.ReadFromResult {
        var message: std.Io.net.IncomingMessage = .init;
        const result = try self.operate(.{ .net_receive = .{
            .socket_handle = self.socket.handle,
            .message_buffer = (&message)[0..1],
            .data_buffer = buf,
            .flags = .{},
        } }, deadline);
        const receive_error, const count = result.net_receive;
        if (receive_error) |err| return err;
        if (count != 1) return error.Unexpected;
        const msg = message;
        const sender_port = switch (msg.from) {
            .ip4 => |v4| v4.port,
            .ip6 => |v6| v6.port,
        };
        const sender_ip: ip_mod.IP = switch (msg.from) {
            .ip4 => |v4| .{ .v4 = v4.bytes },
            .ip6 => |v6| .{ .v6 = v6.bytes },
        };
        return .{
            .n = msg.data.len,
            .addr = .{
                .ip = sender_ip,
                .port = sender_port,
            },
        };
    }

    pub fn writeTo(self: *UDPConn, bytes: []const u8, dest_addr: UDPAddr) anyerror!usize {
        var ip_buf: [46]u8 = undefined;
        const ip_str = dest_addr.ip.stringBuf(&ip_buf);
        const target_ip = try std.Io.net.IpAddress.parse(ip_str, dest_addr.port);
        try self.socket.send(self.io, &target_ip, bytes);
        return bytes.len;
    }

    pub fn read(self: *UDPConn, buf: []u8) anyerror!usize {
        return self.readDeadline(buf, .none);
    }

    pub fn readDeadline(self: *UDPConn, buf: []u8, deadline: Deadline) anyerror!usize {
        while (true) {
            const res = try self.readFromDeadline(buf, deadline);
            if (self.connected_dest) |dest| {
                const match = switch (dest) {
                    .ip4 => |v4| switch (res.addr.ip) {
                        .v4 => |s4| v4.port == res.addr.port and std.mem.eql(u8, &v4.bytes, &s4),
                        .v6 => false,
                    },
                    .ip6 => |v6| switch (res.addr.ip) {
                        .v6 => |s6| v6.port == res.addr.port and std.mem.eql(u8, &v6.bytes, &s6),
                        .v4 => false,
                    },
                };
                if (!match) continue;
            }
            return res.n;
        }
    }

    pub fn write(self: *UDPConn, bytes: []const u8) anyerror!usize {
        return self.writeDeadline(bytes, .none);
    }

    pub fn writeDeadline(self: *UDPConn, bytes: []const u8, deadline: Deadline) anyerror!usize {
        if (self.connected_dest) |dest| {
            var message: std.Io.net.OutgoingMessage = .{
                .address = &dest,
                .data_ptr = bytes.ptr,
                .data_len = bytes.len,
            };
            const result = try self.operate(.{ .net_send = .{
                .socket_handle = self.socket.handle,
                .messages = (&message)[0..1],
                .flags = .{},
            } }, deadline);
            const send_error, const count = result.net_send;
            if (send_error) |err| return err;
            if (count != 1) return error.Unexpected;
            return bytes.len;
        }
        return error.SocketUnconnected;
    }

    fn operate(
        self: *UDPConn,
        operation: std.Io.Operation,
        deadline: Deadline,
    ) !std.Io.Operation.Result {
        try deadline.validate();
        if (deadline.isNone()) return self.io.operate(operation);
        try deadline.check(self.io);
        var ready: std.Io.Event = .unset;
        var future = try self.io.concurrent(operateTask, .{ self.io, operation, &ready });
        var pending = true;
        defer if (pending) {
            if (future.cancel(self.io)) |_| {} else |_| {}
        };
        while (true) {
            try self.io.checkCancel();
            try deadline.check(self.io);
            const tick = deadline.earlier(Deadline.after(self.io, .fromMilliseconds(25)));
            ready.waitTimeout(self.io, tick.timeout()) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return error.Canceled,
            };
            try self.io.checkCancel();
            try deadline.check(self.io);
            const result = future.await(self.io);
            pending = false;
            return result;
        }
    }

    fn operateTask(
        io: std.Io,
        operation: std.Io.Operation,
        ready: *std.Io.Event,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        defer ready.set(io);
        return io.operate(operation);
    }

    pub fn close(self: *UDPConn) void {
        self.socket.close(self.io);
        self.allocator.destroy(self);
    }

    // PacketConn VTable implementations
    fn pcReadFrom(ctx: *anyopaque, buf: []u8) anyerror!PacketConn.ReadFromResult {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.readFrom(buf);
    }

    fn pcWriteTo(ctx: *anyopaque, bytes: []const u8, dest_addr: UDPAddr) anyerror!usize {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.writeTo(bytes, dest_addr);
    }

    fn pcClose(ctx: *anyopaque) void {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        self.close();
    }

    fn pcLocalAddr(ctx: *anyopaque) ?[]const u8 {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        if (self.local_addr_len > 0) return self.local_addr_buf[0..self.local_addr_len];
        return null;
    }

    const udp_packet_conn_vtable: PacketConn.VTable = .{
        .readFrom = pcReadFrom,
        .writeTo = pcWriteTo,
        .close = pcClose,
        .localAddr = pcLocalAddr,
    };

    // Conn VTable implementations
    fn cRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    fn cWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn cReadDeadline(ctx: *anyopaque, buf: []u8, deadline: Deadline) anyerror!usize {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.readDeadline(buf, deadline);
    }

    fn cWriteDeadline(ctx: *anyopaque, bytes: []const u8, deadline: Deadline) anyerror!usize {
        const self: *UDPConn = @ptrCast(@alignCast(ctx));
        return self.writeDeadline(bytes, deadline);
    }

    const udp_conn_vtable: Conn.VTable = .{
        .read = cRead,
        .write = cWrite,
        .readDeadline = cReadDeadline,
        .writeDeadline = cWriteDeadline,
        .close = pcClose,
        .localAddr = pcLocalAddr,
    };
};

/// ListenUDP acts like ListenPacket for UDP networks.
pub fn listenUDP(
    allocator: Allocator,
    io: std.Io,
    network: []const u8,
    laddr: []const u8,
) !*UDPConn {
    if (!std.mem.startsWith(u8, network, "udp")) {
        return error.UnknownNetwork;
    }

    const hp = try hostport.splitHostPort(laddr);
    const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
    const bind_host = if (hp.host.len == 0)
        (if (std.mem.eql(u8, network, "udp6")) "::" else "0.0.0.0")
    else
        hp.host;

    const bind_ip = try std.Io.net.IpAddress.parse(bind_host, port);
    const sock = try bind_ip.bind(io, .{ .mode = .dgram });
    errdefer sock.close(io);

    return UDPConn.init(allocator, io, sock, null);
}

/// DialUDP acts like Dial for UDP networks, creating a connected UDP socket.
pub fn dialUDP(
    allocator: Allocator,
    io: std.Io,
    network: []const u8,
    laddr: ?[]const u8,
    raddr: []const u8,
) !*UDPConn {
    if (!std.mem.startsWith(u8, network, "udp")) {
        return error.UnknownNetwork;
    }

    const rhp = try hostport.splitHostPort(raddr);
    const rport = std.fmt.parseInt(u16, rhp.port, 10) catch return error.InvalidPort;
    const dest_ip = try std.Io.net.IpAddress.parse(rhp.host, rport);

    const default_laddr = switch (dest_ip) {
        .ip4 => "0.0.0.0:0",
        .ip6 => "[::]:0",
    };
    const bind_addr_str = laddr orelse default_laddr;
    const local_uc = try listenUDP(allocator, io, network, bind_addr_str);
    errdefer local_uc.close();

    local_uc.connected_dest = dest_ip;
    return local_uc;
}
