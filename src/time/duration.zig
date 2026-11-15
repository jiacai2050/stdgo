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

    /// String returns a string representing the duration in the form "72h3m0.5s",
    /// like Go's time.Duration.String. Durations less than one second use a smaller
    /// unit (ms, µs, ns) so that the leading digit is non-zero. The zero duration
    /// formats as "0s". The caller owns the returned slice.
    pub fn string(self: Duration, allocator: Allocator) Allocator.Error![]u8 {
        const ns = @intFromEnum(self);
        if (ns == 0) return try allocator.dupe(u8, "0s");

        var buf: [32]u8 = undefined;
        var u: u64 = @abs(ns);
        var w: usize = buf.len;

        if (u < std.time.ns_per_s) {
            w -= 1;
            buf[w] = 's';
            var prec: usize = undefined;
            if (u < std.time.ns_per_us) {
                prec = 0;
                w -= 1;
                buf[w] = 'n';
            } else if (u < std.time.ns_per_ms) {
                prec = 3;
                w -= "µ".len;
                @memcpy(buf[w..][0.."µ".len], "µ");
            } else {
                prec = 6;
                w -= 1;
                buf[w] = 'm';
            }
            w, u = fmtFrac(buf[0..w], u, prec);
            w = fmtInt(buf[0..w], u);
        } else {
            w -= 1;
            buf[w] = 's';
            w, u = fmtFrac(buf[0..w], u, 9);
            w = fmtInt(buf[0..w], u % 60);
            u /= 60;
            if (u > 0) {
                w -= 1;
                buf[w] = 'm';
                w = fmtInt(buf[0..w], u % 60);
                u /= 60;
                if (u > 0) {
                    w -= 1;
                    buf[w] = 'h';
                    w = fmtInt(buf[0..w], u);
                }
            }
        }

        if (ns < 0) {
            w -= 1;
            buf[w] = '-';
        }
        return try allocator.dupe(u8, buf[w..]);
    }
};

/// Formats the fraction of v / 10^prec (e.g. ".12345") into the tail of buf, omitting
/// trailing zeros, and omitting the decimal point when the fraction is 0.
/// Returns the index where the output begins and v / 10^prec.
fn fmtFrac(buf: []u8, v: u64, prec: usize) struct { usize, u64 } {
    var w = buf.len;
    var rest = v;
    var print = false;
    for (0..prec) |_| {
        const digit: u8 = @intCast(rest % 10);
        print = print or digit != 0;
        if (print) {
            w -= 1;
            buf[w] = digit + '0';
        }
        rest /= 10;
    }
    if (print) {
        w -= 1;
        buf[w] = '.';
    }
    return .{ w, rest };
}

/// Formats v into the tail of buf and returns the index where the output begins.
fn fmtInt(buf: []u8, v: u64) usize {
    var w = buf.len;
    var rest = v;
    while (true) {
        w -= 1;
        buf[w] = @as(u8, @intCast(rest % 10)) + '0';
        rest /= 10;
        if (rest == 0) break;
    }
    return w;
}

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

test "time.Duration.string Go test cases" {
    const testing = std.testing;
    const minute: i64 = 60 * std.time.ns_per_s;
    const hour: i64 = 60 * minute;
    const cases = [_]struct { []const u8, i64 }{
        .{ "0s", 0 },
        .{ "1ns", 1 },
        .{ "1.1µs", 1100 },
        .{ "2.2ms", 2_200_000 },
        .{ "3.3s", 3_300_000_000 },
        .{ "4m5s", 4 * minute + 5 * std.time.ns_per_s },
        .{ "4m5.001s", 4 * minute + 5001 * std.time.ns_per_ms },
        .{ "5h6m7.001s", 5 * hour + 6 * minute + 7001 * std.time.ns_per_ms },
        .{ "8m0.000000001s", 8 * minute + 1 },
        .{ "-1.5s", -1_500_000_000 },
        .{ "2562047h47m16.854775807s", std.math.maxInt(i64) },
        .{ "-2562047h47m16.854775808s", std.math.minInt(i64) },
    };
    for (cases) |c| {
        const want, const ns = c;
        const got = try (@as(Duration, @enumFromInt(ns))).string(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
}
