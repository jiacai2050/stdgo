//! Example demonstrating stdgo.database.sql:
//! Generic database connection pooling, transactions, prepared statements, and metrics.

const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo database/sql Connection Pool & Transaction Demo ===\n\n", .{});

    // 1. Initialize In-Memory Mock Driver
    var state = sql.MockDriver.State.init(allocator);
    defer state.deinit();

    var mock = sql.MockDriver{ .state = &state };

    // 2. Open DB Connection Pool
    const db = try sql.DB.open(allocator, init.io, mock.driver(), "mock://cluster-primary.internal:5432/production");
    defer db.close();

    // Configure connection pool parameters
    db.setMaxOpenConns(5);
    db.setMaxIdleConns(2);

    std.debug.print("1. DB Pool initialized (DSN: {s})\n", .{db.dsn});

    // 3. Ping Database
    try db.ping(.none);
    std.debug.print("2. Ping successful. Open Conns: {d}, Idle: {d}\n\n", .{
        db.stats().open_connections,
        db.stats().idle,
    });

    // 4. Execute Queries (INSERT / UPDATE)
    const res = try db.exec(
        "INSERT INTO users (name, role, status) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "diana" },
            sql.Value{ .string = "secops" },
            sql.Value{ .string = "active" },
        },
        .none,
    );
    std.debug.print("3. db.exec executed:\n   -> Last Insert ID: {d}\n   -> Rows Affected:  {d}\n\n", .{
        res.lastInsertId(),
        res.rowsAffected(),
    });

    // 5. Query Rows (SELECT)
    std.debug.print("4. db.query executed (SELECT id, name, role FROM users):\n", .{});
    var rows = try db.query("SELECT id, name, role FROM users", &.{}, .none);
    defer rows.close();

    const cols = rows.columns();
    std.debug.print("   Columns: [", .{});
    for (cols, 0..) |col, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{col});
    }
    std.debug.print("]\n", .{});

    var row_record: [3]sql.Value = undefined;
    while (try rows.next(&row_record, .none)) {
        std.debug.print("   Row -> ID: {d}, Name: '{s}', Role: '{s}'\n", .{
            row_record[0].int,
            row_record[1].string,
            row_record[2].string,
        });
    }
    // Verify rows.err() is clean
    if (rows.err()) |e| {
        std.debug.print("   -> rows iteration error: {any}\n", .{e});
    }
    std.debug.print("\n", .{});

    // 6. Single Row Query (db.queryRow & ErrNoRows)
    std.debug.print("5. Single-row Query (db.queryRow & ErrNoRows):\n", .{});
    {
        var row = db.queryRow("SELECT id, name, role FROM users LIMIT 1", &.{}, .none);
        defer row.close();
        var single_dest: [3]sql.Value = undefined;
        try row.scan(&single_dest, .none);
        std.debug.print("   -> Single row scanned: ID {d}, Name '{s}'\n", .{
            single_dest[0].int,
            single_dest[1].string,
        });

        // Demonstrating ErrNoRows on empty result:
        var empty_row = sql.Row{ .rows = null };
        defer empty_row.close();
        var dummy_dest: [1]sql.Value = undefined;
        empty_row.scan(&dummy_dest, .none) catch |err| switch (err) {
            error.ErrNoRows => std.debug.print("   -> Empty result handled gracefully with error.ErrNoRows!\n\n", .{}),
            else => return err,
        };
    }

    // 7. Transactions with Isolation Levels (db.beginTx & TxOptions)
    std.debug.print("6. Transactions (ACID Commit, Rollback, and Isolation Levels):\n", .{});
    // Successful transaction with serializable isolation:
    {
        var tx = try db.beginTx(.{
            .isolation = .serializable,
            .read_only = false,
        }, .none);
        _ = try tx.exec("UPDATE accounts SET balance = balance - 250 WHERE id = 1", &.{}, .none);
        _ = try tx.exec("UPDATE accounts SET balance = balance + 250 WHERE id = 2", &.{}, .none);
        try tx.commit(.none);
        std.debug.print("   -> Transaction #1 (Serializable) committed successfully!\n", .{});
    }

    // Aborted transaction rollback:
    {
        var tx = try db.begin(.none);
        _ = try tx.exec("UPDATE inventory SET stock = stock - 10 WHERE item_id = 99", &.{}, .none);
        // Something failed during checkout, rollback:
        try tx.rollback(.none);
        std.debug.print("   -> Transaction #2 rolled back cleanly on error!\n\n", .{});
    }

    // 8. Bad Connection Auto-Retry (driver.ErrBadConn)
    std.debug.print("7. Connection Pool Fault-Tolerance (driver.ErrBadConn Auto-Retry):\n", .{});
    {
        // Connection currently in idle pool will fail with ErrBadConn on next attempt
        state.fail_with_bad_conn_count = 1;
        std.debug.print("   -> Simulating server-side closed connection in idle pool...\n", .{});

        // db.exec transparently discards bad connection and retries on a fresh one:
        const retry_res = try db.exec("SELECT 1", &.{}, .none);
        std.debug.print("   -> db.exec auto-retried on fresh connection! Rows Affected: {d}\n\n", .{
            retry_res.rowsAffected(),
        });
    }

    // 9. Out-of-band Query Interruption (db.interruptAll)
    std.debug.print("8. Out-of-band Interruption (db.interruptAll):\n", .{});
    {
        const pc = try db.conn(.none);
        defer pc.release();

        const signaled = db.interruptAll();
        std.debug.print("   -> Signaled {d} active in-flight connection(s) to abort out-of-band.\n\n", .{
            signaled,
        });
    }

    // 10. Concurrent Connection Contention
    std.debug.print("9. Concurrent Workers Pool Contention (4 threads competing for pool):\n", .{});
    const Worker = struct {
        fn workerThread(db_handle: *sql.DB) void {
            for (0..10) |_| {
                const pc = db_handle.conn(.none) catch return;
                defer pc.release();
                var stmt = pc.raw.prepare(db_handle.io, "SELECT 1", .none) catch continue;
                defer stmt.close();
                _ = stmt.exec(db_handle.io, &.{}, .none) catch {};
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t2 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t3 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t4 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    // 11. DB Pool Statistics
    const st = db.stats();
    std.debug.print("10. Final Pool Statistics:\n", .{});
    std.debug.print("   -> Max Open:          {d}\n", .{st.max_open_connections});
    std.debug.print("   -> Current Open:      {d}\n", .{st.open_connections});
    std.debug.print("   -> In-Use:            {d}\n", .{st.in_use});
    std.debug.print("   -> Idle in Pool:      {d}\n", .{st.idle});
    std.debug.print("   -> Total Waits:       {d}\n", .{st.wait_count});
    std.debug.print("   -> Max-Idle Closed:   {d}\n", .{st.max_idle_closed});

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
