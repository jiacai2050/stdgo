# 演进与重构：stdgo.database.sql 的架构设计与优化之路

**日期**: 2026-11-22

在系统级语言中操作数据库，通常要么直接使用底层 C 接口手动处理连接、语句步进和参数绑定，要么引入较重的第三方库。Go 标准库的 `database/sql` 通过连接池抽象和驱动接口提供了一套相对平衡的使用体验，`stdgo` 的目标就是将其引入 Zig 0.17 体系。

本文记录我们在 `stdgo.database.sql` 模块上的主要优化：参数绑定的栈上展开与零堆分配、列元数据从切片缓存改为按索引直查、二进制数据截断排查，以及类型转换协议向 `bind` 与 `scan` 的收敛。

---

## 1. 架构基石：显式依赖注入与事务状态机

移植 Go 的 `database/sql` 首先需要处理两门语言在运行时模型上的差异：

### 1.1 摒弃全局状态，采用显式依赖注入
Go 的常见模式是在驱动包的 `init()` 中调用 `sql.Register("sqlite3", &Driver{})`，业务代码通过空导入 `_ "github.com/..."` 注册全局表，再通过全局 `sql.Open` 连接。
这种做法在 Zig 中并不适用。Zig 没有运行时的隐式初始化机制，全局注册表容易引入并发竞争，也无法支持在同一进程内运行多个不同配置的驱动实例。

因此，`stdgo.database.sql` 采用显式依赖注入：
```zig
const db = try sql.DB.open(
    allocator,
    io,
    sqlite_drv.driver(),
    "file:production.db?cache=shared",
);
defer db.close();
```
`Allocator`、`std.Io` 和 `driver.Driver` 由调用方传入，连接池的生命周期由外层显式管理。

### 1.2 连接池与事务状态机
`DB` 维护了线程安全的连接池，支持：
- `setMaxOpenConns`、`setMaxIdleConns`
- `setConnMaxLifetime`（最长存活时间自动淘汰）
- `setConnMaxIdleTime`（空闲超时剔除）
- `db.stats()`（连接与等待指标统计）

`db.begin()` 与 `db.beginTx(opts)` 返回的 `Tx` 受状态机保护。一旦 `commit` 或 `rollback` 完成，事务立即标记为失效。后续在已结束事务或其预编译语句（`TxStmt`）上的操作会直接返回 `error.TxDone`，避免连接归还后被旧语句继续操作。

---

## 2. 参数绑定优化：从堆分配切片到编译期零分配（Zero-Alloc）

### 2.1 早期实现与问题
Go 的 `db.Exec(query, args ...any)` 依赖运行时的动态切片。早期为了兼顾灵活性，我们允许调用方传入动态切片 `[]const Value`，并设计了折中策略：
- $\le 16$ 个参数时在栈上分配临时数组；
- $> 16$ 个参数时调用 `allocator.alloc` 在堆上申请内存。

伴随而来的还有针对 `*[N]Value`、`*[N]NamedValue` 以及数组值传递的分支。这种设计带来了一些问题：
1. **隐式堆分配**：SQL 执行函数在参数较多时会触发堆分配，增加内存管理开销。
2. **签名透传**：内部辅助函数 `withNamedValues` 必须携带 `allocator: ?Allocator`，调用链路上即使不分配内存也需传递分配器。
3. **参数混用与容错**：若调用方在一个查询中混用 `?` 与 `:name`，驱动内部只能依靠字符串匹配做 fallback 猜测。

### 2.2 重构：基于 Zig Comptime 反射的编译期解构
后来我们清理了兼容分支，对参数规则做了明确区分：
- **位置参数（`?`）**：使用匿名元组 `.{ "Alice", 30 }`。
- **具名参数（`:name`）**：使用匿名结构体 `.{ .name = "Alice", .age = 30 }`。
- **禁止混用**：若包含具名占位符却传入元组，返回 `error.SQLitePositionalArgForNamedParam`；参数数量不匹配时返回 `error.SQLiteParameterCountMismatch`。

在此约束下，`withNamedValues` 不再需要 `Allocator`：
```zig
inline fn withNamedValues(
    args: anytype,
    ctx: anytype,
    comptime func: anytype,
) !@typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.payload {
    const ArgType = @TypeOf(args);
    const arg_info = @typeInfo(ArgType);

    if (arg_info == .@"struct") {
        const s_info = arg_info.@"struct";
        // 在当前调用栈上分配长度精确等于字段数量的缓冲区
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
    @compileError("query/exec arguments must be an anonymous tuple or struct");
}
```
参数解构与绑定完全在栈上完成，去除了运行时的堆分配开销，参数的数量和形式在编译期就能被检查。

---

## 3. 列元数据查询优化：从切片缓存到按索引零分配

在结果集的元数据处理上，Go 与 Zig 之间也存在显著的设计差异。

### 3.1 旧有切片模式的痛点
在 Go 原生 `database/sql` 中，检查查询返回的列结构通常通过两个方法：
- `rows.Columns() ([]string, error)`
- `rows.ColumnTypes() ([]*ColumnType, error)`

受此习惯影响，`stdgo` 早期也提供了 `rows.columns()`，在底层驱动（以 SQLite 为例）中每次调用或首次准备时，调用 `self.allocator.alloc([]const u8, count)` 分配动态切片，并将结果保存在驱动结构体的 `cols_cached` 字段中：

```zig
// 早期实现：驱动内部需要维护切片缓存与堆分配
pub const SQLiteRows = struct {
    allocator: Allocator,
    stmt: *c.sqlite3_stmt,
    cols_cached: ?[]const []const u8 = null, // 堆分配缓存

    fn columns(ctx: *anyopaque) anyerror![]const []const u8 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
        if (self.cols_cached) |cols| return cols;
        const count: usize = @intCast(c.sqlite3_column_count(self.stmt));
        var col_list = try self.allocator.alloc([]const u8, count);
        ...
        self.cols_cached = col_list;
        return col_list;
    }

    fn close(ctx: *anyopaque) void {
        ...
        if (self.cols_cached) |cols| self.allocator.free(cols);
        self.allocator.destroy(self);
    }
};
```

这种设计在 Zig 中有几个缺点：
1. **隐式堆分配**：哪怕调用方只需要获取列数或读取某一列的列名，底层都必须分配整个切片。
2. **游标状态复杂**：驱动游标内部需要维护 `cols_cached` 指针，并在 `close` 时显式释放，增加了内存管理负担。
3. **分配器生命周期耦合**：行游标必须绑定一个 `Allocator`，即便它只是在进行只读查询迭代。

### 3.2 优化：按索引直查（Index-Based Accessors）
我们重构了 `Rows` 与底层 `driver.Rows` 接口，废除了全量切片缓存模式，改为基于列索引的按需查询：

```zig
pub const Rows = struct {
    raw_rows: driver.Rows,
    ...

    /// 返回结果集的总列数，无堆分配
    pub fn columnCount(self: *Rows) usize {
        return self.raw_rows.columnCount();
    }

    /// 根据列索引（从 0 开始）获取列名切片，直接借用底层元数据，无堆分配
    pub fn columnName(self: *Rows, index: usize) []const u8 {
        return self.raw_rows.columnName(index);
    }

    /// 根据列索引获取单个列的详细元数据（类型名、可空性、长度、精度），无堆分配
    pub fn columnType(self: *Rows, index: usize) !ColumnType {
        const count = self.columnCount();
        if (index >= count) return error.ColumnIndexOutOfBounds;
        ...
    }
};
```

在 SQLite 驱动实现中：
- `columnCount` 直接调用 `c.sqlite3_column_count(self.stmt)`；
- `columnName` 直接调用 `c.sqlite3_column_name(self.stmt, @intCast(index))`，通过 `std.mem.span` 返回切片，直接复用 SQLite 语句持有的元数据；
- `SQLiteRows` 结构体删除了 `cols_cached` 字段及其释放逻辑。

如果业务确实需要获得所有列的完整切片（例如需要长期脱机保存），`Rows` 提供了一个显式接收分配器的辅助方法：
```zig
pub fn columnTypes(self: *Rows, allocator: Allocator) ![]ColumnType
```
内存分配由调用方自主掌控，驱动游标本身无需分配内存。

---

## 4. 类型系统排坑：二进制大对象（BLOB）的截断问题

在 Go 中，文本是 `string`，二进制切片是 `[]byte`。而在 Zig 中，字符串字面量与原始字节切片的类型都是 `[]const u8`。

这在 SQLite 驱动中会导致问题：如果传入包含 `0x00` 字节的二进制数据，驱动层若默认按 UTF-8 `TEXT`（`sqlite3_bind_text`）绑定，遇到 `\0` 时就会被提前截断。

### 解决方案：引入显式的 `Blob` 包装
我们在 `driver` 层增加了轻量包装：
```zig
pub const Blob = struct {
    data: []const u8,
    pub fn init(data: []const u8) Blob { return .{ .data = data }; }
};
pub fn blob(data: []const u8) Blob { return Blob.init(data); }
```
并在 `Value.bind` 与 `val.scan` 中提供支持。写入时显式使用 `sql.blob(bytes)`，驱动层调用 `sqlite3_bind_blob`，区分了文本与原始字节。

---

## 5. API 调整：统一为 `bind` 与 `scan`

最初的实现中，函数命名不够统一：参数编码叫 `toValue(val)`，字段解码叫 `valueToField(T, val)`，多列解码叫 `valuesToStruct(T, vals)`。此外扩展协议也不对称：读取支持自定义类型实现 `scan(v)`，写入却没有对应的转换方法。

我们将它们调整为数据库领域更通用的术语——绑定（`bind`）与扫描（`scan`），并内聚为 `Value` 的方法：

```zig
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,

    /// 编译期绑定任何 Zig 标量、时间、Blob 及自定义类型
    pub fn bind(val: anytype) Value { ... }

    /// 编译期解码为目标 Zig 类型
    pub fn scan(self: Value, comptime T: type) !T { ... }
};
```

扩展协议也相应对齐：
- **写入参数**：自定义类型实现 `pub fn bind(self: @This()) Value`。
- **读取列数据**：自定义类型实现 `pub fn scan(self: *@This(), v: Value) !void`。
- **多列扫描**：统一为 `scanValues(T, values)`，由 `Row.scanStruct` 和 `Rows.nextStruct` 复用。

清理后移除了所有过渡性的别名（`toValue`、`fromValue`、`valueToField`、`fromValues`、`NamedArg`），API 结构更加清晰。

---

## 6. 总结与对照速查

| 对比维度 | 优化前 / Go 原生实现 | 优化后 stdgo 现行实现 |
| :--- | :--- | :--- |
| **依赖注入** | 全局 `sql.Register` 注册表，副作用导入 | 显式传入 `Allocator`、`std.Io` 与驱动实例，无全局可变状态 |
| **参数绑定** | 运行时 `[]any` 动态装箱，两段式堆分配 | 编译期 Comptime 解构，栈上固定数组，无堆分配 |
| **参数隔离** | 位置与具名参数容易混用 | 元组 `.{}` 与结构体 `.{ .k = v }` 分开，不匹配时报错 |
| **列元数据获取** | `rows.Columns()` 返回动态切片，驱动内部缓存 | `columnCount`、`columnName(i)` 索引直查，无切片堆分配 |
| **结果集扫描** | 运行时反射 `rows.Scan` 或第三方 `sqlx` | 编译期直解：`rows.nextStruct(T)` / `row.scanStruct(T)` |
| **类型扩展** | `driver.Valuer` 与 `sql.Scanner` 接口虚表 | 对称的 `.bind()` 与 `.scan()` 方法，无动态分发开销 |
| **二进制处理** | 仅依赖 `[]byte` 切片区分 | 显式 `sql.Blob` / `sql.blob()` 包装，避免 `\0` 提前截断 |
| **超时管理** | 级联 `context.Context` 树 | 显式 `Deadline`，基于 `.awake` 单调时钟，休眠不扣减配额 |
| **事务与语句生命周期** | 依赖驱动内部实现或手动管理 | 事务结束自动关闭语句并失效，二次执行报错 `error.TxDone` |

当前架构在保持 Go 原生连接池语义的同时，去除了多余的动态分配与中间缓存，为后续支持 PostgreSQL、MySQL 等其他数据库驱动提供了统一的连接与类型抽象基础。
