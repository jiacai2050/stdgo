//! Package database/sql provides a generic interface around SQL (or SQL-like) databases.
//!
//! It manages a thread-safe connection pool, connection life-cycle, transaction management,
//! and statement execution.

const std = @import("std");
const build_options = @import("build_options");
const driver_pkg = @import("sql/driver.zig");
pub const driver = driver_pkg;
pub const sqlite = if (build_options.have_sqlite) @import("sql/sqlite.zig") else struct {};
const Allocator = std.mem.Allocator;
const Deadline = @import("../io/deadline.zig").Deadline;
const time_pkg = @import("../time/time.zig");
pub const Time = time_pkg.Time;

pub const Value = driver.Value;
pub const Result = driver.Result;
pub const IsolationLevel = driver.IsolationLevel;
pub const TxOptions = driver.TxOptions;
/// Returned by drivers when a pooled connection is broken and should be discarded.
pub const ErrBadConn = driver.ErrBadConn;
/// Returned by `Row.scan` / `Row.scanStruct` when a query matches zero rows.
pub const ErrNoRows = error.ErrNoRows;
/// Returned when an operation is attempted on a committed or rolled-back `Tx`.
pub const ErrTxDone = error.TxDone;
/// Returned when an operation is attempted on a closed `Stmt`.
pub const ErrStmtClosed = error.StmtClosed;
/// Returned when an operation is attempted on a closed `Conn` or its invalidated children.
pub const ErrConnDone = error.ConnDone;
pub const ColumnType = driver.ColumnType;
pub const DecimalSize = driver.DecimalSize;
pub const NamedValue = driver.NamedValue;
pub const MockDriver = @import("sql/mock.zig").MockDriver;

pub const Blob = driver.Blob;
pub const blob = driver.blob;

/// DBStats contains database connection pool statistics.
pub const DBStats = struct {
    max_open_connections: usize,
    open_connections: usize,
    in_use: usize,
    idle: usize,
    wait_count: u64,
    wait_duration_ns: u64,
    max_idle_closed: u64,
    max_idle_time_closed: u64,
    max_lifetime_closed: u64,
};

/// Inlines and unpacks anytype args (struct, tuple, pointer to struct, or []const NamedValue)
/// into a stack-allocated []const NamedValue slice with zero heap allocations.
///
/// Dispatched mapping rules:
/// - Anonymous tuples (`is_tuple == true`): mapped to positional parameters (`name = null`).
/// - Structs (`is_tuple == false`): mapped to named parameters (`name = field_name`).
/// - Pointer to struct/tuple (`&.{}` / `&.{ ... }`): unwrapped automatically.
/// - NamedValue slice (`[]const NamedValue`): forwarded directly.
inline fn withNamedValues(
    args: anytype,
    ctx: anytype,
    comptime func: anytype,
) !@typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.payload {
    const ArgT = @TypeOf(args);
    const arg_info = @typeInfo(ArgT);

    // 1. Single-pointer to struct/tuple (e.g. &.{ ... } or &.{})
    if (arg_info == .pointer and arg_info.pointer.size == .one and
        @typeInfo(arg_info.pointer.child) == .@"struct")
    {
        return withNamedValues(args.*, ctx, func);
    }

    // 2. NamedValue slice (for internal driver forwarding)
    if (ArgT == []const NamedValue or ArgT == []NamedValue) {
        return @call(.auto, func, .{ ctx, args });
    }

    // 3. Struct / Tuple (e.g. .{ .name = "Alice", .age = 30 } or .{ "Alice", 30 } or .{})
    if (arg_info == .@"struct") {
        const s_info = arg_info.@"struct";
        var nv_buf: [s_info.field_names.len]NamedValue = undefined;
        if (s_info.is_tuple) {
            inline for (s_info.field_names, 0..) |name, i| {
                nv_buf[i] = .{ .name = null, .value = try Value.bind(@field(args, name)) };
            }
        } else {
            inline for (s_info.field_names, 0..) |name, i| {
                nv_buf[i] = .{ .name = name, .value = try Value.bind(@field(args, name)) };
            }
        }
        return @call(.auto, func, .{ ctx, &nv_buf });
    }

    @compileError("unsupported argument type for database/sql query: " ++ @typeName(ArgT));
}

/// Scans a slice of driver Values directly into a destination struct at compile time.
/// Columns are mapped strictly by position: the i-th column populates the i-th struct field.
pub fn scanValues(comptime T: type, values: []const Value) !T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("expected a struct type, found " ++ @typeName(T));
    }
    const s_info = type_info.@"struct";
    if (values.len != s_info.field_names.len) {
        return error.ColumnCountMismatch;
    }
    var result: T = undefined;
    inline for (s_info.field_names, s_info.field_types, 0..) |name, FieldType, i| {
        @field(result, name) = try values[i].scan(FieldType);
    }
    return result;
}

const max_stack_scan_columns: usize = 128;

fn resolveColumnMapping(
    rows: *Rows,
    comptime T: type,
    col_count: usize,
) ![(@typeInfo(T).@"struct").field_names.len]usize {
    const s_info = @typeInfo(T).@"struct";
    var mapping: [s_info.field_names.len]usize = undefined;
    inline for (s_info.field_names, 0..) |field_name, field_idx| {
        var found_col: ?usize = null;
        for (0..col_count) |col_idx| {
            if (std.mem.eql(u8, rows.columnName(col_idx), field_name)) {
                if (found_col != null) {
                    return error.AmbiguousColumnName;
                }
                found_col = col_idx;
            }
        }
        mapping[field_idx] = found_col orelse return error.ColumnNotFound;
    }
    return mapping;
}

fn scanValuesByMapping(
    comptime T: type,
    values: []const Value,
    mapping: *const [(@typeInfo(T).@"struct").field_names.len]usize,
) !T {
    const s_info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (s_info.field_names, s_info.field_types, 0..) |name, FieldType, i| {
        @field(result, name) = try values[mapping[i]].scan(FieldType);
    }
    return result;
}

fn typeBorrowsDriverMemory(comptime T: type) bool {
    const info = @typeInfo(T);
    if (T == Blob) return true;
    if (T == time_pkg.Time) return false;
    if (T == Value) return true;
    return switch (info) {
        .optional => |opt| typeBorrowsDriverMemory(opt.child),
        .pointer => true,
        .@"struct" => |s| {
            if (@hasDecl(T, "scan")) return true;
            inline for (s.field_types) |FieldType| {
                if (typeBorrowsDriverMemory(FieldType)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn dupeOwnedField(allocator: Allocator, comptime FieldType: type, val: FieldType) !FieldType {
    if (FieldType == []const u8) {
        return try allocator.dupe(u8, val);
    }
    if (FieldType == Blob) {
        return Blob.init(try allocator.dupe(u8, val.data));
    }
    if (FieldType == ?[]const u8) {
        if (val) |s| return try allocator.dupe(u8, s);
        return null;
    }
    if (FieldType == ?Blob) {
        if (val) |b| return Blob.init(try allocator.dupe(u8, b.data));
        return null;
    }
    if (comptime typeBorrowsDriverMemory(FieldType)) {
        @compileError(
            "Row.scanStructOwned cannot duplicate field type: " ++ @typeName(FieldType),
        );
    }
    return val;
}

fn freeOwnedField(allocator: Allocator, comptime FieldType: type, val: FieldType) void {
    if (FieldType == []const u8) {
        allocator.free(val);
        return;
    }
    if (FieldType == Blob) {
        allocator.free(val.data);
        return;
    }
    if (FieldType == ?[]const u8) {
        if (val) |s| allocator.free(s);
        return;
    }
    if (FieldType == ?Blob) {
        if (val) |b| allocator.free(b.data);
        return;
    }
}

/// Owned wraps a scanned struct together with the allocator used to duplicate
/// its `[]const u8` and `Blob` fields (analogous to `std.json.Parsed(T)`).
/// Call `deinit()` when done to release all duplicated slice memory.
pub fn Owned(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("expected a struct type, found " ++ @typeName(T));
    }
    return struct {
        value: T,
        allocator: Allocator,

        /// Releases all `[]const u8` and `Blob` fields duplicated for `value`.
        pub fn deinit(self: @This()) void {
            const s_info = @typeInfo(T).@"struct";
            inline for (s_info.field_names, s_info.field_types) |name, FieldType| {
                freeOwnedField(self.allocator, FieldType, @field(self.value, name));
            }
        }
    };
}

fn dupeOwnedStruct(allocator: Allocator, comptime T: type, value: T) !Owned(T) {
    const s_info = @typeInfo(T).@"struct";
    var result = value;
    var duped_count: usize = 0;
    errdefer {
        inline for (s_info.field_names, s_info.field_types, 0..) |name, FieldType, i| {
            if (i < duped_count) {
                freeOwnedField(allocator, FieldType, @field(result, name));
            }
        }
    }
    inline for (s_info.field_names, s_info.field_types, 0..) |name, FieldType, i| {
        @field(result, name) = try dupeOwnedField(allocator, FieldType, @field(result, name));
        duped_count = i + 1;
    }
    return .{
        .value = result,
        .allocator = allocator,
    };
}

/// Row is the result of calling QueryRow to select a single row.
pub const Row = struct {
    rows: ?Rows = null,
    err_state: ?anyerror = null,

    /// Scan copies the columns from the matched row into the values pointed at by dest.
    /// If more than one row matches the query, Scan uses the first row and discards the rest.
    /// If no rows match the query, Scan returns error.ErrNoRows.
    /// Note: Any string/bytes in dest point into driver memory while the row is open;
    /// use `defer row.close()` to release the connection after using the scanned values.
    pub fn scan(self: *Row, dest: []Value, deadline: Deadline) !void {
        if (self.err_state) |e| {
            self.close();
            return e;
        }
        var r = &(self.rows orelse return error.ErrNoRows);
        const has_row = r.next(dest, deadline) catch |next_error| {
            self.err_state = next_error;
            self.close();
            return next_error;
        };
        if (!has_row) {
            self.close();
            return error.ErrNoRows;
        }
    }

    /// ScanStruct copies the matched row's columns directly into a strongly-typed struct.
    /// Columns are matched strictly by case-sensitive column name (independent of column order,
    /// and extra columns in the query are ignored). For expressions, alias them with `AS`.
    /// Returns `error.ColumnNotFound` if a struct field has no matching column,
    /// `error.AmbiguousColumnName` if multiple columns share a field's name,
    /// `error.TooManyColumns` if the result set exceeds 128 columns, or `error.ErrNoRows`
    /// if no rows match.
    ///
    /// Lifetime:
    /// - If `T` contains only value types (no slices, `Blob`, `Value`, or custom `.scan()` types),
    ///   the row is automatically closed and its pooled connection is released before returning.
    /// - If `T` contains `[]const u8` or `Blob`, those slices borrow driver memory while the row
    ///   is open; use `defer row.close()` after use, or call `scanStructOwned()` instead.
    pub fn scanStruct(self: *Row, comptime T: type, deadline: Deadline) !T {
        errdefer self.close();
        if (self.err_state) |e| return e;
        var r = &(self.rows orelse return error.ErrNoRows);
        const maybe_result = r.nextStruct(T, deadline) catch |scan_err| {
            self.err_state = scan_err;
            return scan_err;
        };
        const result = maybe_result orelse return error.ErrNoRows;
        if (comptime !typeBorrowsDriverMemory(T)) {
            self.close();
        }
        return result;
    }

    /// ScanStructOwned copies the matched row's columns into a strongly-typed struct,
    /// duplicates any `[]const u8` or `Blob` fields using `allocator`, and immediately
    /// closes the underlying query so the pooled connection is returned to the pool.
    /// Columns are matched strictly by case-sensitive column name (independent of column order,
    /// and extra columns in the query are ignored). For expressions, alias them with `AS`.
    /// Returns `error.ColumnNotFound` if a struct field has no matching column,
    /// `error.AmbiguousColumnName` if multiple columns share a field's name, or
    /// `error.ErrNoRows` if no rows match.
    ///
    /// Returns an `Owned(T)` wrapper; access the scanned struct via `.value` and call
    /// `defer owned.deinit()` to release all duplicated slices.
    pub fn scanStructOwned(
        self: *Row,
        allocator: Allocator,
        comptime T: type,
        deadline: Deadline,
    ) !Owned(T) {
        defer self.close();
        if (self.err_state) |e| return e;
        var r = &(self.rows orelse return error.ErrNoRows);
        const maybe_owned = r.nextStructOwned(allocator, T, deadline) catch |scan_err| {
            self.err_state = scan_err;
            return scan_err;
        };
        return maybe_owned orelse return error.ErrNoRows;
    }

    /// Close closes the underlying query and releases the pooled connection back to the pool.
    pub fn close(self: *Row) void {
        if (self.rows) |*r| {
            r.close();
            self.rows = null;
        }
    }

    /// Err returns the error, if any, that was encountered while preparing or executing the query.
    pub fn err(self: *Row) ?anyerror {
        if (self.err_state) |e| return e;
        if (self.rows) |*r| return r.err();
        return null;
    }

    /// LastError returns the error message for the last operation on the underlying connection.
    /// The returned slice borrows driver memory and is only valid until `row.close()`.
    pub fn lastError(self: *Row) ?[]const u8 {
        if (self.rows) |*r| return r.lastError();
        return null;
    }
};

/// Internal pooled connection tracked by DB.
const PooledConn = struct {
    raw: driver.Conn,
    created_at_ns: i128,
    last_used_at_ns: i128,
    db: *DB,
    from_pool: bool = false,
    bad: bool = false,
    prev: ?*PooledConn = null,
    next: ?*PooledConn = null,

    fn release(self: *PooledConn) void {
        self.db.putConn(self);
    }

    fn interrupt(self: *PooledConn) bool {
        return self.raw.interrupt();
    }

    fn lastError(self: *PooledConn) ?[]const u8 {
        return self.raw.lastError();
    }

    fn exec(
        self: *PooledConn,
        query_str: []const u8,
        args: anytype,
        deadline: Deadline,
    ) !Result {
        const Runner = struct {
            conn: *PooledConn,
            q: []const u8,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Result {
                const io = r.conn.db.io;
                try r.conn.db.checkOperation(r.dl);
                return r.conn.raw.execDirect(io, r.q, nv, r.dl);
            }
        };
        return withNamedValues(
            args,
            Runner{ .conn = self, .q = query_str, .dl = deadline },
            Runner.invoke,
        );
    }

    fn query(
        self: *PooledConn,
        query_str: []const u8,
        args: anytype,
        deadline: Deadline,
    ) !Rows {
        const Runner = struct {
            conn: *PooledConn,
            q: []const u8,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Rows {
                const io = r.conn.db.io;
                try r.conn.db.checkOperation(r.dl);
                var stmt = try r.conn.raw.prepare(io, r.q, r.dl);
                errdefer stmt.close();

                const raw_rows = try stmt.query(io, nv, r.dl);
                return Rows{
                    .pooled_conn = null,
                    .error_conn = r.conn,
                    .stmt = stmt,
                    .raw_rows = raw_rows,
                    .io = io,
                };
            }
        };
        return withNamedValues(
            args,
            Runner{ .conn = self, .q = query_str, .dl = deadline },
            Runner.invoke,
        );
    }

    fn beginTxInternal(
        self: *PooledConn,
        opts: TxOptions,
        deadline: Deadline,
        owns_conn: bool,
        conn_state: ?*ConnState,
    ) !Tx {
        try self.db.checkOperation(deadline);
        const state = try self.db.allocator.create(TxState);
        errdefer self.db.allocator.destroy(state);
        const raw_tx = try self.raw.beginTx(self.db.io, opts, deadline);
        state.* = .{
            .allocator = self.db.allocator,
            .pooled_conn = self,
            .owns_conn = owns_conn,
            .conn_state = conn_state,
            .raw_tx = raw_tx,
            .ref_count = if (conn_state != null) 2 else 1,
        };
        if (conn_state) |cs| {
            cs.active_tx = state;
        }
        return Tx{
            .state = state,
        };
    }
};

/// Internal heap-allocated state for a user-borrowed `Conn`, tracking all child
/// `Tx`, `Stmt`, and `Rows` handles so `Conn.close()` cleanly invalidates them before
/// returning the underlying `PooledConn` to the pool.
const ConnState = struct {
    allocator: Allocator,
    pooled_conn: ?*PooledConn,
    closed: bool = false,
    active_tx: ?*TxState = null,
    stmts_head: ?*StmtState = null,
    rows_head: ?*RowsState = null,

    fn closeResources(self: *ConnState) void {
        // 1. Close direct conn.query() rows first.
        while (self.rows_head) |rows_state| {
            rows_state.closeAndDetach(error.ConnDone);
        }

        // 2. Close all conn.prepare() statements (which also closes their active_rows).
        var current_stmt = self.stmts_head;
        self.stmts_head = null;
        while (current_stmt) |stmt_state| {
            const next = stmt_state.conn_next;
            stmt_state.conn_next = null;
            stmt_state.conn_prev = null;
            stmt_state.conn_state = null;
            if (!stmt_state.closed) {
                stmt_state.closed = true;
                stmt_state.invalidation_err = error.ConnDone;
                if (stmt_state.active_rows) |rows_state| {
                    rows_state.closeAndDetach(error.ConnDone);
                }
                std.debug.assert(stmt_state.active_rows == null);
                stmt_state.raw_stmt.close();
                stmt_state.pooled_conn = null;
            }
            stmt_state.release(); // release Conn's reference
            current_stmt = next;
        }

        // 3. Force rollback any still-open transaction started on this Conn.
        if (self.active_tx) |tx_state| {
            self.active_tx = null;
            tx_state.conn_state = null;
            if (!tx_state.done) {
                tx_state.done = true;
                tx_state.invalidation_err = error.ConnDone;
                tx_state.closeResources(error.ConnDone);
                if (tx_state.pooled_conn) |pc| {
                    tx_state.pooled_conn = null;
                    tx_state.raw_tx.vtable.rollback(tx_state.raw_tx.ptr, pc.db.io, .none) catch {
                        pc.bad = true;
                    };
                }
            }
            tx_state.release(); // release Conn's reference
        }
    }
};

/// Conn represents a single database connection borrowed exclusively from a `DB` pool.
///
/// All operations on a `Conn` run on the same underlying connection. It is not safe for
/// concurrent use without caller-side synchronization.
///
/// Call `close()` (idempotent) to return the connection to the pool. Any still-open
/// `Tx`, `Stmt`, or `Rows` derived from this `Conn` are automatically closed/rolled back
/// and invalidated with `error.ConnDone` before the connection is returned to the pool.
pub const Conn = struct {
    state: ?*ConnState,

    const Active = struct {
        state: *ConnState,
        pc: *PooledConn,
    };

    fn active(self: *Conn) !Active {
        const state = self.state orelse return error.ConnDone;
        if (state.closed) return error.ConnDone;
        const pc = state.pooled_conn orelse return error.ConnDone;
        return .{ .state = state, .pc = pc };
    }

    /// Close returns this connection to the DB pool (idempotent).
    /// Any still-open child `Tx`, `Stmt`, or `Rows` are closed and invalidated with `error.ConnDone`.
    pub fn close(self: *Conn) void {
        const state = self.state orelse return;
        self.state = null;
        if (!state.closed) {
            state.closed = true;
            state.closeResources();
            if (state.pooled_conn) |pc| {
                state.pooled_conn = null;
                pc.release();
            }
        }
        state.allocator.destroy(state);
    }

    /// Ping verifies that this connection is still alive.
    pub fn ping(self: *Conn, deadline: Deadline) !void {
        const a = try self.active();
        try a.pc.db.checkOperation(deadline);
        return a.pc.raw.ping(a.pc.db.io, deadline);
    }

    /// Interrupt aborts any in-progress query on this connection out-of-band.
    /// Returns true if supported and signaled, false otherwise.
    pub fn interrupt(self: *Conn) bool {
        const a = self.active() catch return false;
        return a.pc.interrupt();
    }

    /// LastError returns the error message for the last operation on this connection.
    /// The returned slice borrows driver memory and is only valid until the next operation
    /// on this connection or `conn.close()`.
    pub fn lastError(self: *Conn) ?[]const u8 {
        const a = self.active() catch return null;
        return a.pc.lastError();
    }

    /// Exec executes a query on this specific connection.
    /// Supports positional tuples `.{ ... }`, named structs `.{ .name = ... }`, or empty `.{}`.
    pub fn exec(self: *Conn, query_str: []const u8, args: anytype, deadline: Deadline) !Result {
        const a = try self.active();
        return a.pc.exec(query_str, args, deadline);
    }

    /// Query executes a query returning rows on this connection.
    /// Closing this `Conn` before `rows.close()` automatically closes and invalidates `rows`
    /// with `error.ConnDone`.
    pub fn query(self: *Conn, query_str: []const u8, args: anytype, deadline: Deadline) !Rows {
        const a = try self.active();
        var rows = try a.pc.query(query_str, args, deadline);
        errdefer rows.close();

        const rows_state = try a.pc.db.allocator.create(RowsState);
        rows_state.* = .{
            .allocator = a.pc.db.allocator,
            .raw_rows = rows.raw_rows,
            .owned_stmt = rows.stmt,
            .conn_state = a.state,
            .ref_count = 2,
            .conn_next = a.state.rows_head,
            .conn_prev = null,
        };
        if (a.state.rows_head) |head| {
            head.conn_prev = rows_state;
        }
        a.state.rows_head = rows_state;

        rows.stmt = null;
        rows.rows_state = rows_state;
        rows.pooled_conn = null;
        rows.error_conn = a.pc;
        return rows;
    }

    /// QueryRow executes a query that is expected to return at most one row.
    pub fn queryRow(self: *Conn, query_str: []const u8, args: anytype, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// Prepare creates a prepared statement on this specific connection.
    /// Closing the returned `Stmt` does NOT close this `Conn`; closing this `Conn` early
    /// automatically closes and invalidates the `Stmt` with `error.ConnDone`.
    pub fn prepare(self: *Conn, query_str: []const u8, deadline: Deadline) !Stmt {
        const a = try self.active();
        try a.pc.db.checkOperation(deadline);
        var raw_stmt = try a.pc.raw.prepare(a.pc.db.io, query_str, deadline);
        errdefer raw_stmt.close();

        const stmt_state = try a.pc.db.allocator.create(StmtState);
        stmt_state.* = .{
            .allocator = a.pc.db.allocator,
            .raw_stmt = raw_stmt,
            .pooled_conn = a.pc,
            .owns_conn = false,
            .conn_state = a.state,
            .tx_state = null,
            .from_tx = false,
            .active_rows = null,
            .ref_count = 2,
            .conn_next = a.state.stmts_head,
            .conn_prev = null,
        };
        if (a.state.stmts_head) |head| {
            head.conn_prev = stmt_state;
        }
        a.state.stmts_head = stmt_state;

        return Stmt{
            .state = stmt_state,
            .io = a.pc.db.io,
            .from_tx = false,
        };
    }

    /// BeginTx starts a transaction on this connection with the given options.
    /// Committing or rolling back the transaction does NOT close this `Conn`; closing this
    /// `Conn` while the transaction is still open automatically rolls it back and invalidates
    /// the `Tx` with `error.ConnDone`.
    pub fn beginTx(self: *Conn, opts: TxOptions, deadline: Deadline) !Tx {
        const a = try self.active();
        if (a.state.active_tx != null) return error.TxAlreadyActive;
        return a.pc.beginTxInternal(opts, deadline, false, a.state);
    }

    /// Begin starts a transaction on this connection with default options.
    pub fn begin(self: *Conn, deadline: Deadline) !Tx {
        return self.beginTx(.{}, deadline);
    }
};

fn listPush(
    head: *?*PooledConn,
    tail: *?*PooledConn,
    count: *usize,
    node: *PooledConn,
) void {
    node.prev = tail.*;
    node.next = null;
    if (tail.*) |t| {
        t.next = node;
    } else {
        head.* = node;
    }
    tail.* = node;
    count.* += 1;
}

fn listPop(
    head: *?*PooledConn,
    tail: *?*PooledConn,
    count: *usize,
) ?*PooledConn {
    const node = tail.* orelse return null;
    tail.* = node.prev;
    if (node.prev) |p| {
        p.next = null;
    } else {
        head.* = null;
    }
    node.prev = null;
    node.next = null;
    count.* -= 1;
    return node;
}

fn listRemove(
    head: *?*PooledConn,
    tail: *?*PooledConn,
    count: *usize,
    node: *PooledConn,
) void {
    if (node.prev) |p| {
        p.next = node.next;
    } else if (head.* == node) {
        head.* = node.next;
    }
    if (node.next) |n| {
        n.prev = node.prev;
    } else if (tail.* == node) {
        tail.* = node.prev;
    }
    node.prev = null;
    node.next = null;
    count.* -= 1;
}

/// DB is a database handle representing a pool of zero or more underlying connections.
/// It is safe for concurrent use by multiple threads.
/// The owner must prevent new operations from racing with close and handle destruction.
pub const DB = struct {
    allocator: Allocator,
    io: std.Io,
    driver_instance: driver.Driver,
    dsn: []const u8,

    mutex: std.Io.Mutex = .init,
    pool_changed: std.Io.Condition = .init,

    max_open_conns: usize = 0, // 0 means unlimited
    max_idle_conns: usize = 2,
    conn_max_lifetime_ns: ?u64 = null,
    conn_max_idle_time_ns: ?u64 = null,

    num_open: usize = 0,
    free_head: ?*PooledConn = null,
    free_tail: ?*PooledConn = null,
    free_count: usize = 0,

    active_head: ?*PooledConn = null,
    active_tail: ?*PooledConn = null,
    active_count: usize = 0,

    closed: bool = false,
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    wait_count: u64 = 0,
    wait_duration_ns: u64 = 0,
    max_idle_closed: u64 = 0,
    max_idle_time_closed: u64 = 0,
    max_lifetime_closed: u64 = 0,

    fn pushActive(self: *DB, pc: *PooledConn) void {
        listPush(&self.active_head, &self.active_tail, &self.active_count, pc);
    }

    fn removeActive(self: *DB, pc: *PooledConn) void {
        listRemove(&self.active_head, &self.active_tail, &self.active_count, pc);
    }

    fn pushFree(self: *DB, pc: *PooledConn) void {
        listPush(&self.free_head, &self.free_tail, &self.free_count, pc);
    }

    fn popFree(self: *DB) ?*PooledConn {
        return listPop(&self.free_head, &self.free_tail, &self.free_count);
    }

    /// Open creates a database handle using the supplied allocator, I/O, and driver.
    ///
    /// Lifetime:
    /// `allocator`, `io`, and the underlying driver instance behind `drv` must all outlive
    /// the `DB` and its derived handles (`Conn`, `Tx`, `Stmt`, `Rows`, `Row`).
    pub fn open(allocator: Allocator, io: std.Io, drv: driver.Driver, dsn: []const u8) !*DB {
        const dsn_copy = try allocator.dupe(u8, dsn);
        errdefer allocator.free(dsn_copy);
        const db = try allocator.create(DB);
        db.* = .{
            .allocator = allocator,
            .io = io,
            .driver_instance = drv,
            .dsn = dsn_copy,
            .ref_count = std.atomic.Value(usize).init(1),
        };
        return db;
    }

    fn destroySelf(self: *DB) void {
        while (self.popFree()) |pc| {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -%= 1;
        }
        self.allocator.free(self.dsn);
        self.allocator.destroy(self);
    }

    fn decrementRef(self: *DB) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.destroySelf();
        }
    }

    fn currentNanoTimestamp(self: *DB) i128 {
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn checkOperation(self: *DB, deadline: Deadline) !void {
        try driver_pkg.checkOperation(self.io, deadline);
    }

    /// Close closes the database and prevents new queries from starting.
    /// Close interrupts active queries, closes all idle connections, and waits briefly
    /// (up to 500ms) for in-flight connections to be returned.
    ///
    /// Callers should close all derived `Conn`, `Tx`, `Stmt`, `Rows`, and `Row` handles
    /// before calling `db.close()` (standard LIFO `defer` order), or ensure `allocator`,
    /// `io`, and any stateful driver remain valid until the last derived handle closes.
    pub fn close(self: *DB) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        self.pool_changed.broadcast(self.io);

        var curr_active = self.active_head;
        while (curr_active) |pc| {
            _ = pc.interrupt();
            curr_active = pc.next;
        }

        // Close and free all idle connections immediately
        while (self.popFree()) |pc| {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
        }

        // Wait briefly (up to 500ms) for in-flight connections to be returned via pool_changed.
        const grace_deadline = Deadline.after(self.io, .fromMilliseconds(500));
        while (self.active_count > 0) {
            self.pool_changed.waitTimeout(
                self.io,
                &self.mutex,
                grace_deadline.timeout(),
            ) catch break;
        }
        self.mutex.unlock(self.io);

        self.decrementRef();
    }

    /// SetMaxOpenConns sets the maximum number of open connections to the database.
    /// If n == 0, then there is no limit on the number of open connections.
    /// If n > 0 and max_idle_conns > n, max_idle_conns is reduced to n and excess idle
    /// connections are closed immediately.
    pub fn setMaxOpenConns(self: *DB, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.max_open_conns = n;
        if (n > 0 and self.max_idle_conns > n) {
            self.max_idle_conns = n;
            while (self.free_count > self.max_idle_conns) {
                const pc = self.popFree().?;
                pc.raw.close();
                self.allocator.destroy(pc);
                self.num_open -= 1;
                self.max_idle_closed += 1;
            }
        }
        self.pool_changed.broadcast(self.io);
    }

    /// SetMaxIdleConns sets the maximum number of connections in the idle
    /// connection pool. If `max_open_conns > 0` and `n > max_open_conns`, the new
    /// idle limit is reduced to `max_open_conns`.
    pub fn setMaxIdleConns(self: *DB, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.max_idle_conns = if (self.max_open_conns > 0 and n > self.max_open_conns)
            self.max_open_conns
        else
            n;
        var closed_any = false;
        while (self.free_count > self.max_idle_conns) {
            const pc = self.popFree().?;
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.max_idle_closed += 1;
            closed_any = true;
        }
        if (closed_any) {
            self.pool_changed.broadcast(self.io);
        }
    }

    /// SetConnMaxLifetime sets the maximum amount of time a connection may be reused.
    pub fn setConnMaxLifetime(self: *DB, duration_ns: ?u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.conn_max_lifetime_ns = duration_ns;
    }

    /// SetConnMaxIdleTime sets the maximum amount of time a connection may be idle.
    /// Expired connections may be closed lazily before reuse.
    pub fn setConnMaxIdleTime(self: *DB, duration_ns: ?u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.conn_max_idle_time_ns = duration_ns;
    }

    /// Stats returns database statistics.
    pub fn stats(self: *DB) DBStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idle = self.free_count;
        return .{
            .max_open_connections = self.max_open_conns,
            .open_connections = self.num_open,
            .in_use = self.num_open - idle,
            .idle = idle,
            .wait_count = self.wait_count,
            .wait_duration_ns = self.wait_duration_ns,
            .max_idle_closed = self.max_idle_closed,
            .max_idle_time_closed = self.max_idle_time_closed,
            .max_lifetime_closed = self.max_lifetime_closed,
        };
    }

    /// Executes `func(ctx, pc)` on an acquired connection, discarding and retrying once
    /// if a recycled idle connection fails with `error.ErrBadConn`.
    inline fn runWithRetry(
        self: *DB,
        deadline: Deadline,
        comptime release_on_success: bool,
        ctx: anytype,
        comptime func: anytype,
    ) !@typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.payload {
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.acquireConn(deadline);
            const result = func(ctx, pc) catch |err| {
                if (err == error.ErrBadConn) {
                    const from_pool = pc.from_pool;
                    self.discardConn(pc);
                    if (from_pool) {
                        if (retry == 0) continue;
                    }
                    return err;
                }
                pc.release();
                return err;
            };
            if (release_on_success) {
                pc.release();
            }
            return result;
        }
        return error.ErrBadConn;
    }

    /// Ping verifies a connection to the database is still alive, establishing a
    /// connection if necessary. If an idle connection fails with ErrBadConn, it is
    /// discarded and retried once with a fresh connection.
    pub fn ping(self: *DB, deadline: Deadline) !void {
        const Op = struct {
            io: std.Io,
            dl: Deadline,
            fn run(op: @This(), pc: *PooledConn) !void {
                return pc.raw.ping(op.io, op.dl);
            }
        };
        return self.runWithRetry(deadline, true, Op{ .io = self.io, .dl = deadline }, Op.run);
    }

    /// Conn returns a single exclusive connection by either opening a new connection
    /// or returning an existing connection from the free pool.
    /// Call `conn.close()` (idempotent) when done to return it to the pool.
    pub fn conn(self: *DB, deadline: Deadline) !Conn {
        const pc = try self.acquireConn(deadline);
        errdefer pc.release();

        const state = try self.allocator.create(ConnState);
        state.* = .{
            .allocator = self.allocator,
            .pooled_conn = pc,
        };
        return Conn{ .state = state };
    }

    fn acquireConn(self: *DB, deadline: Deadline) !*PooledConn {
        try self.checkOperation(deadline);
        _ = self.ref_count.fetchAdd(1, .acquire);
        defer self.decrementRef();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            try driver_pkg.checkOperation(self.io, deadline);
            if (self.closed) return error.DBClosed;

            const now = self.currentNanoTimestamp();

            // 1. Try to find a valid idle connection
            while (self.popFree()) |pc| {
                if (self.conn_max_lifetime_ns) |max_life| {
                    if (now - pc.created_at_ns > max_life) {
                        pc.raw.close();
                        self.allocator.destroy(pc);
                        self.num_open -= 1;
                        self.max_lifetime_closed += 1;
                        self.pool_changed.signal(self.io);
                        continue;
                    }
                }
                if (self.conn_max_idle_time_ns) |max_idle| {
                    if (now - pc.last_used_at_ns > max_idle) {
                        pc.raw.close();
                        self.allocator.destroy(pc);
                        self.num_open -= 1;
                        self.max_idle_time_closed += 1;
                        self.pool_changed.signal(self.io);
                        continue;
                    }
                }
                pc.last_used_at_ns = now;
                pc.from_pool = true;
                self.pushActive(pc);
                _ = self.ref_count.fetchAdd(1, .acquire);
                return pc;
            }

            // 2. Open a new connection if under max_open_conns
            if (self.max_open_conns == 0 or self.num_open < self.max_open_conns) {
                self.num_open += 1;
                // Temporarily release mutex while opening connection to avoid
                // blocking other threads.
                self.mutex.unlock(self.io);
                var raw_conn = self.driver_instance.open(
                    self.io,
                    self.dsn,
                    deadline,
                ) catch |err| {
                    self.mutex.lockUncancelable(self.io);
                    self.num_open -= 1;
                    self.pool_changed.signal(self.io);
                    return err;
                };
                self.mutex.lockUncancelable(self.io);

                if (self.closed) {
                    raw_conn.close();
                    self.num_open -= 1;
                    self.pool_changed.signal(self.io);
                    return error.DBClosed;
                }

                const pc = self.allocator.create(PooledConn) catch |create_err| {
                    self.mutex.unlock(self.io);
                    raw_conn.close();
                    self.mutex.lockUncancelable(self.io);
                    self.num_open -= 1;
                    self.pool_changed.signal(self.io);
                    return create_err;
                };
                pc.* = .{
                    .raw = raw_conn,
                    .created_at_ns = self.currentNanoTimestamp(),
                    .last_used_at_ns = self.currentNanoTimestamp(),
                    .db = self,
                    .from_pool = false,
                };
                self.pushActive(pc);
                _ = self.ref_count.fetchAdd(1, .acquire);
                return pc;
            }

            // 3. Wait until capacity changes or the task is canceled.
            self.wait_count += 1;
            const wait_started = std.Io.Clock.awake.now(self.io).nanoseconds;
            const wait_result = self.pool_changed.waitTimeout(
                self.io,
                &self.mutex,
                deadline.timeout(),
            );
            const waited = std.Io.Clock.awake.now(self.io).nanoseconds - wait_started;
            if (waited > 0) {
                self.wait_duration_ns +|= std.math.cast(u64, waited) orelse std.math.maxInt(u64);
            }
            wait_result catch |err| switch (err) {
                error.Timeout => {
                    try deadline.check(self.io);
                    continue;
                },
                error.Canceled => return error.Canceled,
            };
        }
    }

    fn putConn(self: *DB, pc: *PooledConn) void {
        self.mutex.lockUncancelable(self.io);
        self.pool_changed.signal(self.io);

        self.removeActive(pc);

        if (self.closed or pc.bad) {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.mutex.unlock(self.io);
            self.decrementRef();
            return;
        }

        const now = self.currentNanoTimestamp();
        if (self.conn_max_lifetime_ns) |max_life| {
            if (now - pc.created_at_ns > max_life) {
                pc.raw.close();
                self.allocator.destroy(pc);
                self.num_open -= 1;
                self.max_lifetime_closed += 1;
                self.mutex.unlock(self.io);
                self.decrementRef();
                return;
            }
        }

        if (self.free_count >= self.max_idle_conns) {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.max_idle_closed += 1;
            self.mutex.unlock(self.io);
            self.decrementRef();
            return;
        }

        pc.last_used_at_ns = now;
        pc.from_pool = false;
        self.pushFree(pc);
        self.mutex.unlock(self.io);
        self.decrementRef();
    }

    /// Discards a bad connection from the pool permanently.
    fn discardConn(self: *DB, pc: *PooledConn) void {
        self.mutex.lockUncancelable(self.io);
        self.pool_changed.signal(self.io);
        self.removeActive(pc);
        pc.raw.close();
        self.allocator.destroy(pc);
        self.num_open -= 1;
        self.mutex.unlock(self.io);

        self.decrementRef();
    }

    /// Exec executes a query without returning any rows. If an idle connection
    /// from the pool fails with ErrBadConn, it retries once with a fresh connection.
    ///
    /// Argument Conventions (`args: anytype`):
    /// - Positional arguments: pass an anonymous tuple `.{ arg1, arg2 }` for `?` placeholders.
    /// - Named arguments: pass an anonymous struct literal `.{ .name = "Alice", .age = 30 }`
    ///   for `:name`, `@name`, or `$name` placeholders.
    /// - No arguments: pass an empty tuple `.{}`.
    /// - Batch struct mapping: directly pass a struct instance (e.g., `stmt.exec(item, dl)`).
    ///
    /// Supported Field & Value Types:
    /// - Integers (`i8`..`i64`, `u8`..`u64`, `comptime_int`)
    /// - Floats (`f32`, `f64`, `comptime_float`)
    /// - Booleans (`bool`)
    /// - Strings & byte slices (`[]const u8`, `*const [N]u8`)
    /// - Optionals (`?T`), automatically unwrapped or bound to NULL
    /// - Enums (automatically encoded as tag names)
    /// - `stdgo.time.Time` (automatically encoded as Unix epoch wall seconds)
    ///
    /// Anti-pattern Warning:
    /// Do NOT mix positional (`?`) and named (`:name`) placeholders in a single SQL query.
    /// Tuples are strictly mapped to positional bindings, and structs are strictly mapped
    /// to named bindings.
    pub fn exec(self: *DB, query_str: []const u8, args: anytype, deadline: Deadline) !Result {
        const Op = struct {
            q: []const u8,
            a: @TypeOf(args),
            dl: Deadline,
            fn run(op: @This(), pc: *PooledConn) !Result {
                return pc.exec(op.q, op.a, op.dl);
            }
        };
        return self.runWithRetry(
            deadline,
            true,
            Op{ .q = query_str, .a = args, .dl = deadline },
            Op.run,
        );
    }

    /// Query executes a query that returns rows, typically a SELECT. If an idle
    /// connection from the pool fails with ErrBadConn, it retries once with fresh conn.
    ///
    /// Accepts positional tuples `.{ id }`, named structs `.{ .status = "active" }`,
    /// or empty tuples `.{}` for arguments. See `exec` for detailed argument conventions.
    /// Slice arguments are defensively copied by drivers (e.g. SQLite) before returning `Rows`,
    /// so caller-owned temporary buffers do not need to remain live until `Rows.close()`.
    /// Use `exec()` instead when no rows are needed and zero-copy parameter binding is desired.
    pub fn query(self: *DB, query_str: []const u8, args: anytype, deadline: Deadline) !Rows {
        const Op = struct {
            q: []const u8,
            a: @TypeOf(args),
            dl: Deadline,
            fn run(op: @This(), pc: *PooledConn) !Rows {
                var rows = try pc.query(op.q, op.a, op.dl);
                rows.pooled_conn = pc;
                rows.error_conn = pc;
                return rows;
            }
        };
        return self.runWithRetry(
            deadline,
            false,
            Op{ .q = query_str, .a = args, .dl = deadline },
            Op.run,
        );
    }

    /// QueryRow executes a query that is expected to return at most one row.
    ///
    /// Accepts positional tuples `.{ id }`, named structs `.{ .status = "active" }`,
    /// or empty tuples `.{}` for arguments. See `exec` for detailed argument conventions.
    pub fn queryRow(self: *DB, query_str: []const u8, args: anytype, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// InterruptAll signals all active/in-flight queries across the pool to abort out-of-band.
    /// Returns the number of connections that were successfully signaled.
    pub fn interruptAll(self: *DB) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        var curr = self.active_head;
        while (curr) |pc| {
            if (pc.interrupt()) {
                count += 1;
            }
            curr = pc.next;
        }
        return count;
    }

    /// BeginTx starts a transaction with options.
    pub fn beginTx(self: *DB, opts: TxOptions, deadline: Deadline) !Tx {
        const Op = struct {
            o: TxOptions,
            dl: Deadline,
            fn run(op: @This(), pc: *PooledConn) !Tx {
                return pc.beginTxInternal(op.o, op.dl, true, null);
            }
        };
        return self.runWithRetry(deadline, false, Op{ .o = opts, .dl = deadline }, Op.run);
    }

    /// Begin starts a transaction with default options.
    pub fn begin(self: *DB, deadline: Deadline) !Tx {
        return self.beginTx(.{}, deadline);
    }

    /// Prepare creates a prepared statement for later queries or executions.
    /// If an idle connection fails with ErrBadConn, it is discarded and retried once.
    ///
    /// Note: Unlike Go's `database/sql.DB.Prepare`, the returned `Stmt` holds one
    /// dedicated pooled connection until `stmt.close()` is called. Always close
    /// statements promptly (do not cache `DB.prepare` statements across requests).
    pub fn prepare(self: *DB, query_str: []const u8, deadline: Deadline) !Stmt {
        const Op = struct {
            db: *DB,
            q: []const u8,
            dl: Deadline,
            fn run(op: @This(), pc: *PooledConn) !Stmt {
                var raw_stmt = try pc.raw.prepare(op.db.io, op.q, op.dl);
                errdefer raw_stmt.close();

                const state = try op.db.allocator.create(StmtState);
                state.* = .{
                    .allocator = op.db.allocator,
                    .raw_stmt = raw_stmt,
                    .pooled_conn = pc,
                    .owns_conn = true,
                    .tx_state = null,
                    .from_tx = false,
                    .active_rows = null,
                    .ref_count = 1,
                };
                return Stmt{
                    .state = state,
                    .io = op.db.io,
                    .from_tx = false,
                };
            }
        };
        return self.runWithRetry(
            deadline,
            false,
            Op{ .db = self, .q = query_str, .dl = deadline },
            Op.run,
        );
    }
};

/// Rows is the result of a query. Its cursor starts before the first row of the result set.
/// Use Next to advance through the rows.
pub const Rows = struct {
    pooled_conn: ?*PooledConn,
    error_conn: ?*PooledConn = null,
    stmt: ?driver.Stmt = null,
    raw_rows: driver.Rows,
    io: std.Io,
    closed: bool = false,
    last_err: ?anyerror = null,
    rows_state: ?*RowsState = null,
    invalidation_err: ?anyerror = null,

    fn syncInvalidation(self: *Rows) ?anyerror {
        if (self.invalidation_err) |e| return e;
        if (self.rows_state) |rows_state| {
            if (rows_state.closed) {
                const invalidation_err = rows_state.invalidation_err;
                self.invalidation_err = invalidation_err;
                if (invalidation_err) |e| {
                    self.last_err = e;
                }
                self.close();
                return invalidation_err;
            }
        }
        return null;
    }

    /// ColumnCount returns the number of columns in the result set.
    pub fn columnCount(self: *Rows) usize {
        if (self.syncInvalidation() != null) return 0;
        if (self.closed) return 0;
        return self.raw_rows.columnCount();
    }

    /// ColumnName returns the name of the column at the given 0-based index.
    /// Note: The returned slice borrows driver memory and is only valid until `Rows.close()`.
    pub fn columnName(self: *Rows, index: usize) []const u8 {
        if (self.syncInvalidation() != null) return "";
        if (self.closed) return "";
        return self.raw_rows.columnName(index);
    }

    /// ColumnType returns column metadata for the given 0-based column index.
    /// Returns error.ColumnIndexOutOfBounds if index >= columnCount().
    /// Note: String fields in the returned `ColumnType` (such as `name()` and
    /// `databaseTypeName()`) borrow driver memory and are only valid until `Rows.close()`.
    pub fn columnType(self: *Rows, index: usize) !ColumnType {
        if (self.syncInvalidation()) |e| return e;
        if (self.closed) return error.ColumnIndexOutOfBounds;
        const count = self.columnCount();
        if (index >= count) return error.ColumnIndexOutOfBounds;

        var ct = ColumnType{
            .col_name = self.columnName(index),
        };
        if (self.raw_rows.vtable.columnTypeDatabaseTypeName) |f| {
            ct.raw_type_name = f(self.raw_rows.ptr, index);
        }
        if (self.raw_rows.vtable.columnTypeNullable) |f| {
            ct.nullable_val = f(self.raw_rows.ptr, index);
        }
        if (self.raw_rows.vtable.columnTypeLength) |f| {
            ct.length_val = f(self.raw_rows.ptr, index);
        }
        if (self.raw_rows.vtable.columnTypePrecisionScale) |f| {
            ct.decimal_size = f(self.raw_rows.ptr, index);
        }
        return ct;
    }

    /// Next advances to the next row of the result set.
    /// Note: Value.string and Value.bytes in the scanned destination borrow memory
    /// from the underlying statement and are only valid until the next call to Next or Close.
    pub fn next(self: *Rows, dest: []Value, deadline: Deadline) !bool {
        if (self.syncInvalidation()) |e| return e;
        if (self.closed) return false;
        try driver_pkg.checkOperation(self.io, deadline);
        const has_more = self.raw_rows.next(self.io, dest, deadline) catch |next_error| {
            if (next_error == error.Canceled or next_error == error.InvalidDeadline) {
                return next_error;
            }
            self.last_err = next_error;
            self.close();
            return next_error;
        };
        if (!has_more) {
            self.last_err = self.raw_rows.err();
            self.close();
            if (self.last_err) |row_error| return row_error;
        }
        return has_more;
    }

    fn nextStructInternal(
        self: *Rows,
        comptime T: type,
        deadline: Deadline,
        overflow_allocator: ?Allocator,
    ) !?T {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("expected a struct type, found " ++ @typeName(T));
        }
        if (self.syncInvalidation()) |e| return e;
        if (self.closed) return null;
        try driver_pkg.checkOperation(self.io, deadline);

        const col_count = self.columnCount();
        var stack_buf: [max_stack_scan_columns]Value = undefined;
        var heap_buf: ?[]Value = null;
        defer if (heap_buf) |buf| overflow_allocator.?.free(buf);

        const dest = if (col_count > max_stack_scan_columns) blk: {
            const alloc = overflow_allocator orelse {
                self.last_err = error.TooManyColumns;
                return error.TooManyColumns;
            };
            const buf = try alloc.alloc(Value, col_count);
            heap_buf = buf;
            break :blk buf;
        } else stack_buf[0..col_count];

        const mapping = resolveColumnMapping(self, T, col_count) catch |map_err| {
            self.last_err = map_err;
            return map_err;
        };

        const has_row = try self.next(dest, deadline);
        if (!has_row) return null;
        return scanValuesByMapping(T, dest, &mapping) catch |scan_err| {
            self.last_err = scan_err;
            return scan_err;
        };
    }

    /// NextStruct decodes the next row directly into a strongly-typed struct at compile time.
    /// Columns are matched strictly by case-sensitive column name (independent of column order,
    /// and extra columns in the query are ignored). For expressions, alias them with `AS`.
    /// Returns `error.ColumnNotFound` if a struct field has no matching column,
    /// `error.AmbiguousColumnName` if multiple columns share a field's name,
    /// `error.TooManyColumns` if the result set exceeds 128 columns, or `null` when
    /// iteration finishes cleanly.
    /// Note: Any string or slice fields in the returned struct borrow memory from the
    /// underlying statement and are only valid until the next call to Next, NextStruct, or Close.
    pub fn nextStruct(self: *Rows, comptime T: type, deadline: Deadline) !?T {
        return self.nextStructInternal(T, deadline, null);
    }

    /// NextStructOwned decodes the next row into an `Owned(T)` wrapper, duplicating any
    /// `[]const u8` or `Blob` fields using `allocator` so the returned value can outlive
    /// subsequent `next*` calls and `Rows.close()`.
    /// Columns are matched strictly by case-sensitive column name (independent of column order,
    /// and extra columns in the query are ignored). For expressions, alias them with `AS`.
    /// Returns `error.ColumnNotFound` if a struct field has no matching column,
    /// `error.AmbiguousColumnName` if multiple columns share a field's name, or `null` when
    /// iteration finishes cleanly. Call `defer owned.deinit()` on each non-null item.
    pub fn nextStructOwned(
        self: *Rows,
        allocator: Allocator,
        comptime T: type,
        deadline: Deadline,
    ) !?Owned(T) {
        const borrowed = (try self.nextStructInternal(T, deadline, allocator)) orelse return null;
        return try dupeOwnedStruct(allocator, T, borrowed);
    }

    /// Err returns the error, if any, that was encountered during iteration.
    /// Returns null if iteration finished cleanly.
    pub fn err(self: *Rows) ?anyerror {
        if (self.syncInvalidation()) |e| return e;
        if (self.closed) return self.last_err;
        return self.last_err orelse self.raw_rows.err();
    }

    /// LastError returns the error message for the last operation on the underlying connection.
    /// Note: The returned error message slice borrows memory from the driver/connection.
    /// It is only valid while the connection has not performed a subsequent operation and
    /// before the Rows iterator is closed and the connection returned to the pool.
    pub fn lastError(self: *Rows) ?[]const u8 {
        if (self.syncInvalidation() != null) return null;
        if (self.closed) return null;
        if (self.pooled_conn orelse self.error_conn) |pc| return pc.lastError();
        return null;
    }

    /// Close closes the Rows iterator, preventing further enumeration and releasing
    /// any underlying statement or pooled connection owned by this iterator.
    pub fn close(self: *Rows) void {
        if (self.closed) return;
        self.closed = true;
        self.error_conn = null;

        if (self.rows_state) |rows_state| {
            self.rows_state = null;
            rows_state.closeAndDetach(null);
            rows_state.release();
            return;
        }

        self.raw_rows.close();
        if (self.stmt) |*s| {
            s.close();
        }
        if (self.pooled_conn) |pc| {
            pc.release();
            self.pooled_conn = null;
        }
    }
};

/// Internal heap-allocated state for an active transaction, keeping pointer stability
/// across value moves of `Tx`.
const TxState = struct {
    allocator: Allocator,
    pooled_conn: ?*PooledConn,
    owns_conn: bool = true,
    conn_state: ?*ConnState = null,
    raw_tx: driver.Tx,
    done: bool = false,
    invalidation_err: ?anyerror = null,
    ref_count: usize = 1,
    stmts_head: ?*StmtState = null,
    rows_head: ?*RowsState = null,

    fn release(self: *TxState) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.allocator.destroy(self);
        }
    }

    fn closeResources(self: *TxState, invalidation_err: anyerror) void {
        // Close open rows before finalizing prepared statements, since Stmt.query
        // cursors borrow the underlying driver.Stmt handle.
        while (self.rows_head) |rows_state| {
            rows_state.closeAndDetach(invalidation_err);
        }

        var current_stmt = self.stmts_head;
        self.stmts_head = null;
        while (current_stmt) |state| {
            const next = state.next;
            state.next = null;
            state.prev = null;
            state.tx_state = null;
            if (!state.closed) {
                state.closed = true;
                state.invalidation_err = invalidation_err;
                std.debug.assert(state.active_rows == null);
                state.raw_stmt.close();
            }
            state.release(); // release Tx's reference
            current_stmt = next;
        }
    }
};

/// Internal tracked state for query rows bound to a Conn, Tx, or Stmt, ensuring result cursors
/// are closed before their underlying statement, transaction, or connection is finalized.
const RowsState = struct {
    allocator: Allocator,
    raw_rows: driver.Rows,
    owned_stmt: ?driver.Stmt = null,
    conn_state: ?*ConnState = null,
    tx_state: ?*TxState = null,
    stmt_state: ?*StmtState = null,
    invalidation_err: ?anyerror = null,
    closed: bool = false,
    ref_count: usize = 1,
    conn_next: ?*RowsState = null,
    conn_prev: ?*RowsState = null,
    tx_next: ?*RowsState = null,
    tx_prev: ?*RowsState = null,

    fn release(self: *RowsState) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.allocator.destroy(self);
        }
    }

    fn closeAndDetach(self: *RowsState, invalidation_err: ?anyerror) void {
        if (self.closed) return;
        self.closed = true;
        if (invalidation_err) |e| {
            self.invalidation_err = e;
        }

        var release_conn_ref = false;
        if (self.conn_state) |conn_state| {
            if (self.conn_prev) |prev| {
                prev.conn_next = self.conn_next;
            } else if (conn_state.rows_head == self) {
                conn_state.rows_head = self.conn_next;
            }
            if (self.conn_next) |next_rows_state| {
                next_rows_state.conn_prev = self.conn_prev;
            }
            self.conn_next = null;
            self.conn_prev = null;
            self.conn_state = null;
            release_conn_ref = true;
        }

        var release_tx_ref = false;
        if (self.tx_state) |tx_state| {
            if (self.tx_prev) |prev| {
                prev.tx_next = self.tx_next;
            } else if (tx_state.rows_head == self) {
                tx_state.rows_head = self.tx_next;
            }
            if (self.tx_next) |next_rows_state| {
                next_rows_state.tx_prev = self.tx_prev;
            }
            self.tx_next = null;
            self.tx_prev = null;
            self.tx_state = null;
            release_tx_ref = true;
        }

        var release_stmt_ref = false;
        if (self.stmt_state) |stmt_state| {
            if (stmt_state.active_rows == self) {
                stmt_state.active_rows = null;
            }
            self.stmt_state = null;
            release_stmt_ref = true;
        }

        self.raw_rows.close();
        if (self.owned_stmt) |*s| {
            s.close();
            self.owned_stmt = null;
        }

        if (release_conn_ref) self.release();
        if (release_tx_ref) self.release();
        if (release_stmt_ref) self.release();
        std.debug.assert(self.ref_count >= 1);
    }
};

/// Internal tracked state for prepared statements, supporting automatic lifetime
/// management and invalidation when bound to a connection, transaction, or owning active rows.
const StmtState = struct {
    allocator: Allocator,
    raw_stmt: driver.Stmt,
    pooled_conn: ?*PooledConn = null,
    owns_conn: bool = true,
    conn_state: ?*ConnState = null,
    tx_state: ?*TxState = null,
    from_tx: bool = false,
    active_rows: ?*RowsState = null,
    invalidation_err: ?anyerror = null,
    closed: bool = false,
    ref_count: usize = 1,
    conn_next: ?*StmtState = null,
    conn_prev: ?*StmtState = null,
    next: ?*StmtState = null,
    prev: ?*StmtState = null,

    fn release(self: *StmtState) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.allocator.destroy(self);
        }
    }
};

/// Tx is an in-progress database transaction.
///
/// A transaction wraps a single pooled connection and is not safe for concurrent
/// use without caller-side synchronization. It must end with a call to Commit or
/// Rollback, which releases the underlying pooled connection back to the DB pool.
pub const Tx = struct {
    state: ?*TxState,

    const FinishMode = enum { commit, rollback };

    fn finish(self: *Tx, comptime mode: FinishMode, deadline: Deadline) !void {
        const state = self.state orelse return error.TxDone;
        if (state.done) {
            const invalidation_err = state.invalidation_err orelse error.TxDone;
            self.state = null;
            state.release();
            return invalidation_err;
        }
        const connection = state.pooled_conn orelse return error.TxDone;
        const owns_conn = state.owns_conn;
        const io = connection.db.io;
        switch (mode) {
            .commit => try driver_pkg.checkOperation(io, deadline),
            .rollback => {
                try deadline.validate();
                if (!deadline.isNone()) {
                    try driver_pkg.checkOperation(io, deadline);
                }
            },
        }
        if (state.conn_state) |cs| {
            if (cs.active_tx == state) {
                cs.active_tx = null;
            }
            state.conn_state = null;
            state.release(); // release Conn's reference
        }
        state.done = true;
        state.closeResources(error.TxDone);
        state.pooled_conn = null;
        self.state = null;
        defer state.release();
        const op_res = switch (mode) {
            .commit => state.raw_tx.vtable.commit(state.raw_tx.ptr, io, deadline),
            .rollback => state.raw_tx.vtable.rollback(state.raw_tx.ptr, io, deadline),
        };
        op_res catch |err| {
            if (owns_conn) {
                connection.db.discardConn(connection);
            } else {
                connection.bad = true;
            }
            return err;
        };
        if (owns_conn) {
            connection.release();
        }
    }

    /// Commits the transaction and returns the connection to the pool (if owned by this Tx).
    pub fn commit(self: *Tx, deadline: Deadline) !void {
        return self.finish(.commit, deadline);
    }

    /// Aborts and rolls back the transaction, returning the connection to the pool (if owned).
    ///
    /// Idiomatic usage is `defer tx.rollback(.none) catch {};` right after `begin()`/`beginTx()`
    /// (preferred over `errdefer`, so normal early returns also release the connection).
    /// If `commit()` has already succeeded, `rollback()` immediately returns `error.TxDone`
    /// without touching the underlying driver or database.
    pub fn rollback(self: *Tx, deadline: Deadline) !void {
        return self.finish(.rollback, deadline);
    }

    const Active = struct {
        state: *TxState,
        pc: *PooledConn,
    };

    fn active(self: *Tx) !Active {
        const state = self.state orelse return error.TxDone;
        if (state.done) return state.invalidation_err orelse error.TxDone;
        const pc = state.pooled_conn orelse return error.TxDone;
        return .{ .state = state, .pc = pc };
    }

    /// LastError returns the error message for the last operation on this transaction's connection.
    /// The returned slice borrows driver memory and is only valid until the next operation
    /// on this transaction or `commit()`/`rollback()`.
    pub fn lastError(self: *Tx) ?[]const u8 {
        const a = self.active() catch return null;
        return a.pc.lastError();
    }

    /// Executes a query within the transaction that does not return rows (e.g. INSERT, UPDATE).
    /// Accepts positional tuples `.{ ... }`, named structs `.{ .name = ... }`, or empty `.{}`.
    pub fn exec(self: *Tx, query_str: []const u8, args: anytype, deadline: Deadline) !Result {
        const a = try self.active();
        return a.pc.exec(query_str, args, deadline);
    }

    /// The transaction connection remains tied to this transaction until commit or rollback.
    pub fn query(self: *Tx, query_str: []const u8, args: anytype, deadline: Deadline) !Rows {
        const a = try self.active();
        var rows = try a.pc.query(query_str, args, deadline);
        errdefer rows.close();

        const rows_state = try a.pc.db.allocator.create(RowsState);
        rows_state.* = .{
            .allocator = a.pc.db.allocator,
            .raw_rows = rows.raw_rows,
            .owned_stmt = rows.stmt,
            .tx_state = a.state,
            .stmt_state = null,
            .ref_count = 2,
            .tx_next = a.state.rows_head,
            .tx_prev = null,
        };
        if (a.state.rows_head) |head| {
            head.tx_prev = rows_state;
        }
        a.state.rows_head = rows_state;

        rows.stmt = null;
        rows.rows_state = rows_state;
        rows.pooled_conn = null; // Tx retains connection until commit/rollback
        rows.error_conn = a.pc;
        return rows;
    }

    /// QueryRow executes a query within the transaction expecting at most one row.
    pub fn queryRow(self: *Tx, query_str: []const u8, args: anytype, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// Prepare creates a prepared statement for use within a transaction.
    /// The returned Stmt operates on the transaction's connection and will be
    /// closed when the transaction commits or rolls back, or when stmt.close() is called.
    pub fn prepare(self: *Tx, query_str: []const u8, deadline: Deadline) !Stmt {
        const a = try self.active();
        const io = a.pc.db.io;
        try a.pc.db.checkOperation(deadline);
        var raw_stmt = try a.pc.raw.prepare(io, query_str, deadline);
        errdefer raw_stmt.close();

        const stmt_state = try a.pc.db.allocator.create(StmtState);
        stmt_state.* = .{
            .allocator = a.pc.db.allocator,
            .raw_stmt = raw_stmt,
            .pooled_conn = null,
            .tx_state = a.state,
            .from_tx = true,
            .active_rows = null,
            .ref_count = 2,
            .next = a.state.stmts_head,
            .prev = null,
        };
        if (a.state.stmts_head) |head| {
            head.prev = stmt_state;
        }
        a.state.stmts_head = stmt_state;

        return Stmt{
            .state = stmt_state,
            .io = io,
            .from_tx = true,
        };
    }
};

/// Stmt is a prepared statement bound to a database connection.
/// Note: A Stmt wraps a single underlying driver statement on a pooled connection;
/// concurrent executions on the same Stmt instance are not supported without caller-side
/// synchronization. Callers must call close() when the statement is no longer needed.
pub const Stmt = struct {
    state: ?*StmtState,
    io: std.Io,
    from_tx: bool = false,
    closed: bool = false,

    fn prepareExecution(self: *Stmt, deadline: Deadline) !*StmtState {
        if (self.closed) {
            if (self.from_tx) return error.TxDone;
            return error.StmtClosed;
        }
        const state = self.state orelse {
            if (self.from_tx) return error.TxDone;
            return error.StmtClosed;
        };
        if (state.closed) {
            if (state.invalidation_err) |e| return e;
            if (self.from_tx) return error.TxDone;
            return error.StmtClosed;
        }
        if (state.tx_state) |tx_state| {
            if (tx_state.done) return tx_state.invalidation_err orelse error.TxDone;
        }
        if (state.pooled_conn) |pc| {
            try pc.db.checkOperation(deadline);
        }
        try driver_pkg.checkOperation(self.io, deadline);
        if (state.active_rows) |prev_rows_state| {
            prev_rows_state.closeAndDetach(null);
        }
        return state;
    }

    /// Exec executes a prepared statement with the given arguments and
    /// returns a Result summarizing the effect of the statement.
    ///
    /// Accepts positional tuples `.{ ... }`, named structs `.{ .name = ... }`,
    /// directly passed struct instances (batch execution), or empty tuples `.{}`.
    pub fn exec(self: *Stmt, args: anytype, deadline: Deadline) !Result {
        const state = try self.prepareExecution(deadline);
        const Runner = struct {
            state: *StmtState,
            io: std.Io,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Result {
                return r.state.raw_stmt.exec(r.io, nv, r.dl);
            }
        };
        return withNamedValues(
            args,
            Runner{ .state = state, .io = self.io, .dl = deadline },
            Runner.invoke,
        );
    }

    /// Query executes a prepared query statement with the given arguments
    /// and returns the query results as Rows.
    /// Slice arguments are defensively copied by drivers (e.g. SQLite) before returning `Rows`,
    /// so caller-owned temporary buffers do not need to remain live until `Rows.close()`.
    /// Use `exec()` instead when no rows are needed and zero-copy parameter binding is desired.
    pub fn query(self: *Stmt, args: anytype, deadline: Deadline) !Rows {
        const state = try self.prepareExecution(deadline);
        const Runner = struct {
            state: *StmtState,
            io: std.Io,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Rows {
                var raw_rows = try r.state.raw_stmt.query(r.io, nv, r.dl);
                errdefer raw_rows.close();

                if (r.state.tx_state) |tx_state| {
                    if (tx_state.done) return tx_state.invalidation_err orelse error.TxDone;
                }

                const rows_state = try r.state.allocator.create(RowsState);
                rows_state.* = .{
                    .allocator = r.state.allocator,
                    .raw_rows = raw_rows,
                    .owned_stmt = null,
                    .tx_state = r.state.tx_state,
                    .stmt_state = r.state,
                    .ref_count = if (r.state.tx_state != null) 3 else 2,
                };
                if (r.state.tx_state) |tx_state| {
                    rows_state.tx_next = tx_state.rows_head;
                    if (tx_state.rows_head) |head| {
                        head.tx_prev = rows_state;
                    }
                    tx_state.rows_head = rows_state;
                }
                r.state.active_rows = rows_state;

                const err_conn: ?*PooledConn = r.state.pooled_conn orelse
                    if (r.state.tx_state) |ts| ts.pooled_conn else null;

                return Rows{
                    .pooled_conn = null, // Connection remains held by Stmt or Tx
                    .error_conn = err_conn,
                    .stmt = null,
                    .raw_rows = raw_rows,
                    .io = r.io,
                    .rows_state = rows_state,
                };
            }
        };
        return withNamedValues(
            args,
            Runner{ .state = state, .io = self.io, .dl = deadline },
            Runner.invoke,
        );
    }

    /// QueryRow executes a prepared query statement that is expected to return at most one row.
    pub fn queryRow(self: *Stmt, args: anytype, deadline: Deadline) Row {
        const r = self.query(args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// LastError returns the error message for the last operation on this statement's connection.
    /// The returned slice borrows driver memory and is only valid until the next operation
    /// on this statement/connection or `stmt.close()`.
    pub fn lastError(self: *Stmt) ?[]const u8 {
        if (self.closed) return null;
        const state = self.state orelse return null;
        if (state.closed) return null;
        if (state.tx_state) |tx_state| {
            if (tx_state.done) return null;
            if (tx_state.pooled_conn) |pc| return pc.lastError();
            return null;
        }
        if (state.pooled_conn) |pc| return pc.lastError();
        return null;
    }

    /// Close closes the statement and releases its connection back to the pool (if owned).
    pub fn close(self: *Stmt) void {
        if (self.closed) return;
        self.closed = true;
        const state = self.state orelse return;
        self.state = null;
        if (!state.closed) {
            state.closed = true;
            if (state.active_rows) |rows_state| {
                const invalidation_err: anyerror = if (state.from_tx)
                    error.TxDone
                else
                    error.StmtClosed;
                rows_state.closeAndDetach(invalidation_err);
            }
            std.debug.assert(state.active_rows == null);
            state.raw_stmt.close();
            if (state.pooled_conn) |pc| {
                if (state.owns_conn) {
                    pc.release();
                }
                state.pooled_conn = null;
            }
            if (state.conn_state) |conn_state| {
                if (state.conn_prev) |prev| {
                    prev.conn_next = state.conn_next;
                } else if (conn_state.stmts_head == state) {
                    conn_state.stmts_head = state.conn_next;
                }
                if (state.conn_next) |next| {
                    next.conn_prev = state.conn_prev;
                }
                state.conn_next = null;
                state.conn_prev = null;
                state.conn_state = null;
                state.release(); // release Conn's reference
            }
            if (state.tx_state) |tx_state| {
                if (state.prev) |prev| {
                    prev.next = state.next;
                } else if (tx_state.stmts_head == state) {
                    tx_state.stmts_head = state.next;
                }
                if (state.next) |next| {
                    next.prev = state.prev;
                }
                state.next = null;
                state.prev = null;
                state.tx_state = null;
                state.release(); // release Tx's reference
            }
        }
        state.release(); // release Stmt's reference
    }
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "database.sql: basic open, ping, exec, query and close" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Ping
    try db.ping(.none);
    var s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.open_connections);
    try testing.expectEqual(@as(usize, 1), s.idle);

    // 2. Exec
    const ins_query = "INSERT INTO users (name) VALUES (?)";
    const res = try db.exec(ins_query, &.{Value{ .string = "charlie" }}, .none);
    try testing.expectEqual(@as(i64, 1001), try res.lastInsertId());
    try testing.expectEqual(@as(i64, 1), try res.rowsAffected());

    // 3. Query
    var rows = try db.query("SELECT id, name, role FROM users", &.{}, .none);
    defer rows.close();

    try testing.expectEqual(@as(usize, 3), rows.columnCount());
    try testing.expectEqualStrings("id", rows.columnName(0));

    var record: [3]Value = undefined;
    var count: usize = 0;
    while (try rows.next(&record, .none)) {
        count += 1;
        if (count == 1) {
            try testing.expectEqual(@as(i64, 1), record[0].int);
            try testing.expectEqualStrings("alice", record[1].string);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);

    // After rows closed, connection is returned to pool
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
}

test "database.sql: transaction commit and rollback" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Commit
    {
        var tx = try db.begin(.none);
        _ = try tx.exec("UPDATE accounts SET balance = balance - 100", &.{}, .none);
        try tx.commit(.none);
        try testing.expectEqual(@as(usize, 1), state.tx_commits);
        // Error on repeated commit
        try testing.expectError(error.TxDone, tx.commit(.none));
    }

    // 2. Rollback
    {
        var tx = try db.begin(.none);
        _ = try tx.exec("DELETE FROM logs", &.{}, .none);
        try tx.rollback(.none);
        try testing.expectEqual(@as(usize, 1), state.tx_rollbacks);
        try testing.expectError(error.TxDone, tx.rollback(.none));
    }
}

test "database.sql: max open and idle connections pool limit" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    db.setMaxOpenConns(2);
    db.setMaxIdleConns(1);

    // Acquire 2 connections
    var c1 = try db.conn(.none);
    var c2 = try db.conn(.none);

    var s = db.stats();
    try testing.expectEqual(@as(usize, 2), s.open_connections);
    try testing.expectEqual(@as(usize, 2), s.in_use);
    try testing.expectEqual(@as(usize, 0), s.idle);

    // Release c1 -> goes to idle
    c1.close();
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.in_use);

    // Release c2 -> max_idle is 1, so c2 is closed!
    c2.close();
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.open_connections);
    try testing.expectEqual(@as(u64, 1), s.max_idle_closed);
}

test "database.sql: concurrent connection pool contention" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // Strict limit: only 2 simultaneous connections allowed
    db.setMaxOpenConns(2);
    db.setMaxIdleConns(2);

    const Worker = struct {
        fn run(db_ptr: *DB) void {
            for (0..20) |_| {
                var pc = db_ptr.conn(.none) catch return;
                defer pc.close();
                // Simulating query execution
                var stmt = pc.prepare("SELECT 1", .none) catch continue;
                defer stmt.close();
                _ = stmt.exec(.{}, .none) catch {};
            }
        }
    };

    // Spawn 4 concurrent threads fighting for 2 connections
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{db});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    const s = db.stats();
    // After all finished, open connections <= 2 and in_use == 0
    try testing.expect(s.open_connections <= 2);
    try testing.expectEqual(@as(usize, 0), s.in_use);
    try testing.expect(state.executed_queries.items.len >= 60);
}

test "database.sql: blocked pool waiter is cancelable and release wakes another waiter" {
    const testing = std.testing;
    const io = testing.io;
    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock");
    defer db.close();
    db.setMaxOpenConns(1);
    var held = try db.conn(.none);
    var held_released = false;
    defer if (!held_released) held.close();

    const Worker = struct {
        fn run(database: *DB, _: std.Io) !void {
            var connection = try database.conn(.none);
            connection.close();
        }

        fn waitForCount(database: *DB, task_io: std.Io, count: u64) !void {
            for (0..1000) |_| {
                if (database.stats().wait_count >= count) return;
                try task_io.sleep(.fromMilliseconds(1), .awake);
            }
            return error.WaiterDidNotBlock;
        }
    };

    var first = try io.concurrent(Worker.run, .{ db, io });
    var first_pending = true;
    defer if (first_pending) {
        first.cancel(io) catch {};
    };
    try Worker.waitForCount(db, io, 1);
    const first_result = first.cancel(io);
    first_pending = false;
    try testing.expectError(error.Canceled, first_result);

    var second = try io.concurrent(Worker.run, .{ db, io });
    var second_pending = true;
    defer if (second_pending) {
        second.cancel(io) catch {};
    };
    try Worker.waitForCount(db, io, 2);
    held.close();
    held_released = true;
    const second_result = second.await(io);
    second_pending = false;
    try second_result;
    try testing.expectEqual(@as(usize, 1), db.stats().idle);
}

test "database.sql: close wakes blocked pool waiter" {
    const testing = std.testing;
    const io = testing.io;
    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock");
    var closed = false;
    defer if (!closed) db.close();
    db.setMaxOpenConns(1);
    var held = try db.conn(.none);
    defer held.close();
    const Worker = struct {
        fn run(database: *DB, _: std.Io) !void {
            var connection = try database.conn(.none);
            connection.close();
        }
    };
    var future = try io.concurrent(Worker.run, .{ db, io });
    var pending = true;
    defer if (pending) {
        future.cancel(io) catch {};
    };
    for (0..1000) |_| {
        if (db.stats().wait_count > 0) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.WaiterDidNotBlock;
    db.close();
    closed = true;
    const result = future.await(io);
    pending = false;
    try testing.expectError(error.DBClosed, result);
}

test "database.sql: failed connection open wakes a pool waiter" {
    const testing = std.testing;
    const io = testing.io;
    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    var mock = MockDriver{ .state = &state };
    const Failing = struct {
        mock_driver: *MockDriver,
        started: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        attempts: std.atomic.Value(usize) = .init(0),

        fn open(
            ptr: *anyopaque,
            task_io: std.Io,
            dsn: []const u8,
            deadline: Deadline,
        ) anyerror!driver.Conn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.attempts.fetchAdd(1, .acq_rel) == 0) {
                self.started.set(task_io);
                try self.gate.wait(task_io);
                return error.OpenFailed;
            }
            return self.mock_driver.driver().open(task_io, dsn, deadline);
        }
    };
    var failing: Failing = .{ .mock_driver = &mock };
    const db = try DB.open(testing.allocator, io, .{
        .ptr = &failing,
        .vtable = &.{ .open = Failing.open },
    }, "mock");
    defer db.close();
    db.setMaxOpenConns(1);
    const Worker = struct {
        fn run(database: *DB, _: std.Io) !void {
            var connection = try database.conn(.none);
            connection.close();
        }
    };
    var first = try io.concurrent(Worker.run, .{ db, io });
    var first_pending = true;
    defer if (first_pending) {
        first.cancel(io) catch {};
    };
    try failing.started.wait(io);
    var second = try io.concurrent(Worker.run, .{ db, io });
    var second_pending = true;
    defer if (second_pending) {
        second.cancel(io) catch {};
    };
    for (0..1000) |_| {
        if (db.stats().wait_count > 0) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.WaiterDidNotBlock;
    failing.gate.set(io);
    const first_result = first.await(io);
    first_pending = false;
    try testing.expectError(error.OpenFailed, first_result);
    const second_result = second.await(io);
    second_pending = false;
    try second_result;
    try testing.expectEqual(@as(usize, 2), failing.attempts.load(.acquire));
}

test "database.sql: interrupt and unsupported deadline" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Single connection interrupt()
    {
        var pc = try db.conn(.none);
        defer pc.close();

        try testing.expect(pc.interrupt());
        try testing.expectEqual(@as(usize, 1), state.interrupt_count);
    }

    // 2. DB.interruptAll() across active pool connections
    {
        var pc1 = try db.conn(.none);
        defer pc1.close();
        var pc2 = try db.conn(.none);
        defer pc2.close();

        const interrupted_count = db.interruptAll();
        try testing.expectEqual(@as(usize, 2), interrupted_count);
        try testing.expectEqual(@as(usize, 3), state.interrupt_count);
    }

    // 3. In compatibility mode, valid deadlines are accepted, expired/invalid
    // deadlines fail properly.
    {
        const deadline = @import("../io/deadline.zig").Deadline.after(io, .fromSeconds(1));
        const invalid: Deadline = .{ .timestamp = .now(io, .real) };
        const expired = @import("../io/deadline.zig").Deadline.after(io, .zero);
        try db.ping(deadline);
        _ = try db.exec("SELECT 1", &.{}, deadline);
        var q_rows = try db.query("SELECT 1", &.{}, deadline);
        q_rows.close();
        try testing.expectError(error.Timeout, db.ping(expired));
        try testing.expectError(error.InvalidDeadline, db.ping(invalid));
    }
}

test "database.sql: QueryRow and ErrNoRows" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Successful QueryRow scan
    {
        var row = db.queryRow("SELECT id, name, role FROM users LIMIT 1", &.{}, .none);
        defer row.close();
        var dest: [3]Value = undefined;
        try row.scan(&dest, .none);
        try testing.expectEqual(@as(i64, 1), dest[0].int);
        try testing.expectEqualStrings("alice", dest[1].string);
    }

    // 2. QueryRow on empty rows gives ErrNoRows
    {
        var row_empty = Row{ .rows = null };
        var dest: [1]Value = undefined;
        try testing.expectError(error.ErrNoRows, row_empty.scan(&dest, .none));
    }
}

test "database.sql: beginTx options and deadline" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. BeginTx options propagation
    {
        var tx = try db.beginTx(.{
            .isolation = .serializable,
            .read_only = true,
        }, .none);
        defer tx.rollback(.none) catch {};

        try testing.expect(state.last_tx_opts != null);
        try testing.expectEqual(IsolationLevel.serializable, state.last_tx_opts.?.isolation);
        try testing.expect(state.last_tx_opts.?.read_only);
    }

    // 2. In compatibility mode, deadlines are accepted by transactions.
    {
        var tx = try db.begin(.none);
        defer tx.rollback(.none) catch {};
        const deadline = @import("../io/deadline.zig").Deadline.after(io, .fromSeconds(1));
        _ = try tx.exec("UPDATE users SET age = 30", &.{}, deadline);
        var q_rows = try tx.query("SELECT 1", &.{}, deadline);
        q_rows.close();
        try tx.commit(deadline);
    }
}

test "database.sql: ErrBadConn retry on idle connection" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // Execute first query to warm up connection into idle pool
    _ = try db.exec("SELECT 1", &.{}, .none);
    try testing.expectEqual(@as(usize, 1), db.stats().idle);

    // Set mock to fail the idle connection on its next use with ErrBadConn
    state.fail_with_bad_conn_count = 1;

    // db.exec should catch ErrBadConn on the idle connection, discard it,
    // and retry on a fresh connection
    const res = try db.exec("SELECT 2", &.{}, .none);
    try testing.expectEqual(@as(i64, 1), res.rows_affected);

    // Verify open_count increased to 2 because bad connection was replaced
    try testing.expectEqual(@as(usize, 2), state.open_count);
}

test "database.sql: Rows.next reports task cancellation" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    var rows = try db.query("SELECT 1, 2, 3", &.{}, .none);
    defer rows.close();
    var dest: [3]Value = undefined;
    var ready: std.Io.Event = .unset;
    var gate: std.Io.Event = .unset;
    const Worker = struct {
        fn run(
            task_io: std.Io,
            r: *Rows,
            values: []Value,
            entered: *std.Io.Event,
            wait_gate: *std.Io.Event,
        ) !bool {
            entered.set(task_io);
            wait_gate.wait(task_io) catch |err| switch (err) {
                error.Canceled => task_io.recancel(),
            };
            return r.next(values, .none);
        }
    };
    var future = try io.concurrent(Worker.run, .{ io, &rows, &dest, &ready, &gate });
    try ready.wait(io);
    try testing.expectError(error.Canceled, future.cancel(io));
    try testing.expect(!rows.closed);
}

test "database.sql: Rows.next returns driver iteration errors" {
    const io = std.testing.io;
    const Fake = struct {
        fn columnCount(_: *anyopaque) usize {
            return 0;
        }
        fn columnName(_: *anyopaque, _: usize) []const u8 {
            return "";
        }
        fn next(_: *anyopaque, _: std.Io, _: []Value, _: Deadline) anyerror!bool {
            return false;
        }
        fn rowError(_: *anyopaque) ?anyerror {
            return error.IterationFailed;
        }
        fn close(_: *anyopaque) void {}
        fn numInput(_: *anyopaque) i64 {
            return 0;
        }
        fn exec(
            _: *anyopaque,
            _: std.Io,
            _: []const NamedValue,
            _: Deadline,
        ) anyerror!Result {
            return error.UnexpectedCall;
        }
        fn query(
            _: *anyopaque,
            _: std.Io,
            _: []const NamedValue,
            _: Deadline,
        ) anyerror!driver.Rows {
            return error.UnexpectedCall;
        }
    };
    var anchor: u8 = 0;
    var rows: Rows = .{
        .pooled_conn = null,
        .stmt = .{ .ptr = &anchor, .vtable = &.{
            .close = Fake.close,
            .numInput = Fake.numInput,
            .exec = Fake.exec,
            .query = Fake.query,
        } },
        .raw_rows = .{ .ptr = &anchor, .vtable = &.{
            .columnCount = Fake.columnCount,
            .columnName = Fake.columnName,
            .next = Fake.next,
            .close = Fake.close,
            .err = Fake.rowError,
        } },
        .io = io,
    };
    var values: [0]Value = .{};
    try std.testing.expectError(error.IterationFailed, rows.next(&values, .none));
    try std.testing.expect(rows.closed);
    try std.testing.expectEqual(error.IterationFailed, rows.err().?);
}

test "database.sql: Rows.close called AFTER DB.close is safe without UAF" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");

    // Borrow an active connection into Rows
    var rows = try db.query("SELECT 1, 2, 3", &.{}, .none);

    // DB is closed BEFORE rows is closed
    db.close();

    // Closing rows afterwards must safely reclaim the connection and DB memory without UAF
    rows.close();
}

test "database.sql: transaction rows reject unsupported deadline" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    var tx = try db.begin(.none);
    defer tx.rollback(.none) catch {};

    var rows = try tx.query("SELECT 1, 2, 3", &.{}, .none);
    defer rows.close();
    var dest: [3]Value = undefined;
    const deadline = @import("../io/deadline.zig").Deadline.after(io, .fromSeconds(1));
    const has_row = try rows.next(&dest, deadline);
    try testing.expect(has_row);
    try testing.expect(!rows.closed);

    const expired = @import("../io/deadline.zig").Deadline.after(io, .zero);
    try testing.expectError(error.Timeout, rows.next(&dest, expired));
}

test "database.sql: DB.prepare and Stmt execution on mock driver" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Prepared Exec
    var stmt = try db.prepare("INSERT INTO users (name) VALUES (?)", .none);
    defer stmt.close();

    const res = try stmt.exec(&.{Value{ .string = "dave" }}, .none);
    try testing.expectEqual(@as(i64, 1001), try res.lastInsertId());
    try testing.expectEqual(@as(i64, 1), try res.rowsAffected());

    // 2. Prepared Query with nextStruct
    const UserRow = struct {
        id: i64,
        name: []const u8,
        role: []const u8,
    };
    var rows = try stmt.query(&.{}, .none);
    defer rows.close();

    const user1 = (try rows.nextStruct(UserRow, .none)).?;
    try testing.expectEqual(@as(i64, 1), user1.id);
    try testing.expectEqualStrings("alice", user1.name);
    try testing.expectEqualStrings("admin", user1.role);

    // 3. Result returns error.UnsupportedResult when fields are null
    const unsupported_res = Result{};
    try testing.expectError(error.UnsupportedResult, unsupported_res.lastInsertId());
    try testing.expectError(error.UnsupportedResult, unsupported_res.rowsAffected());

    // 4. scanValues verifies ColumnCountMismatch on slice length mismatch
    const ShortRecord = struct {
        id: i64,
        name: []const u8,
    };
    const vals = [_]Value{
        Value{ .int = 1 },
        Value{ .string = "alice" },
        Value{ .string = "admin" },
    };
    try testing.expectError(error.ColumnCountMismatch, scanValues(ShortRecord, &vals));
    const FullRecord = struct {
        id: i64,
        name: []const u8,
        role: []const u8,
    };
    const decoded = try scanValues(FullRecord, &vals);
    try testing.expectEqual(@as(i64, 1), decoded.id);
    try testing.expectEqualStrings("alice", decoded.name);
    try testing.expectEqualStrings("admin", decoded.role);
}

test "database.sql: Tx.prepare statements are closed and invalidated on commit and rollback" {
    const testing = std.testing;

    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Tx.prepare followed by commit
    {
        var tx = try db.begin(.none);
        var tx_stmt = try tx.prepare("INSERT INTO users (name) VALUES (?)", .none);
        defer tx_stmt.close();

        // Valid execution within transaction
        _ = try tx_stmt.exec(.{"test"}, .none);

        try tx.commit(.none);

        // Executing after commit must return error.TxDone without race or reuse
        try testing.expectError(error.TxDone, tx_stmt.exec(.{"fail"}, .none));
        try testing.expectError(error.TxDone, tx_stmt.query(.{}, .none));

        // tx_stmt.close() can be called safely
        tx_stmt.close();
    }

    // 2. Tx.prepare followed by rollback
    {
        var tx = try db.begin(.none);
        var tx_stmt = try tx.prepare("INSERT INTO users (name) VALUES (?)", .none);
        defer tx_stmt.close();

        _ = try tx_stmt.exec(.{"rollback_test"}, .none);

        try tx.rollback(.none);

        // Executing after rollback must return error.TxDone
        try testing.expectError(error.TxDone, tx_stmt.exec(.{"fail"}, .none));
        try testing.expectError(error.TxDone, tx_stmt.query(.{}, .none));

        // tx_stmt.close() called again in defer is safe
    }

    // 3. Early stmt.close() before tx.commit()
    {
        var tx = try db.begin(.none);
        var tx_stmt = try tx.prepare("INSERT INTO users (name) VALUES (?)", .none);
        _ = try tx_stmt.exec(.{"early_close"}, .none);
        tx_stmt.close();

        // Already closed statement
        try testing.expectError(error.TxDone, tx_stmt.exec(.{"fail"}, .none));

        // Commit should succeed cleanly even when statement was closed early
        try tx.commit(.none);
    }
}

test "database.sql: Rows.columnType indexed metadata" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    var rows = try db.query("SELECT id, name, role FROM users", &.{}, .none);
    defer rows.close();

    try testing.expectEqual(@as(usize, 3), rows.columnCount());

    // Column 0: id
    const col0 = try rows.columnType(0);
    try testing.expectEqualStrings("id", col0.name());
    try testing.expectEqualStrings("BIGINT", col0.databaseTypeName().?);
    try testing.expectEqual(@as(?bool, false), col0.nullable());
    try testing.expectEqual(@as(?i64, null), col0.length());

    // Column 1: name
    const col1 = try rows.columnType(1);
    try testing.expectEqualStrings("name", col1.name());
    try testing.expectEqualStrings("VARCHAR(255)", col1.databaseTypeName().?);
    try testing.expectEqual(@as(?bool, true), col1.nullable());

    // Column 2: role
    const col2 = try rows.columnType(2);
    try testing.expectEqualStrings("role", col2.name());
    try testing.expectEqualStrings("VARCHAR(64)", col2.databaseTypeName().?);
    try testing.expectEqual(@as(?bool, true), col2.nullable());

    // Out of bounds index
    try testing.expectError(error.ColumnIndexOutOfBounds, rows.columnType(3));
}

test "database.sql: Value.bind and val.scan with enum, time, custom valuer and scanner" {
    const testing = std.testing;

    // 1. Enum decoding from int and string
    const Role = enum {
        admin,
        member,
        guest,
    };
    const v_admin = Value{ .int = 0 };
    try testing.expectEqual(Role.admin, try v_admin.scan(Role));

    const v_guest = Value{ .string = "guest" };
    try testing.expectEqual(Role.guest, try v_guest.scan(Role));

    const v_invalid = Value{ .string = "unknown" };
    try testing.expectError(error.InvalidEnumValue, v_invalid.scan(Role));

    // 2. Time decoding from unix timestamp and RFC3339 string
    const v_time_sec = Value{ .int = 1700000000 };
    const t_sec = try v_time_sec.scan(Time);
    try testing.expectEqual(@as(i64, 1700000000), t_sec.wall_sec);

    const v_time_str = Value{ .string = "2026-11-22T14:00:00Z" };
    const t_str = try v_time_str.scan(Time);
    try testing.expectEqual(@as(i64, 2026), t_str.year());

    // 3. Custom type implementing scan() (like Go's sql.Scanner)
    const CustomJson = struct {
        val: i64 = 0,
        pub fn scan(self: *@This(), v: Value) !void {
            switch (v) {
                .int => |i| self.val = i * 2,
                .string => |s| self.val = @intCast(s.len),
                else => return error.ColumnTypeMismatch,
            }
        }
    };
    const c1 = try (Value{ .int = 21 }).scan(CustomJson);
    try testing.expectEqual(@as(i64, 42), c1.val);

    const c2 = try (Value{ .string = "stdgo" }).scan(CustomJson);
    try testing.expectEqual(@as(i64, 5), c2.val);

    // 4. Custom type implementing bind()
    const CustomId = struct {
        raw: i64,
        pub fn bind(self: @This()) Value {
            return .{ .int = self.raw };
        }
    };
    const c_id = try Value.bind(CustomId{ .raw = 999 });
    try testing.expectEqual(@as(i64, 999), c_id.int);
}

test "database.sql: SetConnMaxIdleTime idle connection eviction" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    db.setConnMaxIdleTime(1); // 1 nanosecond idle timeout

    // Acquire and return connection
    var c1 = try db.conn(.none);
    c1.close();

    try testing.expectEqual(@as(usize, 1), db.stats().idle);

    // Sleep slightly so idle duration exceeds 1ns
    try io.sleep(std.Io.Duration.fromNanoseconds(1000), .awake);

    // Acquiring again must evict the expired connection and open a fresh one
    var c2 = try db.conn(.none);
    defer c2.close();

    const stats = db.stats();
    try testing.expect(stats.max_idle_time_closed >= 1);
}

test "database.sql: query and exec with struct and tuple arguments" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Exec with named struct literal
    const r1 = try db.exec(
        "INSERT INTO users (name, age) VALUES (:name, :age)",
        .{ .name = "Alice", .age = 30 },
        .none,
    );
    try testing.expectEqual(@as(i64, 1), try r1.rowsAffected());

    // 2. Exec with positional tuple
    const r2 = try db.exec("UPDATE users SET age = ? WHERE id = ?", .{ 31, 1001 }, .none);
    try testing.expectEqual(@as(i64, 1), try r2.rowsAffected());

    // 3. Exec with 0 arguments .{}
    const r3 = try db.exec("DELETE FROM users", .{}, .none);
    try testing.expectEqual(@as(i64, 1), try r3.rowsAffected());

    // 4. Query with named struct
    var rows1 = try db.query("SELECT id, name FROM users WHERE id = :id", .{ .id = 1 }, .none);
    defer rows1.close();

    // 5. Query with positional tuple
    var rows2 = try db.query("SELECT id, name FROM users WHERE id = ?", .{1}, .none);
    defer rows2.close();

    // 6. Verify positional update
    const r4 = try db.exec("UPDATE users SET name = ? WHERE id = ?", .{ "test", 1 }, .none);
    try testing.expectEqual(@as(i64, 1), try r4.rowsAffected());

    // 7. Verify Blob type and Value.bind / val.scan
    const b = blob("binary_payload\x00\xff");
    const v1 = try Value.bind(b);
    try testing.expectEqual(Value{ .bytes = "binary_payload\x00\xff" }, v1);
    const decoded_blob = try v1.scan(Blob);
    try testing.expectEqualStrings("binary_payload\x00\xff", decoded_blob.data);
}

test "database.sql: Tx.query Rows invalidated on commit and rollback" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Rows invalidated after commit (no UAF on metadata accessors)
    {
        var tx = try db.begin(.none);
        var rows = try tx.query("SELECT 1", &.{}, .none);
        defer rows.close();

        try tx.commit(.none);

        // Verification of safe behavior after commit without UAF
        try testing.expectEqual(@as(usize, 0), rows.columnCount());
        try testing.expectEqualStrings("", rows.columnName(0));
        try testing.expectError(error.TxDone, rows.columnType(0));
        try testing.expectEqual(error.TxDone, rows.err().?);
        try testing.expect(rows.lastError() == null);

        var dest: [1]Value = undefined;
        try testing.expectError(error.TxDone, rows.next(&dest, .none));
    }

    // 2. Rows invalidated after rollback (no UAF on metadata accessors)
    {
        var tx = try db.begin(.none);
        var rows = try tx.query("SELECT 1", &.{}, .none);
        defer rows.close();

        try tx.rollback(.none);

        try testing.expectEqual(@as(usize, 0), rows.columnCount());
        try testing.expectEqualStrings("", rows.columnName(0));
        try testing.expectError(error.TxDone, rows.columnType(0));
        try testing.expectEqual(error.TxDone, rows.err().?);
        try testing.expect(rows.lastError() == null);

        var dest: [1]Value = undefined;
        try testing.expectError(error.TxDone, rows.next(&dest, .none));
    }
}

test "database.sql: Tx value move preserves tracked Rows and Stmt safety" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    const Bundle = struct {
        tx: Tx,
        rows: Rows,
        stmt: Stmt,
    };

    const Helper = struct {
        fn start(d: *DB) !Bundle {
            var tx = try d.begin(.none);
            errdefer tx.rollback(.none) catch {};
            var rows = try tx.query("SELECT id, name, role FROM users", .{}, .none);
            errdefer rows.close();
            const stmt = try tx.prepare("INSERT INTO users (name) VALUES (?)", .none);
            return .{
                .tx = tx,
                .rows = rows,
                .stmt = stmt,
            };
        }
    };

    var bundle = try Helper.start(db);
    defer bundle.rows.close();
    defer bundle.stmt.close();

    // Mutate after Tx has been moved by value out of Helper.start
    _ = try bundle.stmt.exec(.{"moved"}, .none);
    try bundle.tx.commit(.none);

    var dest: [3]Value = undefined;
    try testing.expectError(error.TxDone, bundle.rows.next(&dest, .none));
    try testing.expectError(error.TxDone, bundle.stmt.exec(.{"after_commit"}, .none));
}

test "database.sql: early Stmt.close and reentrant Stmt.query/exec invalidate Rows safely" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Tx.prepare + Stmt.query with early tx_stmt.close() before rows.close() and tx.commit()
    {
        var tx = try db.begin(.none);
        var rows = blk: {
            var tx_stmt = try tx.prepare("SELECT id, name, role FROM users", .none);
            defer tx_stmt.close();
            break :blk try tx_stmt.query(.{}, .none);
        };
        defer rows.close();

        try tx.commit(.none);

        try testing.expectEqual(@as(usize, 0), rows.columnCount());
        try testing.expectEqualStrings("", rows.columnName(0));
        try testing.expectError(error.TxDone, rows.columnType(0));
        try testing.expectEqual(error.TxDone, rows.err().?);

        var dest: [3]Value = undefined;
        try testing.expectError(error.TxDone, rows.next(&dest, .none));
    }

    // 2. DB.prepare + Stmt.query with early stmt.close() before rows.close()
    {
        var rows = blk: {
            var stmt = try db.prepare("SELECT id, name, role FROM users", .none);
            defer stmt.close();
            break :blk try stmt.query(.{}, .none);
        };
        defer rows.close();

        try testing.expectEqual(@as(usize, 0), rows.columnCount());
        try testing.expectEqualStrings("", rows.columnName(0));
        try testing.expectError(error.StmtClosed, rows.columnType(0));
        try testing.expectEqual(error.StmtClosed, rows.err().?);

        var dest: [3]Value = undefined;
        try testing.expectError(error.StmtClosed, rows.next(&dest, .none));
    }

    // 3. Reentrant Stmt.query() and Stmt.exec() close prior active Rows cleanly
    {
        var stmt = try db.prepare("SELECT id, name, role FROM users", .none);
        defer stmt.close();

        var rows1 = try stmt.query(.{}, .none);
        defer rows1.close();

        var rows2 = try stmt.query(.{}, .none);
        defer rows2.close();

        var dest: [3]Value = undefined;
        try testing.expect(!try rows1.next(&dest, .none));
        try testing.expect(rows1.err() == null);
        try testing.expect(try rows2.next(&dest, .none));
        try testing.expectEqual(@as(i64, 1), dest[0].int);

        var rows3 = try stmt.query(.{}, .none);
        defer rows3.close();
        _ = try stmt.exec(.{}, .none);
        try testing.expect(!try rows3.next(&dest, .none));
        try testing.expect(rows3.err() == null);
    }
}

test "database.sql: ErrBadConn discards bad connections and retries across ping/prepare/beginTx" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // Warm up one idle connection
    try db.ping(.none);
    try testing.expectEqual(@as(usize, 1), db.stats().idle);

    // 1. DB.ping retries once on idle ErrBadConn and discards the bad conn
    state.fail_with_bad_conn_count = 1;
    try db.ping(.none);
    try testing.expectEqual(@as(usize, 2), state.open_count);
    try testing.expectEqual(@as(usize, 1), state.close_count);

    // 2. DB.prepare retries once on idle ErrBadConn
    state.fail_with_bad_conn_count = 1;
    var stmt = try db.prepare("SELECT 1", .none);
    stmt.close();
    try testing.expectEqual(@as(usize, 3), state.open_count);
    try testing.expectEqual(@as(usize, 2), state.close_count);

    // 3. DB.beginTx retries once on idle ErrBadConn
    state.fail_with_bad_conn_count = 1;
    var tx = try db.begin(.none);
    try tx.rollback(.none);
    try testing.expectEqual(@as(usize, 4), state.open_count);
    try testing.expectEqual(@as(usize, 3), state.close_count);

    // 4. ErrBadConn on both idle and fresh retry must still discard the fresh conn (idle == 0)
    state.fail_with_bad_conn_count = 2;
    try testing.expectError(error.ErrBadConn, db.exec("SELECT 1", .{}, .none));
    try testing.expectEqual(@as(usize, 0), db.stats().open_connections);
    try testing.expectEqual(@as(usize, 0), db.stats().idle);
}

test "database.sql: Row.err records scan errors and closed Rows.lastError returns null" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // Row.scan error is preserved in row.err() even after row closes
    {
        var row = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        defer row.close();
        var wrong_dest: [1]Value = undefined;
        try testing.expectError(error.ColumnCountMismatch, row.scan(&wrong_dest, .none));
        try testing.expectEqual(error.ColumnCountMismatch, row.err().?);
    }

    // Closed Rows returns null from lastError() (never a dangling connection pointer)
    {
        var rows = try db.query("SELECT id, name, role FROM users", .{}, .none);
        defer rows.close();
        var wrong_dest: [1]Value = undefined;
        try testing.expectError(error.ColumnCountMismatch, rows.next(&wrong_dest, .none));
        try testing.expect(rows.closed);
        try testing.expect(rows.lastError() == null);
    }
}

test "database.sql: Conn owns connection across beginTx, prepare, ping, and early close" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();
    db.setMaxOpenConns(1);

    // 1. Normal lifecycle: beginTx / prepare / ping do NOT close Conn; Conn.close() is idempotent
    {
        var pc = try db.conn(.none);
        defer pc.close();

        try pc.ping(.none);

        var tx1 = try pc.beginTx(.{}, .none);
        _ = try tx1.exec("INSERT INTO users VALUES (1)", .{}, .none);
        try tx1.commit(.none);
        try testing.expectEqual(@as(usize, 1), db.stats().in_use);
        try testing.expectEqual(@as(usize, 0), db.stats().idle);

        var tx2 = try pc.begin(.none);
        try tx2.rollback(.none);
        try testing.expectEqual(@as(usize, 1), db.stats().in_use);

        var stmt = try pc.prepare("INSERT INTO users VALUES (?)", .none);
        _ = try stmt.exec(.{42}, .none);
        stmt.close();
        try testing.expectError(error.StmtClosed, stmt.exec(.{42}, .none));
        try testing.expectError(error.StmtClosed, stmt.query(.{}, .none));
        try testing.expectEqual(@as(usize, 1), db.stats().in_use);

        try pc.ping(.none);

        // Idempotent close: second close must be a no-op
        pc.close();
        pc.close();
        try testing.expectEqual(@as(usize, 0), db.stats().in_use);
        try testing.expectEqual(@as(usize, 1), db.stats().idle);
        try testing.expectError(error.ConnDone, pc.ping(.none));
        try testing.expect(pc.lastError() == null);
        try testing.expect(!pc.interrupt());
    }

    // 2. Early Conn.close() invalidates still-open Rows, Stmt, and Tx with error.ConnDone
    {
        var pc = try db.conn(.none);
        var rows = try pc.query("SELECT id, name, role FROM users", .{}, .none);
        defer rows.close();
        var stmt = try pc.prepare("SELECT id, name, role FROM users", .none);
        defer stmt.close();
        var stmt_rows = try stmt.query(.{}, .none);
        defer stmt_rows.close();
        var tx = try pc.begin(.none);
        defer tx.rollback(.none) catch {};

        // Duplicate begin on same Conn is rejected while tx is active
        try testing.expectError(error.TxAlreadyActive, pc.begin(.none));

        const rollbacks_before = state.tx_rollbacks;
        pc.close();

        try testing.expectEqual(rollbacks_before + 1, state.tx_rollbacks);
        try testing.expectEqual(@as(usize, 0), db.stats().in_use);

        var dest: [3]Value = undefined;
        try testing.expectError(error.ConnDone, rows.next(&dest, .none));
        try testing.expect(rows.lastError() == null);
        try testing.expectError(error.ConnDone, stmt.exec(.{}, .none));
        try testing.expectError(error.ConnDone, stmt_rows.next(&dest, .none));
        try testing.expectError(error.ConnDone, tx.exec("SELECT 1", .{}, .none));
        try testing.expectError(error.ConnDone, tx.commit(.none));
    }
}

test "database.sql: Rows.lastError works across Conn, Tx, and Stmt queries" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    state.last_error_msg = "mock diagnostic error";

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Conn.query
    {
        var pc = try db.conn(.none);
        defer pc.close();
        var rows = try pc.query("SELECT id, name, role FROM users", .{}, .none);
        try testing.expectEqualStrings("mock diagnostic error", rows.lastError().?);
        rows.close();
        try testing.expect(rows.lastError() == null);
    }

    // 2. Tx.lastError, Tx.query, & Tx.prepare + Stmt.lastError / Stmt.query
    {
        var tx = try db.begin(.none);
        defer tx.rollback(.none) catch {};

        try testing.expectEqualStrings("mock diagnostic error", tx.lastError().?);

        var tx_rows = try tx.query("SELECT id, name, role FROM users", .{}, .none);
        try testing.expectEqualStrings("mock diagnostic error", tx_rows.lastError().?);
        tx_rows.close();
        try testing.expect(tx_rows.lastError() == null);

        var tx_stmt = try tx.prepare("SELECT id, name, role FROM users", .none);
        defer tx_stmt.close();
        try testing.expectEqualStrings("mock diagnostic error", tx_stmt.lastError().?);
        var stmt_rows = try tx_stmt.query(.{}, .none);
        try testing.expectEqualStrings("mock diagnostic error", stmt_rows.lastError().?);
        stmt_rows.close();
        try testing.expect(stmt_rows.lastError() == null);
    }

    // 3. DB.prepare + Stmt.lastError / Stmt.query & Row.lastError
    {
        var stmt = try db.prepare("SELECT id, name, role FROM users", .none);
        try testing.expectEqualStrings("mock diagnostic error", stmt.lastError().?);
        var stmt_rows = try stmt.query(.{}, .none);
        try testing.expectEqualStrings("mock diagnostic error", stmt_rows.lastError().?);
        stmt_rows.close();
        try testing.expect(stmt_rows.lastError() == null);
        stmt.close();
        try testing.expect(stmt.lastError() == null);

        var row = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        try testing.expectEqualStrings("mock diagnostic error", row.lastError().?);
        row.close();
        try testing.expect(row.lastError() == null);
    }
}

test "database.sql: Row.scanStruct auto-closes pure values and scanStructOwned dupes slices" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();
    db.setMaxOpenConns(1);

    // 1. Pure value struct auto-closes Row and returns connection to pool immediately
    {
        const PureValueUser = struct {
            id: i64,
            name: enum { alice, bob },
            role: enum { admin, dev },
        };
        var row = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        const res = try row.scanStruct(PureValueUser, .none);
        try testing.expectEqual(@as(i64, 1), res.id);
        try testing.expectEqual(@as(@TypeOf(res.name), .alice), res.name);
        try testing.expectEqual(@as(@TypeOf(res.role), .admin), res.role);
        // Connection already returned without calling row.close()
        try testing.expectEqual(@as(usize, 0), db.stats().in_use);
        try testing.expectEqual(@as(usize, 1), db.stats().idle);
        row.close(); // idempotent
    }

    // 2. scanStructOwned duplicates slices and closes Row immediately
    {
        const UserRow = struct { id: i64, name: []const u8, role: []const u8 };
        var row = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        const owned = try row.scanStructOwned(testing.allocator, UserRow, .none);
        defer owned.deinit();

        try testing.expectEqual(@as(i64, 1), owned.value.id);
        try testing.expectEqualStrings("alice", owned.value.name);
        try testing.expectEqualStrings("admin", owned.value.role);
        try testing.expectEqual(@as(usize, 0), db.stats().in_use);
    }

    // 3. Rows.nextStructOwned duplicates slices across multiple rows and survives Rows.close()
    {
        const UserRow = struct { id: i64, name: []const u8, role: []const u8 };
        var collected: std.ArrayList(Owned(UserRow)) = .empty;
        defer {
            for (collected.items) |item| item.deinit();
            collected.deinit(testing.allocator);
        }

        {
            var rows = try db.query("SELECT id, name, role FROM users", .{}, .none);
            defer rows.close();
            while (try rows.nextStructOwned(testing.allocator, UserRow, .none)) |item| {
                try collected.append(testing.allocator, item);
            }
        }
        try testing.expectEqual(@as(usize, 0), db.stats().in_use);
        try testing.expectEqual(@as(usize, 2), collected.items.len);
        try testing.expectEqualStrings("alice", collected.items[0].value.name);
        try testing.expectEqualStrings("bob", collected.items[1].value.name);
    }

    // 4. Rows.nextStruct records scan errors in rows.err()
    {
        const BadUserRow = struct { id: i64, name: i64, role: []const u8 };
        var rows = try db.query("SELECT id, name, role FROM users", .{}, .none);
        defer rows.close();
        try testing.expectError(error.ColumnTypeMismatch, rows.nextStruct(BadUserRow, .none));
        try testing.expectEqual(error.ColumnTypeMismatch, rows.err().?);
    }

    // 5. Name-based mapping: reordered fields, subset projection, and case-sensitive errors
    {
        // Reordered fields (query returns id, name, role)
        const Reordered = struct { role: []const u8, id: i64, name: []const u8 };
        var row1 = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        const r1 = try row1.scanStruct(Reordered, .none);
        try testing.expectEqual(@as(i64, 1), r1.id);
        try testing.expectEqualStrings("alice", r1.name);
        try testing.expectEqualStrings("admin", r1.role);
        row1.close();

        // Subset projection (ignores id and role)
        const NameOnly = struct { name: []const u8 };
        var row2 = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        const owned_name = try row2.scanStructOwned(testing.allocator, NameOnly, .none);
        defer owned_name.deinit();
        try testing.expectEqualStrings("alice", owned_name.value.name);

        // Case-sensitive mismatch -> error.ColumnNotFound
        const WrongCase = struct { Name: []const u8 };
        var row3 = db.queryRow("SELECT id, name, role FROM users", .{}, .none);
        defer row3.close();
        try testing.expectError(error.ColumnNotFound, row3.scanStruct(WrongCase, .none));
        try testing.expectEqual(error.ColumnNotFound, row3.err().?);
    }
}

test "database.sql: u64 exceeding maxInt(i64) returns error.IntegerOverflow" {
    const testing = std.testing;
    const io = testing.io;

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    const too_big: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    try testing.expectError(error.IntegerOverflow, Value.bind(too_big));
    try testing.expectError(
        error.IntegerOverflow,
        db.exec("INSERT INTO t VALUES (?)", .{too_big}, .none),
    );
}

test "database.sql: pool limit invariants, Value.scan(Value), deadline precedence, and close wakeup" {
    const testing = std.testing;
    const io = testing.io;

    // 1. Value.scan(Value) and Value.scan(?Value)
    {
        const v_int = Value{ .int = 7 };
        try testing.expectEqual(v_int, try v_int.scan(Value));
        try testing.expectEqual(v_int, (try v_int.scan(?Value)).?);
        const v_null: Value = .null;
        try testing.expectEqual(v_null, try v_null.scan(Value));
        try testing.expect((try v_null.scan(?Value)) == null);
    }

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 2. setMaxOpenConns trims excess idle conns and caps max_idle_conns;
    //    setMaxIdleConns respects max_open_conns.
    {
        db.setMaxIdleConns(3);
        var c1 = try db.conn(.none);
        var c2 = try db.conn(.none);
        var c3 = try db.conn(.none);
        c1.close();
        c2.close();
        c3.close();
        try testing.expectEqual(@as(usize, 3), db.stats().idle);

        db.setMaxOpenConns(1);
        try testing.expectEqual(@as(usize, 1), db.stats().idle);
        try testing.expectEqual(@as(usize, 1), db.stats().open_connections);
        try testing.expectEqual(@as(u64, 2), db.stats().max_idle_closed);

        // Requesting max_idle > max_open is capped to max_open (1)
        db.setMaxIdleConns(5);
        try testing.expectEqual(@as(usize, 1), db.max_idle_conns);
        db.setMaxOpenConns(0);
    }

    // 3. Expired deadline takes precedence over ColumnNotFound in nextStruct / nextStructOwned
    {
        const MissingCol = struct { does_not_exist: i64 };
        var rows = try db.query("SELECT id, name, role FROM users", .{}, .none);
        defer rows.close();
        const expired = Deadline.after(io, .zero);
        try testing.expectError(error.Timeout, rows.nextStruct(MissingCol, expired));
        try testing.expectError(
            error.Timeout,
            rows.nextStructOwned(testing.allocator, MissingCol, expired),
        );
    }

    // 4. DB.close() wakes promptly via pool_changed when an active Conn closes concurrently
    {
        var close_state = MockDriver.State.init(testing.allocator);
        defer close_state.deinit();
        var close_mock = MockDriver{ .state = &close_state };
        const close_db = try DB.open(
            testing.allocator,
            io,
            close_mock.driver(),
            "mock://localhost/close_wakeup",
        );
        var held = try close_db.conn(.none);

        const Releaser = struct {
            fn run(c: *Conn, task_io: std.Io) void {
                task_io.sleep(.fromMilliseconds(15), .awake) catch {};
                c.close();
            }
        };
        var future = try io.concurrent(Releaser.run, .{ &held, io });
        const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
        close_db.close();
        const elapsed_ms = @divFloor(
            std.Io.Clock.awake.now(io).nanoseconds - start_ns,
            std.time.ns_per_ms,
        );
        future.await(io);
        // Should wake shortly after 15ms, well below the 500ms grace timeout
        try testing.expect(elapsed_ms < 350);
    }
}

test {
    if (build_options.have_sqlite) {
        _ = sqlite;
    }
}
