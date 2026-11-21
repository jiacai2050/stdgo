const std = @import("std");

/// Must remain at a stable address until every token and cancel call is finished.
pub const CancelSource = struct {
    event: std.Io.Event = .unset,

    pub fn init() CancelSource {
        return .{};
    }

    pub fn cancel(self: *CancelSource, io: std.Io) void {
        self.event.set(io);
    }

    pub fn isCanceled(self: *const CancelSource) bool {
        return self.event.isSet();
    }

    pub fn token(self: *CancelSource) CancelToken {
        return .{ .event = &self.event };
    }
};

/// A borrowed signal; it cannot outlive or be used while moving its source.
pub const CancelToken = struct {
    event: *std.Io.Event,

    pub fn isCanceled(self: CancelToken) bool {
        return self.event.isSet();
    }

    pub fn waitCanceled(self: CancelToken, io: std.Io) std.Io.Cancelable!void {
        try self.event.wait(io);
    }
};

test "cancel source broadcasts and remains canceled" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = CancelSource.init();
    var entered: std.Io.Event = .unset;

    const Waiter = struct {
        fn run(task_io: std.Io, token: CancelToken, ready: *std.Io.Event) std.Io.Cancelable!void {
            ready.set(task_io);
            try token.waitCanceled(task_io);
        }
    };

    var first = try io.concurrent(Waiter.run, .{ io, source.token(), &entered });
    errdefer first.cancel(io) catch {};
    try entered.wait(io);
    var second = try io.concurrent(Waiter.run, .{ io, source.token(), &entered });
    errdefer second.cancel(io) catch {};
    source.cancel(io);
    source.cancel(io);
    try first.await(io);
    try second.await(io);
    try std.testing.expect(source.isCanceled());
    try std.testing.expect(source.token().isCanceled());
    try source.token().waitCanceled(io);
}

test "canceling a waiter leaves the source unset" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var source = CancelSource.init();
    var entered: std.Io.Event = .unset;

    const Waiter = struct {
        fn run(task_io: std.Io, token: CancelToken, ready: *std.Io.Event) std.Io.Cancelable!void {
            ready.set(task_io);
            try token.waitCanceled(task_io);
        }
    };
    var future = try io.concurrent(Waiter.run, .{ io, source.token(), &entered });
    try entered.wait(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(!source.isCanceled());
}
