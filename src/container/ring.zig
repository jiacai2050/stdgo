const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        next_ptr: *Self,
        prev_ptr: *Self,
        value: T,

        pub fn init(allocator: Allocator, n: usize) Allocator.Error!*Self {
            if (n == 0) return error.OutOfMemory;

            var r = try allocator.create(Self);
            r.next_ptr = r;
            r.prev_ptr = r;
            r.value = undefined;

            var p = r;
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const q = try allocator.create(Self);
                q.next_ptr = r;
                q.prev_ptr = p;
                p.next_ptr = q;
                r.prev_ptr = q;
                q.value = undefined;
                p = q;
            }
            return r;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            const count = self.len();
            var cur = self;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const next_node = cur.next_ptr;
                allocator.destroy(cur);
                cur = next_node;
            }
        }

        pub fn next(self: *Self) *Self {
            return self.next_ptr;
        }

        pub fn prev(self: *Self) *Self {
            return self.prev_ptr;
        }

        pub fn move(self: *Self, n: i64) *Self {
            var r = self;
            if (n > 0) {
                var i: i64 = 0;
                while (i < n) : (i += 1) {
                    r = r.next_ptr;
                }
            } else if (n < 0) {
                var i: i64 = 0;
                while (i < -n) : (i += 1) {
                    r = r.prev_ptr;
                }
            }
            return r;
        }

        /// Link connects ring r with ring s such that r.next() becomes s and returns the original value for r.next().
        pub fn link(self: *Self, s: *Self) *Self {
            const n = self.next_ptr;
            const p = s.prev_ptr;
            self.next_ptr = s;
            s.prev_ptr = self;
            n.prev_ptr = p;
            p.next_ptr = n;
            return n;
        }

        /// Unlink removes n % r.len() elements from the ring r, starting at r.next().
        pub fn unlink(self: *Self, n: usize) *Self {
            if (n == 0) return self;
            return self.link(self.move(@as(i64, @intCast(n)) + 1));
        }

        /// Len computes the number of elements in ring r.
        pub fn len(self: *const Self) usize {
            var n: usize = 0;
            if (self.next_ptr == self) return 1;
            var p = self;
            while (true) {
                n += 1;
                p = p.next_ptr;
                if (p == self) break;
            }
            return n;
        }
    };
}

test "container.Ring basic cycle and link" {
    const testing = std.testing;

    const IntRing = Ring(i32);
    const r = try IntRing.init(testing.allocator, 3);
    defer r.deinit(testing.allocator);

    r.value = 1;
    r.next().value = 2;
    r.next().next().value = 3;

    try testing.expectEqual(@as(usize, 3), r.len());
    try testing.expectEqual(@as(i32, 1), r.value);
    try testing.expectEqual(@as(i32, 2), r.next().value);
    try testing.expectEqual(@as(i32, 3), r.prev().value);
}
