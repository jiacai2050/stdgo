//! Example demonstrating stdgo's log.slog structured logging:
//! 1. TextHandler (Go logfmt key=value)
//! 2. JSONHandler (RFC-valid JSON structured logging)
//! 3. Logger.with context propagation
//! 4. Level-based filtering

const std = @import("std");
const stdgo = @import("stdgo");
const slog = stdgo.log.slog;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: log.slog Structured Logging Example ===\n\n", .{});

    // 1. TextHandler Output (key=value logfmt)
    std.debug.print("1. TextHandler (logfmt):\n", .{});
    var text_buf = bytes.Buffer.init(gpa);
    defer text_buf.deinit();

    var text_handler = slog.TextHandler.init(text_buf.writer(), .Info);
    var text_logger = slog.Logger.init(text_handler.handler());

    try text_logger.info("server started", &.{
        slog.Attr.string("env", "production"),
        slog.Attr.int("port", 8080),
        slog.Attr.boolean("tls", true),
    });

    try text_logger.warn("high memory usage", &.{
        slog.Attr.float("usage_pct", 87.5),
        slog.Attr.int("threshold_pct", 80),
    });

    // Debug is below min_level (.Info), so it gets filtered out
    try text_logger.debug("this debug message is ignored", &.{});

    std.debug.print("{s}\n", .{text_buf.string()});

    // 2. JSONHandler Output (Structured JSON)
    std.debug.print("2. JSONHandler (JSON logs):\n", .{});
    var json_buf = bytes.Buffer.init(gpa);
    defer json_buf.deinit();

    var json_handler = slog.JSONHandler.init(json_buf.writer(), .Debug);
    var json_logger = slog.Logger.init(json_handler.handler());

    try json_logger.info("user signup completed", &.{
        slog.Attr.string("user_id", "usr_99182"),
        slog.Attr.string("email", "gopher@stdgo.dev"),
        slog.Attr.boolean("verified", false),
    });

    try json_logger.errorLevel("database query failed", &.{
        slog.Attr.string("error", "timeout after 500ms"),
        slog.Attr.int("retry_count", 3),
    });

    std.debug.print("{s}\n", .{json_buf.string()});

    // 3. Logger.with Contextual Logging
    std.debug.print("3. Contextual Logger with extra default attributes:\n", .{});
    var scoped_buf = bytes.Buffer.init(gpa);
    defer scoped_buf.deinit();

    var scoped_handler = slog.TextHandler.init(scoped_buf.writer(), .Info);
    const base_logger = slog.Logger.init(scoped_handler.handler());

    // Bind request_id and trace_id to all subsequent log lines
    const req_logger = base_logger.with(&.{
        slog.Attr.string("req_id", "req_abc123"),
        slog.Attr.string("service", "auth-service"),
    });

    try req_logger.info("authenticating token", &.{
        slog.Attr.string("auth_method", "bearer"),
    });

    try req_logger.info("token validated successfully", &.{
        slog.Attr.int("duration_ms", 12),
    });

    std.debug.print("{s}\n", .{scoped_buf.string()});
}
