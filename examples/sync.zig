//! Example demonstrating stdgo sync primitives:
//! 1. sync.WaitGroup: Concurrent barrier
//! 2. sync.Once: Safe single-execution initialization
//! 3. sync.Mutex: Critical section mutual exclusion
//! 4. sync.Pool: High-throughput memory buffer reuse
//! (See also examples/errgroup.zig for structured concurrent errgroup)

const std = @import("std");
const stdgo = @import("stdgo");
const sync = stdgo.sync;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: sync Concurrency Primitives Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. sync.WaitGroup: Barrier Synchronization
    // -------------------------------------------------------------
    std.debug.print("1. sync.WaitGroup:\n", .{});
    var wg = sync.WaitGroup.init();

    const Worker = struct {
        fn run(group: *sync.WaitGroup, id: usize) void {
            defer group.done();
            std.debug.print("   -> Worker {d} starting task...\n", .{id});
            std.Thread.yield() catch {};
            std.debug.print("   -> Worker {d} task completed.\n", .{id});
        }
    };

    const worker_count = 3;
    wg.add(worker_count);
    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &wg, idx + 1 });
    }

    wg.wait();
    for (threads) |t| t.join();
    std.debug.print("   All workers finished!\n\n", .{});

    // -------------------------------------------------------------
    // 2. sync.Once: Exactly once initialization
    // -------------------------------------------------------------
    std.debug.print("2. sync.Once:\n", .{});
    var once = sync.Once.init();
    var init_calls: usize = 0;

    const Initializer = struct {
        fn initResource(counter: *usize) void {
            counter.* += 1;
            std.debug.print("   *** Resource expensive setup executed! (Count: {d}) ***\n", .{counter.*});
        }
    };

    // Call 5 times, should execute only once
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        once.do(Initializer.initResource, .{&init_calls});
    }
    std.debug.print("   After 5 calls to once.do(), setup run count is: {d}\n\n", .{init_calls});

    // -------------------------------------------------------------
    // 3. sync.Pool: Temporary Object Pooling
    // -------------------------------------------------------------
    std.debug.print("3. sync.Pool (Buffer Pooling):\n", .{});

    const ScratchBuffer = struct {
        data: [128]u8 = undefined,
        len: usize = 0,

        fn new(allocator: std.mem.Allocator) std.mem.Allocator.Error!*@This() {
            return try allocator.create(@This());
        }

        fn destroy(allocator: std.mem.Allocator, buf: *@This()) void {
            allocator.destroy(buf);
        }
    };

    var pool = sync.Pool(ScratchBuffer).init(gpa, ScratchBuffer.new);
    defer pool.deinit(ScratchBuffer.destroy);

    // Get item from pool (triggers new)
    const buf1 = (try pool.get()).?;
    buf1.len = 42;
    std.debug.print("   Acquired buf1 from pool, set len = {d}\n", .{buf1.len});

    // Return to pool
    try pool.put(buf1);
    std.debug.print("   Returned buf1 to pool\n", .{});

    // Acquire again (should reuse)
    const buf2 = (try pool.get()).?;
    std.debug.print("   Acquired buf2 from pool, reused same buffer? {any} (len={d})\n", .{ buf1 == buf2, buf2.len });
    try pool.put(buf2);

    std.debug.print("\n=== sync demo completed successfully! ===\n", .{});
}
