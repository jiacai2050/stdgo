//! Network I/O utility functions using std.Io.Operation.
const std = @import("std");

pub fn writeAllTimeout(
    io: std.Io,
    stream: std.Io.net.Stream,
    data: []const u8,
    timeout_ns: ?u64,
) !void {
    var written: usize = 0;
    while (written < data.len) {
        var slice = [1][]const u8{data[written..]};
        const op = std.Io.Operation{
            .net_write = .{
                .socket_handle = stream.socket.handle,
                .data = &slice,
            },
        };
        const n: usize = if (timeout_ns) |ns| blk: {
            const timeout = std.Io.Timeout{
                .duration = .{
                    .raw = .{ .nanoseconds = @intCast(ns) },
                    .clock = .boot,
                },
            };
            const res = try io.operateTimeout(op, timeout);
            break :blk try res.net_write;
        } else blk: {
            break :blk try (try io.operate(op)).net_write;
        };

        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

pub fn readSocket(
    io: std.Io,
    stream: std.Io.net.Stream,
    buffer: []u8,
    timeout_ns: ?u64,
) !usize {
    var data = [1][]u8{buffer};
    const op = std.Io.Operation{
        .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        },
    };

    if (timeout_ns) |ns| {
        const timeout = std.Io.Timeout{
            .duration = .{
                .raw = .{ .nanoseconds = @intCast(ns) },
                .clock = .boot,
            },
        };
        const res = try io.operateTimeout(op, timeout);
        const read_res = try res.net_read;
        return read_res.data_len;
    } else {
        const res = try (try io.operate(op)).net_read;
        return res.data_len;
    }
}
