//! Package sync/semaphore provides a weighted semaphore implementation,
//! equivalent to Go's golang.org/x/sync/semaphore.
//!
const std = @import("std");
const deadlines = @import("../io/deadline.zig");

pub const Error = error{
    WeightExceedsCapacity,
} || deadlines.Error || std.Io.Cancelable;

/// Waiter node in the FIFO queue to guarantee fair, starvation-free scheduling.
const Waiter = struct {
    n: i64,
    ready: std.Io.Event = .unset,
    granted: bool = false,
    next: ?*Waiter = null,
    prev: ?*Waiter = null,
};

/// Weighted provides a concurrent, weighted semaphore implementation.
pub const Weighted = struct {
    size: i64,
    cur: i64 = 0,
    mu: std.Io.Mutex = .init,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,

    /// Initializes a Weighted semaphore with the given maximum weight capacity.
    pub fn init(n: i64) Weighted {
        std.debug.assert(n > 0);
        return .{ .size = n };
    }

    /// Tries to acquire the semaphore with weight n without blocking.
    /// On success, returns true. On failure, returns false and leaves the semaphore unchanged.
    pub fn tryAcquire(self: *Weighted, io: std.Io, n: i64) bool {
        std.debug.assert(n > 0);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        if (self.size - self.cur >= n and self.head == null) {
            self.cur += n;
            return true;
        }
        return false;
    }

    /// Acquires the semaphore with weight n, blocking until resources are available
    /// or the task is canceled or the deadline expires.
    /// On failure, no resources are retained.
    pub fn acquire(self: *Weighted, io: std.Io, n: i64, deadline: deadlines.Deadline) Error!void {
        std.debug.assert(n > 0);
        if (n > self.size) {
            return Error.WeightExceedsCapacity;
        }

        try deadline.validate();
        try io.checkCancel();
        try self.mu.lock(io);
        deadline.check(io) catch |err| {
            self.mu.unlock(io);
            return err;
        };
        if (self.size - self.cur >= n and self.head == null) {
            self.cur += n;
            self.mu.unlock(io);
            return;
        }

        var w = Waiter{
            .n = n,
            .prev = self.tail,
        };

        if (self.tail) |t| {
            t.next = &w;
            self.tail = &w;
        } else {
            self.head = &w;
            self.tail = &w;
        }

        self.mu.unlock(io);

        while (true) {
            const result = if (!deadline.isNone())
                w.ready.waitTimeout(io, deadline.timeout())
            else
                w.ready.wait(io);
            self.mu.lockUncancelable(io);
            if (result) |_| {
                std.debug.assert(w.granted);
                self.mu.unlock(io);
                return;
            } else |err| switch (err) {
                error.Canceled => {
                    if (w.granted) {
                        self.cur -= n;
                    } else {
                        self.removeWaiter(&w);
                    }
                    self.notifyWaiters(io);
                    self.mu.unlock(io);
                    return error.Canceled;
                },
                error.Timeout => {
                    if (w.granted) {
                        self.mu.unlock(io);
                        return;
                    }
                    deadline.check(io) catch |check_err| switch (check_err) {
                        error.InvalidDeadline => unreachable,
                        error.Timeout => {
                            self.removeWaiter(&w);
                            self.notifyWaiters(io);
                            self.mu.unlock(io);
                            return error.Timeout;
                        },
                    };
                    self.mu.unlock(io);
                },
            }
        }
    }

    /// Releases the semaphore with a weight of n.
    pub fn release(self: *Weighted, io: std.Io, n: i64) void {
        std.debug.assert(n > 0);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        self.cur -= n;
        std.debug.assert(self.cur >= 0);

        self.notifyWaiters(io);
    }

    /// Wakes up as many FIFO waiters as capacity allows.
    fn notifyWaiters(self: *Weighted, io: std.Io) void {
        while (self.head) |w| {
            if (self.size - self.cur < w.n) {
                // Front waiter cannot be satisfied; don't bypass (FIFO)
                break;
            }
            self.cur += w.n;
            self.removeWaiter(w);
            w.granted = true;
            w.ready.set(io);
        }
    }

    fn removeWaiter(self: *Weighted, w: *Waiter) void {
        if (w.prev) |p| {
            p.next = w.next;
        } else {
            self.head = w.next;
        }

        if (w.next) |next| {
            next.prev = w.prev;
        } else {
            self.tail = w.prev;
        }

        w.prev = null;
        w.next = null;
    }
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "Weighted: tryAcquire and release" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sem = Weighted.init(3);

    try testing.expect(sem.tryAcquire(io, 2));
    try testing.expect(!sem.tryAcquire(io, 2));
    try testing.expect(sem.tryAcquire(io, 1));
    try testing.expect(!sem.tryAcquire(io, 1));

    sem.release(io, 2);
    try testing.expect(sem.tryAcquire(io, 2));
    sem.release(io, 3);
}

test "Weighted: acquire and deadline" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sem = Weighted.init(2);

    try sem.acquire(io, 1, .none);
    try sem.acquire(io, 1, .none);
    try testing.expect(!sem.tryAcquire(io, 1));
    try testing.expectError(error.Timeout, sem.acquire(io, 1, deadlines.Deadline.after(io, .zero)));
    try testing.expectError(error.WeightExceedsCapacity, sem.acquire(io, 3, .none));

    sem.release(io, 2);
}

test "Weighted: cancel a waiting task" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sem = Weighted.init(1);
    try sem.acquire(io, 1, .none);

    const Worker = struct {
        fn run(s: *Weighted, task_io: std.Io) Error!void {
            try s.acquire(task_io, 1, .none);
        }
    };
    var future = try io.concurrent(Worker.run, .{ &sem, io });
    try testing.expectError(error.Canceled, future.cancel(io));
    sem.release(io, 1);
    try testing.expect(sem.tryAcquire(io, 1));
    sem.release(io, 1);
}

test "Weighted: queued waiters are served in FIFO order" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sem = Weighted.init(3);
    try sem.acquire(io, 2, .none);
    var held: i64 = 2;
    defer if (held > 0) sem.release(io, held);

    const Worker = struct {
        fn run(s: *Weighted, task_io: std.Io, weight: i64, acquired: *std.Io.Event, gate: *std.Io.Event) !void {
            try s.acquire(task_io, weight, .none);
            defer s.release(task_io, weight);
            acquired.set(task_io);
            try gate.wait(task_io);
        }
        fn waitQueued(s: *Weighted, task_io: std.Io, count: usize) !void {
            for (0..1000) |_| {
                s.mu.lockUncancelable(task_io);
                var waiter = s.head;
                var queued: usize = 0;
                while (waiter) |node| : (waiter = node.next) queued += 1;
                s.mu.unlock(task_io);
                if (queued >= count) return;
                try task_io.sleep(.fromMilliseconds(1), .awake);
            }
            return error.WaiterDidNotBlock;
        }
    };
    var first_acquired: std.Io.Event = .unset;
    var second_acquired: std.Io.Event = .unset;
    var first_gate: std.Io.Event = .unset;
    var second_gate: std.Io.Event = .unset;
    var first = try io.concurrent(Worker.run, .{ &sem, io, 2, &first_acquired, &first_gate });
    var first_pending = true;
    defer if (first_pending) {
        first.cancel(io) catch {};
    };
    try Worker.waitQueued(&sem, io, 1);
    var second = try io.concurrent(Worker.run, .{ &sem, io, 1, &second_acquired, &second_gate });
    var second_pending = true;
    defer if (second_pending) {
        second.cancel(io) catch {};
    };
    try Worker.waitQueued(&sem, io, 2);
    try testing.expect(!second_acquired.isSet());
    sem.release(io, 1);
    held -= 1;
    try first_acquired.wait(io);
    try testing.expect(!second_acquired.isSet());
    first_gate.set(io);
    try second_acquired.wait(io);
    second_gate.set(io);
    const first_result = first.await(io);
    first_pending = false;
    try first_result;
    const second_result = second.await(io);
    second_pending = false;
    try second_result;
}

test "Weighted: concurrent worker rate limiting" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sem = Weighted.init(2);
    var active_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var max_observed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    const Worker = struct {
        fn run(s: *Weighted, task_io: std.Io, active: *std.atomic.Value(usize), max_obs: *std.atomic.Value(usize)) void {
            for (0..10) |_| {
                s.acquire(task_io, 1, .none) catch return;
                const cur = active.fetchAdd(1, .monotonic) + 1;

                var old_max = max_obs.load(.monotonic);
                while (cur > old_max) {
                    old_max = max_obs.cmpxchgWeak(old_max, cur, .monotonic, .monotonic) orelse break;
                }

                var dummy: u64 = 0;
                for (0..10_000) |j| {
                    dummy +%= j;
                }
                std.mem.doNotOptimizeAway(dummy);
                _ = active.fetchSub(1, .monotonic);
                s.release(task_io, 1);
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, io, &active_count, &max_observed });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, io, &active_count, &max_observed });
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, io, &active_count, &max_observed });
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, io, &active_count, &max_observed });

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try testing.expect(max_observed.load(.monotonic) <= 2);
}
