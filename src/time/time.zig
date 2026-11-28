const std = @import("std");
const Allocator = std.mem.Allocator;
const duration_mod = @import("duration.zig");
pub const Duration = duration_mod.Duration;
pub const parseDuration = duration_mod.parseDuration;

pub const Month = enum(u8) {
    January = 1,
    February = 2,
    March = 3,
    April = 4,
    May = 5,
    June = 6,
    July = 7,
    August = 8,
    September = 9,
    October = 10,
    November = 11,
    December = 12,

    pub fn string(self: Month) []const u8 {
        return switch (self) {
            .January => "January",
            .February => "February",
            .March => "March",
            .April => "April",
            .May => "May",
            .June => "June",
            .July => "July",
            .August => "August",
            .September => "September",
            .October => "October",
            .November => "November",
            .December => "December",
        };
    }

    pub fn shortString(self: Month) []const u8 {
        return self.string()[0..3];
    }
};

pub const Weekday = enum(u8) {
    Sunday = 0,
    Monday = 1,
    Tuesday = 2,
    Wednesday = 3,
    Thursday = 4,
    Friday = 5,
    Saturday = 6,

    pub fn string(self: Weekday) []const u8 {
        return switch (self) {
            .Sunday => "Sunday",
            .Monday => "Monday",
            .Tuesday => "Tuesday",
            .Wednesday => "Wednesday",
            .Thursday => "Thursday",
            .Friday => "Friday",
            .Saturday => "Saturday",
        };
    }

    pub fn shortString(self: Weekday) []const u8 {
        return self.string()[0..3];
    }
};

pub const Location = struct {
    name: []const u8,
    offset_sec: i32,

    pub const UTC: Location = .{ .name = "UTC", .offset_sec = 0 };

    pub fn fixedZone(name: []const u8, offset_sec: i32) Location {
        return .{ .name = name, .offset_sec = offset_sec };
    }
};

// Standard Go layout format strings
pub const ANSIC = "Mon Jan _2 15:04:05 2006";
pub const UnixDate = "Mon Jan _2 15:04:05 MST 2006";
pub const RubyDate = "Mon Jan 02 15:04:05 -0700 2006";
pub const RFC822 = "02 Jan 06 15:04 MST";
pub const RFC822Z = "02 Jan 06 15:04 -0700";
pub const RFC850 = "Monday, 02-Jan-06 15:04:05 MST";
pub const RFC1123 = "Mon, 02 Jan 2006 15:04:05 MST";
pub const RFC1123Z = "Mon, 02 Jan 2006 15:04:05 -0700";
pub const RFC3339 = "2006-01-02T15:04:05Z07:00";
pub const RFC3339Nano = "2006-01-02T15:04:05.999999999Z07:00";
pub const Kitchen = "3:04PM";
pub const Stamp = "Jan _2 15:04:05";
pub const StampMilli = "Jan _2 15:04:05.000";
pub const StampMicro = "Jan _2 15:04:05.000000";
pub const StampNano = "Jan _2 15:04:05.000000000";
pub const DateTime = "2006-01-02 15:04:05";
pub const DateOnly = "2006-01-02";
pub const TimeOnly = "15:04:05";

pub const Time = struct {
    wall_sec: i64,
    nsec: i32,
    loc: Location = Location.UTC,

    pub fn now(io: std.Io) Time {
        const ts = std.Io.Clock.real.now(io);
        const ns: i64 = @intCast(ts.nanoseconds);
        const sec = @divFloor(ns, std.time.ns_per_s);
        const rem = @mod(ns, std.time.ns_per_s);
        return .{
            .wall_sec = sec,
            .nsec = @intCast(rem),
            .loc = Location.UTC,
        };
    }

    pub fn unix(sec: i64, nsec: i64) Time {
        return .{
            .wall_sec = sec,
            .nsec = @intCast(nsec),
            .loc = Location.UTC,
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
            .loc = self.loc,
        };
    }

    pub fn sub(self: Time, u: Time) Duration {
        const diff = self.unixNano() - u.unixNano();
        return @fromBackingInt(@intCast(diff));
    }

    pub fn utc(self: Time) Time {
        var res = self;
        res.loc = Location.UTC;
        return res;
    }

    pub fn inLocation(self: Time, loc: Location) Time {
        var res = self;
        res.loc = loc;
        return res;
    }

    // Civil Calendar conversion using Howard Hinnant algorithm
    fn civil(self: Time) struct { y: i32, m: u8, d: u8, h: u8, min: u8, sec: u8 } {
        const local_sec = self.wall_sec + self.loc.offset_sec;
        const days = @divFloor(local_sec, 86400);
        var rem_sec = @mod(local_sec, 86400);
        if (rem_sec < 0) rem_sec += 86400;

        const h: u8 = @intCast(@divFloor(rem_sec, 3600));
        const rem_min = @mod(rem_sec, 3600);
        const min: u8 = @intCast(@divFloor(rem_min, 60));
        const sec: u8 = @intCast(@mod(rem_min, 60));

        const z = days + 719468;
        const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
        const doe = z - era * 146097;
        const doe_adj = doe - @divFloor(doe, 1460) +
            @divFloor(doe, 36524) -
            @divFloor(doe, 146096);
        const yoe = @divFloor(doe_adj, 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
        const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
        const final_y: i32 = @intCast(y + (if (m <= 2) @as(i64, 1) else 0));

        return .{ .y = final_y, .m = m, .d = d, .h = h, .min = min, .sec = sec };
    }

    pub fn year(self: Time) i32 {
        return self.civil().y;
    }

    pub fn month(self: Time) Month {
        return @fromBackingInt(@intCast(self.civil().m));
    }

    pub fn day(self: Time) u8 {
        return self.civil().d;
    }

    pub fn hour(self: Time) u8 {
        return self.civil().h;
    }

    pub fn minute(self: Time) u8 {
        return self.civil().min;
    }

    pub fn second(self: Time) u8 {
        return self.civil().sec;
    }

    pub fn nanosecond(self: Time) u32 {
        var ns = self.nsec;
        if (ns < 0) ns += std.time.ns_per_s;
        return @intCast(ns);
    }

    pub fn weekday(self: Time) Weekday {
        const local_sec = self.wall_sec + self.loc.offset_sec;
        const days = @divFloor(local_sec, 86400);
        var wd = @mod(days + 4, 7);
        if (wd < 0) wd += 7;
        return @fromBackingInt(@intCast(@as(u8, @intCast(wd))));
    }

    pub fn yearDay(self: Time) u16 {
        const c = self.civil();
        const start_of_year = date(c.y, .January, 1, 0, 0, 0, 0, self.loc);
        const cur_sec = self.wall_sec + self.loc.offset_sec;
        const soy_sec = start_of_year.wall_sec + start_of_year.loc.offset_sec;
        const days = @divFloor(cur_sec - soy_sec, 86400);
        return @intCast(days + 1);
    }

    /// Format writes the formatted time into buf according to the Go layout string.
    pub fn format(self: Time, layout: []const u8, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try self.formatToWriter(layout, &w);
        return w.buffered();
    }

    /// FormatAlloc allocates and returns the formatted time string according to layout.
    pub fn formatAlloc(self: Time, allocator: Allocator, layout: []const u8) ![]u8 {
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        if (self.formatToWriter(layout, &w)) |_| {
            return try allocator.dupe(u8, w.buffered());
        } else |_| {
            var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
            defer aw.deinit();
            try self.formatToWriter(layout, &aw.writer);
            return try allocator.dupe(u8, aw.writer.buffered());
        }
    }

    fn formatToWriter(self: Time, layout: []const u8, w: *std.Io.Writer) !void {
        const c = self.civil();
        const wd = self.weekday();
        const m = self.month();

        var i: usize = 0;
        while (i < layout.len) {
            // Check longer tokens first
            if (std.mem.startsWith(u8, layout[i..], "2006")) {
                const u_y: u32 = if (c.y >= 0) @intCast(c.y) else @intCast(-c.y);
                if (c.y < 0) try w.writeByte('-');
                try w.print("{d:0>4}", .{u_y});
                i += 4;
            } else if (std.mem.startsWith(u8, layout[i..], "06")) {
                const short_y: u32 = @intCast(@mod(if (c.y >= 0) c.y else -c.y, 100));
                try w.print("{d:0>2}", .{short_y});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "January")) {
                try w.writeAll(m.string());
                i += 7;
            } else if (std.mem.startsWith(u8, layout[i..], "Jan")) {
                try w.writeAll(m.shortString());
                i += 3;
            } else if (std.mem.startsWith(u8, layout[i..], "Monday")) {
                try w.writeAll(wd.string());
                i += 6;
            } else if (std.mem.startsWith(u8, layout[i..], "Mon")) {
                try w.writeAll(wd.shortString());
                i += 3;
            } else if (std.mem.startsWith(u8, layout[i..], "01")) {
                try w.print("{d:0>2}", .{@as(u32, c.m)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "02")) {
                try w.print("{d:0>2}", .{@as(u32, c.d)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "_2")) {
                try w.print("{d: >2}", .{@as(u32, c.d)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "15")) {
                try w.print("{d:0>2}", .{@as(u32, c.h)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "03")) {
                const h12: u32 = if (c.h == 0) 12 else if (c.h > 12) c.h - 12 else c.h;
                try w.print("{d:0>2}", .{h12});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "04")) {
                try w.print("{d:0>2}", .{@as(u32, c.min)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "05")) {
                try w.print("{d:0>2}", .{@as(u32, c.sec)});
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "PM")) {
                try w.writeAll(if (c.h >= 12) "PM" else "AM");
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], "pm")) {
                try w.writeAll(if (c.h >= 12) "pm" else "am");
                i += 2;
            } else if (std.mem.startsWith(u8, layout[i..], ".000000000")) {
                try formatFrac(w, self.nanosecond(), 9, false);
                i += 10;
            } else if (std.mem.startsWith(u8, layout[i..], ".999999999")) {
                try formatFrac(w, self.nanosecond(), 9, true);
                i += 10;
            } else if (std.mem.startsWith(u8, layout[i..], ".000000")) {
                try formatFrac(w, self.nanosecond(), 6, false);
                i += 7;
            } else if (std.mem.startsWith(u8, layout[i..], ".999999")) {
                try formatFrac(w, self.nanosecond(), 6, true);
                i += 7;
            } else if (std.mem.startsWith(u8, layout[i..], ".000")) {
                try formatFrac(w, self.nanosecond(), 3, false);
                i += 4;
            } else if (std.mem.startsWith(u8, layout[i..], ".999")) {
                try formatFrac(w, self.nanosecond(), 3, true);
                i += 4;
            } else if (std.mem.startsWith(u8, layout[i..], "Z07:00")) {
                if (self.loc.offset_sec == 0) {
                    try w.writeByte('Z');
                } else {
                    try formatOffset(self.loc.offset_sec, true, w);
                }
                i += 6;
            } else if (std.mem.startsWith(u8, layout[i..], "Z0700")) {
                if (self.loc.offset_sec == 0) {
                    try w.writeByte('Z');
                } else {
                    try formatOffset(self.loc.offset_sec, false, w);
                }
                i += 5;
            } else if (std.mem.startsWith(u8, layout[i..], "-07:00")) {
                try formatOffset(self.loc.offset_sec, true, w);
                i += 6;
            } else if (std.mem.startsWith(u8, layout[i..], "-0700")) {
                try formatOffset(self.loc.offset_sec, false, w);
                i += 5;
            } else if (std.mem.startsWith(u8, layout[i..], "MST")) {
                try w.writeAll(self.loc.name);
                i += 3;
            } else if (std.mem.startsWith(u8, layout[i..], "1")) {
                try w.print("{d}", .{@as(u32, c.m)});
                i += 1;
            } else if (std.mem.startsWith(u8, layout[i..], "2")) {
                try w.print("{d}", .{@as(u32, c.d)});
                i += 1;
            } else if (std.mem.startsWith(u8, layout[i..], "3")) {
                const h12: u32 = if (c.h == 0) 12 else if (c.h > 12) c.h - 12 else c.h;
                try w.print("{d}", .{h12});
                i += 1;
            } else if (std.mem.startsWith(u8, layout[i..], "4")) {
                try w.print("{d}", .{@as(u32, c.min)});
                i += 1;
            } else if (std.mem.startsWith(u8, layout[i..], "5")) {
                try w.print("{d}", .{@as(u32, c.sec)});
                i += 1;
            } else {
                try w.writeByte(layout[i]);
                i += 1;
            }
        }
    }
};

fn formatFrac(w: *std.Io.Writer, nsec: u32, digits: usize, strip_zeros: bool) !void {
    var buf: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{nsec}) catch unreachable;
    var len = digits;
    if (strip_zeros) {
        while (len > 0 and buf[len - 1] == '0') {
            len -= 1;
        }
        if (len == 0) return;
    }
    try w.writeByte('.');
    try w.writeAll(buf[0..len]);
}

fn formatOffset(offset_sec: i32, with_colon: bool, w: *std.Io.Writer) !void {
    var off = offset_sec;
    const sign: u8 = if (off >= 0) '+' else '-';
    if (off < 0) off = -off;
    const h: u32 = @intCast(@divFloor(off, 3600));
    const m: u32 = @intCast(@divFloor(@mod(off, 3600), 60));
    if (with_colon) {
        try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, h, m });
    } else {
        try w.print("{c}{d:0>2}{d:0>2}", .{ sign, h, m });
    }
}

/// Constructs a Time value from its civil calendar date and time parts.
pub fn date(
    y_in: i32,
    m: Month,
    d_in: u8,
    hour: u8,
    min: u8,
    sec: u8,
    nsec: u32,
    loc_in: ?Location,
) Time {
    var y = y_in;
    const m_val: u8 = @backingInt(m);
    if (m_val <= 2) y -= 1;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe = y - era * 400;
    const m_adj: u32 = if (m_val <= 2) m_val + 9 else m_val - 3;
    const doy: i32 = @intCast(@divFloor(153 * m_adj + 2, 5) + d_in - 1);
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;

    const loc = loc_in orelse Location.UTC;
    const local_sec = days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
    const utc_sec = local_sec - loc.offset_sec;

    return .{
        .wall_sec = utc_sec,
        .nsec = @intCast(nsec),
        .loc = loc,
    };
}

pub const ParseError = error{
    InvalidFormat,
    ValueOutOfRange,
};

/// Parse parses a formatted string and returns the time value it represents.
pub fn parse(layout: []const u8, value: []const u8) ParseError!Time {
    var y: i32 = 1970;
    var m: Month = .January;
    var d: u8 = 1;
    var hour: u8 = 0;
    var min: u8 = 0;
    var sec: u8 = 0;
    var nsec: u32 = 0;
    var offset_sec: i32 = 0;
    var zone_name: []const u8 = "UTC";
    var pm: ?bool = null;

    var li: usize = 0;
    var vi: usize = 0;

    while (li < layout.len) {
        // Optional trailing-zero fractional tokens may be omitted even at end of value.
        if (std.mem.startsWith(u8, layout[li..], ".999999999")) {
            li += 10;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 9);
            }
            continue;
        } else if (std.mem.startsWith(u8, layout[li..], ".999999")) {
            li += 7;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 6);
            }
            continue;
        } else if (std.mem.startsWith(u8, layout[li..], ".999")) {
            li += 4;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 3);
            }
            continue;
        }

        if (vi >= value.len) return ParseError.InvalidFormat;

        if (std.mem.startsWith(u8, layout[li..], "2006")) {
            if (vi + 4 > value.len) return ParseError.InvalidFormat;
            y = std.fmt.parseInt(i32, value[vi .. vi + 4], 10) catch {
                return ParseError.InvalidFormat;
            };
            li += 4;
            vi += 4;
        } else if (std.mem.startsWith(u8, layout[li..], "06")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            const yy = std.fmt.parseInt(i32, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            y = if (yy >= 69) 1900 + yy else 2000 + yy;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "January")) {
            var found = false;
            inline for (std.meta.tags(Month)) |tag| {
                const name = tag.string();
                if (std.mem.startsWith(u8, value[vi..], name)) {
                    m = tag;
                    vi += name.len;
                    found = true;
                    break;
                }
            }
            if (!found) return ParseError.InvalidFormat;
            li += 7;
        } else if (std.mem.startsWith(u8, layout[li..], "Jan")) {
            var found = false;
            inline for (std.meta.tags(Month)) |tag| {
                const sname = tag.shortString();
                if (std.mem.startsWith(u8, value[vi..], sname)) {
                    m = tag;
                    vi += 3;
                    found = true;
                    break;
                }
            }
            if (!found) return ParseError.InvalidFormat;
            li += 3;
        } else if (std.mem.startsWith(u8, layout[li..], "01")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            const month_num = std.fmt.parseInt(u8, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            if (month_num < 1 or month_num > 12) return ParseError.ValueOutOfRange;
            m = @fromBackingInt(@intCast(month_num));
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "Monday")) {
            var found = false;
            inline for (std.meta.tags(Weekday)) |tag| {
                const wname = tag.string();
                if (std.mem.startsWith(u8, value[vi..], wname)) {
                    vi += wname.len;
                    found = true;
                    break;
                }
            }
            if (!found) return ParseError.InvalidFormat;
            li += 6;
        } else if (std.mem.startsWith(u8, layout[li..], "Mon")) {
            var found = false;
            inline for (std.meta.tags(Weekday)) |tag| {
                const swname = tag.shortString();
                if (std.mem.startsWith(u8, value[vi..], swname)) {
                    vi += 3;
                    found = true;
                    break;
                }
            }
            if (!found) return ParseError.InvalidFormat;
            li += 3;
        } else if (std.mem.startsWith(u8, layout[li..], "02") or
            std.mem.startsWith(u8, layout[li..], "_2"))
        {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            const s = std.mem.trimStart(u8, value[vi .. vi + 2], " ");
            d = std.fmt.parseInt(u8, s, 10) catch return ParseError.InvalidFormat;
            if (d < 1 or d > 31) return ParseError.ValueOutOfRange;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "15")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            hour = std.fmt.parseInt(u8, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            if (hour > 23) return ParseError.ValueOutOfRange;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "03")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            hour = std.fmt.parseInt(u8, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            if (hour < 1 or hour > 12) return ParseError.ValueOutOfRange;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "04")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            min = std.fmt.parseInt(u8, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            if (min > 59) return ParseError.ValueOutOfRange;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "05")) {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            sec = std.fmt.parseInt(u8, value[vi .. vi + 2], 10) catch {
                return ParseError.InvalidFormat;
            };
            if (sec > 59) return ParseError.ValueOutOfRange;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], "PM") or
            std.mem.startsWith(u8, layout[li..], "pm"))
        {
            if (vi + 2 > value.len) return ParseError.InvalidFormat;
            if (std.ascii.eqlIgnoreCase(value[vi .. vi + 2], "PM")) {
                pm = true;
            } else if (std.ascii.eqlIgnoreCase(value[vi .. vi + 2], "AM")) {
                pm = false;
            } else return ParseError.InvalidFormat;
            li += 2;
            vi += 2;
        } else if (std.mem.startsWith(u8, layout[li..], ".000000000")) {
            li += 10;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 9);
            }
        } else if (std.mem.startsWith(u8, layout[li..], ".000000")) {
            li += 7;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 6);
            }
        } else if (std.mem.startsWith(u8, layout[li..], ".000")) {
            li += 4;
            if (vi < value.len and value[vi] == '.') {
                nsec = try parseFracDigits(value, &vi, 3);
            }
        } else if (std.mem.startsWith(u8, layout[li..], "Z07:00") or
            std.mem.startsWith(u8, layout[li..], "-07:00"))
        {
            const has_z = std.mem.startsWith(u8, layout[li..], "Z");
            li += 6;
            if (has_z and vi < value.len and (value[vi] == 'Z' or value[vi] == 'z')) {
                offset_sec = 0;
                zone_name = "UTC";
                vi += 1;
            } else {
                if (vi + 6 > value.len) return ParseError.InvalidFormat;
                const sign_ch = value[vi];
                if (sign_ch != '+' and sign_ch != '-') return ParseError.InvalidFormat;
                const oh = std.fmt.parseInt(
                    i32,
                    value[vi + 1 .. vi + 3],
                    10,
                ) catch return ParseError.InvalidFormat;
                if (value[vi + 3] != ':') return ParseError.InvalidFormat;
                const om = std.fmt.parseInt(
                    i32,
                    value[vi + 4 .. vi + 6],
                    10,
                ) catch return ParseError.InvalidFormat;
                const total = oh * 3600 + om * 60;
                offset_sec = if (sign_ch == '-') -total else total;
                zone_name = value[vi .. vi + 6];
                vi += 6;
            }
        } else if (std.mem.startsWith(u8, layout[li..], "Z0700") or
            std.mem.startsWith(u8, layout[li..], "-0700"))
        {
            const has_z = std.mem.startsWith(u8, layout[li..], "Z");
            li += 5;
            if (has_z and vi < value.len and (value[vi] == 'Z' or value[vi] == 'z')) {
                offset_sec = 0;
                zone_name = "UTC";
                vi += 1;
            } else {
                if (vi + 5 > value.len) return ParseError.InvalidFormat;
                const sign_ch = value[vi];
                if (sign_ch != '+' and sign_ch != '-') return ParseError.InvalidFormat;
                const oh = std.fmt.parseInt(
                    i32,
                    value[vi + 1 .. vi + 3],
                    10,
                ) catch return ParseError.InvalidFormat;
                const om = std.fmt.parseInt(
                    i32,
                    value[vi + 3 .. vi + 5],
                    10,
                ) catch return ParseError.InvalidFormat;
                const total = oh * 3600 + om * 60;
                offset_sec = if (sign_ch == '-') -total else total;
                zone_name = value[vi .. vi + 5];
                vi += 5;
            }
        } else if (std.mem.startsWith(u8, layout[li..], "MST")) {
            li += 3;
            // Parse alphanumeric timezone name, e.g. UTC, GMT, CST
            const v_start = vi;
            while (vi < value.len and
                ((value[vi] >= 'A' and value[vi] <= 'Z') or
                    (value[vi] >= 'a' and value[vi] <= 'z'))) : (vi += 1)
            {}
            if (vi == v_start) return ParseError.InvalidFormat;
            zone_name = value[v_start..vi];
            if (std.mem.eql(u8, zone_name, "UTC") or std.mem.eql(u8, zone_name, "GMT")) {
                offset_sec = 0;
            }
        } else if (std.mem.startsWith(u8, layout[li..], "1")) {
            const month_num = try parse1Or2Digits(value, &vi);
            if (month_num < 1 or month_num > 12) return ParseError.ValueOutOfRange;
            m = @fromBackingInt(@intCast(month_num));
            li += 1;
        } else if (std.mem.startsWith(u8, layout[li..], "2")) {
            d = try parse1Or2Digits(value, &vi);
            if (d < 1 or d > 31) return ParseError.ValueOutOfRange;
            li += 1;
        } else if (std.mem.startsWith(u8, layout[li..], "3")) {
            hour = try parse1Or2Digits(value, &vi);
            if (hour < 1 or hour > 12) return ParseError.ValueOutOfRange;
            li += 1;
        } else if (std.mem.startsWith(u8, layout[li..], "4")) {
            min = try parse1Or2Digits(value, &vi);
            if (min > 59) return ParseError.ValueOutOfRange;
            li += 1;
        } else if (std.mem.startsWith(u8, layout[li..], "5")) {
            sec = try parse1Or2Digits(value, &vi);
            if (sec > 59) return ParseError.ValueOutOfRange;
            li += 1;
        } else {
            if (layout[li] != value[vi]) return ParseError.InvalidFormat;
            li += 1;
            vi += 1;
        }
    }

    if (vi != value.len) return ParseError.InvalidFormat;

    if (pm) |is_pm| {
        if (hour > 12) return ParseError.ValueOutOfRange;
        if (is_pm and hour < 12) {
            hour += 12;
        } else if (!is_pm and hour == 12) {
            hour = 0;
        }
    }

    if (hour > 23 or min > 59 or sec > 59) return ParseError.ValueOutOfRange;

    const loc = Location.fixedZone(zone_name, offset_sec);
    return date(y, m, d, hour, min, sec, nsec, loc);
}

fn parse1Or2Digits(value: []const u8, vi: *usize) ParseError!u8 {
    if (vi.* >= value.len or value[vi.*] < '0' or value[vi.*] > '9') {
        return ParseError.InvalidFormat;
    }
    var val: u8 = value[vi.*] - '0';
    vi.* += 1;
    if (vi.* < value.len and value[vi.*] >= '0' and value[vi.*] <= '9') {
        val = val * 10 + (value[vi.*] - '0');
        vi.* += 1;
    }
    return val;
}

fn parseFracDigits(value: []const u8, vi: *usize, max_digits: usize) ParseError!u32 {
    std.debug.assert(vi.* < value.len and value[vi.*] == '.');
    vi.* += 1;
    var count: usize = 0;
    var frac: u32 = 0;
    while (vi.* < value.len and value[vi.*] >= '0' and value[vi.*] <= '9' and count < max_digits) : ({
        vi.* += 1;
        count += 1;
    }) {
        frac = frac * 10 + (value[vi.*] - '0');
    }
    if (count == 0) return ParseError.InvalidFormat;
    var scale_remaining = 9 - count;
    while (scale_remaining > 0) : (scale_remaining -= 1) {
        frac *= 10;
    }
    return frac;
}

pub fn sleep(io: std.Io, d: Duration) !void {
    const ns = d.nanoseconds();
    if (ns <= 0) return;
    try io.sleep(std.Io.Duration.fromNanoseconds(ns), .awake);
}

test "time.Time now and add/sub" {
    const testing = std.testing;

    const io = testing.io;

    const t_now = Time.now(io);
    try testing.expect(t_now.wall_sec > 0);

    const t0 = Time.unix(100, 0);
    const t1 = t0.add(try duration_mod.parseDuration("10s"));

    try testing.expectEqual(@as(i64, 110), t1.wall_sec);
    const diff = t1.sub(t0);
    try testing.expectEqual(@as(i64, 10_000_000_000), diff.nanoseconds());

    // verify sleep executes cleanly via caller-provided std.Io
    try sleep(io, @fromBackingInt(@intCast(1_000)));
}

test "time calendar breakdown and date construction" {
    const testing = std.testing;

    // 2026-11-15 00:05:00 UTC
    const t = date(2026, .November, 15, 0, 5, 30, 500_000_000, null);
    try testing.expectEqual(@as(i32, 2026), t.year());
    try testing.expectEqual(Month.November, t.month());
    try testing.expectEqual(@as(u8, 15), t.day());
    try testing.expectEqual(@as(u8, 0), t.hour());
    try testing.expectEqual(@as(u8, 5), t.minute());
    try testing.expectEqual(@as(u8, 30), t.second());
    try testing.expectEqual(@as(u32, 500_000_000), t.nanosecond());
    try testing.expectEqual(Weekday.Sunday, t.weekday());

    // Leap year verification: 2024-02-29
    const leap_t = date(2024, .February, 29, 12, 0, 0, 0, null);
    try testing.expectEqual(@as(i32, 2024), leap_t.year());
    try testing.expectEqual(Month.February, leap_t.month());
    try testing.expectEqual(@as(u8, 29), leap_t.day());
    try testing.expectEqual(Weekday.Thursday, leap_t.weekday());
}

test "time format and parse standard layouts" {
    const testing = std.testing;

    const loc = Location.fixedZone("CST", 8 * 3600);
    const t0 = date(2026, .November, 15, 14, 30, 45, 123_000_000, loc);

    // RFC3339 format
    var buf: [64]u8 = undefined;
    const s_rfc = try t0.format(RFC3339, &buf);
    try testing.expectEqualStrings("2026-11-15T14:30:45+08:00", s_rfc);

    // RFC3339 parse
    const t_parsed = try parse(RFC3339, "2026-11-15T14:30:45+08:00");
    try testing.expectEqual(t0.wall_sec, t_parsed.wall_sec);

    // DateTime
    const s_dt = try t0.format(DateTime, &buf);
    try testing.expectEqualStrings("2026-11-15 14:30:45", s_dt);

    const t_dt = try parse(DateTime, "2026-11-15 14:30:45");
    try testing.expectEqual(@as(i32, 2026), t_dt.year());
    try testing.expectEqual(@as(u8, 15), t_dt.day());
    try testing.expectEqual(@as(u8, 14), t_dt.hour());

    // RFC1123 for HTTP headers: "Sun, 15 Nov 2026 06:30:45 GMT"
    const t_utc = t0.utc();
    const s_http = try t_utc.format(RFC1123, &buf);
    try testing.expectEqualStrings("Sun, 15 Nov 2026 06:30:45 UTC", s_http);

    const t_http_parsed = try parse(RFC1123, s_http);
    try testing.expectEqual(t_utc.wall_sec, t_http_parsed.wall_sec);

    // Alloc format
    const s_alloc = try t0.formatAlloc(testing.allocator, DateOnly);
    defer testing.allocator.free(s_alloc);
    try testing.expectEqualStrings("2026-11-15", s_alloc);

    // Negative timezone offset (New York UTC-5)
    const t_ny = date(2026, .November, 15, 9, 30, 0, 0, Location.fixedZone("EST", -5 * 3600));
    const s_ny = try t_ny.format(RFC3339, &buf);
    try testing.expectEqualStrings("2026-11-15T09:30:00-05:00", s_ny);

    const t_ny_parsed = try parse(RFC3339, "2026-11-15T09:30:00-05:00");
    try testing.expectEqual(t_ny.wall_sec, t_ny_parsed.wall_sec);

    // Kitchen format (12-hour AM/PM)
    const s_kitchen = try t0.format(Kitchen, &buf);
    try testing.expectEqualStrings("2:30PM", s_kitchen);

    const t_morning = date(2026, .November, 15, 9, 5, 0, 0, null);
    const s_morning_k = try t_morning.format(Kitchen, &buf);
    try testing.expectEqualStrings("9:05AM", s_morning_k);

    // YearDay test: 2026-01-01 is day 1, 2026-02-01 is day 32
    const t_jan1 = date(2026, .January, 1, 0, 0, 0, 0, null);
    try testing.expectEqual(@as(u16, 1), t_jan1.yearDay());
    const t_feb1 = date(2026, .February, 1, 0, 0, 0, 0, null);
    try testing.expectEqual(@as(u16, 32), t_feb1.yearDay());

    // RFC3339Nano strips trailing zeros (and omits dot when nsec == 0)
    const s_nano = try t0.format(RFC3339Nano, &buf);
    try testing.expectEqualStrings("2026-11-15T14:30:45.123+08:00", s_nano);
    const s_nano_zero = try t_morning.format(RFC3339Nano, &buf);
    try testing.expectEqualStrings("2026-11-15T09:05:00Z", s_nano_zero);

    // Parse Kitchen and microsecond layouts
    const t_kitchen = try parse(Kitchen, "2:30PM");
    try testing.expectEqual(@as(u8, 14), t_kitchen.hour());
    try testing.expectEqual(@as(u8, 30), t_kitchen.minute());

    const t_micro = try parse(StampMicro, "Nov 15 14:30:45.123456");
    try testing.expectEqual(@as(u32, 123_456_000), t_micro.nanosecond());

    // Range validation
    try testing.expectError(ParseError.ValueOutOfRange, parse(TimeOnly, "25:00:00"));
    try testing.expectError(ParseError.ValueOutOfRange, parse(TimeOnly, "12:60:00"));
    try testing.expectError(ParseError.ValueOutOfRange, parse(TimeOnly, "12:00:60"));
}
