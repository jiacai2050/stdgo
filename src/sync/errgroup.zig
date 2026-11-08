const std = @import("std");
const Allocator = std.mem.Allocator;
const WaitGroup = @import("waitgroup.zig").WaitGroup;
const Mutex = @import("mutex.zig").Mutex;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const CancelContext = context_mod.CancelContext;

/// Group provides synchronization, error propagation, and Context cancelation
/// for groups of concurrent tasks, modeled after Go's golang.org/x/sync/errgroup.
pub const Group = struct {
    allocator: Allocator,
    wg: WaitGroup = WaitGroup.init(),
    mutex: Mutex = .{},
    first_err: ?anyerror = null,
    cancel_ctx: ?*CancelContext = null,
    limit: usize = 0,
    active_count: usize = 0,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,

    /// Init creates an empty Group without context cancellation.
    pub fn init(allocator: Allocator) Group {
        return .{
            .allocator = allocator,
        };
    }

    /// WithContext returns a new Group and an associated Context derived from parent.
    /// The derived Context is canceled the first time a function passed to spawn returns a non-nil error
    /// or the first time Wait returns, whichever occurs first.
    pub fn withContext(allocator: Allocator, parent: Context) !struct { group: Group, ctx: Context } {
        const cancel_ctx = try context_mod.withCancel(allocator, parent);
        return .{
            .group = .{
                .allocator = allocator,
                .cancel_ctx = cancel_ctx,
            },
            .ctx = cancel_ctx.context(),
        };
    }

    /// Deinit releases memory and resources allocated by the Group.
    pub fn deinit(self: *Group) void {
        self.mutex.lock();
        for (self.threads.items) |*t| {
            t.join();
        }
        self.threads.deinit(self.allocator);
        self.mutex.unlock();

        if (self.cancel_ctx) |c| {
            self.allocator.destroy(c);
            self.cancel_ctx = null;
        }
    }

    /// SetLimit limits the number of active goroutines in this group.
    /// A limit <= 0 means no limit.
    pub fn setLimit(self: *Group, n: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.limit = n;
    }

    /// Spawn runs the given task function concurrently in a new thread.
    /// The function must return `!void` or `anyerror!void`.
    pub fn spawn(self: *Group, comptime func: anytype, args: anytype) !void {
        if (self.limit > 0) {
            while (true) {
                self.mutex.lock();
                if (self.active_count < self.limit) {
                    self.active_count += 1;
                    self.mutex.unlock();
                    break;
                }
                self.mutex.unlock();
                std.Thread.yield() catch {};
            }
        }

        self.wg.add(1);

        const Args = @TypeOf(args);
        const TaskContext = struct {
            group: *Group,
            task_args: Args,

            fn run(ctx_ptr: *@This()) void {
                defer {
                    if (ctx_ptr.group.limit > 0) {
                        ctx_ptr.group.mutex.lock();
                        if (ctx_ptr.group.active_count > 0) {
                            ctx_ptr.group.active_count -= 1;
                        }
                        ctx_ptr.group.mutex.unlock();
                    }

                    ctx_ptr.group.wg.done();
                    ctx_ptr.group.allocator.destroy(ctx_ptr);
                }

                const result = @call(.auto, func, ctx_ptr.task_args);
                if (result) |_| {} else |err| {
                    ctx_ptr.group.setError(err);
                }
            }
        };

        const ctx = try self.allocator.create(TaskContext);
        ctx.* = .{
            .group = self,
            .task_args = args,
        };

        const thread = std.Thread.spawn(.{}, TaskContext.run, .{ctx}) catch |spawn_err| {
            self.allocator.destroy(ctx);
            if (self.limit > 0) {
                self.mutex.lock();
                if (self.active_count > 0) self.active_count -= 1;
                self.mutex.unlock();
            }
            self.wg.done();
            return spawn_err;
        };

        self.mutex.lock();
        self.threads.append(self.allocator, thread) catch {};
        self.mutex.unlock();
    }

    fn setError(self: *Group, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.first_err == null) {
            self.first_err = err;
            if (self.cancel_ctx) |c| {
                c.cancel();
            }
        }
    }

    /// Wait blocks until all function calls from the spawn method have returned, then
    /// returns the first non-nil error (if any) from them.
    pub fn wait(self: *Group) ?anyerror {
        self.wg.wait();

        self.mutex.lock();
        for (self.threads.items) |*t| {
            t.join();
        }
        self.threads.clearRetainingCapacity();
        const err = self.first_err;
        self.mutex.unlock();

        if (self.cancel_ctx) |c| {
            c.cancel();
        }

        return err;
    }
};

test "sync.errgroup basic success" {
    const testing = std.testing;

    var g = Group.init(testing.allocator);
    defer g.deinit();

    var counter: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const Task = struct {
        fn worker(c: *std.atomic.Value(i32)) !void {
            _ = c.fetchAdd(1, .monotonic);
        }
    };

    for (0..5) |_| {
        try g.spawn(Task.worker, .{&counter});
    }

    const err = g.wait();
    try testing.expectEqual(@as(?anyerror, null), err);
    try testing.expectEqual(@as(i32, 5), counter.load(.acquire));
}

test "sync.errgroup first error propagation and context cancellation" {
    const testing = std.testing;

    const bg = context_mod.background();
    var eg = try Group.withContext(testing.allocator, bg);
    defer eg.group.deinit();

    const FailingTask = struct {
        fn task1() !void {
            return error.CustomFailure;
        }

        fn task2(ctx: Context, counter: *std.atomic.Value(i32)) !void {
            while (!ctx.done()) {
                std.Thread.yield() catch {};
            }
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var counter: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    try eg.group.spawn(FailingTask.task1, .{});
    try eg.group.spawn(FailingTask.task2, .{ eg.ctx, &counter });

    const result_err = eg.group.wait();
    try testing.expectEqual(@as(?anyerror, error.CustomFailure), result_err);
    try testing.expect(eg.ctx.done());
    try testing.expectEqual(@as(i32, 1), counter.load(.acquire));
}

test "sync.errgroup concurrency limit" {
    const testing = std.testing;

    var g = Group.init(testing.allocator);
    defer g.deinit();
    g.setLimit(2);

    var current_concurrency: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);
    var max_seen: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const LimitedTask = struct {
        fn work(cur: *std.atomic.Value(i32), mx: *std.atomic.Value(i32)) !void {
            const now = cur.fetchAdd(1, .monotonic) + 1;
            while (true) {
                const old_max = mx.load(.monotonic);
                if (now > old_max) {
                    if (mx.cmpxchgWeak(old_max, now, .monotonic, .monotonic) == null) break;
                } else break;
            }

            // Yield briefly
            for (0..100) |_| {
                std.Thread.yield() catch {};
            }

            _ = cur.fetchAdd(-1, .monotonic);
        }
    };

    for (0..6) |_| {
        try g.spawn(LimitedTask.work, .{ &current_concurrency, &max_seen });
    }

    const err = g.wait();
    try testing.expectEqual(@as(?anyerror, null), err);
    try testing.expect(max_seen.load(.acquire) <= 2);
}
