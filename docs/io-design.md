# stdgo I/O 设计演进与架构规范

本文档记录了 `stdgo` 在数据流抽象（`io.Reader` / `io.Writer`）上的演进历程、设计取舍、与 Zig 0.17 原生 `std.Io` 的底层能力对比，以及最终确立的**原生归一化架构**。

---

## 1. 架构演进与最终决策

在 `stdgo` 项目初期，曾尝试过两种路线：
1. **初期探索（Go 风格无状态虚表）**：引入极简的 `read([]u8)` / `write([]const u8)` 虚表，外挂 `bufio` 与中继桥接 `bridge.zig`。
2. **最终确立（原生归一化架构）**：**全面沿用 Zig 0.17 原生 `std.Io.Reader` 与 `std.Io.Writer` 作为 `stdgo` 的主流式抽象，彻底移除冗余的 `bufio` 与 `bridge.zig`。**

### 决策理由：
- **性能不妥协**：`stdgo` 的定位是把 Go 标准库的丰富生态与优雅人体工学带给 Zig，但**绝不能妥协性能**。Zig 0.17 原生的 `std.Io` 拥有内置三指针滑动窗口、向量化 I/O（Scatter-Gather）、原生模式填充展开（`splat`）以及内核态直传（`sendFile` / `sendFileAll`），这些机器效率是 Go 经典无状态虚表无法企及的。
- **消灭冗余抽象**：由于 Zig 0.17 的 `std.Io.Reader` 和 `std.Io.Writer` 结构体自身已是有状态的高性能缓冲容器，Go 时代的 `bufio.Reader` / `bufio.Writer` 在 Zig 0.17 下已丧失存在意义；将其移除可以消除多层内存中继与二次虚表分发。

---

## 2. 核心流模型对比

| 维度 | 旧版 Go 虚表模式（已废弃） | 最终归一架构（Zig 0.17 原生 `std.Io`） |
| :--- | :--- | :--- |
| **基础类型** | 自定义无状态胖指针 `ptr + vtable` | 原生结构体容器 `pub const Reader = std.Io.Reader;` |
| **缓冲职责** | 外挂 `bufio` 堆内存二次包装 | 侵入式三指针内建（`buffer` / `seek` / `end`），零堆分配 |
| **数据流转** | 外部分配 32KB 临时 buffer 循环搬运 | 原生 `src.stream(dst, limit)`，直通快路径与 `sendFileAll` |
| **探查能力** | 必须由外部预供切片并内存复制 | `take`/`peek` 直接原地借用内部切片，O(1) 零拷贝 |
| **刷新语义** | 仅 `bufio` 需 flush；其余依赖即时写 | 写端有缓冲，流末尾显式 `try w.flush()` 保证数据完整 |
| **互操作性** | 需经 `bridge.zig` 转换，中断内核管道 | 100% 无缝对接 Zig 官方标准库与第三方库生态 |

---

## 3. 全局技术亮点与零拷贝实现

在全面归一至 `std.Io` 后，`stdgo` 各模块展现出极致的系统级效率：

### 1) 内存流的原生零拷贝
- **`bytes.Reader`**：内部包装 `std.Io.Reader.fixed(b)`，直接将外部不可变字节切片作为就绪缓冲区，`read`、`buffered`、`stream` 均为 O(1) 零分配。
- **`bytes.Buffer`**：内部通过 `@fieldParentPtr` 将其动态扩容数组直接挂载为 `std.Io.Writer` 的内部缓冲区，`w.writeAll` 在容量充足时走内联 `@memcpy` 快路径；容量不足时通过 `drain` 自动扩容并挂载新切片。

### 2) 流流转的极致简化：`io.copy`
在去除了复杂的探测逻辑后，`stdgo.io.copy` 完全委托给 Zig 0.17 原生流转引擎：
```zig
pub fn copy(dst: *Writer, src: *Reader) anyerror!u64 {
    const bytes = try src.stream(dst, .unlimited);
    return @intCast(bytes);
}
```
当 `src` 或 `dst` 支持文件内核直传时，自动走操作系统的 `copy_file_range` / `fcopyfile`，用户态零拷贝。

### 3) 协议解析器的零拷贝探查
在 `encoding/csv`、`archive/tar`、`compress/gzip`、`net/http` 等流式解析器中：
- 采用 `r.takeDelimiterExclusive('\n')` 和 `r.take(512)` 直接原地借用滑动窗口内部切片；
- CSV 解析器针对未转义字段直接生成子切片，杜绝了中间 `bytes.Buffer` 的额外堆分配与重复复制。

---

## 4. 关键代码模式

### 1) 读取端（Reader 消费者）
```zig
const stdgo = @import("stdgo");
const io = stdgo.io;

// 接受 *io.Reader 指针驱动读取
pub fn processStream(r: *io.Reader) !void {
    var line_buf: [256]u8 = undefined;
    const n = try r.readSliceShort(&line_buf);
    _ = n;
}
```

### 2) 写入端（Writer 生产者）
```zig
const stdgo = @import("stdgo");
const io = stdgo.io;

// 写入完毕后必须显式调用 flush，确保缓冲区数据交付
pub fn writeOutput(w: *io.Writer) !void {
    try w.writeAll("hello world\n");
    try w.flush();
}
```

### 3) 自定义组件实现 `writer()`
通过 `@fieldParentPtr` 原生对接 `std.Io.Writer`：
```zig
pub fn writer(self: *MyComponent) *io.Writer {
    self.writer_inst = .{
        .buffer = &.{},
        .vtable = &.{
            .drain = drainImpl,
            .flush = flushImpl,
        },
    };
    return &self.writer_inst;
}

fn drainImpl(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *MyComponent = @alignCast(@fieldParentPtr("writer_inst", w));
    // 直接消费数据切片并处理 splat 展开
    ...
}
```

---

## 5. 总结

`stdgo` 坚决贯彻 **“借鉴 Go 标准库的人体工学与丰富生态，但不向性能妥协”** 的原则。通过彻底拥抱 Zig 0.17 的 `std.Io` 体系并剥离历史冗余，`stdgo` 在保持 Go 风格直观 API 的同时，获得了完全对齐 Zig 现代化系统级 I/O 的极致性能与内存安全保障。
