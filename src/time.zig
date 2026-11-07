pub const duration = @import("time/duration.zig");
pub const time_mod = @import("time/time.zig");

pub const Duration = duration.Duration;
pub const parseDuration = duration.parseDuration;
pub const Time = time_mod.Time;
pub const sleep = time_mod.sleep;

test {
    @import("std").testing.refAllDecls(@This());
    _ = duration;
    _ = time_mod;
}
