//! Built-in in-memory mock driver for `stdgo.database.sql` unit testing and examples.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = @import("../../sync/mutex.zig").Mutex;
const Deadline = @import("../../io/deadline.zig").Deadline;
const driver_pkg = @import("driver.zig");
const Value = driver_pkg.Value;
const NamedValue = driver_pkg.NamedValue;
const Result = driver_pkg.Result;

/// MockDriver is a built-in in-memory database driver for unit testing and examples.
pub const MockDriver = struct {
    /// State holds shared counters, recorded queries, and fault-injection hooks for MockDriver.
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
        last_error_msg: ?[]const u8 = null,

        /// Initializes a new MockDriver State using the given allocator.
        pub fn init(allocator: Allocator) State {
            return .{
                .allocator = allocator,
                .executed_queries = std.ArrayList([]const u8).empty,
            };
        }

        /// Releases all recorded query strings and internal buffers owned by State.
        pub fn deinit(self: *State) void {
            for (self.executed_queries.items) |q| self.allocator.free(q);
            self.executed_queries.deinit(self.allocator);
        }
    };

    state: *State,

    /// Returns the generic `driver.Driver` interface backed by this MockDriver.
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
            .vtable = &MockConn.vtable,
        };
    }

    /// MockConn implements `driver.Conn` for unit testing.
    pub const MockConn = struct {
        driver: *MockDriver,
        state: *State,

        const vtable: driver_pkg.Conn.VTable = .{
            .prepare = MockConn.prepare,
            .close = MockConn.close,
            .beginTx = MockConn.beginTx,
            .ping = MockConn.ping,
            .execDirect = MockConn.execDirect,
            .interrupt = MockConn.interrupt,
            .lastError = MockConn.lastError,
        };

        /// Safely downcasts a `driver.Conn` (e.g. inside `sql.Conn.raw`) to `*MockConn`.
        /// Returns `null` if `raw_conn` does not belong to `MockDriver`.
        pub fn fromDriverConn(raw_conn: driver_pkg.Conn) ?*MockConn {
            if (raw_conn.vtable != &vtable) return null;
            return @ptrCast(@alignCast(raw_conn.ptr));
        }

        fn lastError(ctx: *anyopaque) ?[]const u8 {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            return self.state.last_error_msg;
        }

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
