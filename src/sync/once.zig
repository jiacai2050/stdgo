const std = @import("std");

pub const Once = struct {
    // 0 = uninitialized, 1 = initializing, 2 = initialized
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init() Once {
        return .{};
    }

    /// Do calls the function f if and only if Do is being called for the
    /// first time for this instance of Once.
    pub fn do(self: *Once, comptime f: anytype, args: anytype) void {
        if (self.state.load(.acquire) == 2) return;

        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
            while (self.state.load(.acquire) != 2) {
                std.Thread.yield() catch {};
            }
            return;
        }

        @call(.auto, f, args);
        self.state.store(2, .release);
    }
};

test "sync.Once executed exactly once across threads" {
    const testing = std.testing;

    var once = Once.init();
    var executed_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const Helper = struct {
        fn initFunc(counter: *std.atomic.Value(i32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }

        fn worker(o: *Once, counter: *std.atomic.Value(i32)) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                o.do(initFunc, .{counter});
            }
        }
    };

    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Helper.worker, .{ &once, &executed_count });
    }

    for (threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(i32, 1), executed_count.load(.monotonic));
}
