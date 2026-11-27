# database/sql：设计、使用指南与 Go 对照

`stdgo.database.sql` 为 Zig 0.17 提供了对应 Go 标准库 `database/sql` 的接口，包含连接池、事务、预编译语句以及流式结果集扫描。

---

## 1. 核心架构与设计原则

1. **显式依赖注入（No Hidden State）**：
   - 不依赖隐式全局状态或全局驱动表（Go 依赖包导入时的 `init()` 和 `sql.Register`）。`Allocator`、`std.Io` 和 `driver.Driver` 均由调用方显式传入 `DB.open`。
2. **栈上参数绑定（Zero-Allocation Bindings）**：
   - 参数绑定不走 Go 运行时的 `[]any` 装箱，而是在编译期根据元组或结构体类型在栈上分配固定长度缓冲区，没有堆分配开销。
3. **编译期强类型扫描（Comptime Struct Scanning）**：
   - 提供 `nextStruct` 和 `scanStruct`，在编译期按字段名称与顺序将列数据解码到目标结构体，不需要类似 Go 中 `sqlx` 的运行时反射库。
4. **统一超时控制（Monotonic Awake Deadline）**：
   - 涉及 I/O 和连接池等待的操作接收 `Deadline`。内部基于 `std.Io.Clock.awake` 单调时钟计算时间，系统休眠期间不消耗超时配额。

---

## 2. 快速上手

### 2.1 初始化连接池与配置

```zig
const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    // 1. 初始化驱动（以 SQLite 为例，亦可使用内置 MockDriver）
    var sqlite_drv = sql.sqlite.SQLiteDriver.init(allocator);

    // 2. 打开连接池
    const db = try sql.DB.open(
        allocator,
        io,
        sqlite_drv.driver(),
        "file:test.db?mode=memory&cache=shared",
    );
    defer db.close();

    // 3. 配置连接池参数
    db.setMaxOpenConns(10);
    db.setMaxIdleConns(5);
    db.setConnMaxLifetime(std.time.ns_per_hour);
    db.setConnMaxIdleTime(10 * std.time.ns_per_min);

    // 4. 健康检查
    try db.ping(.none);
}
```

### 2.2 参数绑定规范（Bind）

`stdgo` 区分位置参数和具名参数，两类参数不能混用，参数数量或类型不匹配时会直接报错：

- **位置参数（`?`）**：使用匿名元组 `.{ ... }`。
  ```zig
  _ = try db.exec(
      "INSERT INTO users (name, age, balance) VALUES (?, ?, ?)",
      .{ "Alice", 30, 100.50 },
      .none,
  );
  ```
- **具名参数（`:name`, `@name`, `$name`）**：使用匿名结构体字面量 `.{ .name = ... }`。
  ```zig
  _ = try db.exec(
      "INSERT INTO users (name, age) VALUES (:name, :age)",
      .{ .name = "Bob", .age = 25 },
      .none,
  );
  ```
- **无参数**：使用空元组 `.{}`。
  ```zig
  _ = try db.exec("DELETE FROM users", .{}, .none);
  ```
- **校验规则**：
  - 若 SQL 包含具名占位符（如 `:name`），传入元组会返回 `error.SQLitePositionalArgForNamedParam`。
  - 参数数量与占位符数量不一致时返回 `error.SQLiteParameterCountMismatch`。

### 2.3 执行写操作（Exec）

```zig
const res = try db.exec(
    "UPDATE users SET balance = balance + ? WHERE id = ?",
    .{ 50.0, 1 },
    .none,
);

const affected = try res.rowsAffected();
std.debug.print("Rows affected: {d}\n", .{affected});
```

### 2.4 查询单行（QueryRow & scanStruct）

```zig
const UserSummary = struct {
    name: []const u8,
    balance: f64,
};

var row = db.queryRow("SELECT name, balance FROM users WHERE id = ?", .{1}, .none);
defer row.close();

const user = row.scanStruct(UserSummary, .none) catch |err| switch (err) {
    error.ErrNoRows => {
        std.debug.print("User not found\n", .{});
        return;
    },
    else => return err,
};

std.debug.print("User: {s}, Balance: {d:.2}\n", .{ user.name, user.balance });
```

### 2.5 查询多行结果集（Query & nextStruct）

```zig
const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
    balance: f64,
};

var rows = try db.query("SELECT id, name, age, balance FROM users WHERE age >= ?", .{18}, .none);
defer rows.close();

// 列元数据探测
const col_count = rows.columnCount();
for (0..col_count) |i| {
    const col_type = try rows.columnType(i);
    std.debug.print("Col #{d}: {s} ({s})\n", .{
        i,
        col_type.name(),
        col_type.databaseTypeName() orelse "UNKNOWN",
    });
}

// 流式强类型迭代
while (try rows.nextStruct(User, .none)) |u| {
    std.debug.print("User #{d}: {s}, Age: {d}\n", .{ u.id, u.name, u.age });
}

// 检查迭代期间是否发生错误
if (rows.err()) |err| return err;
```

> [!IMPORTANT]
> **字符串与切片的内存借用生命周期**：
> 扫描出的 `[]const u8`（字符串或 Blob 数据）直接借用驱动内部缓冲区。在调用 `rows.close()` 或 `row.close()` 后，这部分内存会被释放或复用；若需要在结果集关闭后继续持有该数据，调用方须使用 `allocator.dupe` 进行复制。

### 2.6 事务管理（ACID Transactions）

```zig
var tx = try db.beginTx(.{
    .isolation = .serializable,
    .read_only = false,
}, .none);
// 退出作用域时若未提交则回滚
defer tx.rollback(.none) catch {};

_ = try tx.exec("UPDATE accounts SET balance = balance - 100 WHERE id = 1", .{}, .none);
_ = try tx.exec("UPDATE accounts SET balance = balance + 100 WHERE id = 2", .{}, .none);

// 提交事务
try tx.commit(.none);
```

### 2.7 预编译语句（Stmt）

```zig
var stmt = try db.prepare(
    "INSERT INTO users (name, age, balance) VALUES (:name, :age, :balance)",
    .none,
);
defer stmt.close();

const batch = [_]struct { name: []const u8, age: i64, balance: f64 }{
    .{ .name = "Charlie", .age = 22, .balance = 50.0 },
    .{ .name = "Dave", .age = 28, .balance = 80.0 },
};

for (batch) |item| {
    _ = try stmt.exec(item, .none);
}
```

> [!NOTE]
> **参数生命周期与多语句约定（SQLite 驱动）**：
> - `exec()` 绑定切片参数采用零拷贝（`SQLITE_STATIC`），并在返回前自动复位语句与清空绑定；无参数调用（`.{}`）支持顺序执行多条 SQL（如建表/迁移脚本）。
> - `query()` 绑定切片参数会由驱动拷贝（`SQLITE_TRANSIENT`），调用方的临时缓冲区无需存活到 `rows.close()`；`prepare()` 与带参数的 `exec()` 严格要求单条 SQL，尾部存在多余可执行语句时返回 `error.SQLiteMultipleStatements`。
> - `Tx.commit()` / `Tx.rollback()` 或提前 `stmt.close()` 会自动关闭并失效关联的 `Rows` 与 `Stmt`，避免悬空游标与 use-after-free。

---

## 3. 类型系统与 `bind` / `scan` 协议

底层驱动的值表示定义在 `driver.Value` 中：

```zig
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,

    pub fn bind(val: anytype) Value { ... }
    pub fn scan(self: Value, comptime T: type) !T { ... }
};
```

### 3.1 二进制大对象（BLOB）
Zig 中字符串和二进制切片类型都是 `[]const u8`。为了避免将二进制数据当作 SQL `TEXT` 处理（在遇到 `\x00` 字节时被提前截断），`stdgo` 提供了专用的 `sql.Blob`：

```zig
// 写入 BLOB
const data = sql.blob("BIN\x00\xFF\xAA\x55");
_ = try db.exec("INSERT INTO files (payload) VALUES (?)", .{data}, .none);

// 读取 BLOB
const FileRecord = struct { payload: sql.Blob };
const file = try row.scanStruct(FileRecord, .none);
std.debug.print("Blob len: {d}\n", .{file.payload.data.len});
```

### 3.2 自定义类型扩展协议（Custom Valuer / Scanner）
自定义类型实现对应的方法后，可直接被 `bind` 绑定或接收 `scan` 扫描：

- **写入自定义类型**：实现 `pub fn bind(self: @This()) Value`
  ```zig
  const CustomId = struct {
      id: i64,
      pub fn bind(self: @This()) sql.Value {
          return .{ .int = self.id };
      }
  };
  ```
- **读取自定义类型**：实现 `pub fn scan(self: *@This(), v: Value) !void`
  ```zig
  const CustomJson = struct {
      count: usize = 0,
      pub fn scan(self: *@This(), v: sql.Value) !void {
          switch (v) {
              .string => |s| self.count = s.len,
              else => return error.ColumnTypeMismatch,
          }
      }
  };
  ```

---

## 4. 与 Go `database/sql` 对照表

| 维度 | stdgo (`database/sql`) | Go (`database/sql`) | 差异说明 |
| :--- | :--- | :--- | :--- |
| **内存与环境隔离** | 显式注入 `allocator` 和 `std.Io` | 依赖隐式运行时与全局 GC | 无隐藏全局状态，不使用全局分配器，内存和 I/O 资源完全由调用方传入。 |
| **驱动注册** | 显式实例化驱动并传给 `DB.open` | 包导入 `init()` + `sql.Register` 全局表 | 避免包导入的注册副作用，同一个进程可以同时打开多个不同配置的驱动实例。 |
| **参数绑定形式** | 匿名元组 `.{}` 与匿名结构体 `.{ .name = ... }` | 变长切片 `args ...any` / `sql.Named` | 栈上在编译期展开，没有堆分配；位置参数与具名参数分开，禁止混用。 |
| **结果集扫描** | `rows.nextStruct(T)` 编译期直接解码 | `rows.Scan(&dest...)` / 第三方库 `sqlx` | 编译期直接将多列数据扫描到强类型结构体，没有运行时反射开销。 |
| **超时与取消控制** | 按操作传入 `Deadline`（单调 `.awake`） | 沿 context 树传递 `context.Context` | 单次操作显式指定预算，系统休眠时不扣减超时额度；事务回滚超时须调用方处理。 |
| **事务内 Stmt 生命周期** | Commit / Rollback 时自动关闭并失效 | 依赖驱动内部实现或调用方手动关闭 | 事务结束时自动清理关联的 Stmt，再次调用返回 `error.TxDone`，防止连接归还后引发泄露或锁冲突。 |
| **自定义类型映射** | 实现 `.bind()` 与 `.scan()` 方法 | 实现 `driver.Valuer` 与 `sql.Scanner` 接口 | 编译期通过 `@hasDecl` 检测类型方法，没有接口动态分发（interface vtable）开销。 |
| **二进制表示** | 专用的 `sql.Blob` / `sql.blob()` 类型 | 原生 `[]byte` 切片与 `string` 区分 | Zig 缺少独立的字节切片类型，用 `Blob` 包装避免底层当成 C 风格以 `\0` 结尾的字符串截断。 |
| **连接池统计** | `DBStats` 结构体 | `sql.DBStats` 结构体 | 字段基本对齐，包含最大连接数、打开连接数、在用连接数、空闲数和等待统计。 |

---

## 5. 常见错误与排查指南

- **`error.SQLitePositionalArgForNamedParam`**：
  SQL 中包含 `:name`、`@name` 等具名占位符，但执行时传入了位置元组（如 `.{ "val" }`）。请改为匿名结构体 `.{ .name = "val" }`。
- **`error.SQLiteParameterCountMismatch`**：
  传入参数的数量与 SQL 语句中的占位符数量不一致。
- **`error.TxDone`**：
  事务已提交或已回滚，不能继续在该事务或事务内的 `TxStmt` 上执行操作。
- **`error.ErrNoRows`**：
  `queryRow` 未匹配到任何数据行，对应 Go 的 `sql.ErrNoRows`。
- **`error.ColumnCountMismatch`**：
  目标结构体的字段数量与 SQL 返回的列数不一致。
