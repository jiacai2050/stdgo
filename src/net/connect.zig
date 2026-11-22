//! Deadline-aware dialing through the injected I/O backend.
const std = @import("std");
const Deadline = @import("../io/deadline.zig").Deadline;

pub fn connect(io: std.Io, host: []const u8, port: u16, deadline: Deadline) !std.Io.net.Stream {
    return connectWithOrder(io, host, port, deadline, false);
}

pub fn connectOrdered(
    io: std.Io,
    host: []const u8,
    port: u16,
    deadline: Deadline,
) !std.Io.net.Stream {
    return connectWithOrder(io, host, port, deadline, true);
}

fn connectWithOrder(
    io: std.Io,
    host: []const u8,
    port: u16,
    deadline: Deadline,
    ordered: bool,
) !std.Io.net.Stream {
    try deadline.validate();
    try deadline.check(io);
    if (deadline.isNone()) return connectInner(io, host, port, ordered);

    var ready: std.Io.Event = .unset;
    var future = try io.concurrent(connectTask, .{ io, host, port, ordered, &ready });
    var pending = true;
    defer if (pending) {
        if (future.cancel(io)) |stream| {
            stream.close(io);
        } else |_| {}
    };
    while (true) {
        try io.checkCancel();
        try deadline.check(io);
        const tick = deadline.earlier(Deadline.after(io, .fromMilliseconds(25)));
        ready.waitTimeout(io, tick.timeout()) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return error.Canceled,
        };
        try io.checkCancel();
        try deadline.check(io);
        const result = future.await(io);
        pending = false;
        return result;
    }
}

fn connectTask(
    io: std.Io,
    host: []const u8,
    port: u16,
    ordered: bool,
    ready: *std.Io.Event,
) !std.Io.net.Stream {
    defer ready.set(io);
    return connectInner(io, host, port, ordered);
}

fn connectInner(io: std.Io, host: []const u8, port: u16, ordered: bool) !std.Io.net.Stream {
    if (std.Io.net.IpAddress.parse(host, port)) |ip| {
        return ip.connect(io, .{ .mode = .stream, .timeout = .none });
    } else |_| {}
    const host_name = try std.Io.net.HostName.init(host);
    if (ordered) {
        var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        var lookup_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        var future = io.async(std.Io.net.HostName.lookup, .{ host_name, io, &queue, .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buffer,
            .family = null,
        } });
        defer future.cancel(io) catch {};
        while (queue.getOne(io)) |result| switch (result) {
            .address => |address| {
                if (address.connect(io, .{ .mode = .stream, .timeout = .none })) |stream| {
                    return stream;
                } else |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => continue,
                }
            },
            .canonical_name => continue,
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => {},
        }
    }
    return host_name.connect(io, port, .{ .mode = .stream, .timeout = .none });
}

test "connect deadline cancels a stalled dial" {
    const base_io = std.testing.io;
    const Stub = struct {
        fn dial(
            userdata: ?*anyopaque,
            _: *const std.Io.net.IpAddress,
            _: std.Io.net.IpAddress.ConnectOptions,
        ) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
            const backend: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
            try std.Io.sleep(backend.io(), .fromSeconds(1), .awake);
            return error.ConnectionRefused;
        }
    };
    var vtable = base_io.vtable.*;
    vtable.netConnectIp = Stub.dial;
    const io: std.Io = .{ .userdata = base_io.userdata, .vtable = &vtable };
    const deadline = Deadline.after(io, .fromMilliseconds(50));
    try std.testing.expectError(error.Timeout, connect(io, "127.0.0.1", 80, deadline));
}
