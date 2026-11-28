pub const duration = @import("time/duration.zig");
const time_mod = @import("time/time.zig");
pub const rate = @import("time/rate.zig");

pub const Duration = duration.Duration;
pub const parseDuration = duration.parseDuration;

pub const Time = time_mod.Time;
pub const Month = time_mod.Month;
pub const Weekday = time_mod.Weekday;
pub const Location = time_mod.Location;
pub const date = time_mod.date;
pub const parse = time_mod.parse;
pub const sleep = time_mod.sleep;

// Standard Go layouts
pub const RFC3339 = time_mod.RFC3339;
pub const RFC3339Nano = time_mod.RFC3339Nano;
pub const RFC1123 = time_mod.RFC1123;
pub const RFC1123Z = time_mod.RFC1123Z;
pub const RFC822 = time_mod.RFC822;
pub const RFC822Z = time_mod.RFC822Z;
pub const RFC850 = time_mod.RFC850;
pub const DateTime = time_mod.DateTime;
pub const DateOnly = time_mod.DateOnly;
pub const TimeOnly = time_mod.TimeOnly;
pub const Kitchen = time_mod.Kitchen;

test {
    @import("std").testing.refAllDecls(@This());
    _ = duration;
    _ = time_mod;
    _ = rate;
}
