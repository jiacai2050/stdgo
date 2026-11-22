const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = @import("mutex.zig").Mutex;

/// Pool is a set of temporary objects that may be individually saved and
/// retrieved, replicating Go's sync.Pool semantics.
///
/// Thread-safe via internal spin Mutex.
/// Allocator is explicitly provided by the caller upon initialization.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const capacity: usize = 256;

        allocator: Allocator,
        new_fn: ?*const fn (Allocator) Allocator.Error!*T,
        destroy_fn: ?*const fn (Allocator, *T) void = null,
        items: [capacity]*T = undefined,
        count: usize = 0,
        mutex: Mutex = .{},

        pub fn init(allocator: Allocator, new_fn: ?*const fn (Allocator) Allocator.Error!*T) Self {
            return .{
                .allocator = allocator,
                .new_fn = new_fn,
                .destroy_fn = null,
                .items = undefined,
                .count = 0,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self, destroy_fn: ?*const fn (Allocator, *T) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const df = destroy_fn orelse self.destroy_fn;
            if (df) |d| {
                for (self.items[0..self.count]) |item| {
                    d(self.allocator, item);
                }
            }
            self.count = 0;
        }

        pub fn get(self: *Self) Allocator.Error!?*T {
            self.mutex.lock();
            if (self.count > 0) {
                self.count -= 1;
                const item = self.items[self.count];
                self.mutex.unlock();
                return item;
            }
            self.mutex.unlock();

            if (self.new_fn) |nf| {
                return try nf(self.allocator);
            }
            return null;
        }

        pub fn put(self: *Self, item: *T) void {
            self.mutex.lock();
            if (self.count < capacity) {
                self.items[self.count] = item;
                self.count += 1;
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();

            if (self.destroy_fn) |df| {
                df(self.allocator, item);
            }
        }
    };
}

test "sync.Pool basic get/put with new_fn" {
    const testing = std.testing;

    const TestObj = struct {
        val: i32,
    };

    const Helper = struct {
        fn create(allocator: Allocator) Allocator.Error!*TestObj {
            const ptr = try allocator.create(TestObj);
            ptr.val = 100;
            return ptr;
        }

        fn destroy(allocator: Allocator, ptr: *TestObj) void {
            allocator.destroy(ptr);
        }
    };

    var pool = Pool(TestObj).init(testing.allocator, Helper.create);
    defer pool.deinit(Helper.destroy);

    // Initial get should invoke new_fn
    const obj1 = (try pool.get()).?;
    try testing.expectEqual(@as(i32, 100), obj1.val);

    obj1.val = 42;
    pool.put(obj1);

    // Next get should retrieve the recycled instance
    const obj2 = (try pool.get()).?;
    try testing.expectEqual(@as(i32, 42), obj2.val);
    try testing.expectEqual(obj1, obj2);

    pool.put(obj2);
}

test "sync.Pool capacity overflow discards or destroys excess items" {
    const testing = std.testing;

    const TestObj = struct {
        val: usize,
    };

    const Context = struct {
        var destroyed_count: usize = 0;

        fn create(allocator: Allocator) Allocator.Error!*TestObj {
            const ptr = try allocator.create(TestObj);
            ptr.val = 0;
            return ptr;
        }

        fn destroy(allocator: Allocator, ptr: *TestObj) void {
            destroyed_count += 1;
            allocator.destroy(ptr);
        }
    };

    Context.destroyed_count = 0;
    var pool = Pool(TestObj).init(testing.allocator, Context.create);
    pool.destroy_fn = Context.destroy;
    defer pool.deinit(Context.destroy);

    // Allocate capacity + 10 items
    const total_items = Pool(TestObj).capacity + 10;
    var items: [total_items]*TestObj = undefined;
    for (0..total_items) |i| {
        items[i] = (try pool.get()).?;
        items[i].val = i;
    }

    // Return all items to pool
    for (0..total_items) |i| {
        pool.put(items[i]);
    }

    // Exactly 10 items should have been destroyed immediately due to overflow
    try testing.expectEqual(@as(usize, 10), Context.destroyed_count);

    // The pool should now contain exactly capacity items
    try testing.expectEqual(Pool(TestObj).capacity, pool.count);

    // Draining the pool should return 256 items
    for (0..Pool(TestObj).capacity) |_| {
        const item = (try pool.get()).?;
        testing.allocator.destroy(item);
    }

    // Now empty
    try testing.expectEqual(@as(usize, 0), pool.count);
}
