# 从 SQL 字符串到磁盘页：SQLite 查询执行全链路与 VDBE 内部机制

**日期**: 2026-11-27

在为 `stdgo.database.sql` 实现和排查 SQLite 驱动（[src/database/sql/sqlite.zig](../src/database/sql/sqlite.zig)）时，我们反复碰到一些看起来“反直觉”的 C API 约束：为什么 `query` 绑定字符串不能用 `SQLITE_STATIC`？为什么 `INSERT ... RETURNING` 在 `exec` 里必须用 `while` 消费完 `SQLITE_ROW`？为什么 `Rows.next()` 扫出来的切片不能跨行保存？

要弄懂这些行为，光看 C API 文档不够，还得看清一段 SQL 字符串交给 SQLite 后，经过哪些组件、怎样编译和执行，最后又怎么从文件或内存里把数据一行行读出来。

本文基于本仓库使用的 [SQLite 3.53.0](https://github.com/sqlite/sqlite/tree/version-3.53.0) 源码，从整体分层和一条查询的生命周期讲起，接着拆解核心执行引擎 VDBE（Virtual Database Engine，虚拟数据库引擎）的数据结构与字节码机制，最后回到驱动层踩过的具体问题。

---

## 1. 先看全貌：SQLite 的四层架构

和 MySQL、PostgreSQL 这种“客户端 + 独立数据库服务端进程”的架构不同，SQLite 是直接链接进应用程序进程的嵌入式库。没有网络协议，也没有后台守护进程，一次 SQL 查询本质上就是一次进程内的函数调用链。

从源码结构看，SQLite 可以划成四层：

```mermaid
flowchart TB
    classDef api stroke:#0066cc,stroke-width:2px;
    classDef comp stroke:#8a2be2,stroke-width:2px;
    classDef vm stroke:#ff9900,stroke-width:2px;
    classDef store stroke:#2e8b57,stroke-width:2px;

    subgraph SG_API ["1. C API 接口层 (Interface)"]
        direction LR
        API["sqlite3_open_v2 / prepare_v2 / bind_* / step / column_* / finalize"]
    end

    subgraph SG_Compiler ["2. SQL 编译器前端 (Compiler)"]
        direction LR
        Tok["词法分析器 Tokenizer<br/>src/tokenize.c"] --> Parse["语法分析器 Lemon Parser<br/>src/parse.y"]
        Parse --> CodeGen["查询规划与代码生成<br/>select.c / where.c / build.c"]
    end

    subgraph SG_VM ["3. 字节码虚拟机 (VDBE)"]
        direction LR
        VDBE["sqlite3VdbeExec 解释循环<br/>src/vdbe.c / vdbeaux.c / vdbeapi.c"]
    end

    subgraph SG_Backend ["4. 存储引擎后端 (Backend)"]
        direction LR
        BTree["B-Tree 索引与表组织<br/>src/btree.c"] --> Pager["Pager 页缓存与事务日志 (WAL/Journal)<br/>src/pager.c / wal.c"]
        Pager --> VFS["OS / VFS 文件系统适配<br/>src/os.c / os_unix.c"]
    end

    API -->|"编译 SQL 文本"| Tok
    CodeGen -->|"产出字节码程序 (struct Vdbe)"| VDBE
    API -->|"绑定参数 / 步进取行"| VDBE
    VDBE -->|"游标定位与列读取"| BTree

    style SG_API stroke:#0066cc,stroke-width:2px;
    style SG_Compiler stroke:#8a2be2,stroke-width:2px;
    style SG_VM stroke:#ff9900,stroke-width:2px;
    style SG_Backend stroke:#2e8b57,stroke-width:2px;

    class API api;
    class Tok,Parse,CodeGen comp;
    class VDBE vm;
    class BTree,Pager,VFS store;
```

这四层的分工如下：

1. **C API 接口层**：对外暴露统一的句柄与函数（`sqlite3` 连接、`sqlite3_stmt` 语句），负责参数校验、加连接互斥锁以及把内部状态翻译成 C 错误码。
2. **SQL 编译器前端**：SQLite **不在运行时解释执行 AST**，而是像编程语言编译器一样，先把 SQL 文本编译成线性字节码：
   - **Tokenizer**（[`src/tokenize.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/tokenize.c#L273)）：手写的状态机词法分析器，把 SQL 字符串切成 `TK_SELECT`、`TK_ID`、`TK_VARIABLE` 等 token。
   - **Parser**（[`src/parse.y`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/parse.y)）：由 SQLite 自研的 LALR(1) 生成器 Lemon 生成的语法分析器，将 token 流归约为语法树（`Select`、`Expr` 等节点，挂在编译上下文 [`struct Parse`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/sqliteInt.h#L3875) 上）。
   - **查询规划与代码生成**（[`src/select.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/select.c#L7578)、[`src/where.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/where.c#L6828)、[`src/build.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/build.c#L141)）：基于统计信息决定走全表扫描还是索引查找、是否需要临时排序表，再把执行计划直接翻译成一条条 VDBE 字节码指令。
3. **字节码虚拟机（VDBE）**：真正的执行引擎。它是一个基于寄存器的解释器，逐条执行前端生成的字节码，向下按需取页，向上逐行吐出结果。
4. **存储引擎后端**：
   - **B-Tree**（[`src/btree.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L4765)）：每张表和每个索引在数据库文件里都是一棵 B-Tree（表是按 `rowid` 组织的 B+Tree，索引是 B-Tree）。B-Tree 层对外提供游标（`BtCursor`），支持首行定位、按键二分查找、顺序遍历和记录增删。
   - **Pager & WAL/Journal**（[`src/pager.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/pager.c#L5726)）：整个数据库文件按固定页大小（默认 4 KB）切分。Pager 管理内存页缓存（Page Cache），并通过回滚日志（Rollback Journal）或预写日志（WAL）保证事务的原子性、持久性与多读单写并发控制。
   - **OS / VFS**（[`src/os.c`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/os.c#L88)、[`struct sqlite3_vfs`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/sqlite.h.in#L1513)）：抽象不同操作系统的 `read`/`write`/`fsync`/文件锁，SQLite 借此同时支持 Linux、macOS、Windows 以及纯内存（`:memory:`）环境。

---

## 2. 一条查询的完整生命周期

把上面四层串起来，看一条最常见的参数化查询从发起到结束会经历什么：

```zig
var rows = try db.query("SELECT id, name FROM users WHERE name = ?", .{"Alice"}, .none);
defer rows.close();
while (try rows.next(&dest, .none)) { ... }
```

整个过程分为编译准备（Prepare）、参数绑定（Bind）、步进执行（Step & Column）和清理收尾（Reset & Finalize）四个阶段：

```mermaid
flowchart TD
    classDef phase1 stroke:#8a2be2,stroke-width:2px;
    classDef phase2 stroke:#ff9900,stroke-width:2px;
    classDef phase3 stroke:#2e8b57,stroke-width:2px;
    classDef phase4 stroke:#0066cc,stroke-width:2px;

    P1["1. sqlite3_prepare_v2(db, sql, ...)"] --> P2["sqlite3RunParser<br/>sqlite3GetToken 切分 token -> Lemon 语法归约"]
    P2 --> P3["sqlite3Select / sqlite3WhereBegin<br/>选择索引或全表扫描，生成 VDBE 字节码"]
    P3 --> P4["sqlite3FinishCoding -> sqlite3VdbeMakeReady<br/>打包分配寄存器 aMem / 参数槽 aVar / 游标表 apCsr，返回 sqlite3_stmt*"]

    P4 --> B1["2. sqlite3_bind_*(stmt, idx, val)<br/>将参数写入参数槽 Vdbe.aVar[idx-1]"]

    B1 --> S1["3. sqlite3_step(stmt)<br/>进入 sqlite3VdbeExec 字节码解释循环"]
    S1 --> S2["执行 OP_OpenRead / OP_Rewind / OP_Next<br/>调用 sqlite3BtreeCursor / First / Next"]
    S2 --> S3["B-Tree 向 Pager 请求页面 (sqlite3PagerGet)<br/>命中页缓存或经 VFS (sqlite3OsRead) 读盘"]
    S3 --> S4{"当前字节码结果?"}
    S4 -->|"OP_ResultRow<br/>返回 SQLITE_ROW"| S5["调用方 sqlite3_column_*()<br/>直接读取输出寄存器 Vdbe.pResultRow"]
    S5 -->|"继续下一行"| S1
    S4 -->|"OP_Halt<br/>返回 SQLITE_DONE"| C1["4. 收尾：sqlite3_reset / clear_bindings / finalize<br/>释放游标、刷新 changes、回收 Vdbe 内存"]

    class P1,P2,P3,P4 phase1;
    class B1,S1,S4,S5 phase2;
    class S2,S3 phase3;
    class C1 phase4;
```

### 2.1 编译阶段究竟做了什么

当调用 [`sqlite3_prepare_v2()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/prepare.c#L937) 时，内部沿 `sqlite3LockAndPrepare()` → [`sqlite3Prepare()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/prepare.c#L682) → [`sqlite3RunParser()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/tokenize.c#L600) 推进：

1. **词法与语法驱动**：`sqlite3RunParser()` 在一个 `while (1)` 循环里不断调用 `sqlite3GetToken()` 取下一个 token，喂给 Lemon 解析器；如果遇到多条语句（分号分隔），会在第一条语句结束处停下，把剩余未解析 SQL 的起始地址写入 `sqlite3_prepare_v2()` 的输出参数 `pzTail`（我们在 `stdgo` 的多语句 `execDirect` 中正是靠循环推进 `pzTail` 实现的）。
2. **即时代码生成**：SQLite 并不是先构造完整 AST 再遍历生成代码，而是在语法归约动作触发时直接调用 `sqlite3Select()`、`sqlite3Insert()` 等模块向 `Vdbe` 追加字节码指令。
3. **打包就绪**：语句编译完成后，[`sqlite3FinishCoding()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/build.c#L141) 调用 [`sqlite3VdbeMakeReady()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L2647) 一次性分配执行期所需的寄存器、参数槽和游标表，并把虚拟机置为就绪状态。**整个 `prepare` 阶段不会读取业务表的数据行**（只会在必要时加载 `sqlite_schema` 元数据）。

### 2.2 为什么 SQLite 要设计一层字节码虚拟机？

多出这一层字节码虚拟机，主要换来三个实际好处：
- **编译与执行解耦**：预编译语句（`Stmt`）只需走一次词法、语法和查询规划，之后换不同参数反复 `bind` + `step` 即可，批量写入时开销极低。
- **天然支持流式按行拉取（Pull-based）**：VDBE 产出一行结果后直接暂停返回 `SQLITE_ROW`，保留程序计数器 `pc` 和游标现场，下次 `sqlite3_step()` 从断点继续。哪怕表里有上百万行，内存里也只需保留当前这一行。
- **可观测性强**：执行计划就是一段扁平的字节码程序，一条 `EXPLAIN <SQL>` 就能把数据库的真实执行路径完整打印出来。

### 2.3 `sqlite3_stmt` 与 `struct Vdbe` 的关系

SQLite C API 对外暴露的是不透明指针 [`sqlite3_stmt*`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/sqlite.h.in#L4303)。它在公开头文件里只是一个未定义结构体的前置声明（`typedef struct sqlite3_stmt sqlite3_stmt;`），用于隐藏内部实现。而在 SQLite 内部，实际分配的是 [`struct Vdbe`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L458)，各 C API 入口再通过显式指针强转（如 [`sqlite3_step`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L915) 中的 `Vdbe *v = (Vdbe*)pStmt;`）转回使用。

> [!NOTE]
> **这种写法完全符合 C 语言规范（C11）**：
> - `typedef struct sqlite3_stmt sqlite3_stmt;` 声明的是合法的不完整类型（incomplete type），外部代码只能传递或比较指针，无法 `sizeof`、按值创建或解引用；
> - [C11 §6.2.5p28](https://port70.net/~nsz/c/c11/n1570.html#6.2.5p28) 规定**所有结构体指针具有相同的内存表示和对齐要求**，因此 `Vdbe*` → `sqlite3_stmt*` → `Vdbe*` 的往返强转保证无损（[C11 §6.3.2.3p7](https://port70.net/~nsz/c/c11/n1570.html#6.3.2.3p7)）；
> - 因为没有任何代码会通过 `sqlite3_stmt*` 解引用读写内存，所有实际访问都经由真实有效类型 `Vdbe*` 完成，不违反 Strict Aliasing（[C11 §6.5p7](https://port70.net/~nsz/c/c11/n1570.html#6.5p7)）。在 Zig 中，`translate-c` 也会把此类未定义结构体直接映射为 `opaque {}`。

同一条连接（`sqlite3*`）上可以同时存在多个 `Vdbe` 实例（内部通过 `Vdbe.ppVPrev` / `pVNext` 串成双向链表），各自拥有独立的指令、寄存器和游标状态。

---

## 3. 深入核心：`struct Vdbe` 的内部数据结构

[`src/vdbeInt.h`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L458) 中的 `struct Vdbe` 里，与执行最直接相关的字段可以归为五类（`aOp`、`aMem`、`aVar`、`apCsr` 在结构体中均为堆指针，而非定长 C 数组）：

### 3.1 指令序列：[`Op *aOp`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L482)

VDBE 是一台**基于寄存器**的虚拟机（早年是栈式，后来改为寄存器式以减少栈操作指令）。每条指令（[`struct VdbeOp`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.h#L55)）由 1 个操作码和最多 5 个操作数构成：

```c
typedef struct VdbeOp Op;

struct VdbeOp {
  u8 opcode;          /* 操作码，如 OP_OpenRead, OP_Column, OP_ResultRow */
  signed char p4type; /* p4 联合体的类型标签（P4_INT32, P4_COLLSEQ, P4_KEYINFO 等） */
  u16 p5;             /* 16 位附加标志位 */
  int p1;             /* 第 1 操作数（常用于游标编号或参数索引） */
  int p2;             /* 第 2 操作数（常用于跳转目标地址或目标寄存器号） */
  int p3;             /* 第 3 操作数（常用于列号、寄存器号或长度） */
  union p4union {     /* 第 4 操作数（指针、字符串、比较器、表/索引元数据等） */
    /* ... */
  } p4;
  /* 其余 #ifdef 条件编译字段（zComment / iSrcLine / nExec / nCycle）省略 */
};
```

`Vdbe.aOp` 是一个动态分配的 `Op *` 指针（配合 `nOp` 记录有效指令数、`nOpAlloc` 记录已分配容量），指令按地址顺序连续存放在 `aOp[0..nOp-1]` 中，由 `Vdbe.pc` 指向当前正在执行的指令下标。

### 3.2 寄存器缓冲：[`Mem *aMem`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L474)

VDBE 没有固定数量的硬件寄存器，而是在编译收尾阶段（[`sqlite3VdbeMakeReady()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L2647)）根据本条 SQL 需要的寄存器总数 `nMem`，连同 `aVar`、`apCsr` 一起打包分配在连续堆内存中（甚至会优先复用 `aOp` 末尾未用完的空闲空间），再把 `Mem *aMem` 指向对应起点。指令中的寄存器编号从 `1` 开始（`aMem[1]`、`aMem[2]`...，在后文的 `EXPLAIN` 输出与源码注释中习惯简写为 `r[1]`、`r[2]`...）。

[`struct sqlite3_value`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L232) 是 SQLite 的动态类型值容器：

```c
typedef struct sqlite3_value Mem;

struct sqlite3_value {
  union MemValue {
    double r;           /* MEM_Real */
    i64 i;              /* MEM_Int */
    int nZero;          /* MEM_Zero + MEM_Blob */
    const char *zPType; /* sqlite3_bind_pointer 指针类型 */
    FuncDef *pDef;      /* 聚合函数上下文 */
  } u;
  char *z;              /* 字符串或 BLOB 数据指针 */
  int n;                /* 字节长度（不含结尾 '\0'） */
  u16 flags;            /* 类型标志 + 内存所有权标志 */
  u8  enc;              /* UTF-8 / UTF-16LE / UTF-16BE */
  u8  eSubtype;
  /* --- 以上为浅拷贝区域：#define MEMCELLSIZE offsetof(Mem,db) --- */
  sqlite3 *db;
  int szMalloc;         /* zMalloc 容量 */
  u32 uTemp;            /* OP_MakeRecord 临时存储 serial_type */
  char *zMalloc;        /* SQLite 内部持有的堆缓冲区 */
  void (*xDel)(void*);  /* 自定义析构函数（MEM_Dyn 时有效） */
  /* #ifdef SQLITE_DEBUG 调试字段（pScopyFrom / mScopyFlags / bScopy）省略 */
};
```

`flags`（[`src/vdbeInt.h#L310`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L310)）同时编码了两类信息：
- **值类型**：`MEM_Null`、`MEM_Int`、`MEM_Real`、`MEM_Str`、`MEM_Blob`、`MEM_Zero`。
- **内存所有权**（针对 `z` 指针）：
  - `MEM_Static`：`z` 指向外部只读或调用方管理的内存，VDBE 释放该寄存器时**不会 free `z`**。
  - `MEM_Dyn`：`z` 由 `zMalloc` 或析构函数 `xDel` 管理，释放时会回收内存。
  - `MEM_Ephem`：临时借用内存（例如直接指向 B-Tree 页面缓存中的某段字节），只保证当前指令或当前行有效，跨步进前若需持久化会先深拷贝。

注意结构体中间的 `MEMCELLSIZE` 分界线（`offsetof(Mem, db)`）：`db` 之前是“值与指针”（`u`、`z`、`n`、`flags`、`enc`），`db` 之后是“堆内存管理信息”（`zMalloc`、`xDel`）。VDBE 做寄存器浅拷贝时只复制前 `MEMCELLSIZE` 字节，这样既能共享 `z` 指针，又不会把 `zMalloc`/`xDel` 的释放责任错误地拷走。

### 3.3 绑定参数槽：[`Mem *aVar`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L477)

SQL 中的 `?`、`?1`、`:name`、`@name`、`$name` 占位符，在 `Vdbe` 中由 `Mem *aVar` 指向一块长度为 `nVar` 的连续 `Mem` 区域。每个槽位 `aVar[i]` 都是上一节介绍的 `struct sqlite3_value`（即 `Mem`）：
- [`sqlite3_bind_*()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1834) 直接把参数写入 `aVar[idx - 1]`：
  - 整数 / 浮点数写入联合体字段 `aVar[i].u.i` / `aVar[i].u.r`；
  - 字符串 / BLOB 的字节指针存入 `aVar[i].z`、长度存入 `aVar[i].n`，内存所有权由传入的析构策略决定：传 `SQLITE_STATIC` 时，`aVar[i].z` 直接指向调用方外部内存（`flags |= MEM_Static`）；传 `SQLITE_TRANSIENT` 时，SQLite 立即分配私有堆缓冲 `aVar[i].zMalloc` 拷贝数据，再令 `aVar[i].z = aVar[i].zMalloc`（`flags |= MEM_Dyn`）；
- [`sqlite3_clear_bindings()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L149) 遍历 `aVar[0..nVar-1]`，释放其中的动态内存（`zMalloc` / `xDel`）并全部置回 `MEM_Null`。

### 3.4 游标指针表：[`VdbeCursor **apCsr`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L476)

`Vdbe.apCsr` 是指向 `nCursor` 个 [`struct VdbeCursor`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L79) 指针槽位的二级指针，也是 **VDBE 与下层 B-Tree 之间的桥梁**。每张被访问的表、索引、临时表或排序器对应其中一个槽位，内部持有一个 B-Tree 游标（`BtCursor`）和当前行的列偏移缓存。执行引擎正是通过它，把字节码指令（[`OP_OpenRead`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L4386) / [`OP_Rewind`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L6372) / [`OP_Next`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L6510) / [`OP_Column`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L2975)）翻译成底层的 `sqlite3BtreeFirst()`、`sqlite3BtreeNext()` 和页读取调用。

### 3.5 执行现场与输出行

- [`pc`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L466)：程序计数器，记录下次 `sqlite3_step()` 从哪条指令恢复。
- [`eVdbeState`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L502)：虚拟机状态（`INIT` / `READY` / `RUN` / `HALT`）。
- [`pResultRow`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L486)：类型为 `Mem *`，指向 `aMem[]` 中连续的 `nResColumn` 个输出寄存器；`sqlite3_column_*()` 读取第 `col` 列时，本质上就是读取 `pResultRow[col]` 这个 `Mem`（如字符串/BLOB 读取 `pResultRow[col].z`）。
- [`nChange`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L468)：本条语句累计修改的行数，在 VDBE 终止时刷回 `db->nChange`（即 [`sqlite3_changes()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/main.c#L1150) 的返回值）。

---

## 4. 一条 `SELECT` 的字节码走读

以如下查询为例（假设 `users` 表结构为 `(id INTEGER PRIMARY KEY, name TEXT)`，且 `name` 上无索引）：

```sql
SELECT id, name FROM users WHERE name = ?;
```

执行 `EXPLAIN SELECT id, name FROM users WHERE name = ?;` 会得到类似下面的字节码（省略部分次要细节）：

```text
addr  opcode         p1  p2  p3  p4      comment
----  -------------  --  --  --  ------  -------------------------------
0     Init           0   11  0           跳转到 11 启动事务与初始化
1     OpenRead       0   2   0   2       打开 users 表（rootpage=2）到游标 0
2     Rewind         0   10  0           游标 0 定位到第一行；表空则跳到 10
3       Column       0   1   1           读取游标 0 的第 1 列 (name) 到 r[1]
4       Variable     1   2   0           把绑定参数 aVar[0] 浅拷贝到 r[2]
5       Ne           2   9   1   BINARY  若 r[1] != r[2]，跳到 9（下一行）
6       Rowid        0   3   0           读取主键 id 到 r[3]
7       Column       0   1   4           读取 name 到 r[4]
8       ResultRow    3   2   0           输出 r[3..4] 共 2 列，暂停返回 SQLITE_ROW
9     Next           0   3   0           游标 0 移到下一行，若有则跳回 3
10    Halt           0   0   0           结束执行，返回 SQLITE_DONE
11    Transaction    0   0   ...         开启读事务
12    Goto           0   1   0           跳回 1 开始主循环
```

对应的字节码执行流与暂停/恢复路径如下：

```mermaid
flowchart TD
    classDef init stroke:#0066cc,stroke-width:2px;
    classDef loop stroke:#ff9900,stroke-width:2px;
    classDef out stroke:#2e8b57,stroke-width:2px;

    A0["0: Init -> 11"] --> A11["11: Transaction (开启读事务)<br/>12: Goto -> 1"]
    A11 --> A1["1: OpenRead (游标 0 指向 users)<br/>2: Rewind (定位到首行)"]
    A1 -->|"表为空 (跳到 10)"| A10["10: Halt<br/>关闭游标并返回 SQLITE_DONE"]
    A1 -->|"有数据"| A3["3: Column -> r[1] (name)<br/>4: Variable -> r[2] (aVar[0])"]
    A3 --> A5{"5: Ne (r[1] != r[2])?"}
    A5 -->|"不相等 (跳到 9)"| A9["9: Next (游标推进到下一行)"]
    A5 -->|"相等"| A6["6: Rowid -> r[3] (id)<br/>7: Column -> r[4] (name)<br/>8: ResultRow (pResultRow = r[3..4])"]
    A6 -->|"暂停返回 SQLITE_ROW<br/>下次 step() 从 pc=9 恢复"| A9
    A9 -->|"仍有下一行 (跳回 3)"| A3
    A9 -->|"扫描结束"| A10

    class A0,A11,A1 init;
    class A3,A5,A9 loop;
    class A6,A10 out;
```

把每一步和底层存储引擎对应起来看：
1. `sqlite3_prepare_v2` 生成上述 13 条指令，设置 `eVdbeState = VDBE_READY_STATE`，此时尚未触碰任何数据页。
2. `sqlite3_bind_text64` 把参数写入 `aVar[0]`。
3. 第一次调用 `sqlite3_step()`：虚拟机先从 `addr=0` 跳到 `11` 开启读事务，再回到 `1` 通过 [`sqlite3BtreeCursor()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L4765) 打开表游标，并经 [`sqlite3BtreeFirst()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L5676) 让 Pager 读入 B-Tree 叶子页。一旦匹配到第一条满足 `name = ?` 的记录，执行 `addr=8` 的 `OP_ResultRow`，将 `pResultRow = &aMem[3]`、`pc = 9`，随后**暂停并返回 `SQLITE_ROW`**。
4. 调用方通过 `sqlite3_column_int64(stmt, 0)` 和 `sqlite3_column_text(stmt, 1)` 读取 `pResultRow[0]`（即 `r[3]`）和 `pResultRow[1]`（即 `r[4]`）。
5. 再次调用 `sqlite3_step()`：虚拟机从断点 `pc = 9` 恢复，执行 `OP_Next`（底层调用 [`sqlite3BtreeNext()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L6369)）推进游标；扫描完所有行后跳到 `addr=10` 执行 `OP_Halt`，关闭游标、结束读事务并返回 `SQLITE_DONE`。

---

## 5. 状态机与协程式调度

`Vdbe.eVdbeState` 定义了 4 个状态（[`src/vdbeInt.h#L534-L537`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L534-L537)）：

```mermaid
flowchart LR
    classDef state stroke:#0066cc,stroke-width:2px;
    classDef active stroke:#ff9900,stroke-width:2px;

    INIT["VDBE_INIT_STATE<br/>编译构造中"] -->|"prepare 完成"| READY["VDBE_READY_STATE<br/>就绪 (pc=0)"]
    READY -->|"sqlite3_step()"| RUN["VDBE_RUN_STATE<br/>执行中 / 暂停于 SQLITE_ROW"]
    RUN -->|"OP_ResultRow<br/>返回 SQLITE_ROW"| RUN
    RUN -->|"OP_Halt 或出错<br/>返回 SQLITE_DONE / err"| HALT["VDBE_HALT_STATE<br/>已终止"]
    RUN -->|"sqlite3_reset()"| READY
    HALT -->|"sqlite3_reset()"| READY
    READY -->|"sqlite3_finalize()"| FREE["已销毁"]
    RUN -->|"sqlite3_finalize()"| FREE
    HALT -->|"sqlite3_finalize()"| FREE

    class INIT,READY,HALT,FREE state;
    class RUN active;
```

有三个容易被忽略的细节：
- **进入 `VDBE_RUN_STATE` 后**：只要还没走到 [`OP_Halt`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1293) 且没有调用 `sqlite3_reset()`，虚拟机就处于活跃状态，持有的 B-Tree 游标和事务锁不会释放。
- **[`sqlite3_reset()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L128) 的职责**：调用 [`sqlite3VdbeReset()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L3586)（若仍在 `VDBE_RUN_STATE` 则先强行 [`sqlite3VdbeHalt()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L3315)，并把错误码/错误信息转移到 `db` 上），再调用 [`sqlite3VdbeRewind()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L2593) 把状态拨回 `VDBE_READY_STATE`。注意 **`sqlite3_reset()` 不会清空 `aVar[]` 中的绑定参数**，清空绑定需要单独调用 [`sqlite3_clear_bindings()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L149)。
- **[`sqlite3_finalize()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L99) 的职责**：先执行 `reset` 关闭游标，再释放 `aOp`、`aMem`、`aVar`、`apCsr` 和 `Vdbe` 结构体本身。

---

## 6. 从 VDBE 视角看驱动层踩过的 5 个工程坑

回看我们在 [src/database/sql/sqlite.zig](../src/database/sql/sqlite.zig) 和 [src/database/sql.zig](../src/database/sql.zig) 中遇到的几类问题，都能直接对应到上面的机制：

### 6.1 为什么 `query` 必须用 `SQLITE_TRANSIENT`，而 `exec` 用 `SQLITE_STATIC` 必须配 `reset + clear_bindings`

把写入参数（`sqlite3_bind_*`）和读取参数（`OP_Variable`）两步连起来，就能看清原因：

**第一步：`sqlite3_bind_*()` 决定了参数槽 `aVar[i]` 的数据指针 `aVar[i].z` 指向哪里**（第 3.3 节提到，`aVar[i]` 是一个 `Mem`，绑定字符串或 BLOB 时由其 `z` 字段持有底层字节指针，实现见 [`sqlite3VdbeMemSetStr`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbemem.c#L1273) / [`sqlite3VdbeMemSetText`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbemem.c#L1374)）：
- 传 `SQLITE_STATIC`：`aVar[i].z` **直接保存调用方传入的裸指针**，不做内存拷贝。
- 传 `SQLITE_TRANSIENT`：SQLite 立即在堆上分配 `aVar[i].zMalloc`，把调用方数据拷贝进去，让 `aVar[i].z` 指向这份私有拷贝。

**第二步：`sqlite3_step()` 运行到 [`OP_Variable`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1575) 时，只做指针浅拷贝**：

```c
case OP_Variable: {            /* out2: 把第 p1 个绑定参数加载到寄存器 r[p2] */
  Mem *pVar;

  assert( pOp->p1>0 && pOp->p1<=p->nVar );
  pVar = &p->aVar[pOp->p1 - 1];        /* 取出绑定槽中的参数（1-based 转 0-based） */
  if( sqlite3VdbeMemTooBig(pVar) ){    /* 校验长度是否超过 SQLITE_LIMIT_LENGTH */
    goto too_big;
  }
  pOut = &aMem[pOp->p2];               /* 目标输出寄存器 r[p2] */
  if( VdbeMemDynamic(pOut) ) sqlite3VdbeMemSetNull(pOut); /* 先释放 r[p2] 原有的动态内存 */
  memcpy(pOut, pVar, MEMCELLSIZE);     /* 仅浅拷贝 u/z/n/flags/enc，不复制字符串/BLOB 内容 */
  pOut->flags &= ~(MEM_Dyn|MEM_Ephem); /* 清除动态/临时所有权标志，避免 r[p2] 误释放 aVar 的内存 */
  pOut->flags |= MEM_Static|MEM_FromBind; /* 标记为借用自绑定槽（所有权仍归 aVar[p1-1]） */
  UPDATE_MAX_BLOBSIZE(pOut);           /* 更新语句最大 BLOB/字符串尺寸统计 */
  break;
}
```

关键就在 `memcpy(pOut, pVar, MEMCELLSIZE)` 这一行（正如第 3.2 节对 `MEMCELLSIZE` 分界线的说明）：`OP_Variable` 只是把 `aVar[i].z` 原样抄给目标寄存器 `pOut->z`（即 `r[p2].z`），既不复制字符串字节，也不接管 `zMalloc`/`xDel`，因此最终的指针链路是：
- `SQLITE_STATIC`：`r[p2].z` → `aVar[i].z` → **调用方的外部缓冲区**
- `SQLITE_TRANSIENT`：`r[p2].z` → `aVar[i].z` → **SQLite 持有的 `aVar[i].zMalloc` 堆拷贝**

由此可以直接推出驱动层的两条做法：
- **为什么 `query()` 必须用 `SQLITE_TRANSIENT`**：`db.query()` 内部只执行了第一步（`bind`），还没执行 `OP_Variable`；`OP_Variable` 是在 `query()` 返回之后、调用方每次调 `Rows.next()`（即 `sqlite3_step()`）时才执行的。如果第一步传了 `SQLITE_STATIC`，等调用方栈上缓冲区销毁或被覆写后，第二步 `OP_Variable` 抄出来的 `r[p2].z` 读到的就是悬空内存。改用 `SQLITE_TRANSIENT` 后，`aVar[i].zMalloc` 一直存活到 `Rows.close()` 调用 `sqlite3_clear_bindings()` 时才释放。
- **为什么 `SQLiteStmt.exec()` 用 `SQLITE_STATIC` 必须在返回前 `clear_bindings`**：`exec()` 内第一步（`bind`）和第二步（`step` 执行 `OP_Variable`）都在同一次同步调用里完成，期间调用方缓冲区始终存活，因此可以零拷贝；但前面说过 `sqlite3_reset()` **不会清空 `aVar[]`**，所以必须在 `exec()` 的 `defer` 里同时调 `sqlite3_reset()` 和 `sqlite3_clear_bindings()`，防止 `exec()` 返回后 `aVar[i].z` 仍悬空指向已销毁的调用方内存。

### 6.2 为什么 `exec` 遇到 `INSERT ... RETURNING` 必须循环 `while (step_rc == SQLITE_ROW)`

在 SQLite 中，`INSERT ... RETURNING id` 第一次 `sqlite3_step()` 会在 [`OP_ResultRow`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1746) 处暂停并返回 `SQLITE_ROW`。此时：
1. [`sqlite3VdbeHalt()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L3315) 尚未执行，`Vdbe.nChange` 还没有刷回 `db->nChange`，立刻调用 `sqlite3_changes(db)` 读到的还是上一条语句的旧值；
2. 语句仍停在 `VDBE_RUN_STATE`，在 autocommit 模式下隐式写事务要等到 `OP_Halt`（或 `reset`/`finalize`）才提交。

因此在 [src/database/sql/sqlite.zig](../src/database/sql/sqlite.zig) 的 `SQLiteStmt.stepToDone()` 中，我们用 `while (step_rc == c.SQLITE_ROW)` 把所有结果行消费到 `SQLITE_DONE`，确保 VDBE 正常 halt 后再读取 `sqlite3_changes()` 和 `sqlite3_last_insert_rowid()`。

### 6.3 为什么 `Rows.next()` 扫描出的 `[]const u8` 只能借用到下一次 `next()` 或 `close()`

[`sqlite3_column_text()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1416) 和 [`sqlite3_column_blob()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1381) 直接返回输出行寄存器 `pResultRow[col]` 中的字节指针 `z`（见第 3.5 节），它可能指向 `aMem[]` 内部缓冲，也可能直接借用 B-Tree 页面缓存（`MEM_Ephem`）。
一旦调用下一次 `Rows.next()`，下一轮循环的 `OP_Column` / `OP_Rowid` 会直接覆写同一个 `aMem[]` 寄存器，B-Tree 游标也会移动；调用 `Rows.close()` 则会触发 `sqlite3_reset()` 释放所有寄存器内容。因此驱动层在文档中明确要求：若要在下一次 `next()` 或 `close()` 后继续持有切片数据，必须由调用方显式 `allocator.dupe`。

### 6.4 为什么 `Stmt.close()` 早于 `Rows.close()` 会触发 Use-After-Free

`SQLiteRows` 并不拥有独立的 `Vdbe`，它只是借用了 `SQLiteStmt.stmt`（同一个 `Vdbe*`）。如果 `Stmt.close()` 先调用了 `sqlite3_finalize()`，整个 `Vdbe` 结构体已经被释放；后续 `Rows.next()`（`sqlite3_step`）或 `Rows.close()`（`sqlite3_reset`）再操作这个指针就会立刻触发 UAF。

这也是我们在 [src/database/sql.zig](../src/database/sql.zig) 中引入 `RowsState` 并挂接到 `StmtState.active_rows` 与 `TxState.rows_head` 的原因：无论 `Stmt.close()`、`Tx.commit()` 还是同 `Stmt` 重入执行，都会先通过 `RowsState.closeAndDetach()` 完成 `raw_rows.close()`（`sqlite3_reset` + `sqlite3_clear_bindings`），再执行 `raw_stmt.close()`（`sqlite3_finalize`）。

### 6.5 为什么 [`sqlite3_progress_handler`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/main.c#L1812) 能优雅中断慢查询

[`sqlite3VdbeExec()`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L846) 的指令解释主循环内部维护了操作计数器：每执行 `N` 条 VDBE 字节码（我们在 `Progress.start` 中配置为 `1000`），虚拟机就会回调注册的 `xProgress` 函数。只要回调返回非零值（例如 `Deadline` 到期或 `io.checkCancel()` 检测到任务取消），VDBE 就会在当前指令边界跳出循环、安全回滚/中止语句并返回 `SQLITE_INTERRUPT`，不会破坏数据库文件结构或连接状态。

---

## 7. 排查与观察执行计划的实用手段

排查慢查询或确认 SQL 执行路径时，SQLite 自带了三种现成工具：

- **`EXPLAIN <SQL>`**：输出完整的 `VdbeOp` 字节码列表（`addr`, `opcode`, `p1..p5`, `comment`），适合精确定位索引回表、临时排序表或触发器展开。
- **`EXPLAIN QUERY PLAN <SQL>`**：输出更高层的访问计划（`SCAN` / `SEARCH USING INDEX` / `USE TEMP B-TREE`），适合日常索引调优。
- **[`sqlite3_stmt_status(stmt, op, resetFlag)`](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L2106)**：读取 `Vdbe.aCounter[]` 中的运行时统计，例如 `SQLITE_STMTSTATUS_FULLSCAN_STEP`（全表扫描步数）、`SQLITE_STMTSTATUS_SORT`（排序次数）和 `SQLITE_STMTSTATUS_VM_STEP`（执行的字节码总步数）。

---

## 8. 参考源码（SQLite `version-3.53.0`）

| 分层 | 符号 / 模块 | 源码位置 | 说明 |
| :--- | :--- | :--- | :--- |
| **接口层** | `sqlite3_stmt` | [src/sqlite.h.in#L4303](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/sqlite.h.in#L4303) | C API 对外暴露的不透明语句句柄 |
| **接口层** | `sqlite3_finalize` / `reset` / `clear_bindings` / `step` | [src/vdbeapi.c#L99](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L99) / [#L128](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L128) / [#L149](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L149) / [#L913](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L913) | 语句生命周期与步进 C API |
| **接口层** | `sqlite3_column_blob` / `text` / `bind_text64` / `stmt_status` | [src/vdbeapi.c#L1381](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1381) / [#L1416](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1416) / [#L1834](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L1834) / [#L2106](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeapi.c#L2106) | 列读取、参数绑定与状态统计 C API |
| **接口层** | `sqlite3_changes` / `sqlite3_progress_handler` | [src/main.c#L1150](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/main.c#L1150) / [#L1812](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/main.c#L1812) | 变更计数与执行中断回调注册 |
| **编译前端** | `sqlite3_prepare_v2` / `sqlite3Prepare` | [src/prepare.c#L937](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/prepare.c#L937) / [#L682](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/prepare.c#L682) | SQL 编译为 VDBE 字节码入口 |
| **编译前端** | `sqlite3GetToken` / `sqlite3RunParser` | [src/tokenize.c#L273](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/tokenize.c#L273) / [#L600](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/tokenize.c#L600) | 词法切分与 Lemon 语法解析驱动 |
| **编译前端** | `sqlite3Select` / `sqlite3WhereBegin` / `sqlite3FinishCoding` | [src/select.c#L7578](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/select.c#L7578) / [src/where.c#L6828](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/where.c#L6828) / [src/build.c#L141](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/build.c#L141) | 查询规划、索引选择与字节码收尾 |
| **VDBE 引擎** | `struct VdbeOp` / `struct Vdbe` / `struct VdbeCursor` | [src/vdbe.h#L55](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.h#L55) / [src/vdbeInt.h#L458](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L458) / [#L79](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L79) | 指令、虚拟机与游标核心结构 |
| **VDBE 引擎** | `struct sqlite3_value` (`Mem`) / `MEM_*` / `VDBE_*_STATE` | [src/vdbeInt.h#L232](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L232) / [#L310](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L310) / [#L534-L537](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeInt.h#L534-L537) | 寄存器容器、内存标志与状态机 |
| **VDBE 引擎** | `sqlite3VdbeExec` / 核心指令 (`Halt`, `Variable`, `ResultRow`, `Column`, `OpenRead`, `Rewind`, `Next`) | [src/vdbe.c#L846](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L846) / [#L1293](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1293) / [#L1575](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1575) / [#L1746](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L1746) / [#L2975](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L2975) / [#L4386](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L4386) / [#L6372](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L6372) / [#L6510](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbe.c#L6510) | 虚拟机主循环与核心字节码实现 |
| **VDBE 引擎** | `sqlite3VdbeRewind` / `MakeReady` / `Halt` / `Reset` | [src/vdbeaux.c#L2593](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L2593) / [#L2647](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L2647) / [#L3315](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L3315) / [#L3586](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbeaux.c#L3586) | 复原、打包内存分配、终止与复位 |
| **VDBE 引擎** | `sqlite3VdbeMemSetStr` / `sqlite3VdbeMemSetText` | [src/vdbemem.c#L1273](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbemem.c#L1273) / [#L1374](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/vdbemem.c#L1374) | `SQLITE_STATIC` / `SQLITE_TRANSIENT` 底层实现 |
| **存储后端** | `sqlite3BtreeCursor` / `First` / `Next` | [src/btree.c#L4765](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L4765) / [#L5676](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L5676) / [#L6369](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/btree.c#L6369) | B-Tree 游标创建与遍历 |
| **存储后端** | `sqlite3PagerGet` / `sqlite3OsRead` / `struct sqlite3_vfs` | [src/pager.c#L5726](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/pager.c#L5726) / [src/os.c#L88](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/os.c#L88) / [src/sqlite.h.in#L1513](https://github.com/sqlite/sqlite/blob/version-3.53.0/src/sqlite.h.in#L1513) | 页缓存管理与 VFS 操作系统读写适配 |
