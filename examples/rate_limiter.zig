const std = @import("std");
const stdgo = @import("stdgo");
const time = stdgo.time;
const rate = time.rate;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("=== stdgo.time.rate Token Bucket Limiter Demo ===\n\n");

    // Initialize rate limiter: 5 requests per second, burst capacity of 3
    var lim = rate.Limiter.init(5.0, 3);
    try stdout.print("Created Limiter: {d:.1} tokens/sec, burst capacity = {d}\n\n", .{ lim.limit(), lim.burst() });

    // 1. Non-blocking allow(): first 3 events should pass immediately (burst)
    try stdout.writeAll("Sending 5 immediate requests using allow():\n");
    for (1..6) |i| {
        const allowed = lim.allow(init.io);
        if (allowed) {
            try stdout.print("  Request #{d}: ALLOWED (burst consumed)\n", .{i});
        } else {
            try stdout.print("  Request #{d}: REJECTED (rate limit exceeded)\n", .{i});
        }
    }

    // 2. Pace requests through token refill.
    try stdout.writeAll("\nSending 3 requests paced with wait(io, deadline):\n");
    for (1..4) |i| {
        const t_start = time.Time.now(init.io);
        try lim.wait(init.io, .none);
        const t_end = time.Time.now(init.io);
        const elapsed_ms = t_end.sub(t_start).milliseconds();
        try stdout.print("  Paced Request #{d}: ALLOWED after {d}ms delay\n", .{ i, elapsed_ms });
    }

    try stdout.writeAll("\nRate limiter demo completed successfully!\n");
    try stdout.flush();
}
