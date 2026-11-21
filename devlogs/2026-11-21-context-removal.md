# 从 Context 到显式的任务、取消与期限

**日期**: 2026-11-21

stdgo 曾模仿 Go 提供 `stdgo.context`，将取消信号、超时期限和请求元数据打包在一棵动态上下文树中。现在我们移除了这个模块，将任务生命周期、取消广播、时间预算和业务数据拆解为独立的原生机制。

本文记录这次重构的原因与过程：回顾 `context.Context` 在 Go 生态中的作用与运行机制，梳理此前在 Zig 中探索定时器驱动（`TimerDriver`）遇到的并发与生命周期问题，最后介绍各个核心子系统的替代实现与迁移指南。

---

## 1. Context 在 Go 生态中的地位与作用

`context.Context` 是 Go 标准库与并发模型的核心接口之一。它最早源于 Google 内部并发 RPC 的实践，于 2014 年在 Go 官方博客介绍，并在 Go 1.7 正式并入标准库。

在 Go 社区中，涉及 I/O、网络调用、并发任务或长时间运行的函数，通常将 `ctx context.Context` 作为第一个形参。无论是标准库的 `net/http`、`database/sql`、`os/exec`，还是 gRPC、Kubernetes、etcd 等开源项目，都普遍依赖 Context 协调跨边界调用。

Context 主要负责三类职责：

1. 级联取消与生命周期管理：当一次请求分叉派生出多个 Goroutine（如并发查询缓存与数据库）时，若客户端断开连接或某个前置检查失败，上游调用 `cancel()`，信号便能沿上下文树传递给下游任务，避免后台 Goroutine 泄漏与无效计算。
2. 端到端时间预算（Deadline / Timeout）：通过 `WithTimeout` 或 `WithDeadline` 在请求入口设定绝对期限，下游各调用阶段共享同一份不可逆的预算，超时后由 Go 运行时触发取消。
3. 请求级元数据透传（Value）：通过 `WithValue` 传递 TraceID、认证凭证等跨关注点数据，无需逐层修改中间函数的签名。

### 为什么它在 Go 中适用？

这套模型在 Go 中之所以顺畅，离不开语言运行时的两项支撑：
- 垃圾回收（GC）：Context 是引用类型，跨 Goroutine 传递或被后台闭包捕获时，无需显式管理节点的所有权和生命周期，内存会在无引用后自动回收。
- 运行时与 Netpoller：Go 的网络与并发原语由运行时调度器和非阻塞网络轮询器统一管理，Goroutine 在 `select { case <-ctx.Done(): }` 或 Socket 阻塞时能被直接挂起和唤醒。

移植 stdgo 时，我们很自然地尝试在 Zig 中提供对应的 `stdgo.context`。但 Zig 没有垃圾回收，也没有全局协程运行时；当 Context 的动态对象模型与手动内存管理、同步阻塞系统调用相遇时，二者的语义差异很快带来了难以兼顾的复杂度。

---

## 2. stdgo 旧版的实现细节与用法

旧版 `stdgo.context`（参见提交 [`929e872`](https://github.com/jiacai2050/stdgo/blob/929e872/src/context/context.zig)）在 Zig 中实现了一套动态类型擦除的对象模型与树状订阅系统。

### 2.1 核心数据结构与 VTable 模型

旧版 `Context` 采用类似 Go 接口值的胖指针结构，由实例数据指针与包含 10 个函数指针的虚函数表（VTable）构成：

```zig
pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deadline: *const fn (ctx: *anyopaque) ?time.Time,
        done: *const fn (ctx: *anyopaque) bool,
        err: *const fn (ctx: *anyopaque) ?Error,
        cause: *const fn (ctx: *anyopaque) ?anyerror,
        value: *const fn (ctx: *anyopaque, key: []const u8) ?*const anyopaque,
        refresh: *const fn (ctx: *anyopaque, io: std.Io) void,
        wait: *const fn (ctx: *anyopaque, io: std.Io) WaitError!void,
        waitTimeout: *const fn (ctx: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void,
        subscribe: *const fn (ctx: *anyopaque, sub: *Subscriber) bool,
        unsubscribe: *const fn (ctx: *anyopaque, sub: *Subscriber) void,
    };
};
```

根节点 `background()` 与 `todo()` 指向全局静态的只读空 VTable，不产生内存分配；而派生子节点（取消、超时、键值）均通过调用方提供的 `std.mem.Allocator` 动态分配在堆上。

### 2.2 派生节点的内部实现机制

整个 Context 树依靠三个核心派生结构体相互支撑：

#### 1. 取消节点与侵入式订阅链表（`CancelContext` 与 `Subscriber`）

为了实现父节点取消时通知所有子节点与回调，旧版设计了侵入式双向链表系统：

```zig
// 侵入式订阅节点（嵌入在子 Context 或 afterFunc 句柄中）：
pub const Subscriber = struct {
    next: ?*Subscriber = null,
    prev: ?*Subscriber = null,
    subscribed: bool = false,
    on_cancel: *const fn (sub: *Subscriber, err: Error, cause: ?anyerror, io: ?std.Io) void,
};

pub const CancelContext = struct {
    parent: Context,
    canceled: std.atomic.Value(bool) = .init(false),
    cancel_err: ?Error = null,
    cause_err: ?anyerror = null,
    done_event: std.Io.Event = .unset,
    mutex: Mutex = .{},
    notify_mutex: Mutex = .{},
    subs_head: ?*Subscriber = null,
    parent_sub: Subscriber = .{ .on_cancel = onParentCancel },
    // ...
};
```

- 父子订阅绑定：调用 `withCancel(allocator, parent)` 时，新创建的子 Context 内嵌一个 `parent_sub` 实例，并通过父节点的 `vtable.subscribe` 挂载进父节点的 `subs_head` 双向链表。
- 级联通知：当父节点调用 `cancel()` 时，获取 `notify_mutex`，线性遍历 `subs_head` 链表，逐个触发 `sub.on_cancel()`，将信号推送到各叶子节点。
- 事件阻塞：调用 `ctx.wait(io)` 内部在 `done_event: std.Io.Event` 上挂起，取消发生时通过 `done_event.set(io)` 唤醒。

#### 2. 超时节点（`DeadlineContext`）

`DeadlineContext` 内部内嵌一个完整的 `CancelContext`，额外记录绝对时间戳 `deadline_val: time.Time`，并负责驱动定时触发机制：
- 早期实现通过为每个节点启动独立的内核线程 sleep 触发；
- 后期尝试通过集中式 `TimerDriver` 统一调度（详见第 3 节）。

#### 3. 键值节点与递归查找（`ValueContext`）

通过 `withValue(allocator, parent, key, val_ptr)` 派生的节点保存当前层的 `key: []const u8` 与类型擦除后的指针 `val_ptr: *const anyopaque`。
- 链表回溯：调用 `ctx.value(k)` 时，若当前节点 key 不匹配，递归调用 `parent.value(k)` 向上回溯整棵树，查找耗时与树深度成正比。
- 类型安全扩展：后续引入了 `TypedKey(T, "name")`，利用编译期独立静态变量地址作为内存标识符，减少指针强转错误。

### 2.3 旧版完整使用流程与析构负担

以下是旧版在处理带有超时和取消的请求时的用法：

```zig
// 旧版用法（需要管理堆内存与退订顺序）：
const bg = context.background();

// 1. 堆分配创建取消节点，借用父节点
var cancel_node = try context.withCancel(allocator, bg);
defer cancel_node.deinit(allocator);

// 2. 堆分配创建超时节点，挂入取消节点的订阅链表
const deadline_time = time.Time.now(io).add(time.Duration.fromSeconds(5));
var dl_node = try context.withDeadline(allocator, cancel_node.context(), deadline_time);
defer dl_node.deinit(allocator);

// 3. 堆分配创建键值节点，挂载追踪 ID
const trace_id: usize = 9527;
var val_node = try context.withValue(allocator, dl_node.context(), "trace_id", &trace_id);
defer val_node.deinit(allocator);

// 4. 将叶子节点的胖指针传入下游函数
const ctx = val_node.context();
try handleRequest(io, ctx);
```

这种设计在 Zig 中带来了明显的维护负担：
- 析构顺序敏感：`deinit()` 释放堆内存前，必须先持锁从父节点的双向链表中执行 `unsubscribe` 摘除自身；若顺序错误，父节点取消时可能解引用已释放的内存。
- 堆分配开销：单次请求为了组合超时和追踪 ID，需要在堆上执行多次 `allocator.create`，增加了内存碎片和管理成本。

---

## 3. 为什么移除：从定时线程到 TimerDriver 的泥潭

在手动管理内存的语言中，直接复刻这套机制会带来持续的生命周期与同步问题。我们的探索经历了以下阶段：

### 3.1 早期实现：每个超时一个独立线程

在最早期的 `withTimeout` / `withDeadlineIo` 实现中，每次创建带有超时的 Context，都会为它启动一个操作系统线程：

```zig
// 早期 DeadlineContext 内部简化模型（已废弃）：
pub const DeadlineContext = struct {
    cancel_ctx: CancelContext,
    deadline_val: time.Time,
    timer_thread: ?std.Thread = null,

    fn startTimer(self: *DeadlineContext, io: std.Io) !void {
        const Worker = struct {
            fn run(ctx_ptr: *DeadlineContext, task_io: std.Io) void {
                const now = time.Time.now(task_io);
                const diff_ns = ctx_ptr.deadline_val.sub(now).nanoseconds();
                if (diff_ns > 0) {
                    task_io.sleep(.fromNanoseconds(@intCast(diff_ns)), .awake) catch {};
                }
                ctx_ptr.cancel_ctx.cancel();
            }
        };
        self.timer_thread = try std.Thread.spawn(.{}, Worker.run, .{ self, io });
    }
};
```

这种实现存在明显缺陷：
1. 线程开销过大：高并发短连接请求下，频繁创建和销毁线程会消耗大量系统资源。
2. 销毁等待延迟：请求提前完成后执行 `defer ctx.deinit()`，若后台线程仍在 sleep，调用方需要阻塞等待线程退出（`thread.join()`），影响处理耗时。

### 3.2 集中式 TimerDriver 的尝试与并发问题

为了避免单 Context 单线程，我们尝试引入了集中式定时器驱动器 `TimerDriver`。它使用单个后台工作线程结合索引最小堆（Indexed Min-Heap）维护所有超时的 Context：

```zig
// 探索阶段的集中式 TimerDriver 骨架（已废弃）：
pub const TimerDriver = struct {
    allocator: Allocator,
    io: std.Io,
    entries: std.ArrayListUnmanaged(TimerEntry) = .empty,
    mutex: Mutex = .{},
    wakeup_event: std.Io.Event = .unset,
    worker_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    firing_id: ?u64 = null,

    pub const TimerEntry = struct {
        id: u64,
        deadline: time.Time,
        deadline_ctx: *DeadlineContext,
    };

    pub fn addTimer(self: *TimerDriver, ctx: *DeadlineContext, dl: time.Time) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .id = self.next_id, .deadline = dl, .deadline_ctx = ctx });
        ctx.heap_index = index;
        self.siftUp(index);
        self.wakeup_event.set(self.io);
        return self.next_id;
    }
};
```

`TimerDriver` 减少了线程数量，但引入了新的竞态与所有权约束：

#### 并发触发与提前析构的竞态（Use-After-Free）

后台 Worker 线程检测到堆顶定时器到期并准备调用回调时，主线程可能刚好结束工作并执行 `defer ctx.deinit()`。若主线程释放了 `ctx` 的内存，Worker 线程随后访问 `ctx.cancel_ctx` 会发生非法内存访问。
为了避免该问题，`removeTimer` 被迫加入了自旋等待逻辑：

```zig
// 为了防止在途触发时发生 UAF 的自旋逻辑：
pub fn removeTimer(self: *TimerDriver, deadline_ctx: *DeadlineContext) void {
    while (true) {
        self.mutex.lock();
        // 若 Worker 线程正在触发该定时器，主线程需要等待其回调执行完成
        if (self.firing_id == deadline_ctx.timer_id) {
            self.mutex.unlock();
            std.Thread.yield() catch {};
            continue;
        }
        self.removeFromHeap(deadline_ctx.heap_index);
        self.mutex.unlock();
        return;
    }
}
```

#### 跨模块锁竞争与顺序冲突

- 主线程调用 `ctx.cancel()`：先持有 `ctx.cancel_ctx.mutex`，再在 `removeTimer` 中请求 `driver.mutex`；
- Worker 线程触发超时：先持有 `driver.mutex`，再在 `cancelInternal` 中请求 `ctx.cancel_ctx.mutex`。
为了避免死锁，调度线程在调用回调前必须提前释放 `driver.mutex`，但这扩大了在途时间窗口，需要增加额外的同步状态位。

#### 所有权拓扑与析构顺序

`TimerDriver` 是外部注入的依赖，不是全局单例：
- 若 `TimerDriver` 先于 `Context` 析构，堆中残留的 Context 在调用 `deinit()` 时会解引用已释放的 Driver 指针；
- 若 `Context` 必须先于 `TimerDriver` 析构，调用方就需要严格规划对象生命周期的层级关系。

#### 被动对象无法中断底层阻塞

最根本的限制在于：Context 只是内存中的状态标记，无法主动中断处于阻塞状态的系统调用。阻塞读取的 Socket、正在执行的 SQLite 查询或等待子进程退出的调用，不会因为 Context 状态变为 canceled 而立即返回。要响应取消，底层代码仍需配合主动检查或由系统调用层提供超时支持。

---

## 4. 设计原则：生命周期的正交分解

重构方案将异步任务的各项要素解耦为独立职责：

| 职责 | 核心诉求 | 原生机制 | 设计契约 |
| --- | --- | --- | --- |
| 任务收尾 | 任务是否已结束？借用的缓冲区何时可安全释放？ | `std.Io.Future` / `std.Io.Group` | 结构化并发：启动任务的作用域负责等待或取消并等待其退出。收尾完成前，借用数据不可释放。 |
| 退出广播 | 跨组件如何非阻塞接收退出信号？ | `stdgo.io.CancelSource` / `CancelToken` | 栈上信号：内嵌 `std.Io.Event`，无堆分配与链表，仅发信号、不负责收尾。 |
| 时间预算 | 阻塞操作最多等待多久？ | `stdgo.io.Deadline` | 绝对时间：基于 `.awake` 单调时钟，直接下沉至具体阻塞点，各调用阶段共享预算。 |
| 请求数据 | 查询需要什么业务参数？ | 具体 Struct / 函数参数 | 显式传递：通过类型与参数传递数据，避免通用的键值字典装箱。 |

---

## 5. 核心子系统的落地实现细节

本次重构删除了 `src/context/` 及其相关文件，并在各模块中完成了原生接口替换：

### 5.1 任务收尾与结构化并发

- 派生独立工作函数时，调用方持有 `std.Io.Future`。
- 调用 `future.cancel(io)` 会向任务注入取消请求，并同步等待任务退出。`cancel` 返回后，调用方借给子任务的内存才能安全回收。
- 批量任务使用 `stdgo.sync.errgroup`（底层基于 `stdgo.sync.Group`）：
  - 并发度通过 `limit` 限制在 `min(limit, tasks.len)`，内部队列容量固定；
  - 观察到首个业务错误后，通过 `group.cancel(io)` 取消并等待其余任务结束；
  - 调度由 Owner 持续运行，Worker 仅投递结果，避免 Worker 自身调用 `cancel` 引发等待自身的问题。

```zig
// 使用 stdgo.sync.errgroup 执行有界并发任务：
const Worker = struct {
    fn run(task_io: std.Io, id: usize) !void {
        try task_io.checkCancel();
    }
};

const tasks = [_]std.meta.ArgsTuple(@TypeOf(Worker.run)){
    .{ io, 1 },
    .{ io, 2 },
    .{ io, 3 },
};
// 最多并发执行 2 个任务，任一任务报错即取消其余任务并等待退出
try stdgo.sync.errgroup.Group.run(allocator, io, Worker.run, &tasks, 2);
```

### 5.2 零堆分配的协作式取消广播（`CancelSource` / `CancelToken`）

针对长连接流式消费、事件主循环等跨组件通知场景，在 `src/io/cancel.zig` 中实现轻量级原语：
- 零堆分配：`CancelSource` 内部内嵌 `std.Io.Event = .unset`，通常就地分配在调用方栈帧上。
- 只读借用：`token` 仅持有 `event: *std.Io.Event`，供下游调用 `token.isCanceled()` 或 `token.waitCanceled(io)`。
- 语义区分：`token.waitCanceled(io)` 正常返回表示收到广播信号；返回 `error.Canceled` 表示等待任务自身被 I/O 运行时取消。

```zig
var source = stdgo.io.CancelSource.init();

// 将只读 Token 借给下游并发任务
var future = try io.concurrent(worker, .{ io, source.token() });

// 触发退出信号（多次调用幂等）
source.cancel(io);

// 调用方仍负责等待任务退出收尾
try future.await(io);
```

### 5.3 HTTP Client 全链路流式 Deadline

HTTP Client 实现了完整的流式超时控制：
- 套接字适配：通过 `src/net/io_util.zig` 的 `SocketReader` 与 `SocketWriter`，将 `Deadline`（`.awake` 绝对时间戳）传入底层 Plain TCP 及 `std.crypto.tls.Client`。当 TLS 内部返回 `ReadFailed` / `WriteFailed` 时，可还原出真实的 `error.Timeout` 或 `error.Canceled`。
- 阶段预算共享：同一个 `request_deadline` 贯穿域名解析、TCP 拨号（`connect.zig` 配合 25ms tick 与即时清理）、TLS 握手、请求体分块上传（`io_util.readBody`）、`100-continue` 等待及响应体流式读取。
- 异常连接隔离：在 `Response.close()` 中加入 `if (body_ptr.eof_reached and body_ptr.read_err == null)` 判断。若读取过程中发生超时或取消，连接会被直接关闭销毁，不放回空闲连接池。
- 主动空闲连接淘汰：在 `src/net/http/pool.zig` 中引入 `expireLoop` 任务，结合 `std.Io.Event.waitTimeout` 在最早到期时间主动关闭闲置连接，并在互斥锁保护下重置与触发事件。

```zig
// 创建 5 秒的绝对时间预算：
const deadline = stdgo.io.Deadline.after(io, .fromSeconds(5));

var req = try stdgo.net.http.Request.init(allocator, .GET, "https://example.com/api");
defer req.deinit();

// 请求全链路共享同一份 5 秒预算：
var resp = try client.do(&req, deadline);
defer resp.close();

var body_buf: [1024]u8 = undefined;
while (true) {
    const n = try resp.body.read(&body_buf);
    if (n == 0) break;
}
```

### 5.4 数据库驱动与 SQLite VM 指令级超时

- 兼容超时模式：在 `src/database/sql/driver.zig` 中采用与 Go 一致的尽力而为（best-effort）模式，操作前统一校验任务取消与截止期。执行中是否支持超时打断取决于具体驱动实现（如 SQLite 支持虚拟机执行中断）。
- SQLite 虚拟机中断：`src/database/sql/sqlite.zig` 接入 `sqlite3_progress_handler(db, 1000, callback, self)`。每执行 1000 条虚拟机字节码，检查一次 `io.checkCancel()` 与 `deadline`；若已超时或被取消，返回 1 促使 SQLite 退出并返回 `SQLITE_INTERRUPT`。
- 连接池条件变量：连接池等待使用 `std.Io.Condition`，在连接归还、丢弃、扩容或关闭时唤醒等待者，替代了此前的 sleep 轮询。

### 5.5 信号量与限流器的并发安全性

- Weighted 信号量：等待者在自身调用栈上分配 `Waiter` 节点。队列操作、授权标记及 `event.set(io)` 全部在同一个互斥锁保护下完成。等待者唤醒或超时后必须重获同一把锁才能释放栈帧；取消时若已被授权，会执行 `cur -= n` 并尝试唤醒后续等待者。
- Rate Limiter 保守回滚：针对并发预约取消可能导致的超额突发问题，引入 `generation: u64`。仅当被取消的预约属于当前最新、且未被后续预约推进过时，才退还 token；已有更新预约或限流配置变更时，取消不增加当前可用 token。

### 5.6 子进程（os.exec）

- 移除后台 watchdog 监控线程与 raw POSIX `kill` 调用。
- 在 `child.wait(io)` 期间通过 `io.swapCancelProtection(.blocked)` 暂时阻断取消，防止在主线程调用 `wait4` 期间发生并发 reap 导致 ECHILD 或 double-free；子进程退出后再通过 `io.checkCancel()` 传播取消。

---

## 6. 迁移指南与 API 对照速查

| 场景 | 旧版用法（已删除） | 当前版本用法 |
| --- | --- | --- |
| 任务派生与取消 | `ctx, cancel = withCancel(...)`<br>`go worker(ctx)` | `var future = try io.concurrent(worker, .{io});`<br>`future.cancel(io) catch {};` |
| 信号广播 | `ctx, cancel = withCancel(...)`<br>向多个任务传 `ctx` | `var src = CancelSource.init();`<br>向多个任务传 `src.token()`，主控调用 `src.cancel(io)` |
| 时间预算 | `ctx, _ = withTimeout(parent, 5s)` | `const dl = Deadline.after(io, .fromSeconds(5));`<br>作为普通参数传递给各调用点 |
| HTTP 请求 | `req.withContext(ctx)`<br>`client.do(req)` | `client.do(req, deadline)`<br>（亦可配置 `ClientOptions.timeout`） |
| SQL 操作 | `db.queryContext(ctx, sql, args)` | `db.query(sql, args, deadline)` |
| 信号量获取 | `sem.acquire(ctx, weight)` | `sem.acquire(io, weight, deadline)` |
| 限流器等待 | `limiter.wait(ctx)` | `limiter.wait(io, deadline)` |
| 子进程执行 | `exec.commandContext(ctx, argv)` | `exec.command(allocator, argv)` 并配合 Future 管理 |
| 元数据透传 | `ctx = withValue(ctx, key, val)` | 定义结构体显式传参 |

### 行为边界与注意事项

1. 超时与取消的协作性：`Deadline` 和 `CancelToken` 属于协作式协议。若调用的外部 C 库、第三方驱动或纯计算循环未嵌入取消检查点，操作可能在超时后继续运行一段时间，调用方需通过任务 `await` 确保退出后再清理借用资源。
2. 写操作的副作用：当网络写入或数据库事务操作返回 `error.Timeout` 时，网络数据可能已部分发送，数据库也可能执行了部分语句，调用方不能假定状态未受影响。
3. 事务生命周期：`Tx.commit` 与 `Tx.rollback` 接收 `Deadline`；若提交前已超时，事务仍由调用方持有，可调用 `tx.rollback(.none)` 清理连接。

---

## 7. 总结

删除 `stdgo.context` 后，库内部不再维护侵入式订阅链表、锁屏障和全局定时器线程；任务生命周期由 Future / Group 在调用作用域显式收尾，时间预算直接传给支持 deadline 的等待点。全套 326 项测试在 ThreadSanitizer（TSAN）下均通过且无数据竞态。

面对跨组件并发与超时需求，在 Zig 中以结构化任务管理所有权、以单调时钟传递时间预算，比维护一个全局 Context 对象更能保证内存安全与行为明确。
