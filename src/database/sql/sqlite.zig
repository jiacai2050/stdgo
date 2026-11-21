//! SQLite driver adapter for stdgo.database.sql using nDimensional/zig-sqlite.
//! This module is only active when the 'sqlite' build option is enabled (-Dsqlite=true).
//!
//! Provides a complete implementation of stdgo.database.sql.driver interfaces
//! (Driver, Conn, Stmt, Rows, Tx) wrapping SQLite's native C library.

const std = @import("std");
const build_options = @import("build_options");
const driver_pkg = @import("driver.zig");
const Deadline = @import("../../io/deadline.zig").Deadline;
const Allocator = std.mem.Allocator;
const Value = driver_pkg.Value;
const Result = driver_pkg.Result;

/// SQLiteDriver is the database/sql driver implementation for SQLite.
/// When compiled with -Dsqlite=false, accessing or initializing this struct
/// triggers a compile error explaining how to enable it.
pub const SQLiteDriver = if (!build_options.have_sqlite) struct {
    pub fn init(_: Allocator) @This() {
        @compileError("SQLite driver is disabled. Build with -Dsqlite=true to enable it.");
    }
} else struct {
    const sqlite = @import("sqlite");
    const c = sqlite.c;

    allocator: Allocator,

    const Progress = struct {
        io: std.Io,
        deadline: Deadline,
        failure: ?anyerror = null,

        fn start(self: *Progress, db: *c.sqlite3) void {
            c.sqlite3_progress_handler(db, 1000, callback, self);
        }

        fn stop(_: *Progress, db: *c.sqlite3) void {
            c.sqlite3_progress_handler(db, 0, null, null);
        }

        fn callback(ctx: ?*anyopaque) callconv(.c) c_int {
            const self: *Progress = @ptrCast(@alignCast(ctx.?));
            driver_pkg.checkOperation(self.io, self.deadline) catch |err| {
                self.failure = err;
                return 1;
            };
            return 0;
        }
    };

    /// Initializes a new SQLiteDriver instance with the given memory allocator.
    pub fn init(allocator: Allocator) SQLiteDriver {
        return .{ .allocator = allocator };
    }

    /// Returns the generic database/sql Driver interface wrapping this driver.
    pub fn driver(self: *SQLiteDriver) driver_pkg.Driver {
        return .{
            .ptr = self,
            .vtable = &.{
                .supports_deadline = true,
                .open = SQLiteDriver.open,
            },
        };
    }

    /// Opens a new SQLite connection.
    ///
    /// Supported DSN formats:
    /// - Standard in-memory: `":memory:"`
    /// - File paths: `"app.db"`, `"./data/app.db"`, `"/var/lib/sqlite.db"`
    /// - SQLite URI filenames: `"file:memdb1?mode=memory&cache=shared"`
    /// - Optional URL scheme prefixes (automatically stripped for user convenience):
    ///   `"sqlite://:memory:"`, `"sqlite3://app.db"`, `"sqlite:///path/to/db"`
    fn open(ctx: *anyopaque, io: std.Io, dsn: []const u8, deadline: Deadline) anyerror!driver_pkg.Conn {
        try driver_pkg.checkOperation(io, deadline);
        const self: *SQLiteDriver = @ptrCast(@alignCast(ctx));

        // Strip optional "sqlite://" or "sqlite3://" scheme prefixes if provided.
        // SQLite's native sqlite3_open_v2 expects a file path, ":memory:", or a "file:..." URI.
        var clean_dsn = dsn;
        if (std.mem.startsWith(u8, clean_dsn, "sqlite3://")) {
            clean_dsn = clean_dsn["sqlite3://".len..];
        } else if (std.mem.startsWith(u8, clean_dsn, "sqlite://")) {
            clean_dsn = clean_dsn["sqlite://".len..];
        }

        var db: ?*c.sqlite3 = null;
        const null_terminated_dsn = try self.allocator.alloc(u8, clean_dsn.len + 1);
        defer self.allocator.free(null_terminated_dsn);
        @memcpy(null_terminated_dsn[0..clean_dsn.len], clean_dsn);
        null_terminated_dsn[clean_dsn.len] = 0;

        // Open database with READWRITE, CREATE, and URI support
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI;
        const rc = c.sqlite3_open_v2(null_terminated_dsn.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close_v2(d);
            return error.SQLiteOpenFailed;
        }
        errdefer _ = c.sqlite3_close_v2(db);
        try driver_pkg.checkOperation(io, deadline);

        const conn = try self.allocator.create(SQLiteConn);
        conn.* = .{
            .allocator = self.allocator,
            .db = db.?,
        };

        return driver_pkg.Conn{
            .ptr = conn,
            .vtable = &.{
                .supports_deadline = true,
                .prepare = SQLiteConn.prepare,
                .close = SQLiteConn.close,
                .begin = SQLiteConn.begin,
                .beginTx = SQLiteConn.beginTx,
                .ping = SQLiteConn.ping,
                .interrupt = SQLiteConn.interrupt,
                .lastError = SQLiteConn.lastError,
            },
        };
    }

    /// SQLiteConn wraps a live sqlite3 handle and implements driver_pkg.Conn.
    const SQLiteConn = struct {
        allocator: Allocator,
        db: *c.sqlite3,

        /// Prepares a SQL query statement for execution.
        fn prepare(ctx: *anyopaque, io: std.Io, query: []const u8, deadline: Deadline) anyerror!driver_pkg.Stmt {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);

            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, query.ptr, @intCast(query.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                return progress.failure orelse error.SQLitePrepareFailed;
            }
            errdefer _ = c.sqlite3_finalize(stmt);
            try driver_pkg.checkOperation(io, deadline);

            const s = try self.allocator.create(SQLiteStmt);
            s.* = .{
                .allocator = self.allocator,
                .db = self.db,
                .stmt = stmt.?,
            };

            return driver_pkg.Stmt{
                .ptr = s,
                .vtable = &.{
                    .supports_deadline = true,
                    .close = SQLiteStmt.close,
                    .numInput = SQLiteStmt.numInput,
                    .exec = SQLiteStmt.exec,
                    .query = SQLiteStmt.query,
                },
            };
        }

        /// Closes the underlying SQLite connection.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_close_v2(self.db);
            self.allocator.destroy(self);
        }

        /// Starts a new SQLite transaction ("BEGIN TRANSACTION").
        fn begin(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!driver_pkg.Tx {
            return beginTx(ctx, io, .{}, deadline);
        }

        /// Starts a new SQLite transaction observing TxOptions.
        fn beginTx(ctx: *anyopaque, io: std.Io, opts: driver_pkg.TxOptions, deadline: Deadline) anyerror!driver_pkg.Tx {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            const tx = try self.allocator.create(SQLiteTx);
            errdefer self.allocator.destroy(tx);
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);
            const sql: [*c]const u8 = switch (opts.isolation) {
                .serializable => if (opts.read_only) "BEGIN DEFERRED" else "BEGIN IMMEDIATE",
                .default, .read_committed, .read_uncommitted, .repeatable_read, .snapshot, .write_committed, .linearizable => "BEGIN DEFERRED",
            };
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, sql, null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return progress.failure orelse error.SQLiteTxBeginFailed;
            }
            tx.* = .{
                .allocator = self.allocator,
                .db = self.db,
            };

            return driver_pkg.Tx{
                .ptr = tx,
                .vtable = &.{
                    .supports_deadline = true,
                    .commit = SQLiteTx.commit,
                    .rollback = SQLiteTx.rollback,
                },
            };
        }

        /// Verifies connection health by stepping a dummy "SELECT 1" statement.
        fn ping(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT 1", -1, &stmt, null) != c.SQLITE_OK) {
                return progress.failure orelse error.SQLitePingFailed;
            }
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
                return progress.failure orelse error.SQLitePingFailed;
            }
            try driver_pkg.checkOperation(io, deadline);
        }

        /// Interrupts any ongoing database operation on this connection via native sqlite3_interrupt.
        /// Thread-safe per SQLite specification (sqlite3_interrupt may be called concurrently from another thread).
        fn interrupt(ctx: *anyopaque) void {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            c.sqlite3_interrupt(self.db);
        }

        /// Returns the last detailed error message on this connection, or null if no error occurred.
        fn lastError(ctx: *anyopaque) ?[]const u8 {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            const msg_ptr = c.sqlite3_errmsg(self.db);
            if (msg_ptr == null) return null;
            const msg = std.mem.span(msg_ptr);
            if (std.mem.eql(u8, msg, "not an error")) return null;
            return msg;
        }
    };

    /// SQLiteStmt wraps a prepared sqlite3_stmt handle and implements driver_pkg.Stmt.
    const SQLiteStmt = struct {
        allocator: Allocator,
        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        /// Finalizes the prepared statement handle and frees memory.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_finalize(self.stmt);
            self.allocator.destroy(self);
        }

        /// Returns the number of parameter placeholders in the prepared statement.
        fn numInput(ctx: *anyopaque) i64 {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            return c.sqlite3_bind_parameter_count(self.stmt);
        }

        /// Resets bindings and binds positional parameters (?) to SQLite native types.
        fn bindArgs(stmt: *c.sqlite3_stmt, args: []const Value) anyerror!void {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);

            for (args, 1..) |arg, idx_usize| {
                const idx: c_int = @intCast(idx_usize);
                switch (arg) {
                    .null => {
                        if (c.sqlite3_bind_null(stmt, idx) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .int => |i| {
                        if (c.sqlite3_bind_int64(stmt, idx, i) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .float => |f| {
                        if (c.sqlite3_bind_double(stmt, idx, f) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .bool => |b| {
                        if (c.sqlite3_bind_int(stmt, idx, if (b) 1 else 0) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .string => |s| {
                        // SQLITE_STATIC is safe here because args stay valid for the duration of sqlite3_step
                        if (c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .bytes => |b| {
                        if (c.sqlite3_bind_blob(stmt, idx, b.ptr, @intCast(b.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                }
            }
        }

        /// Executes a prepared query that does not return rows (e.g., INSERT, UPDATE, DELETE).
        fn exec(ctx: *anyopaque, io: std.Io, args: []const Value, deadline: Deadline) anyerror!Result {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            try bindArgs(self.stmt, args);
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);

            const step_rc = c.sqlite3_step(self.stmt);
            if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                return progress.failure orelse error.SQLiteExecFailed;
            }

            const last_id = c.sqlite3_last_insert_rowid(self.db);
            const rows_affected = c.sqlite3_changes(self.db);

            return Result{
                .last_insert_id = last_id,
                .rows_affected = rows_affected,
            };
        }

        /// Executes a query that returns rows (e.g., SELECT).
        fn query(ctx: *anyopaque, io: std.Io, args: []const Value, deadline: Deadline) anyerror!driver_pkg.Rows {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            try bindArgs(self.stmt, args);
            try driver_pkg.checkOperation(io, deadline);

            const rows = try self.allocator.create(SQLiteRows);
            rows.* = .{
                .allocator = self.allocator,
                .db = self.db,
                .stmt = self.stmt,
            };

            return driver_pkg.Rows{
                .ptr = rows,
                .vtable = &.{
                    .supports_deadline = true,
                    .columns = SQLiteRows.columns,
                    .next = SQLiteRows.next,
                    .close = SQLiteRows.close,
                    .err = SQLiteRows.err,
                },
            };
        }
    };

    /// SQLiteRows implements driver_pkg.Rows, iterating over result rows.
    const SQLiteRows = struct {
        allocator: Allocator,
        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,
        cols_cached: ?[]const []const u8 = null,
        last_step_err: ?anyerror = null,

        /// Retrieves and caches column names from the current result set.
        fn columns(ctx: *anyopaque) []const []const u8 {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            if (self.cols_cached) |cols| return cols;

            const count: usize = @intCast(c.sqlite3_column_count(self.stmt));
            var col_list = self.allocator.alloc([]const u8, count) catch return &.{};
            for (0..count) |i| {
                const name_ptr = c.sqlite3_column_name(self.stmt, @intCast(i));
                col_list[i] = if (name_ptr != null) std.mem.span(name_ptr) else "";
            }
            self.cols_cached = col_list;
            return col_list;
        }

        /// Advances the cursor to the next row, decoding SQLite column types into dest.
        /// Returns true if a row was retrieved, false on completion.
        fn next(ctx: *anyopaque, io: std.Io, dest: []Value, deadline: Deadline) anyerror!bool {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_ROW) {
                const col_count: usize = @intCast(c.sqlite3_column_count(self.stmt));
                const limit = @min(dest.len, col_count);

                for (0..limit) |i| {
                    const col_idx: c_int = @intCast(i);
                    const col_type = c.sqlite3_column_type(self.stmt, col_idx);
                    dest[i] = switch (col_type) {
                        c.SQLITE_INTEGER => Value{ .int = c.sqlite3_column_int64(self.stmt, col_idx) },
                        c.SQLITE_FLOAT => Value{ .float = c.sqlite3_column_double(self.stmt, col_idx) },
                        c.SQLITE_TEXT => blk: {
                            const text_ptr = c.sqlite3_column_text(self.stmt, col_idx);
                            const bytes_len = c.sqlite3_column_bytes(self.stmt, col_idx);
                            if (text_ptr == null) break :blk Value.null;
                            break :blk Value{ .string = text_ptr[0..@intCast(bytes_len)] };
                        },
                        c.SQLITE_BLOB => blk: {
                            const blob_ptr: [*c]const u8 = @ptrCast(c.sqlite3_column_blob(self.stmt, col_idx));
                            const bytes_len = c.sqlite3_column_bytes(self.stmt, col_idx);
                            if (blob_ptr == null) break :blk Value.null;
                            break :blk Value{ .bytes = blob_ptr[0..@intCast(bytes_len)] };
                        },
                        c.SQLITE_NULL => Value.null,
                        else => Value.null,
                    };
                }
                return true;
            }

            if (rc != c.SQLITE_DONE) {
                self.last_step_err = progress.failure orelse switch (rc) {
                    c.SQLITE_INTERRUPT => error.Interrupted,
                    c.SQLITE_BUSY => error.Busy,
                    c.SQLITE_LOCKED => error.Locked,
                    c.SQLITE_NOMEM => error.OutOfMemory,
                    else => error.SQLiteStepFailed,
                };
                return self.last_step_err.?;
            }
            return false;
        }

        /// Returns any error encountered during iteration.
        fn err(ctx: *anyopaque) ?anyerror {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            return self.last_step_err;
        }

        /// Resets statement cursor, frees cached column names, and releases row memory.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_reset(self.stmt);
            if (self.cols_cached) |cols| {
                self.allocator.free(cols);
            }
            self.allocator.destroy(self);
        }
    };

    /// SQLiteTx manages an in-progress transaction, handling COMMIT and ROLLBACK.
    const SQLiteTx = struct {
        allocator: Allocator,
        db: *c.sqlite3,

        /// Commits the active transaction ("COMMIT").
        fn commit(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void {
            const self: *SQLiteTx = @ptrCast(@alignCast(ctx));
            defer self.allocator.destroy(self);
            try driver_pkg.checkOperation(io, deadline);
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, "COMMIT", null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return progress.failure orelse error.SQLiteCommitFailed;
            }
        }

        /// Aborts and rolls back the active transaction ("ROLLBACK").
        fn rollback(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void {
            const self: *SQLiteTx = @ptrCast(@alignCast(ctx));
            defer self.allocator.destroy(self);
            var progress: Progress = .{ .io = io, .deadline = deadline };
            if (!deadline.isNone()) {
                try driver_pkg.checkOperation(io, deadline);
                progress.start(self.db);
            }
            defer if (!deadline.isNone()) progress.stop(self.db);
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, "ROLLBACK", null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return progress.failure orelse error.SQLiteRollbackFailed;
            }
        }
    };
};

test "SQLite deadlines interrupt execution and connection pool waits" {
    if (!build_options.have_sqlite) return;
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sqlite_driver = SQLiteDriver.init(testing.allocator);
    const sql = @import("../sql.zig");
    const db = try sql.DB.open(testing.allocator, io, sqlite_driver.driver(), ":memory:");
    defer db.close();
    db.setMaxOpenConns(1);

    try db.ping(Deadline.after(io, .fromSeconds(1)));
    const conn = try db.conn(.none);
    try testing.expectError(error.Timeout, db.ping(Deadline.after(io, .fromMilliseconds(30))));
    conn.release();

    const slow_query =
        "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n " ++
        "WHERE x<1000000000) SELECT sum(x) FROM n";
    try testing.expectError(error.Timeout, db.exec(
        slow_query,
        &.{},
        Deadline.after(io, .fromMilliseconds(30)),
    ));
    var rows = try db.query(slow_query, &.{}, Deadline.after(io, .fromSeconds(1)));
    defer rows.close();
    var dest: [1]Value = undefined;
    try testing.expectError(error.Timeout, rows.next(&dest, Deadline.after(io, .fromMilliseconds(30))));
    try db.ping(Deadline.after(io, .fromSeconds(1)));

    var tx = try db.begin(Deadline.after(io, .fromSeconds(1)));
    try testing.expectError(error.Timeout, tx.commit(Deadline.after(io, .zero)));
    try testing.expectError(error.Timeout, tx.rollback(Deadline.after(io, .zero)));
    try tx.rollback(.none);

    var committed = try db.begin(Deadline.after(io, .fromSeconds(1)));
    try committed.commit(Deadline.after(io, .fromSeconds(1)));

    var failed = try db.begin(.none);
    _ = try failed.exec("ROLLBACK", &.{}, .none);
    try testing.expectError(error.SQLiteCommitFailed, failed.commit(Deadline.after(io, .fromSeconds(1))));
    try testing.expectEqual(@as(usize, 0), db.stats().open_connections);
    try db.ping(.none);
}

test "stdgo.database.sql.sqlite: in-memory CRUD and transaction rollback/commit" {
    if (!build_options.have_sqlite) return;

    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sq_driver = SQLiteDriver.init(testing.allocator);
    const sql_db = @import("../sql.zig");
    const db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), ":memory:");
    defer db.close();

    try db.ping(.none);

    // DDL
    _ = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, balance REAL)", &.{}, .none);

    // Insert
    const res1 = try db.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
        Value{ .string = "Alice" },
        Value{ .int = 30 },
        Value{ .float = 100.50 },
    }, .none);
    try testing.expectEqual(@as(i64, 1), res1.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res1.rows_affected);

    const res2 = try db.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
        Value{ .string = "Bob" },
        Value{ .int = 25 },
        Value{ .float = 50.00 },
    }, .none);
    try testing.expectEqual(@as(i64, 2), res2.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res2.rows_affected);

    // Query
    {
        var rows = try db.query("SELECT id, name, age, balance FROM users ORDER BY id ASC", &.{}, .none);
        defer rows.close();

        const cols = rows.columns();
        try testing.expectEqual(@as(usize, 4), cols.len);
        try testing.expectEqualStrings("id", cols[0]);
        try testing.expectEqualStrings("name", cols[1]);
        try testing.expectEqualStrings("age", cols[2]);
        try testing.expectEqualStrings("balance", cols[3]);

        var dest: [4]Value = undefined;

        // Row 1
        try testing.expect(try rows.next(&dest, .none));
        try testing.expectEqual(@as(i64, 1), dest[0].int);
        try testing.expectEqualStrings("Alice", dest[1].string);
        try testing.expectEqual(@as(i64, 30), dest[2].int);
        try testing.expectEqual(@as(f64, 100.50), dest[3].float);

        // Row 2
        try testing.expect(try rows.next(&dest, .none));
        try testing.expectEqual(@as(i64, 2), dest[0].int);
        try testing.expectEqualStrings("Bob", dest[1].string);
        try testing.expectEqual(@as(i64, 25), dest[2].int);
        try testing.expectEqual(@as(f64, 50.00), dest[3].float);

        // End of rows
        try testing.expect(!try rows.next(&dest, .none));
    }

    // Transaction Rollback
    {
        var tx = try db.begin(.none);
        _ = try tx.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
            Value{ .string = "Charlie" },
            Value{ .int = 40 },
            Value{ .float = 0.0 },
        }, .none);
        try tx.rollback(.none);
    }

    // Verify Charlie was not inserted
    {
        var rows_after = try db.query("SELECT COUNT(*) FROM users WHERE name = ?", &.{
            Value{ .string = "Charlie" },
        }, .none);
        defer rows_after.close();
        var count_dest: [1]Value = undefined;
        try testing.expect(try rows_after.next(&count_dest, .none));
        try testing.expectEqual(@as(i64, 0), count_dest[0].int);
    }

    // Transaction Commit
    {
        var tx2 = try db.begin(.none);
        _ = try tx2.exec("UPDATE users SET balance = balance + 10.0 WHERE name = ?", &.{
            Value{ .string = "Alice" },
        }, .none);
        try tx2.commit(.none);
    }

    // Verify balance updated
    {
        var rows_alice = try db.query("SELECT balance FROM users WHERE name = ?", &.{
            Value{ .string = "Alice" },
        }, .none);
        defer rows_alice.close();
        var bal_dest: [1]Value = undefined;
        try testing.expect(try rows_alice.next(&bal_dest, .none));
        try testing.expectEqual(@as(f64, 110.50), bal_dest[0].float);
    }

    // Verify sqlite:// and sqlite3:// prefix handling
    {
        const url_db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), "sqlite://:memory:");
        defer url_db.close();
        try url_db.ping(.none);
    }

    // Verify lastError on syntax error
    {
        const conn = try db.conn(.none);
        defer conn.release();

        const exec_res = conn.exec("SELECT * FORM users", &.{}, .none);
        try testing.expectError(error.SQLitePrepareFailed, exec_res);
        const err_msg = conn.lastError();
        try testing.expect(err_msg != null);
        try testing.expect(std.mem.indexOf(u8, err_msg.?, "syntax error") != null);
    }

    // Verify rows.err() is null on clean completion
    {
        var rows = try db.query("SELECT id FROM users", &.{}, .none);
        defer rows.close();
        var dest: [1]Value = undefined;
        while (try rows.next(&dest, .none)) {}
        try testing.expect(rows.err() == null);
    }

    // Verify QueryRow single-row scan and ErrNoRows
    {
        {
            var row = db.queryRow("SELECT balance FROM users WHERE name = ?", &.{Value{ .string = "Alice" }}, .none);
            defer row.close();
            var dest: [1]Value = undefined;
            try row.scan(&dest, .none);
            try testing.expectEqual(@as(f64, 110.50), dest[0].float);
        }

        {
            var empty_row = db.queryRow("SELECT balance FROM users WHERE name = ?", &.{Value{ .string = "Nonexistent" }}, .none);
            defer empty_row.close();
            var dest_empty: [1]Value = undefined;
            try testing.expectError(error.ErrNoRows, empty_row.scan(&dest_empty, .none));
        }
    }

    // Verify beginTx with IsolationLevel and Tx.queryRow
    {
        var tx = try db.beginTx(.{
            .isolation = .serializable,
            .read_only = false,
        }, .none);
        defer tx.rollback(.none) catch {};

        _ = try tx.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
            Value{ .string = "Dave" },
            Value{ .int = 28 },
            Value{ .float = 300.0 },
        }, .none);

        var tx_row = tx.queryRow("SELECT balance FROM users WHERE name = ?", &.{Value{ .string = "Dave" }}, .none);
        defer tx_row.close();
        var dave_dest: [1]Value = undefined;
        try tx_row.scan(&dave_dest, .none);
        try testing.expectEqual(@as(f64, 300.0), dave_dest[0].float);

        try tx.commit(.none);
    }
}
