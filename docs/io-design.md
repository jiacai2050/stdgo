# stdgo I/O 设计取舍与架构规范

本文档记录了 `stdgo` 项目在数据流抽象（`io.Reader` / `io.Writer`）上的设计取舍、架构权衡、与 Zig 0.17 原生 `std.Io` 的底层能力对比，以及工程落地中的演进方案。

---

## 1. 背景与核心分歧

在现代系统编程中，I/O 流抽象的设计往往决定了整个标准库生态的组合能力与人体工学。在构建 `stdgo` 时，我们面临核心抉择：**是直接使用 Zig 0.17 的 `std.Io` 接口，还是复刻 Go 经典的 `io.Reader` / `io.Writer` 体系？**

### 两者的本质哲学差异

| 维度 | Go 风格设计（`stdgo` 采用） | Zig 0.17 设计（`std.Io`） |
| :--- | :--- | :--- |
| **基础抽象** | **无状态的原语（Unbuffered Primitive）**<br>`read(buf)` / `write(bytes)` | **有状态的容器（Buffered Container）**<br>结构体内置 `buffer: []u8`、`seek`、`end` 三指针模型 |
| **缓冲职责** | **正交分层**：基础层无缓冲；需要缓冲时显式包裹 `bufio.Reader` / `bufio.Writer` | **侵入式内建**：所有 `Reader`/`Writer` 实例都携带缓冲切片状态机（即便切片长度为 0） |
| **Flush 机制** | **按需触发**：仅在使用 `bufio.Writer` 时才需要 `Flush()`；直接写底层句柄即刻同步生效 | **强制心智**：写操作默认先入内部缓冲区，使用者在写完后必须时刻谨防是否需要 `flush()` |
| **数据所有权** | **Caller 驱动**：调用方显式传入切片，被调方纯搬运，无内部悬挂指针风险（契合 TigerStyle） | **Callee 维护**：结构体自持 buffer，存在内部游标移动、借用及扩容状态 |
| **实现门槛** | **极低**：只需实现单个函数即可接入全量流生态 | **较高**：必须维护 `buffer`/`seek`/`end`，并实现满足规范的 `stream`/`drain` 虚表 |

---

## 2. 为什么不能直接全盘采用 Zig 0.17 `std.Io`？

1. **避免上层移植发生“语义雪崩”**：
   Go 庞大的标准库生态（`archive/tar`、`archive/zip`、`compress/gzip`、`encoding/csv`、`mime/multipart`、`net/http`）全部建立在“调用 `write` 即同步交付”的心智模型上。如果基础 `Writer` 强制带有缓冲和 `flush`，上层数十个模块都必须重构引入 `flush` 传播逻辑，任何漏调都会导致尾部数据丢失，引发灾难性隐蔽 Bug。
2. **生命周期与显式内存（TigerStyle）**：
   Go 风格的无状态 `io.Reader` / `io.Writer` 只有两个指针（`ptr` + `vtable`，共 16 字节），零内部内存分配、零生命周期绑定。
3. **即时流与交互协议的健壮性**：
   在 Server-Sent Events (SSE)、HTTP Chunked 传输、TCP 双工通信等场景下，无缓冲基础层天然保证低延迟，杜绝因遗漏 `flush` 导致的数据死锁与迟发。

---

## 3. Zig 0.17 的新能力剖析

Zig 0.17 废弃旧版宏混入泛型 Reader、改用具体结构体，其核心驱动力在于追求**极致的底层机器效率与避免多余内存中继拷贝**：

1. **三指针物理模型（`buffer: []u8`, `seek`, `end`）**：
   - `[0 .. seek]`：已消费区域（无用历史数据）；
   - `[seek .. end]`：就绪有效数据（零拷贝直接读取，提供原地 `peek`）；
   - `[end .. len]`：空闲待写入区域（供底层系统调用直接填充）。
   - **快慢路径分离**：内部有效数据充足时，走快路径 `@memcpy`；当内部数据耗尽时，慢路径通过向量封装调用系统调用（如 `readv` / `io_uring`），将目标切片当作 DMA 目标内存直读，跳过中间临时缓冲。
2. **聚集写入（Gather I/O）与 `splat` 对齐填充**：
   `drain(w, data: []const []const u8, splat: usize)` 天然支持切片向量与尾部填充，一次系统调用批量刷入协议头、消息体与对齐字节。
3. **内核级零拷贝与自动降级（`sendFile` / `sendFileAll`）**：
   `w.sendFile` 对接内核级直传（如 Linux `copy_file_range`、macOS `fcopyfile`），不支持时自动借用 `w.buffer` 回退到常规读写循环。

---

## 4. 能力对等与互补机制：`WriterTo` 与 `ReaderFrom`

虽然 Zig 0.17 将高级能力内建在容器中，但 Go 体系通过 **“主客体双向能力探测”** 同样实现了对等的零拷贝优化，且保持了基础接口的纯粹：

```
                    ┌────────────────────────┐
                    │      io.copy(dst, src) │
                    └───────────┬────────────┘
                                │
               ┌────────────────┴────────────────┐
               ▼                                 ▼
      【源端驱动优化】                    【目标端驱动优化】
        src.writeTo                       dst.readFrom
   (如 bytes.Buffer/Reader)          (如 TCPConn / File / Buffer)
               │                                 │
     直接切片交付，消除用户态               直通操作系统内核
         32KB 中继拷贝                         sendFile / splice
```

### 1) 源驱动优化：`WriterTo`
- **适用场景**：源端最清楚自己的内存布局（如 `bytes.Buffer`、`bytes.Reader`、`strings.Reader`）。
- **优势**：源端直接调用 `w.writeAll(slice)`，**彻底消除 32KB 临时中继栈缓冲与多次无意义的内存拷贝**。

### 2) 目标驱动优化：`ReaderFrom`
- **适用场景**：目标端拥有特殊的吸收通道（如网络套接字、文件或内存接收容器）。
- **优势**：
  - **内存端（`bytes.Buffer`）**：直接在内部存储尾部原地扩容读取，数据一次性落入目标地址；
  - **操作系统端（`Socket` / `File`）**：若源端是文件，直接触发底层 `sendFile` 进行内核态零拷贝。

---

## 5. 关于 `sendFile` 在 Bridge 中的取舍与权衡

在类型擦除的流抽象中，`sendFile` 能够生效必须同时具备：
1. **写端目标（Sink）** 具备内核发送接口（如 Zig `std.Io.Writer` 或系统套接字）；
2. **读端来源（Source）** 必须能够暴露出操作系统文件句柄（如 `*std.Io.File.Reader` 或系统 fd）。

### 设计权衡：
- **常规切片 Bridge**：将 `std.Io.Reader` 桥接为 `stdgo.io.Reader` 时，若只进行通用数据搬运，底层只能依赖 `readSliceShort` 与 `drain`，在传输文件时会退化为内存中继；
- **打通零拷贝通路**：可通过在 `Reader.VTable` 扩展轻量可选探针（如 `getFile`），并在写端 `FromZigWriter.readFrom` 中探测该探针，一旦匹配则直调 Zig 0.17 的 `self.zig_writer.sendFileAll(file_reader, .unlimited)`，兼顾 Go 的简洁调用与 Zig 的内核级直传。

---

## 6. stdgo I/O 三层架构体系

`stdgo` 确立了如下三层分工明确的架构体系：

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 上层标准库生态层 (stdgo 生态闭环)                         │
│    net/http, archive/tar, compress/gzip, bufio, csv...      │
│    (统一基于无状态极简 stdgo.io.Reader / Writer VTable)       │
├─────────────────────────────────────────────────────────────┤
│ 2. 快速路径与优化层 (Go 风格的零拷贝加速)                    │
│    io.copy / io.copyBuffer 自动路由探测:                     │
│    • ReaderFrom (如 bytes.Buffer.readFrom)                  │
│    • WriterTo   (如 bytes.Reader.writeTo, Buffer.writeTo)   │
├─────────────────────────────────────────────────────────────┤
│ 3. Zig 0.17 原生互操作层 (src/io/bridge.zig)                 │
│    • fromZigReader / fromZigWriter: 接入 Zig 0.17 std.Io    │
│    • toZigReader / toZigWriter:     导出给 Zig 0.17 std.Io   │
│    • 零拷贝扩展: 联动 sendFileAll 内核直传                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. 关键代码模式速查

### 从 Zig 原生 I/O 桥接到 stdgo
```zig
const stdgo = @import("stdgo");
const io = stdgo.io;

// 将 Zig 0.17 std.Io.Reader 转换为 stdgo.io.Reader
var bridge = io.fromZigReader(&zig_stream_reader);
const reader = bridge.reader();

// 直接传给 stdgo 的流式解析器
var tar_r = stdgo.archive.tar.Reader.init(reader);
```

### 从 stdgo 导出到 Zig 原生 I/O
```zig
// 将 stdgo 的 reader 包装为 Zig 0.17 原生 std.Io.Reader
var r_buf: [4096]u8 = undefined;
var to_zig = io.toZigReader(my_stdgo_reader, &r_buf);

// 供 Zig 原生支持 std.Io 的库直接消费
_ = try to_zig.reader.readSliceShort(&dest);
```
