const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Duration = enum(i64) {
    _,

    pub const nanosecond: Duration = @enumFromInt(1);
    pub const microsecond: Duration = @enumFromInt(1000);
    pub const millisecond: Duration = @enumFromInt(1_000_000);
    pub const second: Duration = @enumFromInt(1_000_000_000);
    pub const minute: Duration = @enumFromInt(60 * 1_000_000_000);
    pub const hour: Duration = @enumFromInt(60 * 60 * 1_000_000_000);

    pub fn nanoseconds(self: Duration) i64 {
        return @intFromEnum(self);
    }

    pub fn microseconds(self: Duration) i64 {
        return @divTrunc(@intFromEnum(self), 1000);
    }

    pub fn milliseconds(self: Duration) i64 {
        return @divTrunc(@intFromEnum(self), 1_000_000);
    }

    pub fn seconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(@intFromEnum(self))) / 1e9;
    }

    pub fn minutes(self: Duration) f64 {
        return self.seconds() / 60.0;
    }

    pub fn hours(self: Duration) f64 {
        return self.minutes() / 60.0;
    }

    pub fn string(self: Duration, allocator: Allocator) Allocator.Error![]u8 {
        var buf: [32]u8 = undefined;
        const total_ns = @intFromEnum(self);
        if (total_ns == 0) {
            return try allocator.dupe(u8, "0s");
        }

        var u = total_ns;
        var is_neg = false;
        if (u < 0) {
            is_neg = true;
            u = -u;
        }

        const out = if (u < 1000)
            try std.fmt.bufPrint(&buf, "{s}{d}ns", .{ if (is_neg) "-" else "", u })
        else if (u < 1_000_000)
            try std.fmt.bufPrint(&buf, "{s}{d}us", .{ if (is_neg) "-" else "", @divTrunc(u, 1000) })
        else if (u < 1_000_000_000)
            try std.fmt.bufPrint(&buf, "{s}{d}ms", .{ if (is_neg) "-" else "", @divTrunc(u, 1_000_000) })
        else
            try std.fmt.bufPrint(&buf, "{s}{d}s", .{ if (is_neg) "-" else "", @divTrunc(u, 1_000_000_000) });

        return try allocator.dupe(u8, out);
    }
};

pub const Error = error{
    InvalidDuration,
};

/// ParseDuration parses a duration string.
/// A duration string is a sequence of decimal numbers, each with optional
/// fraction and a unit suffix, such as "300ms", "-1.5h" or "2h45m".
/// Valid time units are "ns", "us" (or "µs"), "ms", "s", "m", "h".
pub fn parseDuration(s_in: []const u8) Error!Duration {
    var s = s_in;
    if (s.len == 0) return Error.InvalidDuration;

    var neg = false;
    if (s[0] == '-' or s[0] == '+') {
        neg = (s[0] == '-');
        s = s[1..];
    }

    if (std.mem.eql(u8, s, "0")) {
        return @enumFromInt(0);
    }
    if (s.len == 0) return Error.InvalidDuration;

    var total_ns: u64 = 0;

    while (s.len > 0) {
        var v: u64 = 0;
        var f: u64 = 0;
        var scale: f64 = 1.0;

        if (!(s[0] == '.' or (s[0] >= '0' and s[0] <= '9'))) {
            return Error.InvalidDuration;
        }

        // Consume leading integer digits
        const pl = s.len;
        while (s.len > 0 and s[0] >= '0' and s[0] <= '9') {
            v = v * 10 + (s[0] - '0');
            s = s[1..];
        }
        const pre = (pl != s.len);

        // Consume fraction
        var post = false;
        if (s.len > 0 and s[0] == '.') {
            s = s[1..];
            while (s.len > 0 and s[0] >= '0' and s[0] <= '9') {
                if (scale < 1e9) {
                    f = f * 10 + (s[0] - '0');
                    scale *= 10;
                }
                s = s[1..];
                post = true;
            }
        }

        if (!pre and !post) return Error.InvalidDuration;

        // Consume unit
        var u_end: usize = 0;
        while (u_end < s.len and s[u_end] != '.' and (s[u_end] < '0' or s[u_end] > '9')) : (u_end += 1) {}
        const unit = s[0..u_end];
        s = s[u_end..];

        const unit_ns: u64 = if (std.mem.eql(u8, unit, "ns"))
            1
        else if (std.mem.eql(u8, unit, "us") or std.mem.eql(u8, unit, "µs"))
            1000
        else if (std.mem.eql(u8, unit, "ms"))
            1_000_000
        else if (std.mem.eql(u8, unit, "s"))
            1_000_000_000
        else if (std.mem.eql(u8, unit, "m"))
            60 * 1_000_000_000
        else if (std.mem.eql(u8, unit, "h"))
            60 * 60 * 1_000_000_000
        else
            return Error.InvalidDuration;

        total_ns += v * unit_ns;
        if (post) {
            const frac_ns: u64 = @intFromFloat((@as(f64, @floatFromInt(f)) / scale) * @as(f64, @floatFromInt(unit_ns)));
            total_ns += frac_ns;
        }
    }

    var signed_ns: i64 = @intCast(total_ns);
    if (neg) {
        signed_ns = -signed_ns;
    }
    return @enumFromInt(signed_ns);
}

test "time.parseDuration Go test cases" {
    const testing = std.testing;

    const d0 = try parseDuration("0");
    try testing.expectEqual(@as(i64, 0), d0.nanoseconds());

    const d1 = try parseDuration("300ms");
    try testing.expectEqual(@as(i64, 300), d1.milliseconds());

    const d2 = try parseDuration("-1.5s");
    try testing.expectEqual(@as(i64, -1500), d2.milliseconds());

    const d3 = try parseDuration("2h45m");
    try testing.expectEqual(@as(i64, (2 * 60 + 45) * 60 * 1000), d3.milliseconds());

    const d4 = try parseDuration("50us");
    try testing.expectEqual(@as(i64, 50), d4.microseconds());

    const d5 = try parseDuration("1h30m10s500ms");
    try testing.expectEqual(@as(f64, 90.175), d5.minutes());

    // Error cases
    try testing.expectError(Error.InvalidDuration, parseDuration(""));
    try testing.expectError(Error.InvalidDuration, parseDuration("xyz"));
    try testing.expectError(Error.InvalidDuration, parseDuration("10")); // missing unit
}
