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
const NamedValue = driver_pkg.NamedValue;
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
    fn open(
        ctx: *anyopaque,
        io: std.Io,
        dsn: []const u8,
        deadline: Deadline,
    ) anyerror!driver_pkg.Conn {
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
                .prepare = SQLiteConn.prepare,
                .close = SQLiteConn.close,
                .begin = SQLiteConn.begin,
                .beginTx = SQLiteConn.beginTx,
                .ping = SQLiteConn.ping,
                .execDirect = SQLiteConn.execDirect,
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
        fn prepare(
            ctx: *anyopaque,
            io: std.Io,
            query: []const u8,
            deadline: Deadline,
        ) anyerror!driver_pkg.Stmt {
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

            // Per SQLite C API specification: when the input query contains no executable VDBE
            // bytecode (e.g. empty string, whitespace only, pure comments, or trailing/isolated
            // semicolons), sqlite3_prepare_v2 returns SQLITE_OK (0) but sets *ppStmt to NULL.
            // Guard against null explicitly to eliminate unsafe unwrap (.?) panics.
            const non_null_stmt = stmt orelse return error.SQLiteEmptyStatement;
            errdefer _ = c.sqlite3_finalize(non_null_stmt);
            try driver_pkg.checkOperation(io, deadline);

            const s = try self.allocator.create(SQLiteStmt);
            s.* = .{
                .allocator = self.allocator,
                .db = self.db,
                .stmt = non_null_stmt,
            };

            return driver_pkg.Stmt{
                .ptr = s,
                .vtable = &.{
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
        fn beginTx(
            ctx: *anyopaque,
            io: std.Io,
            opts: driver_pkg.TxOptions,
            deadline: Deadline,
        ) anyerror!driver_pkg.Tx {
            try driver_pkg.checkOperation(io, deadline);
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            const tx = try self.allocator.create(SQLiteTx);
            errdefer self.allocator.destroy(tx);
            var progress: Progress = .{ .io = io, .deadline = deadline };
            progress.start(self.db);
            defer progress.stop(self.db);
            const sql: [*c]const u8 = switch (opts.isolation) {
                .serializable => if (opts.read_only) "BEGIN DEFERRED" else "BEGIN IMMEDIATE",
                .default,
                .read_committed,
                .read_uncommitted,
                .repeatable_read,
                .snapshot,
                .write_committed,
                .linearizable,
                => "BEGIN DEFERRED",
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
            const non_null_stmt = stmt orelse return error.SQLitePingFailed;
            defer _ = c.sqlite3_finalize(non_null_stmt);
            if (c.sqlite3_step(non_null_stmt) != c.SQLITE_ROW) {
                return progress.failure orelse error.SQLitePingFailed;
            }
            try driver_pkg.checkOperation(io, deadline);
        }

        /// Executes a query directly on this connection without allocating SQLiteStmt.
        fn execDirect(
            ctx: *anyopaque,
            io: std.Io,
            query: []const u8,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result {
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
            const non_null_stmt = stmt orelse return error.SQLiteEmptyStatement;
            defer _ = c.sqlite3_finalize(non_null_stmt);

            try SQLiteStmt.bindArgs(non_null_stmt, args);

            const step_rc = c.sqlite3_step(non_null_stmt);
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

        /// Interrupts ongoing operation on this connection via native sqlite3_interrupt.
        /// Thread-safe per SQLite specification (may be called concurrently from another thread).
        fn interrupt(ctx: *anyopaque) void {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            c.sqlite3_interrupt(self.db);
        }

        /// Returns the last detailed error message on this connection, or null if none occurred.
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

        /// Resets bindings and binds positional (?) or named (:name, @name, $name) parameters.
        fn bindArgs(stmt: *c.sqlite3_stmt, args: []const NamedValue) anyerror!void {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);

            const param_count: usize = @intCast(c.sqlite3_bind_parameter_count(stmt));

            // Strictly verify that the supplied argument count matches statement's parameters.
            if (args.len != param_count) {
                return error.SQLiteParameterCountMismatch;
            }

            var auto_pos: c_int = 1;

            for (args) |arg| {
                const idx: c_int = if (arg.name) |name| blk: {
                    var buf: [64]u8 = undefined;
                    // 1. Try :name
                    const colon_name = std.fmt.bufPrint(&buf, ":{s}\x00", .{name}) catch
                        return error.SQLiteParamNameTooLong;
                    var param_idx = c.sqlite3_bind_parameter_index(stmt, colon_name.ptr);
                    if (param_idx == 0) {
                        // 2. Try @name
                        const at_name = std.fmt.bufPrint(&buf, "@{s}\x00", .{name}) catch
                            return error.SQLiteParamNameTooLong;
                        param_idx = c.sqlite3_bind_parameter_index(stmt, at_name.ptr);
                    }
                    if (param_idx == 0) {
                        // 3. Try $name
                        const dollar_name = std.fmt.bufPrint(&buf, "${s}\x00", .{name}) catch
                            return error.SQLiteParamNameTooLong;
                        param_idx = c.sqlite3_bind_parameter_index(stmt, dollar_name.ptr);
                    }
                    if (param_idx == 0) return error.SQLiteUnknownNamedParameter;
                    break :blk param_idx;
                } else blk: {
                    const p = auto_pos;
                    auto_pos += 1;
                    // Fail-fast if user passed positional argument for a named placeholder (:name)
                    if (c.sqlite3_bind_parameter_name(stmt, p) != null) {
                        return error.SQLitePositionalArgForNamedParam;
                    }
                    break :blk p;
                };

                switch (arg.value) {
                    .null => {
                        if (c.sqlite3_bind_null(stmt, idx) != c.SQLITE_OK) {
                            return error.SQLiteBindFailed;
                        }
                    },
                    .int => |i| {
                        if (c.sqlite3_bind_int64(stmt, idx, i) != c.SQLITE_OK) {
                            return error.SQLiteBindFailed;
                        }
                    },
                    .float => |f| {
                        if (c.sqlite3_bind_double(stmt, idx, f) != c.SQLITE_OK) {
                            return error.SQLiteBindFailed;
                        }
                    },
                    .bool => |b| {
                        const val: c_int = if (b) 1 else 0;
                        if (c.sqlite3_bind_int(stmt, idx, val) != c.SQLITE_OK) {
                            return error.SQLiteBindFailed;
                        }
                    },
                    .string => |s| {
                        // SQLITE_STATIC is safe because args stay valid for sqlite3_step.
                        const rc = c.sqlite3_bind_text(
                            stmt,
                            idx,
                            s.ptr,
                            @intCast(s.len),
                            c.SQLITE_STATIC,
                        );
                        if (rc != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .bytes => |b| {
                        const rc = c.sqlite3_bind_blob(
                            stmt,
                            idx,
                            b.ptr,
                            @intCast(b.len),
                            c.SQLITE_STATIC,
                        );
                        if (rc != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                }
            }
        }

        /// Executes a prepared query that does not return rows (e.g., INSERT, UPDATE, DELETE).
        fn exec(
            ctx: *anyopaque,
            io: std.Io,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result {
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
        fn query(
            ctx: *anyopaque,
            io: std.Io,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!driver_pkg.Rows {
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
                    .columnCount = SQLiteRows.columnCount,
                    .columnName = SQLiteRows.columnName,
                    .next = SQLiteRows.next,
                    .close = SQLiteRows.close,
                    .err = SQLiteRows.err,
                    .columnTypeDatabaseTypeName = SQLiteRows.columnTypeDatabaseTypeName,
                },
            };
        }
    };

    /// SQLiteRows implements driver_pkg.Rows, iterating over result rows.
    const SQLiteRows = struct {
        allocator: Allocator,
        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,
        last_step_err: ?anyerror = null,

        /// Returns the number of columns in the SQLite result set.
        fn columnCount(ctx: *anyopaque) usize {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            return @intCast(c.sqlite3_column_count(self.stmt));
        }

        /// Returns the column name at the given 0-based index.
        fn columnName(ctx: *anyopaque, index: usize) []const u8 {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            const name_ptr = c.sqlite3_column_name(self.stmt, @intCast(index));
            if (name_ptr != null) {
                return std.mem.span(name_ptr);
            }
            return "";
        }

        /// Returns the declared column type name from SQLite schema (e.g. "INTEGER", "TEXT").
        fn columnTypeDatabaseTypeName(ctx: *anyopaque, index: usize) ?[]const u8 {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            const decl_ptr = c.sqlite3_column_decltype(self.stmt, @intCast(index));
            if (decl_ptr != null) {
                return std.mem.span(decl_ptr);
            }
            return null;
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
                if (dest.len != col_count) {
                    self.last_step_err = error.ColumnCountMismatch;
                    return error.ColumnCountMismatch;
                }

                for (0..col_count) |i| {
                    const col_idx: c_int = @intCast(i);
                    const col_type = c.sqlite3_column_type(self.stmt, col_idx);
                    dest[i] = switch (col_type) {
                        c.SQLITE_INTEGER => Value{
                            .int = c.sqlite3_column_int64(self.stmt, col_idx),
                        },
                        c.SQLITE_FLOAT => Value{
                            .float = c.sqlite3_column_double(self.stmt, col_idx),
                        },
                        c.SQLITE_TEXT => blk: {
                            const text_ptr = c.sqlite3_column_text(self.stmt, col_idx);
                            const bytes_len = c.sqlite3_column_bytes(self.stmt, col_idx);
                            if (text_ptr == null) break :blk Value.null;
                            break :blk Value{ .string = text_ptr[0..@intCast(bytes_len)] };
                        },
                        c.SQLITE_BLOB => blk: {
                            const blob_raw = c.sqlite3_column_blob(self.stmt, col_idx);
                            const blob_ptr: [*c]const u8 = @ptrCast(blob_raw);
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

        /// Resets statement cursor and releases row memory.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_reset(self.stmt);
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
    const io = testing.io;
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
    const dl_30ms = Deadline.after(io, .fromMilliseconds(30));
    try testing.expectError(error.Timeout, rows.next(&dest, dl_30ms));
    try db.ping(Deadline.after(io, .fromSeconds(1)));

    var tx = try db.begin(Deadline.after(io, .fromSeconds(1)));
    try testing.expectError(error.Timeout, tx.commit(Deadline.after(io, .zero)));
    try testing.expectError(error.Timeout, tx.rollback(Deadline.after(io, .zero)));
    try tx.rollback(.none);

    var committed = try db.begin(Deadline.after(io, .fromSeconds(1)));
    try committed.commit(Deadline.after(io, .fromSeconds(1)));

    var failed = try db.begin(.none);
    _ = try failed.exec("ROLLBACK", &.{}, .none);
    const dl_1s = Deadline.after(io, .fromSeconds(1));
    try testing.expectError(error.SQLiteCommitFailed, failed.commit(dl_1s));
    try testing.expectEqual(@as(usize, 0), db.stats().open_connections);
    try db.ping(.none);
}

test "stdgo.database.sql.sqlite: in-memory CRUD and transaction rollback/commit" {
    if (!build_options.have_sqlite) return;

    const testing = std.testing;

    const io = testing.io;

    var sq_driver = SQLiteDriver.init(testing.allocator);
    const sql_db = @import("../sql.zig");
    const dsn = "file:test_inmem_crud?mode=memory&cache=shared";
    const db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), dsn);
    defer db.close();

    try db.ping(.none);

    // DDL
    const ddl = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, balance REAL)";
    _ = try db.exec(ddl, &.{}, .none);

    // Insert
    const res1 = try db.exec(
        "INSERT INTO users (name, age, balance) VALUES (?, ?, ?)",
        .{ "Alice", 30, 100.50 },
        .none,
    );
    try testing.expectEqual(@as(i64, 1), res1.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res1.rows_affected);

    const res2 = try db.exec(
        "INSERT INTO users (name, age, balance) VALUES (?, ?, ?)",
        .{ "Bob", 25, 50.00 },
        .none,
    );
    try testing.expectEqual(@as(i64, 2), res2.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res2.rows_affected);

    // Query
    {
        const sel_q = "SELECT id, name, age, balance FROM users ORDER BY id ASC";
        var rows = try db.query(sel_q, &.{}, .none);
        defer rows.close();

        try testing.expectEqual(@as(usize, 4), rows.columnCount());
        try testing.expectEqualStrings("id", rows.columnName(0));
        try testing.expectEqualStrings("name", rows.columnName(1));
        try testing.expectEqualStrings("age", rows.columnName(2));
        try testing.expectEqualStrings("balance", rows.columnName(3));

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
        _ = try tx.exec(
            "INSERT INTO users (name, age, balance) VALUES (?, ?, ?)",
            .{ "Charlie", 40, 0.0 },
            .none,
        );
        try tx.rollback(.none);
    }

    // Verify Charlie was not inserted
    {
        const sel_q = "SELECT COUNT(*) FROM users WHERE name = ?";
        var rows_after = try db.query(sel_q, .{"Charlie"}, .none);
        defer rows_after.close();
        var count_dest: [1]Value = undefined;
        try testing.expect(try rows_after.next(&count_dest, .none));
        try testing.expectEqual(@as(i64, 0), count_dest[0].int);
    }

    // Transaction Commit
    {
        var tx2 = try db.begin(.none);
        _ = try tx2.exec(
            "UPDATE users SET balance = balance + 10.0 WHERE name = ?",
            .{"Alice"},
            .none,
        );
        try tx2.commit(.none);
    }

    // Verify balance updated
    {
        const sel_alice = "SELECT balance FROM users WHERE name = ?";
        var rows_alice = try db.query(sel_alice, .{"Alice"}, .none);
        defer rows_alice.close();
        var bal_dest: [1]Value = undefined;
        try testing.expect(try rows_alice.next(&bal_dest, .none));
        try testing.expectEqual(@as(f64, 110.50), bal_dest[0].float);
    }

    // Verify sqlite:// and sqlite3:// prefix handling
    {
        const url_dsn = "sqlite://:memory:";
        const url_db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), url_dsn);
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

        // Verify empty query, comment, semicolon return error.SQLiteEmptyStatement
        try testing.expectError(error.SQLiteEmptyStatement, conn.exec("", &.{}, .none));
        try testing.expectError(error.SQLiteEmptyStatement, conn.exec("   \t\n", &.{}, .none));
        const comment1 = "-- only a single line comment";
        try testing.expectError(error.SQLiteEmptyStatement, conn.exec(comment1, &.{}, .none));
        const comment2 = "/* multi-line comment */";
        try testing.expectError(error.SQLiteEmptyStatement, conn.exec(comment2, &.{}, .none));
        try testing.expectError(error.SQLiteEmptyStatement, conn.exec(";;;", &.{}, .none));
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
            const q = "SELECT balance FROM users WHERE name = ?";
            var row = db.queryRow(q, .{"Alice"}, .none);
            defer row.close();
            var dest: [1]Value = undefined;
            try row.scan(&dest, .none);
            try testing.expectEqual(@as(f64, 110.50), dest[0].float);
        }

        {
            const q = "SELECT balance FROM users WHERE name = ?";
            var empty_row = db.queryRow(q, .{"Nonexistent"}, .none);
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

        _ = try tx.exec(
            "INSERT INTO users (name, age, balance) VALUES (?, ?, ?)",
            .{ "Dave", 28, 300.0 },
            .none,
        );

        const q = "SELECT balance FROM users WHERE name = ?";
        var tx_row = tx.queryRow(q, .{"Dave"}, .none);
        defer tx_row.close();
        var dave_dest: [1]Value = undefined;
        try tx_row.scan(&dave_dest, .none);
        try testing.expectEqual(@as(f64, 300.0), dave_dest[0].float);

        try tx.commit(.none);
    }

    // Verify ColumnCountMismatch on buffer length mismatch
    {
        var rows = try db.query("SELECT id, name, age, balance FROM users LIMIT 1", .{}, .none);
        defer rows.close();
        var short_dest: [2]Value = undefined;
        try testing.expectError(error.ColumnCountMismatch, rows.next(&short_dest, .none));
    }

    // Verify nextStruct comptime struct scanning
    {
        const UserRecord = struct {
            id: i64,
            name: []const u8,
            age: i64,
            balance: f64,
        };

        const sel_q = "SELECT id, name, age, balance FROM users ORDER BY id ASC";
        var rows = try db.query(sel_q, .{}, .none);
        defer rows.close();

        const user1 = (try rows.nextStruct(UserRecord, .none)).?;
        try testing.expectEqual(@as(i64, 1), user1.id);
        try testing.expectEqualStrings("Alice", user1.name);
        try testing.expectEqual(@as(i64, 30), user1.age);
        try testing.expectEqual(@as(f64, 110.50), user1.balance);
    }

    // Verify scanStruct on Row
    {
        const BalanceOnly = struct { balance: f64 };
        const q = "SELECT balance FROM users WHERE name = ?";
        var row = db.queryRow(q, .{"Alice"}, .none);
        defer row.close();
        const b = try row.scanStruct(BalanceOnly, .none);
        try testing.expectEqual(@as(f64, 110.50), b.balance);
    }

    // Verify top-level db.prepare and Stmt execution
    {
        var stmt = try db.prepare("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", .none);
        defer stmt.close();

        const ins_res = try stmt.exec(.{ "Eve", 22, 99.0 }, .none);
        try testing.expect((try ins_res.lastInsertId()) > 0);
        try testing.expectEqual(@as(i64, 1), try ins_res.rowsAffected());

        var q_stmt = try db.prepare("SELECT balance FROM users WHERE name = ?", .none);
        defer q_stmt.close();

        var q_row = q_stmt.queryRow(.{"Eve"}, .none);
        defer q_row.close();
        const EveBal = struct { balance: f64 };
        const eb = try q_row.scanStruct(EveBal, .none);
        try testing.expectEqual(@as(f64, 99.0), eb.balance);
    }

    // Verify Tx.prepare in SQLite: statement is automatically closed before commit
    {
        var tx = try db.begin(.none);
        const upd_q = "UPDATE users SET balance = balance + 10 WHERE name = ?";
        var tx_stmt = try tx.prepare(upd_q, .none);
        defer tx_stmt.close();

        _ = try tx_stmt.exec(.{"Alice"}, .none);

        // Commit should cleanly succeed (statement is auto-closed before sqlite3_step("COMMIT"))
        try tx.commit(.none);

        // Subsequent exec must return error.TxDone
        try testing.expectError(error.TxDone, tx_stmt.exec(.{"Alice"}, .none));
    }

    // Verify Rows.columnType indexed inspection in SQLite
    {
        var rows = try db.query("SELECT id, name, age, balance FROM users LIMIT 1", .{}, .none);
        defer rows.close();

        try testing.expectEqual(@as(usize, 4), rows.columnCount());

        const ct0 = try rows.columnType(0);
        try testing.expectEqualStrings("id", ct0.name());
        try testing.expectEqualStrings("INTEGER", ct0.databaseTypeName().?);

        const ct1 = try rows.columnType(1);
        try testing.expectEqualStrings("name", ct1.name());
        try testing.expectEqualStrings("TEXT", ct1.databaseTypeName().?);

        const ct2 = try rows.columnType(2);
        try testing.expectEqualStrings("age", ct2.name());
        try testing.expectEqualStrings("INTEGER", ct2.databaseTypeName().?);

        const ct3 = try rows.columnType(3);
        try testing.expectEqualStrings("balance", ct3.name());
        try testing.expectEqualStrings("REAL", ct3.databaseTypeName().?);

        try testing.expectError(error.ColumnIndexOutOfBounds, rows.columnType(4));
    }

    // Verify execDirect in SQLite
    {
        const upd_sql = "UPDATE users SET balance = balance + 5 WHERE id = 1";
        const res = try db.exec(upd_sql, .{}, .none);
        try testing.expectEqual(@as(i64, 1), try res.rowsAffected());
    }

    // Verify idiomatic struct and tuple arguments in SQLite
    {
        // 1. Insert via anonymous struct (named args :name, :age, :balance)
        const ins_sql = "INSERT INTO users (name, age, balance) VALUES (:name, :age, :balance)";
        const res_ins = try db.exec(ins_sql, .{
            .name = "Frank",
            .age = 40,
            .balance = 888.88,
        }, .none);
        try testing.expect((try res_ins.lastInsertId()) > 0);

        // 2. Query via anonymous struct
        {
            var row = db.queryRow(
                "SELECT balance FROM users WHERE name = :name",
                .{ .name = "Frank" },
                .none,
            );
            defer row.close();
            const FrankBal = struct { balance: f64 };
            const bal = try row.scanStruct(FrankBal, .none);
            try testing.expectEqual(@as(f64, 888.88), bal.balance);
        }

        // 3. Update via tuple (positional args ?)
        const upd_tup = "UPDATE users SET balance = ? WHERE name = ?";
        const res_upd = try db.exec(upd_tup, .{ 999.99, "Frank" }, .none);
        try testing.expectEqual(@as(i64, 1), try res_upd.rowsAffected());

        // 4. Verify fail-fast: tuple arguments for named placeholders (:name) are rejected
        const fail_sql = "UPDATE users SET balance = 100 WHERE name = :name";
        try testing.expectError(
            error.SQLitePositionalArgForNamedParam,
            db.exec(fail_sql, .{"Frank"}, .none),
        );

        // 5. Verify fail-fast: positional parameter count mismatch (too few or too many)
        try testing.expectError(
            error.SQLiteParameterCountMismatch,
            db.exec("UPDATE users SET balance = ? WHERE name = ?", .{999.99}, .none),
        );
        try testing.expectError(
            error.SQLiteParameterCountMismatch,
            db.exec(
                "UPDATE users SET balance = ? WHERE name = ?",
                .{ 999.99, "Frank", 123 },
                .none,
            ),
        );

        // 6. Verify fail-fast: named parameter count mismatch (under-providing or over-providing)
        const upd_named = "UPDATE users SET balance = :balance WHERE name = :name";
        // Under-providing (missing :balance)
        try testing.expectError(
            error.SQLiteParameterCountMismatch,
            db.exec(upd_named, .{ .name = "Frank" }, .none),
        );
        // Over-providing (extra field .age)
        try testing.expectError(
            error.SQLiteParameterCountMismatch,
            db.exec(upd_named, .{ .name = "Frank", .balance = 50.0, .age = 30 }, .none),
        );
    }

    // Verify raw BLOB storage and scanning via sql.Blob
    {
        _ = try db.exec(
            \\CREATE TABLE IF NOT EXISTS files (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT NOT NULL,
            \\    payload BLOB NOT NULL
            \\);
        , .{}, .none);

        const raw_bytes = "BIN\x00\xFF\xAA\x55";
        const FileItem = struct {
            name: []const u8,
            payload: sql_db.Blob,
        };

        const ins = try db.exec(
            "INSERT INTO files (name, payload) VALUES (:name, :payload)",
            FileItem{
                .name = "firmware.bin",
                .payload = sql_db.blob(raw_bytes),
            },
            .none,
        );
        try testing.expect((try ins.lastInsertId()) > 0);

        var row = db.queryRow(
            "SELECT name, payload FROM files WHERE name = ?",
            .{"firmware.bin"},
            .none,
        );
        defer row.close();

        const scanned = try row.scanStruct(FileItem, .none);
        try testing.expectEqualStrings("firmware.bin", scanned.name);
        try testing.expectEqualStrings(raw_bytes, scanned.payload.data);
    }
}
