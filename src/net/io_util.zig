//! Deadline-aware socket adapters for HTTP and TLS.
const std = @import("std");
const Deadline = @import("../io/deadline.zig").Deadline;

pub fn fromTimeout(io: std.Io, timeout_ns: ?u64) Deadline {
    const ns = timeout_ns orelse return .none;
    if (ns == 0) return .none;
    return Deadline.after(io, .{ .nanoseconds = ns });
}

pub fn earlier(a: Deadline, b: Deadline) Deadline {
    return a.earlier(b);
}

pub fn readBody(
    io: std.Io,
    reader: *std.Io.Reader,
    buffer: []u8,
    deadline: Deadline,
) !usize {
    if (deadline.isNone()) return reader.readSliceShort(buffer);
    try deadline.check(io);
    var ready: std.Io.Event = .unset;
    var future = try io.concurrent(readBodyTask, .{ io, reader, buffer, &ready });
    var pending = true;
    defer if (pending) {
        if (future.cancel(io)) |_| {} else |_| {}
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

fn readBodyTask(
    io: std.Io,
    reader: *std.Io.Reader,
    buffer: []u8,
    ready: *std.Io.Event,
) std.Io.Reader.ShortError!usize {
    defer ready.set(io);
    return reader.readSliceShort(buffer);
}

pub fn operate(
    io: std.Io,
    operation: std.Io.Operation,
    deadline: Deadline,
) !std.Io.Operation.Result {
    if (operation == .net_read) return read(io, operation, deadline);
    if (deadline.isNone()) return io.operate(operation);
    try deadline.check(io);

    // A writable socket can still block on a large write after poll reports readiness.
    var ready: std.Io.Event = .unset;
    var future = try io.concurrent(write, .{ io, operation, &ready });
    var pending = true;
    defer if (pending) {
        if (future.cancel(io)) |_| {} else |_| {}
    };
    while (true) {
        try io.checkCancel();
        try deadline.check(io);
        // Recheck cancellation even when the backend cannot interrupt a wait.
        const tick = earlier(deadline, Deadline.after(io, .fromMilliseconds(25)));
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

fn write(
    io: std.Io,
    operation: std.Io.Operation,
    ready: *std.Io.Event,
) std.Io.Cancelable!std.Io.Operation.Result {
    defer ready.set(io);
    return io.operate(operation);
}

fn read(io: std.Io, operation: std.Io.Operation, deadline: Deadline) !std.Io.Operation.Result {
    if (deadline.isNone()) return io.operate(operation);
    try deadline.check(io);
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, operation);
    while (true) {
        batch.awaitConcurrent(io, deadline.timeout()) catch |err| switch (err) {
            error.Timeout => {
                deadline.check(io) catch |deadline_err| {
                    batch.cancel(io);
                    if (batch.next()) |completion| return completion.result;
                    return deadline_err;
                };
                continue;
            },
            error.Canceled => {
                batch.cancel(io);
                if (batch.next()) |completion| {
                    io.recancel();
                    return completion.result;
                }
                return error.Canceled;
            },
            else => return err,
        };
        const completion = batch.next().?;
        return completion.result;
    }
}

pub const SocketReader = struct {
    io: std.Io,
    socket: std.Io.net.Stream,
    deadline: Deadline,
    interface: std.Io.Reader,
    err: ?anyerror = null,

    pub fn init(
        io: std.Io,
        socket: std.Io.net.Stream,
        buffer: []u8,
        deadline: Deadline,
    ) SocketReader {
        return .{
            .io = io,
            .socket = socket,
            .deadline = deadline,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(reader, &data);
        writer.advance(n);
        return n;
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", reader));
        var vectors: [16][]u8 = undefined;
        const count, const data_size = try reader.writableVector(&vectors, data);
        const result = operate(self.io, .{ .net_read = .{
            .socket_handle = self.socket.socket.handle,
            .data = vectors[0..count],
        } }, self.deadline) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        const n = (result.net_read catch |err| {
            self.err = err;
            return error.ReadFailed;
        }).data_len;
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            reader.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

pub const SocketWriter = struct {
    io: std.Io,
    socket: std.Io.net.Stream,
    deadline: Deadline,
    interface: std.Io.Writer,
    err: ?anyerror = null,

    pub fn init(
        io: std.Io,
        socket: std.Io.net.Stream,
        buffer: []u8,
        deadline: Deadline,
    ) SocketWriter {
        return .{
            .io = io,
            .socket = socket,
            .deadline = deadline,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *SocketWriter = @alignCast(@fieldParentPtr("interface", writer));
        const result = operate(self.io, .{ .net_write = .{
            .socket_handle = self.socket.socket.handle,
            .header = writer.buffered(),
            .data = data,
            .splat = splat,
        } }, self.deadline) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        const n = result.net_write catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        return writer.consume(n);
    }
};
