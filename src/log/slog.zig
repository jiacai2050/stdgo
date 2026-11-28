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
    attrs: []const Attr = &.{},
    /// Additional attribute groups inherited from parent loggers via `Logger.with`.
    attr_groups: []const []const Attr = &.{},
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
        return @backingInt(level) >= @backingInt(self.min_level);
    }

    fn handleImpl(ctx: *anyopaque, record: Record) anyerror!void {
        const self: *TextHandler = @ptrCast(@alignCast(ctx));
        if (!self.handler().enabled(record.level)) return;

        // Stream directly to self.w without fixed buffer length limits.
        try self.w.print("time={d} level={s} msg=", .{
            record.time_unix_sec,
            record.level.asString(),
        });
        try writeQuotedText(self.w, record.message);

        for (record.attr_groups) |group| {
            for (group) |attr| {
                try self.writeAttr(attr);
            }
        }
        for (record.attrs) |attr| {
            try self.writeAttr(attr);
        }
        try self.w.writeAll("\n");
        try self.w.flush();
    }

    fn writeAttr(self: *TextHandler, attr: Attr) !void {
        try self.w.writeAll(" ");
        if (needsTextQuoting(attr.key)) {
            try writeQuotedText(self.w, attr.key);
        } else {
            try self.w.writeAll(attr.key);
        }
        try self.w.writeAll("=");
        switch (attr.value) {
            .String => |s| {
                if (needsTextQuoting(s)) {
                    try writeQuotedText(self.w, s);
                } else {
                    try self.w.writeAll(s);
                }
            },
            .Int64 => |i| try self.w.print("{d}", .{i}),
            .Uint64 => |u| try self.w.print("{d}", .{u}),
            .Float64 => |f| try self.w.print("{d}", .{f}),
            .Bool => |b| try self.w.writeAll(if (b) "true" else "false"),
        }
    }

    fn needsTextQuoting(s: []const u8) bool {
        if (s.len == 0) return true;
        for (s) |c| {
            if (c <= 0x20 or c == '"' or c == '\\' or c == '=') return true;
        }
        return false;
    }

    fn writeQuotedText(w: *io.Writer, s: []const u8) !void {
        try w.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\x{x:0>2}", .{c}),
                else => try w.writeByte(c),
            }
        }
        try w.writeByte('"');
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
        return @backingInt(level) >= @backingInt(self.min_level);
    }

    fn handleImpl(ctx: *anyopaque, record: Record) anyerror!void {
        const self: *JSONHandler = @ptrCast(@alignCast(ctx));
        if (!self.handler().enabled(record.level)) return;

        try self.w.print("{{\"time\":{d},\"level\":\"{s}\",\"msg\":\"", .{
            record.time_unix_sec,
            record.level.asString(),
        });
        try self.writeEscaped(record.message);
        try self.w.writeAll("\"");

        for (record.attr_groups) |group| {
            for (group) |attr| {
                try self.writeAttr(attr);
            }
        }
        for (record.attrs) |attr| {
            try self.writeAttr(attr);
        }
        try self.w.writeAll("}\n");
        try self.w.flush();
    }

    fn writeAttr(self: *JSONHandler, attr: Attr) !void {
        try self.w.writeAll(",\"");
        try self.writeEscaped(attr.key);
        try self.w.writeAll("\":");

        switch (attr.value) {
            .String => |s| {
                try self.w.writeAll("\"");
                try self.writeEscaped(s);
                try self.w.writeAll("\"");
            },
            .Int64 => |i| try self.w.print("{d}", .{i}),
            .Uint64 => |u| try self.w.print("{d}", .{u}),
            .Float64 => |f| try self.w.print("{d}", .{f}),
            .Bool => |b| try self.w.writeAll(if (b) "true" else "false"),
        }
    }

    fn writeEscaped(self: *JSONHandler, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\"' => try self.w.writeAll("\\\""),
                '\\' => try self.w.writeAll("\\\\"),
                '\x08' => try self.w.writeAll("\\b"),
                '\x0c' => try self.w.writeAll("\\f"),
                '\n' => try self.w.writeAll("\\n"),
                '\r' => try self.w.writeAll("\\r"),
                '\t' => try self.w.writeAll("\\t"),
                0x00...0x07, 0x0b, 0x0e...0x1f => try self.w.print("\\u{x:0>4}", .{c}),
                else => try self.w.writeByte(c),
            }
        }
    }
};

/// Logger provides structured logging methods.
pub const Logger = struct {
    /// Maximum number of chained `with()` attribute groups supported without heap allocation.
    pub const max_attr_groups: usize = 32;

    h: Handler,
    /// Optional std.Io clock source; when null, log timestamps default to 0.
    io: ?std.Io = null,
    attr_groups: [max_attr_groups][]const Attr = @splat(&.{}),
    attr_group_count: usize = 0,

    /// Initializes a Logger with the given Handler and no clock source (timestamps default to 0).
    pub fn init(h: Handler) Logger {
        return .{
            .h = h,
        };
    }

    /// Initializes a Logger with the given Handler and std.Io clock source for real timestamps.
    pub fn initWithIo(h: Handler, clock_io: std.Io) Logger {
        return .{
            .h = h,
            .io = clock_io,
        };
    }

    /// Emits a structured log record at the specified severity level.
    pub fn log(self: Logger, level: Level, msg: []const u8, attrs: []const Attr) !void {
        if (!self.h.enabled(level)) return;

        const now_sec: i64 = if (self.io) |clock_io|
            @intCast(@divFloor(std.Io.Clock.real.now(clock_io).nanoseconds, std.time.ns_per_s))
        else
            0;

        return self.h.handle(.{
            .time_unix_sec = now_sec,
            .level = level,
            .message = msg,
            .attrs = attrs,
            .attr_groups = self.attr_groups[0..self.attr_group_count],
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

    /// Returns a child Logger that includes attrs in addition to all parent attributes.
    /// Callers must ensure the attrs slice outlives the returned Logger.
    pub fn with(self: Logger, attrs: []const Attr) Logger {
        if (attrs.len == 0) return self;
        std.debug.assert(self.attr_group_count < max_attr_groups);
        var child = self;
        child.attr_groups[child.attr_group_count] = attrs;
        child.attr_group_count += 1;
        return child;
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
    const expected = "level=INFO msg=\"login attempt\" user=alice attempts=3 admin=false\n";
    try testing.expect(std.mem.indexOf(u8, out, expected) != null);
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

test "log.slog chained with, >32 attrs, long messages, quoting, and real clock" {
    const testing = std.testing;
    const bytes_mod = @import("../bytes.zig");

    var buf = bytes_mod.Buffer.init(testing.allocator);
    defer buf.deinit();

    var th = TextHandler.init(buf.writer(), .Debug);
    const root_logger = Logger.initWithIo(th.handler(), testing.io);

    var many_attrs: [40]Attr = undefined;
    for (&many_attrs, 0..) |*a, idx| {
        a.* = Attr.int("k", @intCast(idx));
    }

    const child1 = root_logger.with(&many_attrs);
    const child2 = child1.with(&.{Attr.string("note", "has \"quotes\"\nand newline")});

    const long_msg: [300]u8 = @splat('x');
    try child2.info(&long_msg, &.{Attr.string("tail", "ok")});

    const out = buf.string();
    try testing.expect(!std.mem.startsWith(u8, out, "time=0 "));
    try testing.expect(std.mem.indexOf(u8, out, "k=39") != null);
    try testing.expect(std.mem.indexOf(u8, out, "note=\"has \\\"quotes\\\"\\nand newline\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tail=ok") != null);
}
