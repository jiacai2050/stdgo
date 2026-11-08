//! Example demonstrating stdgo's sync.errgroup (Go's golang.org/x/sync/errgroup):
//! 1. Concurrent task execution with Group.spawn
//! 2. First error capture and propagation via group.wait()
//! 3. Automatic cancellation of sibling tasks via withContext
//! 4. Concurrency rate limiting via group.setLimit()

const std = @import("std");
const stdgo = @import("stdgo");
const errgroup = stdgo.sync.errgroup;
const context = stdgo.context;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: sync.errgroup Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Success case: Concurrent downloads / tasks
    // -------------------------------------------------------------
    std.debug.print("1. Running 3 concurrent tasks successfully:\n", .{});
    {
        var eg = errgroup.Group.init(gpa);
        defer eg.deinit();

        const Task = struct {
            fn fetchUrl(url: []const u8, delay_ms: u32) !void {
                _ = delay_ms;
                std.debug.print("   -> Fetching {s} completed\n", .{url});
            }
        };

        try eg.spawn(Task.fetchUrl, .{ "https://api.example.com/users", 20 });
        try eg.spawn(Task.fetchUrl, .{ "https://api.example.com/orders", 10 });
        try eg.spawn(Task.fetchUrl, .{ "https://api.example.com/products", 30 });

        if (eg.wait()) |err| return err;
        std.debug.print("   All 3 tasks finished without error!\n\n", .{});
    }

    // -------------------------------------------------------------
    // 2. Error propagation and cancellation with withContext
    // -------------------------------------------------------------
    std.debug.print("2. Error propagation & cancellation with withContext:\n", .{});
    {
        var eg_ctx = try errgroup.Group.withContext(gpa, context.background());
        defer eg_ctx.group.deinit();

        const Worker = struct {
            fn doWork(ctx: context.Context, id: usize) !void {
                if (id == 2) {
                    std.debug.print("   -> Worker {d} encountered an error: NetworkFailure!\n", .{id});
                    return error.NetworkFailure;
                }

                // Check if canceled by sibling worker
                var iter: usize = 0;
                while (iter < 100) : (iter += 1) {
                    if (ctx.done()) {
                        std.debug.print("   -> Worker {d} detected context cancellation and exited early!\n", .{id});
                        return;
                    }
                    std.Thread.yield() catch {};
                }
                std.debug.print("   -> Worker {d} finished normally\n", .{id});
            }
        };

        try eg_ctx.group.spawn(Worker.doWork, .{ eg_ctx.ctx, 1 });
        try eg_ctx.group.spawn(Worker.doWork, .{ eg_ctx.ctx, 2 });
        try eg_ctx.group.spawn(Worker.doWork, .{ eg_ctx.ctx, 3 });

        if (eg_ctx.group.wait()) |err| {
            std.debug.print("   group.wait() caught first error: {s} (Expected: NetworkFailure)\n\n", .{@errorName(err)});
        } else {
            std.debug.print("   Unexpected success!\n", .{});
        }
    }

    // -------------------------------------------------------------
    // 3. Concurrency Limiter (setLimit)
    // -------------------------------------------------------------
    std.debug.print("3. Concurrency Rate Limiter (setLimit = 2):\n", .{});
    {
        var eg = errgroup.Group.init(gpa);
        defer eg.deinit();

        eg.setLimit(2); // Max 2 goroutines active simultaneously

        const LimiterTask = struct {
            fn processItem(id: usize) !void {
                std.debug.print("   [Slot Active] Processing item {d}\n", .{id});
                std.Thread.yield() catch {};
            }
        };

        var i: usize = 1;
        while (i <= 4) : (i += 1) {
            try eg.spawn(LimiterTask.processItem, .{i});
        }

        if (eg.wait()) |err| return err;
        std.debug.print("   All rate-limited items processed cleanly!\n", .{});
    }
}
