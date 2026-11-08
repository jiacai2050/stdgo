//! Example demonstrating stdgo container packages:
//! 1. container.heap: Min-Heap priority queue
//! 2. container.ring: Circular doubly-linked list

const std = @import("std");
const stdgo = @import("stdgo");
const container = stdgo.container;

const Task = struct {
    priority: i32,
    name: []const u8,

    fn less(a: Task, b: Task) bool {
        // Min-heap by priority
        return a.priority < b.priority;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: container (heap & ring) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. container.heap: Min-heap Priority Queue
    // -------------------------------------------------------------
    std.debug.print("1. container.heap (Min-Heap Priority Queue):\n", .{});

    const TaskHeap = container.heap.Heap(Task, Task.less);
    var pq = TaskHeap.init(gpa);
    defer pq.deinit();

    try pq.push(.{ .priority = 30, .name = "Low priority cleanup" });
    try pq.push(.{ .priority = 5, .name = "Critical security patch" });
    try pq.push(.{ .priority = 10, .name = "Feature deployment" });
    try pq.push(.{ .priority = 1, .name = "Production outage alert" });

    std.debug.print("   Heap size: {d}\n", .{pq.len()});
    if (pq.peek()) |top| {
        std.debug.print("   Top priority item peek: [{d}] {s}\n", .{ top.priority, top.name });
    }

    std.debug.print("   Popping tasks in priority order:\n", .{});
    while (pq.pop()) |task| {
        std.debug.print("   -> [{d}] {s}\n", .{ task.priority, task.name });
    }

    // -------------------------------------------------------------
    // 2. container.ring: Circular doubly-linked list
    // -------------------------------------------------------------
    std.debug.print("\n2. container.ring (Circular Ring Buffer):\n", .{});

    const IntRing = container.ring.Ring(i32);
    const ring_size = 5;
    var r = try IntRing.init(gpa, ring_size);
    defer r.deinit(gpa);

    // Populate values 10, 20, 30, 40, 50
    var cur = r;
    var val: i32 = 10;
    var i: usize = 0;
    while (i < ring_size) : (i += 1) {
        cur.value = val;
        val += 10;
        cur = cur.next();
    }

    std.debug.print("   Ring len: {d}\n", .{r.len()});
    std.debug.print("   Traversing forward 5 steps: ", .{});
    cur = r;
    i = 0;
    while (i < ring_size) : (i += 1) {
        std.debug.print("{d} -> ", .{cur.value});
        cur = cur.next();
    }
    std.debug.print("(back to start: {d})\n", .{cur.value});

    const moved = r.move(3);
    std.debug.print("   Moving 3 steps forward from start: value = {d}\n", .{moved.value});

    std.debug.print("\n=== container demo completed successfully! ===\n", .{});
}
