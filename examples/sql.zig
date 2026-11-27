//! Example demonstrating database/sql in stdgo.
//!
//! stdgo brings Go's database/sql connection pool, transaction management,
//! prepared statements, and streaming result iteration to Zig 0.17.
//!
//! By default, this example runs on pure Zig (using the built-in MockDriver)
//! with zero external C dependencies.
//! When built with `-Dsqlite=true`, it automatically switches to the real
//! C SQLite3 engine (in-memory mode) demonstrating live SQL DDL/DML.

const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;
const Allocator = std.mem.Allocator;

/// Product record demonstrating compile-time strongly-typed struct scanning.
const Product = struct {
    id: i64,
    name: []const u8,
    price: f64,
    in_stock: i64,
};

/// Summary struct for single-row queries.
const ProductSummary = struct {
    name: []const u8,
    price: f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const have_sqlite = @hasDecl(sql.sqlite, "SQLiteDriver");

    if (have_sqlite) {
        std.debug.print("=== stdgo: database/sql Example (Engine: Real C SQLite3) ===\n\n", .{});
        var sqlite_drv = sql.sqlite.SQLiteDriver.init(allocator);

        try runDatabaseDemo(
            allocator,
            io,
            sqlite_drv.driver(),
            "file:products_db?mode=memory&cache=shared",
            true,
        );
    } else {
        std.debug.print("=== stdgo: database/sql Example (Engine: Pure Zig MockDriver) ===\n", .{});
        std.debug.print(
            "Tip: Run with `-Dsqlite=true` to test against the real C SQLite3 engine.\n\n",
            .{},
        );

        var mock_state = sql.MockDriver.State.init(allocator);
        defer mock_state.deinit();
        var mock = sql.MockDriver{ .state = &mock_state };

        try runDatabaseDemo(
            allocator,
            io,
            mock.driver(),
            "mock://cluster-primary.internal:5432/production",
            false,
        );
    }

    std.debug.print("=== sql demo completed successfully! ===\n", .{});
}

/// Generic database demo function operating against any database/sql Driver abstraction.
fn runDatabaseDemo(
    allocator: Allocator,
    io: std.Io,
    drv: sql.driver.Driver,
    dsn: []const u8,
    is_sqlite: bool,
) !void {
    // 1. Open Database Connection Pool
    std.debug.print("1. Initializing DB connection pool:\n", .{});
    const db = try sql.DB.open(allocator, io, drv, dsn);
    defer db.close();

    db.setMaxOpenConns(5);
    db.setMaxIdleConns(2);

    // 2. Ping Database
    try db.ping(.none);
    std.debug.print("   -> Ping successful! Open: {d}, Idle: {d}\n\n", .{
        db.stats().open_connections,
        db.stats().idle,
    });

    // 3. DDL: Create Table if running against a live SQL engine
    if (is_sqlite) {
        std.debug.print("2. Creating 'products' table (DDL):\n", .{});
        _ = try db.exec(
            \\CREATE TABLE IF NOT EXISTS products (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT NOT NULL,
            \\    price REAL NOT NULL,
            \\    in_stock INTEGER NOT NULL
            \\);
        , .{}, .none);
        std.debug.print("   -> Table 'products' created successfully.\n\n", .{});
    }

    // 4. Insert Records via db.exec (Positional & Named Args)
    std.debug.print("3. Inserting records via db.exec (positional & named arguments):\n", .{});
    // Positional parameters using anonymous tuple .{ ... }
    const r1 = try db.exec(
        "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
        .{ "Mechanical Keyboard", 129.99, 1 },
        .none,
    );
    std.debug.print("   -> Insert #1 (positional tuple): ID={d}, Rows Affected={d}\n", .{
        try r1.lastInsertId(),
        try r1.rowsAffected(),
    });

    // Named parameters using anonymous struct literal .{ .name = ... }
    const r2 = if (is_sqlite)
        try db.exec(
            "INSERT INTO products (name, price, in_stock) VALUES (:name, :price, :in_stock)",
            .{ .name = "Ergonomic Mouse", .price = 79.50, .in_stock = 1 },
            .none,
        )
    else
        try db.exec(
            "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
            .{ "Ergonomic Mouse", 79.50, 1 },
            .none,
        );
    std.debug.print("   -> Insert #2 (named struct): ID={d}, Rows Affected={d}\n\n", .{
        try r2.lastInsertId(),
        try r2.rowsAffected(),
    });

    // 5. Prepared Statements (db.prepare & Stmt)
    // Precompiles SQL bytecode once and executes repeatedly in batch loops.
    std.debug.print("4. Prepared Statements (db.prepare & Stmt batch execution):\n", .{});
    {
        var prep_stmt = if (is_sqlite)
            try db.prepare(
                "INSERT INTO products (name, price, in_stock) VALUES (:name, :price, :in_stock)",
                .none,
            )
        else
            try db.prepare(
                "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
                .none,
            );
        defer prep_stmt.close();

        const batch = [_]struct { name: []const u8, price: f64, in_stock: i64 }{
            .{ .name = "4K Monitor 27-inch", .price = 399.00, .in_stock = 1 },
            .{ .name = "USB-C Hub Multiport", .price = 45.00, .in_stock = 0 },
        };
        for (batch) |item| {
            // Directly pass the struct instance `item`! Zero manual value mapping.
            const ins_res = try prep_stmt.exec(item, .none);
            std.debug.print("   -> Stmt executed for '{s}': ID={d}, Rows={d}\n", .{
                item.name,
                try ins_res.lastInsertId(),
                try ins_res.rowsAffected(),
            });
        }
        std.debug.print("\n", .{});
    }

    // 6. Query Records with Comptime Typed Struct Scanning (nextStruct)
    // Decodes columns directly into struct fields at compile time with zero heap allocation!
    if (is_sqlite) {
        std.debug.print(
            "5. Querying 'products' table via rows.nextStruct (comptime typed):\n",
            .{},
        );
        var rows = try db.query(
            "SELECT id, name, price, in_stock FROM products ORDER BY id ASC",
            .{},
            .none,
        );
        defer rows.close();

        std.debug.print("   Columns: [", .{});
        for (0..rows.columnCount()) |i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{rows.columnName(i)});
        }
        std.debug.print("]\n", .{});

        std.debug.print("   Schema Column Types: [", .{});
        for (0..rows.columnCount()) |i| {
            if (i > 0) std.debug.print(", ", .{});
            const ct = try rows.columnType(i);
            std.debug.print("{s}: {s}", .{ ct.name(), ct.databaseTypeName() orelse "UNKNOWN" });
        }
        std.debug.print("]\n", .{});

        while (try rows.nextStruct(Product, .none)) |p| {
            std.debug.print("   -> Product #{d}: '{s}' | ${d:.2} | in_stock: {s}\n", .{
                p.id,
                p.name,
                p.price,
                if (p.in_stock == 1) "YES" else "NO",
            });
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("5. Querying 'users' table via rows.nextStruct (comptime typed):\n", .{});
        const User = struct { id: i64, name: []const u8, role: []const u8 };
        var rows = try db.query("SELECT id, name, role FROM users", .{}, .none);
        defer rows.close();

        std.debug.print("   Columns: [", .{});
        for (0..rows.columnCount()) |i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{rows.columnName(i)});
        }
        std.debug.print("]\n", .{});

        std.debug.print("   Schema Column Types: [", .{});
        for (0..rows.columnCount()) |i| {
            if (i > 0) std.debug.print(", ", .{});
            const ct = try rows.columnType(i);
            std.debug.print("{s}: {s}", .{ ct.name(), ct.databaseTypeName() orelse "UNKNOWN" });
        }
        std.debug.print("]\n", .{});

        while (try rows.nextStruct(User, .none)) |u| {
            std.debug.print("   -> User #{d}: '{s}', role: '{s}'\n", .{
                u.id,
                u.name,
                u.role,
            });
        }
        std.debug.print("\n", .{});
    }

    // 7. Single-row Queries (scanStruct & ErrNoRows)
    std.debug.print("6. Single-row Queries (row.scanStruct & ErrNoRows):\n", .{});
    if (is_sqlite) {
        var row = db.queryRow(
            "SELECT name, price FROM products WHERE id = ?",
            .{1},
            .none,
        );
        defer row.close();
        const summary = try row.scanStruct(ProductSummary, .none);
        std.debug.print("   -> Product #1 scanned: '{s}' | ${d:.2}\n", .{
            summary.name,
            summary.price,
        });

        var non_existent = db.queryRow(
            "SELECT name, price FROM products WHERE id = 9999",
            .{},
            .none,
        );
        defer non_existent.close();
        _ = non_existent.scanStruct(ProductSummary, .none) catch |err| switch (err) {
            error.ErrNoRows => std.debug.print(
                "   -> Querying ID 9999 returned error.ErrNoRows as expected!\n\n",
                .{},
            ),
            else => return err,
        };
    } else {
        const UserRole = struct { id: i64, name: []const u8, role: []const u8 };
        var row = db.queryRow("SELECT id, name, role FROM users LIMIT 1", .{}, .none);
        defer row.close();
        const u = try row.scanStruct(UserRole, .none);
        std.debug.print("   -> User scanned: ID {d}, Name '{s}'\n", .{
            u.id,
            u.name,
        });

        var empty_row = sql.Row{ .rows = null };
        defer empty_row.close();
        _ = empty_row.scanStruct(UserRole, .none) catch |err| switch (err) {
            error.ErrNoRows => std.debug.print(
                "   -> Empty result handled gracefully with error.ErrNoRows!\n\n",
                .{},
            ),
            else => return err,
        };
    }

    // 8. ACID Transactions (db.beginTx & Tx.commit/rollback)
    std.debug.print("7. ACID Transactions (db.beginTx with IsolationLevel):\n", .{});
    {
        var tx = try db.beginTx(.{
            .isolation = .serializable,
            .read_only = false,
        }, .none);
        defer tx.rollback(.none) catch {};

        _ = try tx.exec("UPDATE products SET price = price * 0.9 WHERE id = 1", .{}, .none);
        try tx.commit(.none);
        std.debug.print("   -> Transaction #1 (Serializable) committed successfully!\n", .{});

        // Demonstrating clean rollback on error
        var tx_abort = try db.begin(.none);
        defer tx_abort.rollback(.none) catch {};
        _ = try tx_abort.exec("DELETE FROM products", .{}, .none);
        try tx_abort.rollback(.none);
        std.debug.print("   -> Transaction #2 rolled back cleanly on error!\n\n", .{});
    }

    // 9. Engine-specific demonstrations
    if (is_sqlite) {
        std.debug.print("8. Native Detailed Error Reporting (conn.lastError):\n", .{});
        const conn = try db.conn(.none);
        defer conn.release();

        const exec_res = conn.exec("SELECT * FORM products", .{}, .none);
        if (exec_res) |_| {} else |err| {
            std.debug.print("   -> Exec failed with Zig error: {any}\n", .{err});
            if (conn.lastError()) |msg| {
                std.debug.print("   -> SQLite Native Detail: \"{s}\"\n\n", .{msg});
            }
        }
    }

    // 10. Connection Pool Statistics
    const stats = db.stats();
    std.debug.print("9. Final Connection Pool Statistics:\n", .{});
    std.debug.print("   -> Max Open:          {d}\n", .{stats.max_open_connections});
    std.debug.print("   -> Current Open:      {d}\n", .{stats.open_connections});
    std.debug.print("   -> In-Use:            {d}\n", .{stats.in_use});
    std.debug.print("   -> Idle in Pool:      {d}\n\n", .{stats.idle});
}
