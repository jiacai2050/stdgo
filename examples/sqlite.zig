//! Example demonstrating real SQLite integration with stdgo.database.sql.
//! Requires building with '-Dsqlite=true'.

const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo database/sql Real SQLite Driver Demo ===\n\n", .{});

    // 1. Initialize SQLite Driver
    var sqlite_drv = sql.sqlite.SQLiteDriver.init(allocator);

    // 2. Open SQLite Database Pool
    // Supported DSN formats:
    // - ":memory:" (isolated in-memory database per connection)
    // - "app.db" (local file database)
    // - "file:products_db?mode=memory&cache=shared" (shared in-memory URI across all pool connections)
    // - "sqlite://:memory:" or "sqlite3://app.db" (scheme prefixes are automatically stripped)
    const db = try sql.DB.open(allocator, init.io, sqlite_drv.driver(), "file:products_db?mode=memory&cache=shared");
    defer db.close();

    db.setMaxOpenConns(5);
    db.setMaxIdleConns(2);

    std.debug.print("1. SQLite Database opened (DSN: '{s}')\n", .{db.dsn});

    // 3. Ping
    try db.ping(.none);
    std.debug.print("2. Ping successful. Open: {d}, Idle: {d}\n\n", .{
        db.stats().open_connections,
        db.stats().idle,
    });

    // 4. Create Table
    // Executes DDL without parameters
    _ = try db.exec(
        \\CREATE TABLE products (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    price REAL NOT NULL,
        \\    in_stock INTEGER NOT NULL
        \\);
    , &.{}, .none);
    std.debug.print("3. Table 'products' created successfully.\n\n", .{});

    // 5. Insert Records via Parameterized Exec
    // Arguments are bound to positional '?' placeholders safely without SQL injection risk
    const r1 = try db.exec(
        "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "Mechanical Keyboard" },
            sql.Value{ .float = 129.99 },
            sql.Value{ .int = 1 },
        },
        .none,
    );
    std.debug.print("4. Inserted item #1 -> ID: {d}, Rows Affected: {d}\n", .{
        r1.lastInsertId(),
        r1.rowsAffected(),
    });

    const r2 = try db.exec(
        "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "Ergonomic Mouse" },
            sql.Value{ .float = 79.50 },
            sql.Value{ .int = 1 },
        },
        .none,
    );
    std.debug.print("   Inserted item #2 -> ID: {d}, Rows Affected: {d}\n\n", .{
        r2.lastInsertId(),
        r2.rowsAffected(),
    });

    // 6. Query Records (SELECT)
    // db.query obtains a pooled connection and prepares the statement.
    // The connection is held until rows.close() is called or rows are exhausted.
    std.debug.print("5. Querying 'products' table:\n", .{});
    var rows = try db.query("SELECT id, name, price, in_stock FROM products ORDER BY id ASC", &.{}, .none);
    defer rows.close();

    const cols = rows.columns();
    std.debug.print("   Columns: [", .{});
    for (cols, 0..) |col, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{col});
    }
    std.debug.print("]\n", .{});

    // Scan column values sequentially into the record buffer
    var record: [4]sql.Value = undefined;
    while (try rows.next(&record, .none)) {
        std.debug.print("   -> Product #{d}: '{s}' | ${d:.2} | in_stock: {s}\n", .{
            record[0].int,
            record[1].string,
            record[2].float,
            if (record[3].int == 1) "YES" else "NO",
        });
    }
    // Verify rows.err() is clean after iteration
    if (rows.err()) |e| {
        std.debug.print("   -> rows iteration error: {any}\n", .{e});
    }
    std.debug.print("\n", .{});

    // 7. Single-row Queries (db.queryRow & ErrNoRows)
    std.debug.print("6. Single-row Queries (db.queryRow & ErrNoRows):\n", .{});
    {
        var row = db.queryRow("SELECT name, price FROM products WHERE id = ?", &.{sql.Value{ .int = 1 }}, .none);
        defer row.close();
        var dest: [2]sql.Value = undefined;
        try row.scan(&dest, .none);
        std.debug.print("   -> Product #1 single lookup: '{s}' | ${d:.2}\n", .{
            dest[0].string,
            dest[1].float,
        });

        // Querying non-existent item triggers error.ErrNoRows
        var non_existent = db.queryRow("SELECT name, price FROM products WHERE id = 9999", &.{}, .none);
        defer non_existent.close();
        var dummy: [2]sql.Value = undefined;
        non_existent.scan(&dummy, .none) catch |err| switch (err) {
            error.ErrNoRows => std.debug.print("   -> Querying ID 9999 returned error.ErrNoRows as expected!\n\n", .{}),
            else => return err,
        };
    }

    // 8. Advanced Transaction with Isolation Level (db.beginTx & TxOptions)
    // Supports TxOptions with isolation levels (e.g. .serializable) and read-only flags
    std.debug.print("7. Transactions with Isolation Level (db.beginTx & Tx.queryRow):\n", .{});
    {
        var tx = try db.beginTx(.{
            .isolation = .serializable,
            .read_only = false,
        }, .none);
        defer tx.rollback(.none) catch {};

        _ = try tx.exec("UPDATE products SET price = price * 0.9 WHERE id = 1", &.{}, .none);

        // Use tx.queryRow inside transaction to verify new price
        var tx_row = tx.queryRow("SELECT price FROM products WHERE id = 1", &.{}, .none);
        defer tx_row.close();
        var price_dest: [1]sql.Value = undefined;
        try tx_row.scan(&price_dest, .none);
        std.debug.print("   -> In-transaction updated price: ${d:.2}\n", .{price_dest[0].float});

        try tx.commit(.none);
        std.debug.print("   -> Serializable transaction committed successfully!\n\n", .{});
    }

    // 9. Native Diagnostic Error Message (conn.lastError)
    std.debug.print("8. Native Detailed Error Reporting (conn.lastError):\n", .{});
    {
        const pc = try db.conn(.none);
        defer pc.release();

        // Intentionally execute malformed SQL: "FORM" instead of "FROM"
        _ = pc.exec("SELECT * FORM products", &.{}, .none) catch |err| {
            std.debug.print("   -> Exec failed with Zig error: {any}\n", .{err});
            if (pc.lastError()) |native_msg| {
                std.debug.print("   -> SQLite Native Detail: \"{s}\"\n\n", .{native_msg});
            }
        };
    }

    // 10. Pool Stats
    const st = db.stats();
    std.debug.print("9. Pool Stats:\n", .{});
    std.debug.print("   -> Open Conns: {d}, Idle: {d}, In-Use: {d}\n", .{
        st.open_connections,
        st.idle,
        st.in_use,
    });

    std.debug.print("\n=== SQLite Demo Complete ===\n", .{});
}
