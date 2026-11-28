const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// List implements a doubly linked list conforming to Go's container/list.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Element is an element of a linked list.
        pub const Element = struct {
            next: ?*Element = null,
            prev: ?*Element = null,
            list: ?*Self = null,
            value: T,

            /// Next returns the next list element or null.
            pub fn nextElement(self: *const Element) ?*Element {
                if (self.list == null) return null;
                const p = self.next orelse return null;
                if (p == &self.list.?.root) return null;
                return p;
            }

            /// Prev returns the previous list element or null.
            pub fn prevElement(self: *const Element) ?*Element {
                if (self.list == null) return null;
                const p = self.prev orelse return null;
                if (p == &self.list.?.root) return null;
                return p;
            }
        };

        allocator: Allocator,
        root: Element,
        length: usize = 0,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .root = .{
                    .next = null,
                    .prev = null,
                    .list = null,
                    .value = undefined,
                },
                .length = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
        }

        fn lazyInit(self: *Self) void {
            if (self.root.next == null) {
                self.root.next = &self.root;
                self.root.prev = &self.root;
                self.root.list = self;
                self.length = 0;
            }
        }

        /// Len returns the number of elements of list l.
        pub fn len(self: *const Self) usize {
            return self.length;
        }

        /// Front returns the first element of list l or null if the list is empty.
        pub fn front(self: *Self) ?*Element {
            self.lazyInit();
            if (self.length == 0) return null;
            return self.root.next;
        }

        /// Back returns the last element of list l or null if the list is empty.
        pub fn back(self: *Self) ?*Element {
            self.lazyInit();
            if (self.length == 0) return null;
            return self.root.prev;
        }

        fn insert(self: *Self, e: *Element, at: *Element) *Element {
            e.prev = at;
            e.next = at.next;
            e.prev.?.next = e;
            e.next.?.prev = e;
            e.list = self;
            self.length += 1;
            return e;
        }

        fn insertValue(self: *Self, v: T, at: *Element) Allocator.Error!*Element {
            const e = try self.allocator.create(Element);
            e.* = .{
                .next = null,
                .prev = null,
                .list = self,
                .value = v,
            };
            return self.insert(e, at);
        }

        fn removeElement(self: *Self, e: *Element) void {
            e.prev.?.next = e.next;
            e.next.?.prev = e.prev;
            e.next = null;
            e.prev = null;
            e.list = null;
            self.length -= 1;
        }

        fn move(self: *Self, e: *Element, at: *Element) void {
            _ = self;
            if (e == at) return;
            e.prev.?.next = e.next;
            e.next.?.prev = e.prev;

            e.prev = at;
            e.next = at.next;
            e.prev.?.next = e;
            e.next.?.prev = e;
        }

        /// Remove removes e from l if e is an element of list l.
        /// It frees the Element node and returns the stored value.
        pub fn remove(self: *Self, e: *Element) ?T {
            if (e.list != self) return null;
            const val = e.value;
            self.removeElement(e);
            self.allocator.destroy(e);
            return val;
        }

        /// PushFront inserts a new element e with value v at the front of list l.
        pub fn pushFront(self: *Self, v: T) Allocator.Error!*Element {
            self.lazyInit();
            return self.insertValue(v, &self.root);
        }

        /// PushBack inserts a new element e with value v at the back of list l.
        pub fn pushBack(self: *Self, v: T) Allocator.Error!*Element {
            self.lazyInit();
            return self.insertValue(v, self.root.prev.?);
        }

        /// InsertBefore inserts a new element e with value v immediately before mark.
        pub fn insertBefore(self: *Self, v: T, mark: *Element) Allocator.Error!?*Element {
            if (mark.list != self) return null;
            return try self.insertValue(v, mark.prev.?);
        }

        /// InsertAfter inserts a new element e with value v immediately after mark.
        pub fn insertAfter(self: *Self, v: T, mark: *Element) Allocator.Error!?*Element {
            if (mark.list != self) return null;
            return try self.insertValue(v, mark);
        }

        /// MoveToFront moves element e to the front of list l.
        pub fn moveToFront(self: *Self, e: *Element) void {
            if (e.list != self or self.root.next == e) return;
            self.move(e, &self.root);
        }

        /// MoveToBack moves element e to the back of list l.
        pub fn moveToBack(self: *Self, e: *Element) void {
            if (e.list != self or self.root.prev == e) return;
            self.move(e, self.root.prev.?);
        }

        /// MoveBefore moves element e to its new position before mark.
        pub fn moveBefore(self: *Self, e: *Element, mark: *Element) void {
            if (e.list != self or e == mark or mark.list != self) return;
            self.move(e, mark.prev.?);
        }

        /// MoveAfter moves element e to its new position after mark.
        pub fn moveAfter(self: *Self, e: *Element, mark: *Element) void {
            if (e.list != self or e == mark or mark.list != self) return;
            self.move(e, mark);
        }

        /// PushBackList inserts a copy of another list at the back of list l.
        pub fn pushBackList(self: *Self, other: *Self) Allocator.Error!void {
            self.lazyInit();
            var i = other.len();
            var curr = other.front();
            while (i > 0) : (i -= 1) {
                const e = curr orelse break;
                _ = try self.pushBack(e.value);
                curr = e.nextElement();
            }
        }

        /// PushFrontList inserts a copy of another list at the front of list l.
        pub fn pushFrontList(self: *Self, other: *Self) Allocator.Error!void {
            self.lazyInit();
            var i = other.len();
            var curr = other.back();
            while (i > 0) : (i -= 1) {
                const e = curr orelse break;
                _ = try self.pushFront(e.value);
                curr = e.prevElement();
            }
        }

        /// Clear clears all elements from the list.
        pub fn clear(self: *Self) void {
            if (self.root.next == null) return;
            var curr = self.root.next;
            while (curr != &self.root and curr != null) {
                const next = curr.?.next;
                self.allocator.destroy(curr.?);
                curr = next;
            }
            self.root.next = &self.root;
            self.root.prev = &self.root;
            self.length = 0;
        }
    };
}

test "container.list basic push, iteration and removal" {
    const testing = std.testing;
    var l = List(i32).init(testing.allocator);
    defer l.deinit();

    try testing.expectEqual(@as(usize, 0), l.len());
    try testing.expect(l.front() == null);
    try testing.expect(l.back() == null);

    const e1 = try l.pushBack(10);
    const e2 = try l.pushBack(20);
    const e0 = try l.pushFront(5);

    try testing.expectEqual(@as(usize, 3), l.len());
    try testing.expectEqual(@as(i32, 5), l.front().?.value);
    try testing.expectEqual(@as(i32, 20), l.back().?.value);

    // Iteration forwards
    const expected_forward = [_]i32{ 5, 10, 20 };
    var idx: usize = 0;
    var it = l.front();
    while (it) |node| : (it = node.nextElement()) {
        try testing.expectEqual(expected_forward[idx], node.value);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);

    // Iteration backwards
    const expected_back = [_]i32{ 20, 10, 5 };
    idx = 0;
    var bit = l.back();
    while (bit) |node| : (bit = node.prevElement()) {
        try testing.expectEqual(expected_back[idx], node.value);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);

    // InsertBefore & InsertAfter
    const e15 = (try l.insertBefore(15, e2)).?;
    _ = e15;
    const e25 = (try l.insertAfter(25, e2)).?;
    _ = e25;

    // Movement: MoveToFront, MoveToBack
    l.moveToFront(e2); // 20 moves to front: [20, 5, 10, 15, 25]
    try testing.expectEqual(@as(i32, 20), l.front().?.value);

    l.moveToBack(e0); // 5 moves to back: [20, 10, 15, 25, 5]
    try testing.expectEqual(@as(i32, 5), l.back().?.value);

    // Remove
    const removed = l.remove(e1);
    try testing.expectEqual(@as(?i32, 10), removed);
    try testing.expectEqual(@as(usize, 4), l.len());
}

test "container.list pushBackList and pushFrontList" {
    const testing = std.testing;
    var l1 = List([]const u8).init(testing.allocator);
    defer l1.deinit();
    _ = try l1.pushBack("a");
    _ = try l1.pushBack("b");

    var l2 = List([]const u8).init(testing.allocator);
    defer l2.deinit();
    _ = try l2.pushBack("c");
    _ = try l2.pushBack("d");

    try l1.pushBackList(&l2);
    try testing.expectEqual(@as(usize, 4), l1.len());

    const expected = [_][]const u8{ "a", "b", "c", "d" };
    var idx: usize = 0;
    var it = l1.front();
    while (it) |node| : (it = node.nextElement()) {
        try testing.expectEqualStrings(expected[idx], node.value);
        idx += 1;
    }

    // Self-append must not infinite-loop
    try l2.pushBackList(&l2);
    try testing.expectEqual(@as(usize, 4), l2.len());
    try l2.pushFrontList(&l2);
    try testing.expectEqual(@as(usize, 8), l2.len());
}
