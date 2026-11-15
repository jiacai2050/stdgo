//! Package database/sql/driver defines interfaces to be implemented by database drivers
//! as required by package database/sql.

const std = @import("std");

/// Driver value representation.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null => try writer.writeAll("NULL"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .string => |s| try writer.print("'{s}'", .{s}),
            .bytes => |b| try writer.print("0x{x}", .{b}),
        }
    }
};

/// ErrBadConn should be returned by a driver when a connection is in a bad state
/// (e.g. server closed connection) and may be retried by the pool with a fresh connection.
pub const ErrBadConn = error.ErrBadConn;

/// IsolationLevel is the transaction isolation level stored in TxOptions.
pub const IsolationLevel = enum {
    default,
    read_uncommitted,
    read_committed,
    write_committed,
    repeatable_read,
    snapshot,
    serializable,
    linearizable,
};

/// TxOptions holds the transaction options (isolation level and read-only flag).
pub const TxOptions = struct {
    isolation: IsolationLevel = .default,
    read_only: bool = false,
};

/// Result of an Exec query (e.g. INSERT, UPDATE, DELETE).
pub const Result = struct {
    last_insert_id: i64 = 0,
    rows_affected: i64 = 0,

    pub fn lastInsertId(self: Result) i64 {
        return self.last_insert_id;
    }

    pub fn rowsAffected(self: Result) i64 {
        return self.rows_affected;
    }
};

/// Rows is an iterator over an executed query's results.
pub const Rows = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        columns: *const fn (ctx: *anyopaque) []const []const u8,
        next: *const fn (ctx: *anyopaque, dest: []Value) bool,
        close: *const fn (ctx: *anyopaque) void,
        /// Optional: returns the error, if any, that occurred while iterating.
        err: ?*const fn (ctx: *anyopaque) ?anyerror = null,
    };

    pub fn columns(self: *Rows) []const []const u8 {
        return self.vtable.columns(self.ptr);
    }

    pub fn next(self: *Rows, dest: []Value) bool {
        return self.vtable.next(self.ptr, dest);
    }

    pub fn close(self: *Rows) void {
        self.vtable.close(self.ptr);
    }

    /// Err returns the error, if any, that was encountered during iteration.
    /// Returns null if iteration finished cleanly or was closed.
    pub fn err(self: *Rows) ?anyerror {
        if (self.vtable.err) |f| {
            return f(self.ptr);
        }
        return null;
    }
};

/// Stmt is a prepared statement bound to a Conn.
pub const Stmt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (ctx: *anyopaque) void,
        numInput: *const fn (ctx: *anyopaque) i64,
        exec: *const fn (ctx: *anyopaque, args: []const Value) anyerror!Result,
        query: *const fn (ctx: *anyopaque, args: []const Value) anyerror!Rows,
    };

    pub fn close(self: *Stmt) void {
        self.vtable.close(self.ptr);
    }

    pub fn numInput(self: *Stmt) i64 {
        return self.vtable.numInput(self.ptr);
    }

    pub fn exec(self: *Stmt, args: []const Value) !Result {
        return self.vtable.exec(self.ptr, args);
    }

    pub fn query(self: *Stmt, args: []const Value) !Rows {
        return self.vtable.query(self.ptr, args);
    }
};

/// Tx is an in-progress transaction on a Conn.
pub const Tx = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        commit: *const fn (ctx: *anyopaque) anyerror!void,
        rollback: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn commit(self: *Tx) !void {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: *Tx) !void {
        return self.vtable.rollback(self.ptr);
    }
};

/// Conn is a connection to a database. It is not used concurrently by multiple threads.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepare: *const fn (ctx: *anyopaque, query: []const u8) anyerror!Stmt,
        close: *const fn (ctx: *anyopaque) void,
        begin: *const fn (ctx: *anyopaque) anyerror!Tx,
        ping: *const fn (ctx: *anyopaque) anyerror!void,
        /// Optional: starts a transaction with specific options (isolation level, read-only).
        beginTx: ?*const fn (ctx: *anyopaque, opts: TxOptions) anyerror!Tx = null,
        /// [Extension to standard Go driver.Conn]
        /// Optional: Interrupts any in-progress query on this connection (e.g. sqlite3_interrupt,
        /// PostgreSQL CancelRequest, MySQL KILL QUERY).
        /// This extension allows GUI clients (such as Qianliyan) and Context cancellation to
        /// abort slow queries out-of-band without destroying the underlying connection or pool.
        interrupt: ?*const fn (ctx: *anyopaque) void = null,
        /// Optional: returns the detailed error message for the last operation on this connection.
        lastError: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    pub fn prepare(self: *Conn, query: []const u8) !Stmt {
        return self.vtable.prepare(self.ptr, query);
    }

    pub fn close(self: *Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn begin(self: *Conn) !Tx {
        return self.vtable.begin(self.ptr);
    }

    /// BeginTx starts a transaction with the given options.
    /// If the driver does not implement beginTx and the options are default,
    /// it falls back to begin(). If non-default options are requested and unsupported,
    /// it returns error.TxOptionsNotSupported.
    pub fn beginTx(self: *Conn, opts: TxOptions) !Tx {
        if (self.vtable.beginTx) |f| {
            return f(self.ptr, opts);
        }
        if (opts.isolation == .default and !opts.read_only) {
            return self.vtable.begin(self.ptr);
        }
        return error.TxOptionsNotSupported;
    }

    pub fn ping(self: *Conn) !void {
        return self.vtable.ping(self.ptr);
    }

    /// Interrupt aborts any in-progress database operation on this connection out-of-band.
    /// Returns true if the underlying driver supports interruption and the signal was sent,
    /// or false if unsupported by this driver.
    pub fn interrupt(self: *Conn) bool {
        if (self.vtable.interrupt) |f| {
            f(self.ptr);
            return true;
        }
        return false;
    }

    /// LastError returns the error message for the last operation on this connection,
    /// or null if no error has occurred or the driver does not support detailed messages.
    pub fn lastError(self: *Conn) ?[]const u8 {
        if (self.vtable.lastError) |f| {
            return f(self.ptr);
        }
        return null;
    }
};

/// Driver is the interface that must be implemented by a database driver.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, dsn: []const u8) anyerror!Conn,
    };

    pub fn open(self: Driver, dsn: []const u8) !Conn {
        return self.vtable.open(self.ptr, dsn);
    }
};

test "Value format" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const cases = [_]struct { []const u8, Value }{
        .{ "NULL", .null },
        .{ "-42", .{ .int = -42 } },
        .{ "1.5", .{ .float = 1.5 } },
        .{ "true", .{ .bool = true } },
        .{ "'hi'", .{ .string = "hi" } },
        .{ "0x00ff1a", .{ .bytes = &.{ 0x00, 0xff, 0x1a } } },
    };
    for (cases) |c| {
        const want, const v = c;
        try testing.expectEqualStrings(want, try std.fmt.bufPrint(&buf, "{f}", .{v}));
    }
}
