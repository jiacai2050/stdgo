const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../io.zig");

/// Level represents a logging severity level, matching Go's slog.Level.
pub const Level = enum(i32) {
    Debug = -4,
    Info = 0,
    Warn = 4,
    Error = 8,

    pub fn asString(self: Level) []const u8 {
        return switch (self) {
            .Debug => "DEBUG",
            .Info => "INFO",
            .Warn => "WARN",
            .Error => "ERROR",
        };
    }
};

pub const LevelDebug = Level.Debug;
pub const LevelInfo = Level.Info;
pub const LevelWarn = Level.Warn;
pub const LevelError = Level.Error;

/// Value holds a dynamic value for an Attr.
pub const Value = union(enum) {
    String: []const u8,
    Int64: i64,
    Uint64: u64,
    Float64: f64,
    Bool: bool,

    pub fn string(s: []const u8) Value {
        return .{ .String = s };
    }

    pub fn int(i: i64) Value {
        return .{ .Int64 = i };
    }

    pub fn uint(u: u64) Value {
        return .{ .Uint64 = u };
    }

    pub fn float(f: f64) Value {
        return .{ .Float64 = f };
    }

    pub fn boolean(b: bool) Value {
        return .{ .Bool = b };
    }
};

/// Attr represents a key-value attribute associated with a log Record.
pub const Attr = struct {
    key: []const u8,
    value: Value,

    pub fn string(k: []const u8, v: []const u8) Attr {
        return .{ .key = k, .value = Value.string(v) };
    }

    pub fn int(k: []const u8, v: i64) Attr {
        return .{ .key = k, .value = Value.int(v) };
    }

    pub fn uint(k: []const u8, v: u64) Attr {
        return .{ .key = k, .value = Value.uint(v) };
    }

    pub fn float(k: []const u8, v: f64) Attr {
        return .{ .key = k, .value = Value.float(v) };
    }

    pub fn boolean(k: []const u8, v: bool) Attr {
        return .{ .key = k, .value = Value.boolean(v) };
    }
};

/// Record holds the state of a single log event.
pub const Record = struct {
    time_unix_sec: i64,
    level: Level,
    message: []const u8,
    attrs: []const Attr,
};

/// Handler is the interface for processing structured log records.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        enabled: *const fn (ctx: *anyopaque, level: Level) bool,
        handle: *const fn (ctx: *anyopaque, record: Record) anyerror!void,
    };

    pub fn enabled(self: Handler, level: Level) bool {
        return self.vtable.enabled(self.ptr, level);
    }

    pub fn handle(self: Handler, record: Record) anyerror!void {
        return self.vtable.handle(self.ptr, record);
    }
};

/// TextHandler formats log records as key=value lines.
pub const TextHandler = struct {
    w: *io.Writer,
    min_level: Level = .Info,

    pub fn init(w: *io.Writer, min_level: Level) TextHandler {
        return .{
            .w = w,
            .min_level = min_level,
        };
    }

    pub fn handler(self: *TextHandler) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .enabled = enabledImpl,
                .handle = handleImpl,
            },
        };
    }

    fn enabledImpl(ctx: *anyopaque, level: Level) bool {
        const self: *TextHandler = @ptrCast(@alignCast(ctx));
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    fn handleImpl(ctx: *anyopaque, record: Record) anyerror!void {
        const self: *TextHandler = @ptrCast(@alignCast(ctx));
        if (!self.handler().enabled(record.level)) return;

        var buf: [256]u8 = undefined;

        // time=123456789 level=INFO msg="hello world"
        const prefix = try std.fmt.bufPrint(&buf, "time={d} level={s} msg=\"{s}\"", .{
            record.time_unix_sec,
            record.level.asString(),
            record.message,
        });
        try self.w.writeAll(prefix);

        for (record.attrs) |attr| {
            try self.w.writeAll(" ");
            try self.w.writeAll(attr.key);
            try self.w.writeAll("=");
            switch (attr.value) {
                .String => |s| {
                    if (std.mem.indexOfScalar(u8, s, ' ') != null) {
                        try self.w.writeAll("\"");
                        try self.w.writeAll(s);
                        try self.w.writeAll("\"");
                    } else {
                        try self.w.writeAll(s);
                    }
                },
                .Int64 => |i| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{i});
                    try self.w.writeAll(str);
                },
                .Uint64 => |u| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{u});
                    try self.w.writeAll(str);
                },
                .Float64 => |f| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                    try self.w.writeAll(str);
                },
                .Bool => |b| {
                    try self.w.writeAll(if (b) "true" else "false");
                },
            }
        }
        try self.w.writeAll("\n");
        try self.w.flush();
    }
};

/// JSONHandler formats log records as JSON objects.
pub const JSONHandler = struct {
    w: *io.Writer,
    min_level: Level = .Warn,

    pub fn init(w: *io.Writer, min_level: Level) JSONHandler {
        return .{
            .w = w,
            .min_level = min_level,
        };
    }

    pub fn handler(self: *JSONHandler) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .enabled = enabledImpl,
                .handle = handleImpl,
            },
        };
    }

    fn enabledImpl(ctx: *anyopaque, level: Level) bool {
        const self: *JSONHandler = @ptrCast(@alignCast(ctx));
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    fn handleImpl(ctx: *anyopaque, record: Record) anyerror!void {
        const self: *JSONHandler = @ptrCast(@alignCast(ctx));
        if (!self.handler().enabled(record.level)) return;

        var buf: [256]u8 = undefined;

        // {"time":123456789,"level":"INFO","msg":"hello"
        const prefix = try std.fmt.bufPrint(&buf, "{{\"time\":{d},\"level\":\"{s}\",\"msg\":\"", .{
            record.time_unix_sec,
            record.level.asString(),
        });
        try self.w.writeAll(prefix);
        try self.writeEscaped(record.message);
        try self.w.writeAll("\"");

        for (record.attrs) |attr| {
            try self.w.writeAll(",\"");
            try self.writeEscaped(attr.key);
            try self.w.writeAll("\":");

            switch (attr.value) {
                .String => |s| {
                    try self.w.writeAll("\"");
                    try self.writeEscaped(s);
                    try self.w.writeAll("\"");
                },
                .Int64 => |i| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{i});
                    try self.w.writeAll(str);
                },
                .Uint64 => |u| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{u});
                    try self.w.writeAll(str);
                },
                .Float64 => |f| {
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                    try self.w.writeAll(str);
                },
                .Bool => |b| {
                    try self.w.writeAll(if (b) "true" else "false");
                },
            }
        }
        try self.w.writeAll("}\n");
        try self.w.flush();
    }

    fn writeEscaped(self: *JSONHandler, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\"' => try self.w.writeAll("\\\""),
                '\\' => try self.w.writeAll("\\\\"),
                '\n' => try self.w.writeAll("\\n"),
                '\r' => try self.w.writeAll("\\r"),
                '\t' => try self.w.writeAll("\\t"),
                else => try self.w.writeAll(&[1]u8{c}),
            }
        }
    }
};

/// Logger provides structured logging methods.
pub const Logger = struct {
    h: Handler,
    extra_attrs: []const Attr = &.{},

    pub fn init(h: Handler) Logger {
        return .{
            .h = h,
        };
    }

    pub fn log(self: Logger, level: Level, msg: []const u8, attrs: []const Attr) !void {
        if (!self.h.enabled(level)) return;

        // If extra_attrs present, combine them
        if (self.extra_attrs.len == 0) {
            return self.h.handle(.{
                .time_unix_sec = 1700000000,
                .level = level,
                .message = msg,
                .attrs = attrs,
            });
        }

        var combined_buf: [32]Attr = undefined;
        const total = @min(combined_buf.len, self.extra_attrs.len + attrs.len);
        @memcpy(combined_buf[0..self.extra_attrs.len], self.extra_attrs);
        const copied_attrs = @min(attrs.len, total - self.extra_attrs.len);
        @memcpy(combined_buf[self.extra_attrs.len .. self.extra_attrs.len + copied_attrs], attrs[0..copied_attrs]);

        return self.h.handle(.{
            .time_unix_sec = 1700000000,
            .level = level,
            .message = msg,
            .attrs = combined_buf[0..total],
        });
    }

    pub fn debug(self: Logger, msg: []const u8, attrs: []const Attr) !void {
        return self.log(.Debug, msg, attrs);
    }

    pub fn info(self: Logger, msg: []const u8, attrs: []const Attr) !void {
        return self.log(.Info, msg, attrs);
    }

    pub fn warn(self: Logger, msg: []const u8, attrs: []const Attr) !void {
        return self.log(.Warn, msg, attrs);
    }

    pub fn errorLevel(self: Logger, msg: []const u8, attrs: []const Attr) !void {
        return self.log(.Error, msg, attrs);
    }

    pub fn with(self: Logger, attrs: []const Attr) Logger {
        return .{
            .h = self.h,
            .extra_attrs = attrs,
        };
    }
};

test "log.slog TextHandler formatting" {
    const testing = std.testing;
    const bytes_mod = @import("../bytes.zig");

    var buf = bytes_mod.Buffer.init(testing.allocator);
    defer buf.deinit();

    var th = TextHandler.init(buf.writer(), .Info);
    const logger = Logger.init(th.handler());

    const attrs = [_]Attr{
        Attr.string("user", "alice"),
        Attr.int("attempts", 3),
        Attr.boolean("admin", false),
    };

    // Debug should be filtered out
    try logger.debug("this should not appear", &.{});
    try testing.expectEqualStrings("", buf.string());

    // Info should appear
    try logger.info("login attempt", &attrs);
    const out = buf.string();
    try testing.expect(std.mem.indexOf(u8, out, "level=INFO msg=\"login attempt\" user=alice attempts=3 admin=false\n") != null);
}

test "log.slog JSONHandler formatting" {
    const testing = std.testing;
    const bytes_mod = @import("../bytes.zig");

    var buf = bytes_mod.Buffer.init(testing.allocator);
    defer buf.deinit();

    var jh = JSONHandler.init(buf.writer(), .Warn);
    const logger = Logger.init(jh.handler());

    const attrs = [_]Attr{
        Attr.string("path", "/api/v1/resource"),
        Attr.int("status", 404),
    };

    // Info filtered out because min_level is Warn
    try logger.info("normal request", &.{});
    try testing.expectEqualStrings("", buf.string());

    // Warn should be serialized to valid JSON
    try logger.warn("resource missing", &attrs);
    const out = buf.string();
    try testing.expect(std.mem.indexOf(u8, out, "\"level\":\"WARN\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"msg\":\"resource missing\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/api/v1/resource\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":404") != null);
}

test "log.slog Logger.with child logger" {
    const testing = std.testing;
    const bytes_mod = @import("../bytes.zig");

    var buf = bytes_mod.Buffer.init(testing.allocator);
    defer buf.deinit();

    var th = TextHandler.init(buf.writer(), .Debug);
    const root_logger = Logger.init(th.handler());

    const common = [_]Attr{
        Attr.string("component", "auth_service"),
    };
    const auth_logger = root_logger.with(&common);

    try auth_logger.info("token generated", &.{Attr.int("exp", 3600)});
    const out = buf.string();
    try testing.expect(std.mem.indexOf(u8, out, "component=auth_service") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exp=3600") != null);
}
