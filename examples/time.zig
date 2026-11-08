//! Example demonstrating stdgo time package:
//! 1. time.Duration: parseDuration, unit conversions (seconds, minutes, hours)
//! 2. time.Time: now, unix, add, sub (duration arithmetic)
//! 3. time.sleep: cooperative sleeping via Zig 0.17 std.Io

const std = @import("std");
const stdgo = @import("stdgo");
const time = stdgo.time;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print("=== stdgo: time & duration Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. time.parseDuration: Go-style duration strings
    // -------------------------------------------------------------
    std.debug.print("1. Parsing Duration strings:\n", .{});

    const duration_strs = [_][]const u8{
        "300ms",
        "1h30m",
        "45s",
        "2h45m12s",
        "500us",
    };

    for (duration_strs) |d_str| {
        const d = try time.parseDuration(d_str);
        std.debug.print("   parseDuration(\"{s}\"): {d:.3}s (ms: {d}, total ns: {d})\n", .{
            d_str,
            d.seconds(),
            d.milliseconds(),
            d.nanoseconds(),
        });
    }

    // -------------------------------------------------------------
    // 2. time.Time: Now & Arithmetic
    // -------------------------------------------------------------
    std.debug.print("\n2. Time and Arithmetic:\n", .{});
    const t_start = time.Time.now(io);
    std.debug.print("   Current Unix timestamp: {d} seconds (nano: {d})\n", .{
        t_start.wall_sec,
        t_start.unixNano(),
    });

    const shift = try time.parseDuration("1h15m");
    const t_future = t_start.add(shift);
    std.debug.print("   Adding 1h15m -> Future Unix timestamp: {d} seconds\n", .{t_future.wall_sec});

    const diff = t_future.sub(t_start);
    std.debug.print("   Difference: {d:.1} minutes ({d} seconds)\n\n", .{ diff.minutes(), @as(i64, @intFromFloat(diff.seconds())) });

    // -------------------------------------------------------------
    // 3. time.sleep
    // -------------------------------------------------------------
    std.debug.print("3. time.sleep(5ms)...\n", .{});
    const sleep_dur: time.Duration = @enumFromInt(5 * 1_000_000); // 5ms
    try time.sleep(io, sleep_dur);
    const t_after = time.Time.now(io);
    const elapsed = t_after.sub(t_start);
    std.debug.print("   Elapsed since start: {d:.2}ms\n", .{elapsed.seconds() * 1000.0});

    std.debug.print("\n=== time demo completed successfully! ===\n", .{});
}
