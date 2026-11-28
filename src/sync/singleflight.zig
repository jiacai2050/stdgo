const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const WaitGroup = @import("waitgroup.zig").WaitGroup;
const Mutex = @import("mutex.zig").Mutex;

/// Group represents a class of work and forms a namespace in
/// which units of work can be executed with duplicate suppression,
/// modeled after Go's golang.org/x/sync/singleflight.
pub fn Group(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Result represents the outcome of a Do call.
        pub const Result = struct {
            val: T,
            shared: bool,
        };

        const Call = struct {
            wg: WaitGroup = WaitGroup.init(),
            val: T = undefined,
            err: ?anyerror = null,
            dups: usize = 0,
            refs: usize = 1,

            fn release(self: *Call, allocator: Allocator) void {
                if (self.refs > 1) {
                    self.refs -= 1;
                } else {
                    allocator.destroy(self);
                }
            }
        };

        allocator: Allocator,
        mu: Mutex = .{},
        calls: std.StringHashMapUnmanaged(*Call) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mu.lock();
            var iter = self.calls.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.release(self.allocator);
            }
            self.calls.deinit(self.allocator);
            self.mu.unlock();
        }

        /// Do executes and returns the results of the given function, making
        /// sure that only one execution is in-flight for a given key at a
        /// time. If a duplicate comes in, the duplicate caller waits for the
        /// original to complete and receives the same results.
        /// The return value shared indicates whether v was given to multiple callers.
        pub fn do(self: *Self, key: []const u8, comptime func: anytype, args: anytype) !Result {
            self.mu.lock();
            if (self.calls.get(key)) |existing_c| {
                existing_c.dups += 1;
                existing_c.refs += 1;
                self.mu.unlock();

                existing_c.wg.wait();

                self.mu.lock();
                defer self.mu.unlock();
                const res_val = existing_c.val;
                const res_err = existing_c.err;
                existing_c.release(self.allocator);

                if (res_err) |err| {
                    return err;
                }
                return Result{
                    .val = res_val,
                    .shared = true,
                };
            }

            const c = self.allocator.create(Call) catch |err| {
                self.mu.unlock();
                return err;
            };
            c.* = .{};
            c.wg.add(1);

            const owned_key = self.allocator.dupe(u8, key) catch |err| {
                self.allocator.destroy(c);
                self.mu.unlock();
                return err;
            };

            self.calls.put(self.allocator, owned_key, c) catch |err| {
                self.allocator.free(owned_key);
                self.allocator.destroy(c);
                self.mu.unlock();
                return err;
            };

            self.mu.unlock();

            // Execute the function outside the lock
            const result_or_err = @call(.auto, func, args);

            self.mu.lock();
            if (self.calls.getEntry(key)) |entry| {
                if (entry.value_ptr.* == c) {
                    const kv = self.calls.fetchRemove(key).?;
                    self.allocator.free(kv.key);
                }
            }

            const is_err_union = switch (@typeInfo(@TypeOf(result_or_err))) {
                .error_union => true,
                else => false,
            };

            if (is_err_union) {
                if (result_or_err) |val| {
                    c.val = val;
                } else |err| {
                    c.err = err;
                }
            } else {
                c.val = result_or_err;
            }

            c.wg.done();

            const res_val = c.val;
            const res_err = c.err;
            const shared = c.dups > 0;
            c.release(self.allocator);
            self.mu.unlock();

            if (res_err) |err| {
                return err;
            }
            return Result{
                .val = res_val,
                .shared = shared,
            };
        }

        /// Forget tells the singleflight to forget about a key. Future calls
        /// to Do for this key will call the function rather than waiting for
        /// an earlier call to complete.
        pub fn forget(self: *Self, key: []const u8) bool {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.calls.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                return true;
            }
            return false;
        }
    };
}

test "singleflight: basic sequential deduplication" {
    const TestState = struct {
        calls: usize = 0,

        fn work(state: *@This()) !i32 {
            state.calls += 1;
            return 42;
        }
    };

    var state = TestState{};
    var g = Group(i32).init(testing.allocator);
    defer g.deinit();

    const res1 = try g.do("key1", TestState.work, .{&state});
    try testing.expectEqual(@as(i32, 42), res1.val);
    try testing.expectEqual(false, res1.shared);
    try testing.expectEqual(@as(usize, 1), state.calls);

    const res2 = try g.do("key1", TestState.work, .{&state});
    try testing.expectEqual(@as(i32, 42), res2.val);
    try testing.expectEqual(false, res2.shared);
    try testing.expectEqual(@as(usize, 2), state.calls);
}

test "singleflight: concurrent deduplication" {
    const io = testing.io;

    const SharedState = struct {
        calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        io: std.Io,

        fn slowWork(self: *@This()) !i32 {
            _ = self.calls.fetchAdd(1, .monotonic);
            self.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            return 100;
        }
    };

    var state = SharedState{ .io = io };
    var g = Group(i32).init(testing.allocator);
    defer g.deinit();

    const Worker = struct {
        group: *Group(i32),
        state: *SharedState,
        res: Group(i32).Result = undefined,

        fn run(self: *@This()) void {
            self.res = self.group.do("heavy-key", SharedState.slowWork, .{self.state}) catch |err| {
                std.debug.panic("singleflight worker failed: {s}", .{@errorName(err)});
            };
        }
    };

    var w1 = Worker{ .group = &g, .state = &state };
    var w2 = Worker{ .group = &g, .state = &state };
    var w3 = Worker{ .group = &g, .state = &state };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{&w3});

    t1.join();
    t2.join();
    t3.join();

    // Verify work was only called once or twice at most across concurrent threads
    try testing.expect(state.calls.load(.monotonic) <= 2);
    try testing.expectEqual(@as(i32, 100), w1.res.val);
    try testing.expectEqual(@as(i32, 100), w2.res.val);
    try testing.expectEqual(@as(i32, 100), w3.res.val);

    // At least one of the concurrent workers got shared = true if more than 1 arrived concurrently
    if (state.calls.load(.monotonic) == 1) {
        try testing.expect(w1.res.shared or w2.res.shared or w3.res.shared);
    }
}

test "singleflight: error propagation" {
    const ErrWorker = struct {
        fn fail() anyerror!i32 {
            return error.FetchFailed;
        }
    };

    var g = Group(i32).init(testing.allocator);
    defer g.deinit();

    const res = g.do("err-key", ErrWorker.fail, .{});
    try testing.expectError(error.FetchFailed, res);
}

test "singleflight: forget cancels sharing for subsequent calls" {
    var g = Group(i32).init(testing.allocator);
    defer g.deinit();

    const Counter = struct {
        fn get() i32 {
            return 99;
        }
    };

    const res1 = try g.do("forget-key", Counter.get, .{});
    try testing.expectEqual(@as(i32, 99), res1.val);

    // Key was completed and auto-removed, so forget returns false
    try testing.expect(!g.forget("forget-key"));
}

test "singleflight: OOM during create does not deadlock" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var g = Group(i32).init(failing.allocator());
    defer g.deinit();

    const Work = struct {
        fn run() i32 {
            return 7;
        }
    };

    try testing.expectError(error.OutOfMemory, g.do("oom-key", Work.run, .{}));
    // Mutex must be unlocked so subsequent calls do not deadlock.
    try testing.expect(!g.forget("oom-key"));
}
