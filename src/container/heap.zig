const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Heap(comptime T: type, comptime lessFn: fn (a: T, b: T) bool) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        items: std.ArrayList(T),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .items = std.ArrayList(T).empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.items.items.len == 0) return null;
            return self.items.items[0];
        }

        pub fn push(self: *Self, val: T) Allocator.Error!void {
            try self.items.append(self.allocator, val);
            self.siftUp(self.items.items.len - 1);
        }

        pub fn pop(self: *Self) ?T {
            const count = self.items.items.len;
            if (count == 0) return null;

            const root = self.items.items[0];
            const last = self.items.items[count - 1];
            self.items.items[0] = last;
            _ = self.items.pop();

            if (self.items.items.len > 0) {
                self.siftDown(0);
            }
            return root;
        }

        fn siftUp(self: *Self, index: usize) void {
            var i = index;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (!lessFn(self.items.items[i], self.items.items[parent])) {
                    break;
                }
                std.mem.swap(T, &self.items.items[i], &self.items.items[parent]);
                i = parent;
            }
        }

        fn siftDown(self: *Self, index: usize) void {
            var i = index;
            const count = self.items.items.len;
            while (true) {
                var smallest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;

                if (left < count and lessFn(self.items.items[left], self.items.items[smallest])) {
                    smallest = left;
                }
                if (right < count and lessFn(self.items.items[right], self.items.items[smallest])) {
                    smallest = right;
                }
                if (smallest == i) break;

                std.mem.swap(T, &self.items.items[i], &self.items.items[smallest]);
                i = smallest;
            }
        }
    };
}

test "container.Heap min-heap sorting" {
    const testing = std.testing;

    const MinIntHeap = Heap(i32, struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less);

    var h = MinIntHeap.init(testing.allocator);
    defer h.deinit();

    try h.push(40);
    try h.push(10);
    try h.push(30);
    try h.push(20);
    try h.push(5);

    try testing.expectEqual(@as(usize, 5), h.len());
    try testing.expectEqual(@as(?i32, 5), h.peek());

    try testing.expectEqual(@as(?i32, 5), h.pop());
    try testing.expectEqual(@as(?i32, 10), h.pop());
    try testing.expectEqual(@as(?i32, 20), h.pop());
    try testing.expectEqual(@as(?i32, 30), h.pop());
    try testing.expectEqual(@as(?i32, 40), h.pop());
    try testing.expectEqual(@as(?i32, null), h.pop());
}
