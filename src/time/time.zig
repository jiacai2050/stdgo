const std = @import("std");
const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;

pub const Time = struct {
    wall_sec: i64,
    nsec: i32,

    pub fn now(io: std.Io) Time {
        const ts = std.Io.Clock.real.now(io);
        const ns: i64 = @intCast(ts.nanoseconds);
        const sec = @divFloor(ns, std.time.ns_per_s);
        const rem = @mod(ns, std.time.ns_per_s);
        return .{
            .wall_sec = sec,
            .nsec = @intCast(rem),
        };
    }

    pub fn unix(sec: i64, nsec: i64) Time {
        return .{
            .wall_sec = sec,
            .nsec = @intCast(nsec),
        };
    }

    pub fn unixNano(self: Time) i64 {
        return self.wall_sec * std.time.ns_per_s + self.nsec;
    }

    pub fn add(self: Time, d: Duration) Time {
        const total = self.unixNano() + d.nanoseconds();
        const sec = @divFloor(total, std.time.ns_per_s);
        const rem = @mod(total, std.time.ns_per_s);
        return .{
            .wall_sec = sec,
            .nsec = @intCast(rem),
        };
    }

    pub fn sub(self: Time, u: Time) Duration {
        const diff = self.unixNano() - u.unixNano();
        return @enumFromInt(diff);
    }
};

pub fn sleep(io: std.Io, d: Duration) !void {
    const ns = d.nanoseconds();
    if (ns <= 0) return;
    try io.sleep(std.Io.Duration.fromNanoseconds(ns), .awake);
}

test "time.Time now and add/sub" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const t_now = Time.now(io);
    try testing.expect(t_now.wall_sec > 0);

    const t0 = Time.unix(100, 0);
    const t1 = t0.add(try duration_mod.parseDuration("10s"));

    try testing.expectEqual(@as(i64, 110), t1.wall_sec);
    const diff = t1.sub(t0);
    try testing.expectEqual(@as(i64, 10_000_000_000), diff.nanoseconds());

    // verify sleep executes cleanly via caller-provided std.Io
    try sleep(io, @enumFromInt(1_000));
}
