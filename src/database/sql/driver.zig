//! Package database/sql/driver defines interfaces to be implemented by database drivers
//! as required by package database/sql.

const std = @import("std");
const deadlines = @import("../../io/deadline.zig");
const Deadline = deadlines.Deadline;
const time_pkg = @import("../../time/time.zig");

/// Blob represents raw binary data (BLOB) in SQL to distinguish from UTF-8 strings.
pub const Blob = struct {
    data: []const u8,

    /// Creates a Blob wrapping the given byte slice without copying.
    pub fn init(data: []const u8) Blob {
        return .{ .data = data };
    }
};

/// Convenience helper to create a Blob from a byte slice.
pub fn blob(data: []const u8) Blob {
    return Blob.init(data);
}

/// Validates cancellation and deadline before invoking a driver operation.
///
/// Note: Methods in this package accept an optional Deadline parameter.
/// Whether in-flight backend operations can be interrupted before completion
/// depends on the underlying driver implementation.
pub fn checkOperation(io: std.Io, deadline: Deadline) !void {
    try io.checkCancel();
    try deadline.check(io);
}

/// Driver value representation.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,

    /// Binds any supported scalar/struct Zig value into a driver Value at compile time.
    /// Supports native scalars, enums, optional types, time.Time (encoded as Unix epoch
    /// seconds; format explicitly or implement `.bind()` for sub-second precision), Blob,
    /// and custom types implementing `.bind()`.
    ///
    /// Returns `error.IntegerOverflow` if a runtime integer cannot fit in `i64`
    /// (e.g. `u64 > std.math.maxInt(i64)`).
    pub fn bind(val: anytype) error{IntegerOverflow}!Value {
        const T = @TypeOf(val);
        if (T == Value) return val;
        if (T == NamedValue) return val.value;
        if (T == Blob) return .{ .bytes = val.data };
        const info = @typeInfo(T);
        if (info == .@"struct" and @hasDecl(T, "bind")) {
            return val.bind();
        }
        switch (info) {
            .null => return .null,
            .optional => {
                if (val) |v| return bind(v);
                return .null;
            },
            .int => {
                const v = std.math.cast(i64, val) orelse return error.IntegerOverflow;
                return .{ .int = v };
            },
            .comptime_int => return .{ .int = @intCast(val) },
            .float => return .{ .float = @floatCast(val) },
            .comptime_float => return .{ .float = @floatCast(val) },
            .bool => return .{ .bool = val },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    return .{ .string = val };
                }
                if (ptr.size == .one and @typeInfo(ptr.child) == .array and
                    @typeInfo(ptr.child).array.child == u8)
                {
                    return .{ .string = val };
                }
                @compileError("unsupported pointer type for sql Value: " ++ @typeName(T));
            },
            .@"enum" => return .{ .string = @tagName(val) },
            else => {
                if (T == time_pkg.Time) {
                    return .{ .int = val.wall_sec };
                }
                @compileError("unsupported type for sql Value: " ++ @typeName(T));
            },
        }
    }

    /// Scans this driver Value into the destination Zig type T at compile time.
    /// Supports standard scalar types, enums, stdgo.time.Time, Blob, and custom types
    /// implementing .scan().
    pub fn scan(self: Value, comptime T: type) !T {
        if (T == Value) return self;
        const info = @typeInfo(T);
        if (info == .optional) {
            if (self == .null) return null;
            return try self.scan(info.optional.child);
        }
        if (info == .@"struct" and @hasDecl(T, "scan")) {
            var res: T = undefined;
            try res.scan(self);
            return res;
        }
        if (T == Blob) {
            switch (self) {
                .bytes => |b| return Blob{ .data = b },
                .string => |s| return Blob{ .data = s },
                .null => return error.UnexpectedNull,
                else => return error.ColumnTypeMismatch,
            }
        }
        if (T == time_pkg.Time) {
            switch (self) {
                .int => |i| return time_pkg.Time.unix(i, 0),
                .string => |s| {
                    if (time_pkg.parse(time_pkg.RFC3339Nano, s)) |t| return t else |_| {}
                    if (time_pkg.parse(time_pkg.RFC3339, s)) |t| return t else |_| {}
                    if (time_pkg.parse("2006-01-02 15:04:05", s)) |t| return t else |_| {}
                    if (time_pkg.parse("2006-01-02", s)) |t| return t else |_| {}
                    return error.ColumnTypeMismatch;
                },
                else => return error.ColumnTypeMismatch,
            }
        }
        if (info == .@"enum") {
            switch (self) {
                .int => |i| {
                    const TagType = @typeInfo(T).@"enum".tag_type;
                    const tag_val = std.math.cast(TagType, i) orelse return error.IntegerOverflow;
                    return std.enums.fromInt(T, tag_val) orelse error.InvalidEnumValue;
                },
                .string => |s| {
                    return std.meta.stringToEnum(T, s) orelse error.InvalidEnumValue;
                },
                else => return error.ColumnTypeMismatch,
            }
        }
        switch (self) {
            .null => return error.UnexpectedNull,
            .int => |i| {
                switch (info) {
                    .int => return std.math.cast(T, i) orelse error.IntegerOverflow,
                    .float => return @floatFromInt(i),
                    .bool => return i != 0,
                    else => return error.ColumnTypeMismatch,
                }
            },
            .float => |f| {
                switch (info) {
                    .float => return @floatCast(f),
                    else => return error.ColumnTypeMismatch,
                }
            },
            .bool => |b| {
                switch (info) {
                    .bool => return b,
                    .int => return if (b) @as(T, 1) else @as(T, 0),
                    else => return error.ColumnTypeMismatch,
                }
            },
            .string => |s| {
                if (T == []const u8) return s;
                return error.ColumnTypeMismatch;
            },
            .bytes => |b| {
                if (T == []const u8) return b;
                return error.ColumnTypeMismatch;
            },
        }
    }

    /// Formats the Value in a human-readable SQL-like representation.
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

/// NamedValue holds an optional argument name and its driver Value.
/// Corresponds to Go's database/sql/driver.NamedValue.
pub const NamedValue = struct {
    name: ?[]const u8 = null,
    value: Value,
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
    last_insert_id: ?i64 = null,
    rows_affected: ?i64 = null,

    /// LastInsertId returns the integer generated by the database in response to a command.
    /// Typically this will be from an "auto increment" column when inserting a new row.
    /// Returns error.UnsupportedResult if not supported by the underlying driver or query.
    pub fn lastInsertId(self: Result) !i64 {
        return self.last_insert_id orelse error.UnsupportedResult;
    }

    /// RowsAffected returns the number of rows affected by an update, insert, or delete.
    /// Returns error.UnsupportedResult if not supported by the underlying driver or query.
    pub fn rowsAffected(self: Result) !i64 {
        return self.rows_affected orelse error.UnsupportedResult;
    }
};

/// DecimalSize holds the precision and scale of a decimal/numeric column.
pub const DecimalSize = struct {
    precision: i64,
    scale: i64,
};

/// ColumnType represents metadata about a column in a result set,
/// corresponding to Go's database/sql.ColumnType.
pub const ColumnType = struct {
    col_name: []const u8,
    raw_type_name: ?[]const u8 = null,
    nullable_val: ?bool = null,
    length_val: ?i64 = null,
    decimal_size: ?DecimalSize = null,

    /// Name returns the name or alias of the column.
    pub fn name(self: ColumnType) []const u8 {
        return self.col_name;
    }

    /// DatabaseTypeName returns the database system type name of the column,
    /// such as "VARCHAR", "INTEGER", "REAL", "BLOB", or null if not provided by driver.
    pub fn databaseTypeName(self: ColumnType) ?[]const u8 {
        return self.raw_type_name;
    }

    /// Nullable returns whether the column may be null, or null if unknown.
    pub fn nullable(self: ColumnType) ?bool {
        return self.nullable_val;
    }

    /// Length returns the column type length for variable length column types,
    /// or null if unknown / not applicable.
    pub fn length(self: ColumnType) ?i64 {
        return self.length_val;
    }

    /// DecimalSize returns the scale and precision of a decimal type,
    /// or null if unknown / not applicable.
    pub fn decimalSize(self: ColumnType) ?DecimalSize {
        return self.decimal_size;
    }
};

/// Rows is an iterator over an executed query's results.
pub const Rows = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// VTable defines the driver callbacks for iterating over query result rows.
    pub const VTable = struct {
        /// Returns the number of columns in the result set.
        columnCount: *const fn (ctx: *anyopaque) usize,
        /// Returns the column name at the given 0-based index.
        columnName: *const fn (ctx: *anyopaque, index: usize) []const u8,
        /// Advances to the next row.
        /// Whether deadline is checked during iteration depends on the driver.
        next: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            dest: []Value,
            deadline: Deadline,
        ) anyerror!bool,
        close: *const fn (ctx: *anyopaque) void,
        /// Optional: returns the error, if any, that occurred while iterating.
        err: ?*const fn (ctx: *anyopaque) ?anyerror = null,
        /// Optional: returns the database system type name for the column at index
        /// (e.g. "INTEGER", "VARCHAR").
        columnTypeDatabaseTypeName: ?*const fn (
            ctx: *anyopaque,
            index: usize,
        ) ?[]const u8 = null,
        /// Optional: returns whether the column at index is nullable.
        columnTypeNullable: ?*const fn (ctx: *anyopaque, index: usize) ?bool = null,
        /// Optional: returns the column type length for variable-length types.
        columnTypeLength: ?*const fn (ctx: *anyopaque, index: usize) ?i64 = null,
        /// Optional: returns precision and scale for decimal/numeric types.
        columnTypePrecisionScale: ?*const fn (
            ctx: *anyopaque,
            index: usize,
        ) ?DecimalSize = null,
    };

    /// ColumnCount returns the number of columns in the result set.
    pub fn columnCount(self: *Rows) usize {
        return self.vtable.columnCount(self.ptr);
    }

    /// ColumnName returns the name of the column at the given 0-based index.
    pub fn columnName(self: *Rows, index: usize) []const u8 {
        return self.vtable.columnName(self.ptr, index);
    }

    /// Next populates `dest` with the next row's column values and returns false when exhausted.
    pub fn next(self: *Rows, io: std.Io, dest: []Value, deadline: Deadline) !bool {
        try checkOperation(io, deadline);
        return self.vtable.next(self.ptr, io, dest, deadline);
    }

    /// Close closes the rows iterator and releases driver-side cursor resources.
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

    /// VTable defines the driver callbacks for executing and closing a prepared statement.
    pub const VTable = struct {
        close: *const fn (ctx: *anyopaque) void,
        numInput: *const fn (ctx: *anyopaque) i64,
        /// Executes a prepared statement.
        /// Whether deadline is checked during execution depends on the driver.
        exec: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result,
        /// Executes a prepared query.
        /// Whether deadline is checked during execution depends on the driver.
        query: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Rows,
    };

    /// Close closes the prepared statement and frees driver-side resources.
    pub fn close(self: *Stmt) void {
        self.vtable.close(self.ptr);
    }

    /// NumInput returns the number of placeholder parameters, or -1 if unknown.
    pub fn numInput(self: *Stmt) i64 {
        return self.vtable.numInput(self.ptr);
    }

    /// Exec executes a prepared statement that does not return rows.
    pub fn exec(self: *Stmt, io: std.Io, args: []const NamedValue, deadline: Deadline) !Result {
        try checkOperation(io, deadline);
        return self.vtable.exec(self.ptr, io, args, deadline);
    }

    /// Query executes a prepared statement that returns rows.
    pub fn query(self: *Stmt, io: std.Io, args: []const NamedValue, deadline: Deadline) !Rows {
        try checkOperation(io, deadline);
        return self.vtable.query(self.ptr, io, args, deadline);
    }
};

/// Tx is an in-progress transaction on a Conn.
pub const Tx = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// VTable defines the driver callbacks for committing or rolling back a transaction.
    pub const VTable = struct {
        /// Both callbacks consume the transaction even when the driver returns an error.
        commit: *const fn (ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void,
        rollback: *const fn (ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void,
    };

    /// Commit commits the in-progress transaction.
    pub fn commit(self: *Tx, io: std.Io, deadline: Deadline) !void {
        try checkOperation(io, deadline);
        return self.vtable.commit(self.ptr, io, deadline);
    }

    /// Rollback aborts and rolls back the in-progress transaction.
    pub fn rollback(self: *Tx, io: std.Io, deadline: Deadline) !void {
        try deadline.validate();
        if (!deadline.isNone()) {
            try checkOperation(io, deadline);
        }
        return self.vtable.rollback(self.ptr, io, deadline);
    }
};

/// Conn is a connection to a database. It is not used concurrently by multiple threads.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// VTable defines the driver callbacks for a single database connection.
    pub const VTable = struct {
        prepare: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            query: []const u8,
            deadline: Deadline,
        ) anyerror!Stmt,
        close: *const fn (ctx: *anyopaque) void,
        /// Starts a transaction with the given options (isolation level, read-only).
        /// Drivers that do not support non-default options should return
        /// `error.TxOptionsNotSupported`.
        beginTx: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            opts: TxOptions,
            deadline: Deadline,
        ) anyerror!Tx,
        ping: *const fn (ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void,
        /// Optional: executes a query directly without preparing a statement object.
        /// Drivers can optimize this to be zero-allocation (e.g. SQLite stack statement).
        execDirect: ?*const fn (
            ctx: *anyopaque,
            io: std.Io,
            query: []const u8,
            args: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result = null,
        /// [Extension to standard Go driver.Conn]
        /// Optional: Interrupts any in-progress query on this connection (e.g. sqlite3_interrupt,
        /// PostgreSQL CancelRequest, MySQL KILL QUERY).
        /// This extension allows GUI clients (such as Qianliyan) to
        /// abort slow queries out-of-band without destroying the underlying connection or pool.
        interrupt: ?*const fn (ctx: *anyopaque) void = null,
        /// Optional: returns the detailed error message for the last operation on this connection.
        lastError: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    /// Prepare returns a prepared statement bound to this connection.
    pub fn prepare(self: *Conn, io: std.Io, query: []const u8, deadline: Deadline) !Stmt {
        try checkOperation(io, deadline);
        return self.vtable.prepare(self.ptr, io, query, deadline);
    }

    /// Close closes the underlying database connection and frees driver resources.
    pub fn close(self: *Conn) void {
        self.vtable.close(self.ptr);
    }

    /// Begin starts and returns a new transaction with default options.
    pub fn begin(self: *Conn, io: std.Io, deadline: Deadline) !Tx {
        return self.beginTx(io, .{}, deadline);
    }

    /// BeginTx starts a transaction with the given options.
    pub fn beginTx(self: *Conn, io: std.Io, opts: TxOptions, deadline: Deadline) !Tx {
        try checkOperation(io, deadline);
        return self.vtable.beginTx(self.ptr, io, opts, deadline);
    }

    /// Ping verifies that the connection to the database is still alive.
    pub fn ping(self: *Conn, io: std.Io, deadline: Deadline) !void {
        try checkOperation(io, deadline);
        return self.vtable.ping(self.ptr, io, deadline);
    }

    /// ExecDirect executes a query directly without preparing a statement object.
    /// Falls back to prepare -> exec -> close if the driver does not implement execDirect.
    pub fn execDirect(
        self: *Conn,
        io: std.Io,
        query: []const u8,
        args: []const NamedValue,
        deadline: Deadline,
    ) !Result {
        try checkOperation(io, deadline);
        if (self.vtable.execDirect) |f| {
            return f(self.ptr, io, query, args, deadline);
        }
        var stmt = try self.prepare(io, query, deadline);
        defer stmt.close();
        return stmt.exec(io, args, deadline);
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

/// Driver is a non-owning interface implemented by database drivers (analogous to
/// `std.mem.Allocator` and `std.Io`). The caller retains ownership of the underlying
/// driver implementation pointed to by `ptr` and must keep it alive until `DB` and all
/// derived handles are closed.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// VTable defines the driver callback for opening new database connections.
    pub const VTable = struct {
        open: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            dsn: []const u8,
            deadline: Deadline,
        ) anyerror!Conn,
    };

    /// Open returns a new connection to the database specified by `dsn`.
    pub fn open(
        self: Driver,
        io: std.Io,
        dsn: []const u8,
        deadline: Deadline,
    ) !Conn {
        try checkOperation(io, deadline);
        return self.vtable.open(self.ptr, io, dsn, deadline);
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
