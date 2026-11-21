const std = @import("std");

/// Runs a homogeneous list of tasks, canceling siblings after the first observed error.
/// The owner waits for all started tasks before returning; tasks must cooperate with cancellation.
/// `limit` must be positive, and `tasks` and their borrowed arguments must remain valid until return.
pub const Group = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        comptime worker: anytype,
        tasks: []const std.meta.ArgsTuple(@TypeOf(worker)),
        limit: usize,
    ) !void {
        if (limit == 0) return error.InvalidLimit;
        try io.checkCancel();
        if (tasks.len == 0) return;

        const Result = struct { err: ?anyerror };
        const Queue = std.Io.Queue(Result);
        const Args = std.meta.ArgsTuple(@TypeOf(worker));
        const Runner = struct {
            fn run(task_io: std.Io, queue: *Queue, args: Args) void {
                const result: ?anyerror = if (@call(.auto, worker, args)) |_| null else |err| err;
                queue.putOneUncancelable(task_io, .{ .err = result }) catch unreachable;
            }
        };

        const capacity = @min(limit, tasks.len);
        const buffer = try allocator.alloc(Result, capacity);
        defer allocator.free(buffer);
        var queue: Queue = .init(buffer);
        var group: std.Io.Group = .init;
        defer group.cancel(io);

        var next: usize = 0;
        var active: usize = 0;
        while (next < tasks.len or active > 0) {
            while (next < tasks.len and active < capacity) {
                group.concurrent(io, Runner.run, .{ io, &queue, tasks[next] }) catch |err| {
                    group.cancel(io);
                    try io.checkCancel();
                    return err;
                };
                next += 1;
                active += 1;
            }
            const result = queue.getOne(io) catch |err| {
                group.cancel(io);
                try io.checkCancel();
                return err;
            };
            active -= 1;
            if (result.err) |err| {
                group.cancel(io);
                try io.checkCancel();
                return err;
            }
        }
        try group.await(io);
    }
};

test "group runs bounded tasks and propagates the first observed failure" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const State = struct {
        sibling_started: std.Io.Event = .unset,
        blocked: std.Io.Event = .unset,
        sibling_finished: std.atomic.Value(bool) = .init(false),
        extra_started: std.atomic.Value(bool) = .init(false),
    };
    const Worker = struct {
        fn run(task_io: std.Io, state: *State, id: u8) !void {
            if (id == 0) {
                try state.sibling_started.wait(task_io);
                return error.WorkFailed;
            }
            if (id == 2) {
                state.extra_started.store(true, .release);
                return;
            }
            defer state.sibling_finished.store(true, .release);
            state.sibling_started.set(task_io);
            try state.blocked.wait(task_io);
        }
    };
    var state: State = .{};
    const Args = std.meta.ArgsTuple(@TypeOf(Worker.run));
    const tasks = [_]Args{
        .{ io, &state, 0 },
        .{ io, &state, 1 },
        .{ io, &state, 2 },
    };
    try std.testing.expectError(error.WorkFailed, Group.run(std.testing.allocator, io, Worker.run, &tasks, 2));
    try std.testing.expect(state.sibling_finished.load(.acquire));
    try std.testing.expect(!state.extra_started.load(.acquire));
}

test "group runs at most limit tasks until a slot is freed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const State = struct {
        started: std.atomic.Value(usize) = .init(0),
        two_started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
    };
    const Worker = struct {
        fn run(task_io: std.Io, state: *State) !void {
            if (state.started.fetchAdd(1, .acq_rel) + 1 == 2) state.two_started.set(task_io);
            try state.release.wait(task_io);
        }
    };
    const Owner = struct {
        fn run(task_io: std.Io, state: *State) !void {
            const Args = std.meta.ArgsTuple(@TypeOf(Worker.run));
            const tasks = [_]Args{ .{ task_io, state }, .{ task_io, state }, .{ task_io, state } };
            try Group.run(std.testing.allocator, task_io, Worker.run, &tasks, 2);
        }
    };
    var state: State = .{};
    var future = try io.concurrent(Owner.run, .{ io, &state });
    var pending = true;
    defer if (pending) {
        future.cancel(io) catch {};
    };
    try state.two_started.wait(io);
    try std.testing.expectEqual(@as(usize, 2), state.started.load(.acquire));
    state.release.set(io);
    const result = future.await(io);
    pending = false;
    try result;
    try std.testing.expectEqual(@as(usize, 3), state.started.load(.acquire));
}

test "group rejects a zero concurrency limit" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Worker = struct {
        fn run() !void {}
    };
    const Args = std.meta.ArgsTuple(@TypeOf(Worker.run));
    const tasks: [0]Args = .{};
    try std.testing.expectError(error.InvalidLimit, Group.run(std.testing.allocator, io, Worker.run, &tasks, 0));
}

test "canceling the owner waits for running tasks to exit" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const State = struct {
        started: std.Io.Event = .unset,
        blocked: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
    };
    const Worker = struct {
        fn run(task_io: std.Io, state: *State) !void {
            defer state.finished.store(true, .release);
            state.started.set(task_io);
            try state.blocked.wait(task_io);
        }
    };
    const Owner = struct {
        fn run(task_io: std.Io, state: *State) !void {
            const Args = std.meta.ArgsTuple(@TypeOf(Worker.run));
            const tasks = [_]Args{.{ task_io, state }};
            try Group.run(std.testing.allocator, task_io, Worker.run, &tasks, 1);
        }
    };
    var state: State = .{};
    var future = try io.concurrent(Owner.run, .{ io, &state });
    var pending = true;
    defer if (pending) {
        future.cancel(io) catch {};
    };
    try state.started.wait(io);
    const result = future.cancel(io);
    pending = false;
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expect(state.finished.load(.acquire));
}
