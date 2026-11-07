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

        allocator: Allocator,
        new_fn: ?*const fn (Allocator) Allocator.Error!*T,
        items: std.ArrayList(*T),
        mutex: Mutex = .{},

        pub fn init(allocator: Allocator, new_fn: ?*const fn (Allocator) Allocator.Error!*T) Self {
            return .{
                .allocator = allocator,
                .new_fn = new_fn,
                .items = std.ArrayList(*T).empty,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self, destroy_fn: ?*const fn (Allocator, *T) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (destroy_fn) |df| {
                for (self.items.items) |item| {
                    df(self.allocator, item);
                }
            }
            self.items.deinit(self.allocator);
        }

        pub fn get(self: *Self) Allocator.Error!?*T {
            self.mutex.lock();
            if (self.items.items.len > 0) {
                const item = self.items.pop().?;
                self.mutex.unlock();
                return item;
            }
            self.mutex.unlock();

            if (self.new_fn) |nf| {
                return try nf(self.allocator);
            }
            return null;
        }

        pub fn put(self: *Self, item: *T) Allocator.Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(self.allocator, item);
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
    try pool.put(obj1);

    // Next get should retrieve the recycled instance
    const obj2 = (try pool.get()).?;
    try testing.expectEqual(@as(i32, 42), obj2.val);
    try testing.expectEqual(obj1, obj2);

    try pool.put(obj2);
}
