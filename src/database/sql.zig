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
const Mutex = @import("../sync/mutex.zig").Mutex;
const Deadline = @import("../io/deadline.zig").Deadline;
const time_pkg = @import("../time/time.zig");
pub const Time = time_pkg.Time;

pub const Value = driver.Value;
pub const Result = driver.Result;
pub const IsolationLevel = driver.IsolationLevel;
pub const TxOptions = driver.TxOptions;
pub const ErrBadConn = driver.ErrBadConn;
pub const ErrNoRows = error.ErrNoRows;
pub const ColumnType = driver.ColumnType;
pub const NamedValue = driver.NamedValue;

pub const Blob = driver.Blob;
pub const blob = driver.blob;

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
                nv_buf[i] = .{ .name = null, .value = Value.bind(@field(args, name)) };
            }
        } else {
            inline for (s_info.field_names, 0..) |name, i| {
                nv_buf[i] = .{ .name = name, .value = Value.bind(@field(args, name)) };
            }
        }
        return @call(.auto, func, .{ ctx, &nv_buf });
    }

    @compileError("unsupported argument type for database/sql query: " ++ @typeName(ArgT));
}

/// Scans a slice of driver Values directly into a destination struct at compile time.
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
    /// If more than one row matches the query, ScanStruct uses the first row and discards the rest.
    /// If no rows match the query, ScanStruct returns error.ErrNoRows.
    /// Note: Any string/bytes in the returned struct point into driver memory
    /// while the row is open; use `defer row.close()` to release after use.
    pub fn scanStruct(self: *Row, comptime T: type, deadline: Deadline) !T {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("expected a struct type, found " ++ @typeName(T));
        }
        const field_count = comptime type_info.@"struct".field_names.len;
        var dest: [field_count]Value = undefined;
        try self.scan(&dest, deadline);
        return scanValues(T, &dest);
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
};

/// Internal pooled connection tracked by DB.
pub const PooledConn = struct {
    raw: driver.Conn,
    created_at_ns: i128,
    last_used_at_ns: i128,
    db: *DB,
    from_pool: bool = false,
    prev: ?*PooledConn = null,
    next: ?*PooledConn = null,

    pub fn release(self: *PooledConn) void {
        self.db.putConn(self);
    }

    /// Interrupt aborts any in-progress query on this connection out-of-band.
    /// Returns true if supported and signaled, false otherwise.
    pub fn interrupt(self: *PooledConn) bool {
        return self.raw.interrupt();
    }

    /// LastError returns the error message for the last operation on this connection.
    pub fn lastError(self: *PooledConn) ?[]const u8 {
        return self.raw.lastError();
    }

    /// Exec executes a query on this specific connection.
    /// Supports positional tuples `.{ ... }`, named structs `.{ .name = ... }`, or empty `.{}`.
    pub fn exec(
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

    /// Query executes a query returning rows on this connection.
    pub fn query(
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

    /// QueryRow executes a query that is expected to return at most one row.
    pub fn queryRow(
        self: *PooledConn,
        query_str: []const u8,
        args: anytype,
        deadline: Deadline,
    ) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// BeginTx starts a transaction on this connection.
    pub fn beginTx(self: *PooledConn, opts: TxOptions, deadline: Deadline) !Tx {
        try self.db.checkOperation(deadline);
        const state = try self.db.allocator.create(TxState);
        errdefer self.db.allocator.destroy(state);
        const raw_tx = try self.raw.beginTx(self.db.io, opts, deadline);
        state.* = .{
            .allocator = self.db.allocator,
            .pooled_conn = self,
            .raw_tx = raw_tx,
        };
        return Tx{
            .state = state,
        };
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

    /// Open creates a database handle using the supplied I/O implementation.
    /// The I/O implementation must outlive the DB and its borrowed connections and rows.
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
    /// Close then waits for all queries that have started processing on the server
    /// to finish and closes all idle connections.
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

        // Optional grace period waiting for active queries to exit gracefully
        const max_wait_attempts: usize = 1000;
        var attempts: usize = 0;
        while (self.active_count > 0 and attempts < max_wait_attempts) : (attempts += 1) {
            self.mutex.unlock(self.io);
            self.io.sleep(
                std.Io.Duration.fromNanoseconds(500 * std.time.ns_per_us),
                .awake,
            ) catch {
                std.Thread.yield() catch {};
            };
            self.mutex.lockUncancelable(self.io);
        }
        self.mutex.unlock(self.io);

        self.decrementRef();
    }

    /// SetMaxOpenConns sets the maximum number of open connections to the database.
    /// If n <= 0, then there is no limit on the number of open connections.
    pub fn setMaxOpenConns(self: *DB, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.max_open_conns = n;
        self.pool_changed.broadcast(self.io);
    }

    /// SetMaxIdleConns sets the maximum number of connections in the idle
    /// connection pool.
    pub fn setMaxIdleConns(self: *DB, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.max_idle_conns = n;
        while (self.free_count > self.max_idle_conns) {
            const pc = self.popFree().?;
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.max_idle_closed += 1;
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

    /// Ping verifies a connection to the database is still alive, establishing a
    /// connection if necessary. If an idle connection fails with ErrBadConn, it is
    /// discarded and retried once with a fresh connection.
    pub fn ping(self: *DB, deadline: Deadline) !void {
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.conn(deadline);
            pc.raw.ping(self.io, deadline) catch |err| {
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
            pc.release();
            return;
        }
        return error.ErrBadConn;
    }

    /// conn returns a single connection by either opening a new connection
    /// or returning an existing connection from the free pool.
    pub fn conn(self: *DB, deadline: Deadline) !*PooledConn {
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

    pub fn putConn(self: *DB, pc: *PooledConn) void {
        self.mutex.lockUncancelable(self.io);
        self.pool_changed.signal(self.io);

        self.removeActive(pc);

        if (self.closed) {
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
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.conn(deadline);
            const res = pc.exec(query_str, args, deadline) catch |err| {
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
            pc.release();
            return res;
        }
        return error.ErrBadConn;
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
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.conn(deadline);
            var rows = pc.query(query_str, args, deadline) catch |err| {
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
            rows.pooled_conn = pc;
            return rows;
        }
        return error.ErrBadConn;
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
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.conn(deadline);
            const tx = pc.beginTx(opts, deadline) catch |err| {
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
            return tx;
        }
        return error.ErrBadConn;
    }

    /// Begin starts a transaction with default options.
    pub fn begin(self: *DB, deadline: Deadline) !Tx {
        return self.beginTx(.{}, deadline);
    }

    /// Prepare creates a prepared statement for later queries or executions.
    /// If an idle connection fails with ErrBadConn, it is discarded and retried once.
    /// The caller must call stmt.close() when done.
    pub fn prepare(self: *DB, query_str: []const u8, deadline: Deadline) !Stmt {
        try self.checkOperation(deadline);
        for (0..2) |retry| {
            const pc = try self.conn(deadline);
            var raw_stmt = pc.raw.prepare(self.io, query_str, deadline) catch |err| {
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
            errdefer raw_stmt.close();
            errdefer pc.release();

            const state = try self.allocator.create(StmtState);
            state.* = .{
                .allocator = self.allocator,
                .raw_stmt = raw_stmt,
                .pooled_conn = pc,
                .tx_state = null,
                .from_tx = false,
                .active_rows = null,
                .ref_count = 1,
            };
            return Stmt{
                .state = state,
                .io = self.io,
            };
        }
        return error.ErrBadConn;
    }
};

/// Rows is the result of a query. Its cursor starts before the first row of the result set.
/// Use Next to advance through the rows.
pub const Rows = struct {
    pooled_conn: ?*PooledConn,
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
    pub fn columnName(self: *Rows, index: usize) []const u8 {
        if (self.syncInvalidation() != null) return "";
        if (self.closed) return "";
        return self.raw_rows.columnName(index);
    }

    /// ColumnType returns column metadata for the given 0-based column index.
    /// Returns error.ColumnIndexOutOfBounds if index >= columnCount().
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
            if (f(self.raw_rows.ptr, index)) |null_val| {
                ct.has_nullable = true;
                ct.nullable_val = null_val;
            }
        }
        if (self.raw_rows.vtable.columnTypeLength) |f| {
            if (f(self.raw_rows.ptr, index)) |len_val| {
                ct.has_length = true;
                ct.length_val = len_val;
            }
        }
        if (self.raw_rows.vtable.columnTypePrecisionScale) |f| {
            if (f(self.raw_rows.ptr, index)) |ps| {
                ct.has_precision_scale = true;
                ct.precision_val = ps.precision;
                ct.scale_val = ps.scale;
            }
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

    /// NextStruct decodes the next row directly into a strongly-typed struct at compile time.
    /// Returns null when iteration finishes cleanly.
    /// Note: Any string or slice fields in the returned struct borrow memory from the
    /// underlying statement and are only valid until the next call to Next, NextStruct, or Close.
    pub fn nextStruct(self: *Rows, comptime T: type, deadline: Deadline) !?T {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("expected a struct type, found " ++ @typeName(T));
        }
        const field_count = comptime type_info.@"struct".field_names.len;
        var dest: [field_count]Value = undefined;
        const has_row = try self.next(&dest, deadline);
        if (!has_row) return null;
        return try scanValues(T, &dest);
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
        if (self.pooled_conn) |pc| return pc.lastError();
        return null;
    }

    pub fn close(self: *Rows) void {
        if (self.closed) return;
        self.closed = true;

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
    raw_tx: driver.Tx,
    done: bool = false,
    stmts_head: ?*StmtState = null,
    rows_head: ?*RowsState = null,

    fn closeResources(self: *TxState) void {
        // Close open rows before finalizing prepared statements, since Stmt.query
        // cursors borrow the underlying driver.Stmt handle.
        while (self.rows_head) |rows_state| {
            rows_state.closeAndDetach(error.TxDone);
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
                std.debug.assert(state.active_rows == null);
                state.raw_stmt.close();
            }
            state.release(); // release Tx's reference
            current_stmt = next;
        }
    }
};

/// Internal tracked state for query rows bound to a Tx or Stmt, ensuring result cursors
/// are closed before their underlying statement or transaction connection is finalized.
const RowsState = struct {
    allocator: Allocator,
    raw_rows: driver.Rows,
    owned_stmt: ?driver.Stmt = null,
    tx_state: ?*TxState = null,
    stmt_state: ?*StmtState = null,
    invalidation_err: ?anyerror = null,
    closed: bool = false,
    ref_count: usize = 1,
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

        if (release_tx_ref) self.release();
        if (release_stmt_ref) self.release();
        std.debug.assert(self.ref_count >= 1);
    }
};

/// Internal tracked state for prepared statements, supporting automatic lifetime
/// management and invalidation when bound to a transaction or owning active rows.
const StmtState = struct {
    allocator: Allocator,
    raw_stmt: driver.Stmt,
    pooled_conn: ?*PooledConn = null,
    tx_state: ?*TxState = null,
    from_tx: bool = false,
    active_rows: ?*RowsState = null,
    closed: bool = false,
    ref_count: usize = 1,
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

    /// Commits the transaction and returns the connection to the pool.
    pub fn commit(self: *Tx, deadline: Deadline) !void {
        const state = self.state orelse return error.TxDone;
        if (state.done) return error.TxDone;
        const connection = state.pooled_conn orelse return error.TxDone;
        const io = connection.db.io;
        try driver_pkg.checkOperation(io, deadline);
        state.done = true;
        state.closeResources();
        state.pooled_conn = null;
        self.state = null;
        defer state.allocator.destroy(state);
        state.raw_tx.vtable.commit(state.raw_tx.ptr, io, deadline) catch |err| {
            connection.db.discardConn(connection);
            return err;
        };
        connection.release();
    }

    /// Aborts and rolls back the transaction, returning the connection to the pool.
    pub fn rollback(self: *Tx, deadline: Deadline) !void {
        const state = self.state orelse return error.TxDone;
        if (state.done) return error.TxDone;
        const connection = state.pooled_conn orelse return error.TxDone;
        const io = connection.db.io;
        try deadline.validate();
        if (!deadline.isNone()) {
            try driver_pkg.checkOperation(io, deadline);
        }
        state.done = true;
        state.closeResources();
        state.pooled_conn = null;
        self.state = null;
        defer state.allocator.destroy(state);
        state.raw_tx.vtable.rollback(state.raw_tx.ptr, io, deadline) catch |err| {
            connection.db.discardConn(connection);
            return err;
        };
        connection.release();
    }

    /// Executes a query within the transaction that does not return rows (e.g. INSERT, UPDATE).
    /// Accepts positional tuples `.{ ... }`, named structs `.{ .name = ... }`, or empty `.{}`.
    pub fn exec(self: *Tx, query_str: []const u8, args: anytype, deadline: Deadline) !Result {
        const state = self.state orelse return error.TxDone;
        if (state.done) return error.TxDone;
        const pc = state.pooled_conn orelse return error.TxDone;
        return pc.exec(query_str, args, deadline);
    }

    /// The transaction connection remains tied to this transaction until commit or rollback.
    pub fn query(self: *Tx, query_str: []const u8, args: anytype, deadline: Deadline) !Rows {
        const state = self.state orelse return error.TxDone;
        if (state.done) return error.TxDone;
        const pc = state.pooled_conn orelse return error.TxDone;
        var rows = try pc.query(query_str, args, deadline);
        errdefer rows.close();

        const rows_state = try pc.db.allocator.create(RowsState);
        rows_state.* = .{
            .allocator = pc.db.allocator,
            .raw_rows = rows.raw_rows,
            .owned_stmt = rows.stmt,
            .tx_state = state,
            .stmt_state = null,
            .ref_count = 2,
            .tx_next = state.rows_head,
            .tx_prev = null,
        };
        if (state.rows_head) |head| {
            head.tx_prev = rows_state;
        }
        state.rows_head = rows_state;

        rows.stmt = null;
        rows.rows_state = rows_state;
        rows.pooled_conn = null; // Tx retains connection until commit/rollback
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
        const state = self.state orelse return error.TxDone;
        if (state.done) return error.TxDone;
        const pc = state.pooled_conn orelse return error.TxDone;
        const io = pc.db.io;
        try pc.db.checkOperation(deadline);
        var raw_stmt = try pc.raw.prepare(io, query_str, deadline);
        errdefer raw_stmt.close();

        const stmt_state = try pc.db.allocator.create(StmtState);
        stmt_state.* = .{
            .allocator = pc.db.allocator,
            .raw_stmt = raw_stmt,
            .pooled_conn = null,
            .tx_state = state,
            .from_tx = true,
            .active_rows = null,
            .ref_count = 2,
            .next = state.stmts_head,
            .prev = null,
        };
        if (state.stmts_head) |head| {
            head.prev = stmt_state;
        }
        state.stmts_head = stmt_state;

        return Stmt{
            .state = stmt_state,
            .io = io,
        };
    }
};

/// Stmt is a prepared statement bound to a database connection.
/// Note: A Stmt wraps a single underlying driver statement on a pooled connection;
/// concurrent executions on the same Stmt instance are not supported without caller-side
/// synchronization. Callers must call close() when the statement is no longer needed.
pub const Stmt = struct {
    state: *StmtState,
    io: std.Io,
    closed: bool = false,

    /// Exec executes a prepared statement with the given arguments and
    /// returns a Result summarizing the effect of the statement.
    ///
    /// Accepts positional tuples `.{ ... }`, named structs `.{ .name = ... }`,
    /// directly passed struct instances (batch execution), or empty tuples `.{}`.
    pub fn exec(self: *Stmt, args: anytype, deadline: Deadline) !Result {
        if (self.closed or self.state.closed) {
            if (self.state.from_tx) return error.TxDone;
            return error.DBClosed;
        }
        if (self.state.tx_state) |tx_state| {
            if (tx_state.done) return error.TxDone;
        }
        if (self.state.pooled_conn) |pc| {
            try pc.db.checkOperation(deadline);
        }
        try driver_pkg.checkOperation(self.io, deadline);
        if (self.state.active_rows) |prev_rows_state| {
            prev_rows_state.closeAndDetach(null);
        }
        const Runner = struct {
            stmt: *Stmt,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Result {
                return r.stmt.state.raw_stmt.exec(r.stmt.io, nv, r.dl);
            }
        };
        return withNamedValues(
            args,
            Runner{ .stmt = self, .dl = deadline },
            Runner.invoke,
        );
    }

    /// Query executes a prepared query statement with the given arguments
    /// and returns the query results as Rows.
    /// Slice arguments are defensively copied by drivers (e.g. SQLite) before returning `Rows`,
    /// so caller-owned temporary buffers do not need to remain live until `Rows.close()`.
    /// Use `exec()` instead when no rows are needed and zero-copy parameter binding is desired.
    pub fn query(self: *Stmt, args: anytype, deadline: Deadline) !Rows {
        if (self.closed or self.state.closed) {
            if (self.state.from_tx) return error.TxDone;
            return error.DBClosed;
        }
        if (self.state.tx_state) |tx_state| {
            if (tx_state.done) return error.TxDone;
        }
        if (self.state.pooled_conn) |pc| {
            try pc.db.checkOperation(deadline);
        }
        try driver_pkg.checkOperation(self.io, deadline);
        if (self.state.active_rows) |prev_rows_state| {
            prev_rows_state.closeAndDetach(null);
        }
        const Runner = struct {
            stmt: *Stmt,
            dl: Deadline,
            fn invoke(r: @This(), nv: []const NamedValue) !Rows {
                var raw_rows = try r.stmt.state.raw_stmt.query(r.stmt.io, nv, r.dl);
                errdefer raw_rows.close();

                if (r.stmt.state.tx_state) |tx_state| {
                    if (tx_state.done) return error.TxDone;
                }

                const rows_state = try r.stmt.state.allocator.create(RowsState);
                rows_state.* = .{
                    .allocator = r.stmt.state.allocator,
                    .raw_rows = raw_rows,
                    .owned_stmt = null,
                    .tx_state = r.stmt.state.tx_state,
                    .stmt_state = r.stmt.state,
                    .ref_count = if (r.stmt.state.tx_state != null) 3 else 2,
                };
                if (r.stmt.state.tx_state) |tx_state| {
                    rows_state.tx_next = tx_state.rows_head;
                    if (tx_state.rows_head) |head| {
                        head.tx_prev = rows_state;
                    }
                    tx_state.rows_head = rows_state;
                }
                r.stmt.state.active_rows = rows_state;

                return Rows{
                    .pooled_conn = null, // Connection remains held by Stmt or Tx
                    .stmt = null,
                    .raw_rows = raw_rows,
                    .io = r.stmt.io,
                    .rows_state = rows_state,
                };
            }
        };
        return withNamedValues(
            args,
            Runner{ .stmt = self, .dl = deadline },
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

    /// Close closes the statement and releases its connection back to the pool.
    pub fn close(self: *Stmt) void {
        if (self.closed) return;
        self.closed = true;
        const state = self.state;
        if (!state.closed) {
            state.closed = true;
            if (state.active_rows) |rows_state| {
                const invalidation_err: anyerror = if (state.from_tx)
                    error.TxDone
                else
                    error.DBClosed;
                rows_state.closeAndDetach(invalidation_err);
            }
            std.debug.assert(state.active_rows == null);
            state.raw_stmt.close();
            if (state.pooled_conn) |pc| {
                pc.release();
                state.pooled_conn = null;
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
// Built-in In-Memory Mock Driver for Unit Testing & Demonstration
// -------------------------------------------------------------------------

pub const MockDriver = struct {
    pub const RowData = struct {
        cols: []const []const u8,
        data: []const Value,
    };

    pub const State = struct {
        allocator: Allocator,
        mutex: Mutex = .{},
        open_count: usize = 0,
        close_count: usize = 0,
        interrupt_count: usize = 0,
        executed_queries: std.ArrayList([]const u8),
        tx_commits: usize = 0,
        tx_rollbacks: usize = 0,
        fail_with_bad_conn_count: usize = 0,
        last_tx_opts: ?driver_pkg.TxOptions = null,

        pub fn init(allocator: Allocator) State {
            return .{
                .allocator = allocator,
                .executed_queries = std.ArrayList([]const u8).empty,
            };
        }

        pub fn deinit(self: *State) void {
            for (self.executed_queries.items) |q| self.allocator.free(q);
            self.executed_queries.deinit(self.allocator);
        }
    };

    state: *State,

    pub fn driver(self: *MockDriver) driver_pkg.Driver {
        return .{
            .ptr = self,
            .vtable = &.{
                .open = MockDriver.open,
            },
        };
    }

    fn open(
        ctx: *anyopaque,
        io: std.Io,
        _: []const u8,
        deadline: Deadline,
    ) anyerror!driver_pkg.Conn {
        try driver_pkg.checkOperation(io, deadline);
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        {
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            self.state.open_count += 1;
        }

        const conn_ctx = try self.state.allocator.create(MockConn);
        conn_ctx.* = .{
            .driver = self,
            .state = self.state,
        };

        return driver_pkg.Conn{
            .ptr = conn_ctx,
            .vtable = &.{
                .prepare = MockConn.prepare,
                .close = MockConn.close,
                .begin = MockConn.begin,
                .beginTx = MockConn.beginTx,
                .ping = MockConn.ping,
                .execDirect = MockConn.execDirect,
                .interrupt = MockConn.interrupt,
            },
        };
    }

    const MockConn = struct {
        driver: *MockDriver,
        state: *State,

        fn execDirect(
            ctx: *anyopaque,
            io: std.Io,
            _: []const u8,
            _: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                if (self.state.fail_with_bad_conn_count > 0) {
                    self.state.fail_with_bad_conn_count -= 1;
                    return error.ErrBadConn;
                }
            }
            return Result{
                .last_insert_id = 1001,
                .rows_affected = 1,
            };
        }

        fn prepare(
            ctx: *anyopaque,
            io: std.Io,
            query_str: []const u8,
            deadline: Deadline,
        ) anyerror!driver_pkg.Stmt {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                if (self.state.fail_with_bad_conn_count > 0) {
                    self.state.fail_with_bad_conn_count -= 1;
                    return error.ErrBadConn;
                }
            }
            const q_copy = try self.state.allocator.dupe(u8, query_str);
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                try self.state.executed_queries.append(self.state.allocator, q_copy);
            }

            const stmt_ctx = try self.state.allocator.create(MockStmt);
            stmt_ctx.* = .{ .conn = self };
            return driver_pkg.Stmt{
                .ptr = stmt_ctx,
                .vtable = &.{
                    .close = MockStmt.close,
                    .numInput = MockStmt.numInput,
                    .exec = MockStmt.exec,
                    .query = MockStmt.query,
                },
            };
        }

        fn close(ctx: *anyopaque) void {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                self.state.close_count += 1;
            }
            self.state.allocator.destroy(self);
        }

        fn begin(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!driver_pkg.Tx {
            return beginTx(ctx, io, .{}, deadline);
        }

        fn beginTx(
            ctx: *anyopaque,
            io: std.Io,
            opts: driver_pkg.TxOptions,
            deadline: Deadline,
        ) anyerror!driver_pkg.Tx {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                if (self.state.fail_with_bad_conn_count > 0) {
                    self.state.fail_with_bad_conn_count -= 1;
                    return error.ErrBadConn;
                }
                self.state.last_tx_opts = opts;
            }
            const tx_ctx = try self.state.allocator.create(MockTx);
            tx_ctx.* = .{ .conn = self };
            return driver_pkg.Tx{
                .ptr = tx_ctx,
                .vtable = &.{
                    .commit = MockTx.commit,
                    .rollback = MockTx.rollback,
                },
            };
        }

        fn ping(ctx: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            if (self.state.fail_with_bad_conn_count > 0) {
                self.state.fail_with_bad_conn_count -= 1;
                return error.ErrBadConn;
            }
        }

        fn interrupt(ctx: *anyopaque) void {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            self.state.interrupt_count += 1;
        }
    };

    const MockStmt = struct {
        conn: *MockConn,

        fn close(ctx: *anyopaque) void {
            const self: *MockStmt = @ptrCast(@alignCast(ctx));
            self.conn.state.allocator.destroy(self);
        }

        fn numInput(_: *anyopaque) i64 {
            return 0;
        }

        fn exec(
            _: *anyopaque,
            io: std.Io,
            _: []const NamedValue,
            deadline: Deadline,
        ) anyerror!Result {
            try driver_pkg.checkOperation(io, deadline);
            return Result{
                .last_insert_id = 1001,
                .rows_affected = 1,
            };
        }

        fn query(
            ctx: *anyopaque,
            io: std.Io,
            _: []const NamedValue,
            deadline: Deadline,
        ) anyerror!driver_pkg.Rows {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockStmt = @ptrCast(@alignCast(ctx));
            const rows_ctx = try self.conn.state.allocator.create(MockRows);
            rows_ctx.* = .{
                .conn = self.conn,
                .cursor = 0,
            };
            return driver_pkg.Rows{
                .ptr = rows_ctx,
                .vtable = &.{
                    .columnCount = MockRows.columnCount,
                    .columnName = MockRows.columnName,
                    .next = MockRows.next,
                    .close = MockRows.close,
                    .columnTypeDatabaseTypeName = MockRows.columnTypeDatabaseTypeName,
                    .columnTypeNullable = MockRows.columnTypeNullable,
                },
            };
        }
    };

    const MockRows = struct {
        conn: *MockConn,
        cursor: usize = 0,

        const cols = [_][]const u8{ "id", "name", "role" };
        const col_types = [_][]const u8{ "BIGINT", "VARCHAR(255)", "VARCHAR(64)" };

        fn columnCount(_: *anyopaque) usize {
            return cols.len;
        }

        fn columnName(_: *anyopaque, index: usize) []const u8 {
            if (index < cols.len) return cols[index];
            return "";
        }

        fn columnTypeDatabaseTypeName(_: *anyopaque, index: usize) ?[]const u8 {
            if (index < col_types.len) return col_types[index];
            return null;
        }

        fn columnTypeNullable(_: *anyopaque, index: usize) ?bool {
            if (index == 0) return false;
            return true;
        }

        fn next(ctx: *anyopaque, io: std.Io, dest: []Value, deadline: Deadline) anyerror!bool {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockRows = @ptrCast(@alignCast(ctx));
            if (self.cursor >= 2) return false;
            if (dest.len != cols.len) return error.ColumnCountMismatch;

            if (self.cursor == 0) {
                dest[0] = Value{ .int = 1 };
                dest[1] = Value{ .string = "alice" };
                dest[2] = Value{ .string = "admin" };
            } else if (self.cursor == 1) {
                dest[0] = Value{ .int = 2 };
                dest[1] = Value{ .string = "bob" };
                dest[2] = Value{ .string = "dev" };
            }
            self.cursor += 1;
            return true;
        }

        fn close(ctx: *anyopaque) void {
            const self: *MockRows = @ptrCast(@alignCast(ctx));
            self.conn.state.allocator.destroy(self);
        }
    };

    const MockTx = struct {
        conn: *MockConn,

        fn commit(ctx: *anyopaque, _: std.Io, _: Deadline) anyerror!void {
            const self: *MockTx = @ptrCast(@alignCast(ctx));
            self.conn.state.tx_commits += 1;
            self.conn.state.allocator.destroy(self);
        }

        fn rollback(ctx: *anyopaque, _: std.Io, _: Deadline) anyerror!void {
            const self: *MockTx = @ptrCast(@alignCast(ctx));
            self.conn.state.tx_rollbacks += 1;
            self.conn.state.allocator.destroy(self);
        }
    };
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
    const c1 = try db.conn(.none);
    const c2 = try db.conn(.none);

    var s = db.stats();
    try testing.expectEqual(@as(usize, 2), s.open_connections);
    try testing.expectEqual(@as(usize, 2), s.in_use);
    try testing.expectEqual(@as(usize, 0), s.idle);

    // Release c1 -> goes to idle
    c1.release();
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.in_use);

    // Release c2 -> max_idle is 1, so c2 is closed!
    c2.release();
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
                const pc = db_ptr.conn(.none) catch return;
                defer pc.release();
                // Simulating query execution
                var stmt = pc.raw.prepare(db_ptr.io, "SELECT 1", .none) catch continue;
                defer stmt.close();
                _ = stmt.exec(db_ptr.io, &.{}, .none) catch {};
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
    const held = try db.conn(.none);
    var held_released = false;
    defer if (!held_released) held.release();

    const Worker = struct {
        fn run(database: *DB, _: std.Io) !void {
            const connection = try database.conn(.none);
            connection.release();
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
    held.release();
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
    const held = try db.conn(.none);
    defer held.release();
    const Worker = struct {
        fn run(database: *DB, _: std.Io) !void {
            const connection = try database.conn(.none);
            connection.release();
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
            const connection = try database.conn(.none);
            connection.release();
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
        const pc = try db.conn(.none);
        defer pc.release();

        try testing.expect(pc.interrupt());
        try testing.expectEqual(@as(usize, 1), state.interrupt_count);
    }

    // 2. DB.interruptAll() across active pool connections
    {
        const pc1 = try db.conn(.none);
        defer pc1.release();
        const pc2 = try db.conn(.none);
        defer pc2.release();

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
    const c_id = Value.bind(CustomId{ .raw = 999 });
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
    const c1 = try db.conn(.none);
    c1.release();

    try testing.expectEqual(@as(usize, 1), db.stats().idle);

    // Sleep slightly so idle duration exceeds 1ns
    try io.sleep(std.Io.Duration.fromNanoseconds(1000), .awake);

    // Acquiring again must evict the expired connection and open a fresh one
    const c2 = try db.conn(.none);
    defer c2.release();

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
    const v1 = Value.bind(b);
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
        try testing.expectError(error.DBClosed, rows.columnType(0));
        try testing.expectEqual(error.DBClosed, rows.err().?);

        var dest: [3]Value = undefined;
        try testing.expectError(error.DBClosed, rows.next(&dest, .none));
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

test {
    if (build_options.have_sqlite) {
        _ = sqlite;
    }
}
