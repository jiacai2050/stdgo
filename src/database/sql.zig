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

pub const Value = driver.Value;
pub const Result = driver.Result;
pub const IsolationLevel = driver.IsolationLevel;
pub const TxOptions = driver.TxOptions;
pub const ErrBadConn = driver.ErrBadConn;
pub const ErrNoRows = error.ErrNoRows;

pub const DBStats = struct {
    max_open_connections: usize,
    open_connections: usize,
    in_use: usize,
    idle: usize,
    wait_count: u64,
    wait_duration_ns: u64,
    max_idle_closed: u64,
    max_lifetime_closed: u64,
};

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
            self.close();
            return next_error;
        };
        if (!has_row) {
            self.close();
            return error.ErrNoRows;
        }
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
    pub fn exec(self: *PooledConn, query_str: []const u8, args: []const Value, deadline: Deadline) !Result {
        const io = self.db.io;
        try self.db.checkOperation(deadline);
        var stmt = try self.raw.prepare(io, query_str, deadline);
        defer stmt.close();

        return stmt.exec(io, args, deadline);
    }

    /// Query executes a query returning rows on this connection.
    pub fn query(self: *PooledConn, query_str: []const u8, args: []const Value, deadline: Deadline) !Rows {
        const io = self.db.io;
        try self.db.checkOperation(deadline);
        var stmt = try self.raw.prepare(io, query_str, deadline);
        errdefer stmt.close();

        const raw_rows = try stmt.query(io, args, deadline);
        return Rows{
            .pooled_conn = null,
            .stmt = stmt,
            .raw_rows = raw_rows,
            .io = io,
        };
    }

    /// QueryRow executes a query that is expected to return at most one row.
    pub fn queryRow(self: *PooledConn, query_str: []const u8, args: []const Value, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// BeginTx starts a transaction on this connection.
    pub fn beginTx(self: *PooledConn, opts: TxOptions, deadline: Deadline) !Tx {
        try self.db.checkOperation(deadline);
        const raw_tx = try self.raw.beginTx(self.db.io, opts, deadline);
        return Tx{
            .pooled_conn = self,
            .raw_tx = raw_tx,
        };
    }
};

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

    num_open: usize = 0,
    free_conns: std.ArrayList(*PooledConn),
    active_conns: std.ArrayList(*PooledConn),
    closed: bool = false,
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    wait_count: u64 = 0,
    wait_duration_ns: u64 = 0,
    max_idle_closed: u64 = 0,
    max_lifetime_closed: u64 = 0,

    /// Open creates a database handle using the supplied I/O implementation.
    /// The I/O implementation must outlive the DB and its borrowed connections and rows.
    pub fn open(allocator: Allocator, io: std.Io, drv: driver.Driver, dsn: []const u8) !*DB {
        const db = try allocator.create(DB);
        const dsn_copy = try allocator.dupe(u8, dsn);
        db.* = .{
            .allocator = allocator,
            .io = io,
            .driver_instance = drv,
            .dsn = dsn_copy,
            .free_conns = std.ArrayList(*PooledConn).empty,
            .active_conns = std.ArrayList(*PooledConn).empty,
            .ref_count = std.atomic.Value(usize).init(1),
        };
        return db;
    }

    fn destroySelf(self: *DB) void {
        for (self.free_conns.items) |pc| {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -%= 1;
        }
        self.active_conns.deinit(self.allocator);
        self.free_conns.deinit(self.allocator);
        self.allocator.free(self.dsn);
        self.allocator.destroy(self);
    }

    fn decrementRef(self: *DB) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.destroySelf();
        }
    }

    fn currentNanoTimestamp(self: *DB) i128 {
        return @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
    }

    fn checkOperation(self: *DB, deadline: Deadline) !void {
        try driver_pkg.checkDeadlineSupport(self.io, deadline, self.driver_instance.vtable.supports_deadline);
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

        for (self.active_conns.items) |pc| {
            _ = pc.interrupt();
        }

        // Close and free all idle connections immediately
        for (self.free_conns.items) |pc| {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
        }
        self.free_conns.clearRetainingCapacity();

        // Optional grace period waiting for active queries to exit gracefully
        const max_wait_attempts: usize = 1000;
        var attempts: usize = 0;
        while (self.active_conns.items.len > 0 and attempts < max_wait_attempts) : (attempts += 1) {
            self.mutex.unlock(self.io);
            self.io.sleep(std.Io.Duration.fromNanoseconds(500 * std.time.ns_per_us), .awake) catch {
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
        while (self.free_conns.items.len > self.max_idle_conns) {
            const pc = self.free_conns.pop().?;
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

    /// Stats returns database statistics.
    pub fn stats(self: *DB) DBStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idle = self.free_conns.items.len;
        return .{
            .max_open_connections = self.max_open_conns,
            .open_connections = self.num_open,
            .in_use = self.num_open - idle,
            .idle = idle,
            .wait_count = self.wait_count,
            .wait_duration_ns = self.wait_duration_ns,
            .max_idle_closed = self.max_idle_closed,
            .max_lifetime_closed = self.max_lifetime_closed,
        };
    }

    /// Ping verifies a connection to the database is still alive, establishing a connection if necessary.
    pub fn ping(self: *DB, deadline: Deadline) !void {
        const pc = try self.conn(deadline);
        defer pc.release();
        try pc.raw.ping(self.io, deadline);
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
            while (self.free_conns.items.len > 0) {
                const pc = self.free_conns.pop().?;
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
                pc.last_used_at_ns = now;
                pc.from_pool = true;
                self.active_conns.append(self.allocator, pc) catch |append_err| {
                    self.free_conns.append(self.allocator, pc) catch {
                        pc.raw.close();
                        self.allocator.destroy(pc);
                        self.num_open -= 1;
                    };
                    return append_err;
                };
                _ = self.ref_count.fetchAdd(1, .acquire);
                return pc;
            }

            // 2. Open a new connection if under max_open_conns
            if (self.max_open_conns == 0 or self.num_open < self.max_open_conns) {
                self.num_open += 1;
                // Temporarily release mutex while opening connection to avoid blocking other threads
                self.mutex.unlock(self.io);
                var raw_conn = self.driver_instance.open(self.io, self.dsn, deadline) catch |err| {
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
                self.active_conns.append(self.allocator, pc) catch |append_err| {
                    pc.raw.close();
                    self.allocator.destroy(pc);
                    self.num_open -= 1;
                    self.pool_changed.signal(self.io);
                    return append_err;
                };
                _ = self.ref_count.fetchAdd(1, .acquire);
                return pc;
            }

            // 3. Wait until capacity changes or the task is canceled.
            self.wait_count += 1;
            const wait_started = std.Io.Clock.awake.now(self.io).nanoseconds;
            const wait_result = self.pool_changed.waitTimeout(self.io, &self.mutex, deadline.timeout());
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

        for (self.active_conns.items, 0..) |item, i| {
            if (item == pc) {
                _ = self.active_conns.swapRemove(i);
                break;
            }
        }

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

        if (self.free_conns.items.len >= self.max_idle_conns) {
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
        self.free_conns.append(self.allocator, pc) catch {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.mutex.unlock(self.io);
            self.decrementRef();
            return;
        };
        self.mutex.unlock(self.io);
        self.decrementRef();
    }

    /// Discards a bad connection from the pool permanently.
    fn discardConn(self: *DB, pc: *PooledConn) void {
        self.mutex.lockUncancelable(self.io);
        self.pool_changed.signal(self.io);
        for (self.active_conns.items, 0..) |item, i| {
            if (item == pc) {
                _ = self.active_conns.swapRemove(i);
                break;
            }
        }
        pc.raw.close();
        self.allocator.destroy(pc);
        self.num_open -= 1;
        self.mutex.unlock(self.io);

        self.decrementRef();
    }

    /// Exec executes a query without returning any rows.
    /// If an idle connection from the pool fails with ErrBadConn, it retries once with a fresh connection.
    pub fn exec(self: *DB, query_str: []const u8, args: []const Value, deadline: Deadline) !Result {
        try self.checkOperation(deadline);
        var retry: usize = 0;
        while (true) : (retry += 1) {
            const pc = try self.conn(deadline);
            const res = pc.exec(query_str, args, deadline) catch |err| {
                if (err == error.ErrBadConn and pc.from_pool and retry == 0) {
                    self.discardConn(pc);
                    continue;
                }
                pc.release();
                return err;
            };
            pc.release();
            return res;
        }
    }

    /// Query executes a query that returns rows, typically a SELECT.
    /// If an idle connection from the pool fails with ErrBadConn, it retries once with a fresh connection.
    pub fn query(self: *DB, query_str: []const u8, args: []const Value, deadline: Deadline) !Rows {
        try self.checkOperation(deadline);
        var retry: usize = 0;
        while (true) : (retry += 1) {
            const pc = try self.conn(deadline);
            var rows = pc.query(query_str, args, deadline) catch |err| {
                if (err == error.ErrBadConn and pc.from_pool and retry == 0) {
                    self.discardConn(pc);
                    continue;
                }
                pc.release();
                return err;
            };
            rows.pooled_conn = pc;
            return rows;
        }
    }

    /// QueryRow executes a query that is expected to return at most one row.
    pub fn queryRow(self: *DB, query_str: []const u8, args: []const Value, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
    }

    /// InterruptAll signals all currently active/in-flight queries across the pool to abort out-of-band.
    /// Returns the number of connections that were successfully signaled.
    pub fn interruptAll(self: *DB) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.active_conns.items) |pc| {
            if (pc.interrupt()) {
                count += 1;
            }
        }
        return count;
    }

    /// BeginTx starts a transaction with options.
    pub fn beginTx(self: *DB, opts: TxOptions, deadline: Deadline) !Tx {
        try self.checkOperation(deadline);
        var retry: usize = 0;
        while (true) : (retry += 1) {
            const pc = try self.conn(deadline);
            const tx = pc.beginTx(opts, deadline) catch |err| {
                if (err == error.ErrBadConn and pc.from_pool and retry == 0) {
                    self.discardConn(pc);
                    continue;
                }
                pc.release();
                return err;
            };
            return tx;
        }
    }

    /// Begin starts a transaction with default options.
    pub fn begin(self: *DB, deadline: Deadline) !Tx {
        return self.beginTx(.{}, deadline);
    }
};

/// Rows is the result of a query. Its cursor starts before the first row of the result set.
/// Use Next to advance through the rows.
pub const Rows = struct {
    pooled_conn: ?*PooledConn,
    stmt: driver.Stmt,
    raw_rows: driver.Rows,
    io: std.Io,
    closed: bool = false,
    last_err: ?anyerror = null,
    last_error_msg: ?[]const u8 = null,

    pub fn columns(self: *Rows) []const []const u8 {
        return self.raw_rows.columns();
    }

    pub fn next(self: *Rows, dest: []Value, deadline: Deadline) !bool {
        if (self.closed) return false;
        try driver_pkg.checkOperation(self.io, deadline);
        const has_more = self.raw_rows.next(self.io, dest, deadline) catch |next_error| {
            if (next_error == error.Canceled or next_error == error.DeadlineUnsupported or next_error == error.InvalidDeadline) {
                return next_error;
            }
            self.last_err = next_error;
            if (self.pooled_conn) |pc| {
                self.last_error_msg = pc.lastError();
            }
            self.close();
            return next_error;
        };
        if (!has_more) {
            self.last_err = self.raw_rows.err();
            if (self.pooled_conn) |pc| {
                self.last_error_msg = pc.lastError();
            }
            self.close();
            if (self.last_err) |row_error| return row_error;
        }
        return has_more;
    }

    /// Err returns the error, if any, that was encountered during iteration.
    /// Returns null if iteration finished cleanly.
    pub fn err(self: *Rows) ?anyerror {
        if (self.closed) return self.last_err;
        return self.last_err orelse self.raw_rows.err();
    }

    /// LastError returns the error message for the last operation on the underlying connection.
    pub fn lastError(self: *Rows) ?[]const u8 {
        if (self.last_error_msg) |m| return m;
        if (self.closed) return null;
        if (self.pooled_conn) |pc| return pc.lastError();
        return null;
    }

    pub fn close(self: *Rows) void {
        if (self.closed) return;
        self.closed = true;
        self.raw_rows.close();
        self.stmt.close();
        if (self.pooled_conn) |pc| {
            pc.release();
            self.pooled_conn = null;
        }
    }
};

/// Tx is an in-progress database transaction.
///
/// A transaction must end with a call to Commit or Rollback, which releases
/// the underlying pooled connection back to the DB pool.
pub const Tx = struct {
    pooled_conn: ?*PooledConn,
    raw_tx: driver.Tx,
    done: bool = false,

    /// Commits the transaction and returns the connection to the pool.
    pub fn commit(self: *Tx, deadline: Deadline) !void {
        if (self.done) return error.TxDone;
        const connection = self.pooled_conn orelse return error.TxDone;
        const io = connection.db.io;
        try driver_pkg.checkDeadlineSupport(io, deadline, self.raw_tx.vtable.supports_deadline);
        self.done = true;
        self.pooled_conn = null;
        self.raw_tx.vtable.commit(self.raw_tx.ptr, io, deadline) catch |err| {
            connection.db.discardConn(connection);
            return err;
        };
        connection.release();
    }

    /// Aborts and rolls back the transaction, returning the connection to the pool.
    pub fn rollback(self: *Tx, deadline: Deadline) !void {
        if (self.done) return error.TxDone;
        const connection = self.pooled_conn orelse return error.TxDone;
        const io = connection.db.io;
        try deadline.validate();
        if (!deadline.isNone()) {
            try driver_pkg.checkDeadlineSupport(io, deadline, self.raw_tx.vtable.supports_deadline);
        }
        self.done = true;
        self.pooled_conn = null;
        self.raw_tx.vtable.rollback(self.raw_tx.ptr, io, deadline) catch |err| {
            connection.db.discardConn(connection);
            return err;
        };
        connection.release();
    }

    /// Executes a query within the transaction that does not return rows (e.g. INSERT, UPDATE).
    pub fn exec(self: *Tx, query_str: []const u8, args: []const Value, deadline: Deadline) !Result {
        if (self.done) return error.TxDone;
        const pc = self.pooled_conn orelse return error.TxDone;
        return pc.exec(query_str, args, deadline);
    }

    /// The transaction connection remains tied to this transaction until commit or rollback.
    pub fn query(self: *Tx, query_str: []const u8, args: []const Value, deadline: Deadline) !Rows {
        if (self.done) return error.TxDone;
        const pc = self.pooled_conn orelse return error.TxDone;
        var rows = try pc.query(query_str, args, deadline);
        rows.pooled_conn = null; // Tx retains connection until commit/rollback
        return rows;
    }

    /// QueryRow executes a query within the transaction expecting at most one row.
    pub fn queryRow(self: *Tx, query_str: []const u8, args: []const Value, deadline: Deadline) Row {
        const r = self.query(query_str, args, deadline) catch |err| {
            return Row{ .err_state = err };
        };
        return Row{ .rows = r };
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

    fn open(ctx: *anyopaque, io: std.Io, _: []const u8, deadline: Deadline) anyerror!driver_pkg.Conn {
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
                .interrupt = MockConn.interrupt,
            },
        };
    }

    const MockConn = struct {
        driver: *MockDriver,
        state: *State,

        fn prepare(ctx: *anyopaque, io: std.Io, query_str: []const u8, deadline: Deadline) anyerror!driver_pkg.Stmt {
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

        fn beginTx(ctx: *anyopaque, io: std.Io, opts: driver_pkg.TxOptions, deadline: Deadline) anyerror!driver_pkg.Tx {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
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

        fn ping(_: *anyopaque, io: std.Io, deadline: Deadline) anyerror!void {
            try driver_pkg.checkOperation(io, deadline);
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

        fn exec(_: *anyopaque, io: std.Io, _: []const Value, deadline: Deadline) anyerror!Result {
            try driver_pkg.checkOperation(io, deadline);
            return Result{
                .last_insert_id = 1001,
                .rows_affected = 1,
            };
        }

        fn query(ctx: *anyopaque, io: std.Io, _: []const Value, deadline: Deadline) anyerror!driver_pkg.Rows {
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
                    .columns = MockRows.columns,
                    .next = MockRows.next,
                    .close = MockRows.close,
                },
            };
        }
    };

    const MockRows = struct {
        conn: *MockConn,
        cursor: usize = 0,

        const cols = [_][]const u8{ "id", "name", "role" };

        fn columns(_: *anyopaque) []const []const u8 {
            return &cols;
        }

        fn next(ctx: *anyopaque, io: std.Io, dest: []Value, deadline: Deadline) anyerror!bool {
            try driver_pkg.checkOperation(io, deadline);
            const self: *MockRows = @ptrCast(@alignCast(ctx));
            if (self.cursor >= 2) return false;

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    const res = try db.exec("INSERT INTO users (name) VALUES (?)", &.{Value{ .string = "charlie" }}, .none);
    try testing.expectEqual(@as(i64, 1001), res.lastInsertId());
    try testing.expectEqual(@as(i64, 1), res.rowsAffected());

    // 3. Query
    var rows = try db.query("SELECT id, name, role FROM users", &.{}, .none);
    defer rows.close();

    const cols = rows.columns();
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("id", cols[0]);

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();
    var mock = MockDriver{ .state = &state };
    const Failing = struct {
        mock_driver: *MockDriver,
        started: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        attempts: std.atomic.Value(usize) = .init(0),

        fn open(ptr: *anyopaque, task_io: std.Io, dsn: []const u8, deadline: Deadline) anyerror!driver.Conn {
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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // 3. Deadline is rejected before the driver is invoked.
    {
        const deadline = @import("../io/deadline.zig").Deadline.after(io, .fromSeconds(1));
        const invalid: Deadline = .{ .timestamp = .now(io, .real) };
        const open_count = state.open_count;
        try testing.expectError(error.DeadlineUnsupported, db.ping(deadline));
        try testing.expectError(error.DeadlineUnsupported, db.exec("SELECT 1", &.{}, deadline));
        try testing.expectError(error.DeadlineUnsupported, db.query("SELECT 1", &.{}, deadline));
        try testing.expectError(error.InvalidDeadline, db.ping(invalid));
        try testing.expectEqual(open_count, state.open_count);
    }
}

test "database.sql: QueryRow and ErrNoRows" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // 2. Deadlines other than .none are rejected before invoking the driver.
    {
        var tx = try db.begin(.none);
        defer tx.rollback(.none) catch {};
        const deadline = @import("../io/deadline.zig").Deadline.after(io, .fromSeconds(1));
        try testing.expectError(error.DeadlineUnsupported, tx.exec("UPDATE users SET age = 30", &.{}, deadline));
        try testing.expectError(error.DeadlineUnsupported, tx.query("SELECT 1", &.{}, deadline));
        try testing.expectError(error.DeadlineUnsupported, tx.commit(deadline));
        try testing.expectError(error.DeadlineUnsupported, tx.rollback(deadline));
    }
}

test "database.sql: ErrBadConn retry on idle connection" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // db.exec should catch ErrBadConn on the idle connection, discard it, and retry on a fresh connection
    const res = try db.exec("SELECT 2", &.{}, .none);
    try testing.expectEqual(@as(i64, 1), res.rows_affected);

    // Verify open_count increased to 2 because bad connection was replaced
    try testing.expectEqual(@as(usize, 2), state.open_count);
}

test "database.sql: Rows.next reports task cancellation" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
        fn run(task_io: std.Io, r: *Rows, values: []Value, entered: *std.Io.Event, wait_gate: *std.Io.Event) !bool {
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
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Fake = struct {
        fn columns(_: *anyopaque) []const []const u8 {
            return &.{};
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
        fn exec(_: *anyopaque, _: std.Io, _: []const Value, _: Deadline) anyerror!Result {
            return error.UnexpectedCall;
        }
        fn query(_: *anyopaque, _: std.Io, _: []const Value, _: Deadline) anyerror!driver.Rows {
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
            .columns = Fake.columns,
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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    try testing.expectError(error.DeadlineUnsupported, rows.next(&dest, deadline));
    try testing.expect(!rows.closed);
}

test {
    if (build_options.have_sqlite) {
        _ = sqlite;
    }
}
