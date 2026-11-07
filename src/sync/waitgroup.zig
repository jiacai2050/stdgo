const std = @import("std");

pub const WaitGroup = struct {
    counter: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    pub fn init() WaitGroup {
        return .{};
    }

    /// Add adds delta, which may be negative, to the WaitGroup counter.
    /// If the counter becomes zero, all threads blocked on Wait are released.
    /// If the counter goes negative, Add panics.
    pub fn add(self: *WaitGroup, delta: i32) void {
        const prev = self.counter.fetchAdd(delta, .monotonic);
        if (prev + delta < 0) {
            @panic("sync: negative WaitGroup counter");
        }
    }

    /// Done decrements the WaitGroup counter by one.
    pub fn done(self: *WaitGroup) void {
        self.add(-1);
    }

    /// Wait blocks until the WaitGroup counter is zero.
    pub fn wait(self: *WaitGroup) void {
        while (self.counter.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
    }
};

test "sync.WaitGroup concurrent worker threads" {
    const testing = std.testing;

    var wg = WaitGroup.init();
    var sum: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const Worker = struct {
        fn run(group: *WaitGroup, counter: *std.atomic.Value(i32)) void {
            defer group.done();
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    const num_workers = 10;
    wg.add(num_workers);

    var threads: [num_workers]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &wg, &sum });
    }

    wg.wait();

    for (threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(i32, num_workers), sum.load(.monotonic));
}
