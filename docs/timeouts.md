# 超时与 deadline：实现边界及 Go 对照

本文记录当前 stdgo 的超时行为与实现边界，便于选择接口并明确超时后的资源状态。文中的“Go”对照项以 Go 标准库公开接口为准；`semaphore` 和 `rate` 分别对照 `golang.org/x/sync/semaphore` 和 `golang.org/x/time/rate`。Go 的第三方实现与数据库驱动同样需要应用配合检查取消，不能将 Go 的 context 理解为可强制中断任意代码。

## 总体边界

- `stdgo.io.Deadline` 表示 `.none` 或 `.awake` 单调时钟上的绝对时间，不是取消信号；调用方若需跨层共享时间预算，必须显式传递同一个实例。它不提供自动到期广播或上下文树。
- 超时属于协作式机制。依赖并发任务的操作在返回前会先取消并等待任务退出，以保护借用的缓冲区与连接。若底层 I/O 后端或调用方传入的 reader 不响应取消，返回时间可能晚于 deadline。若并发任务创建失败，操作会直接返回启动错误。
- 超时不代表操作完全未发生。网络写入可能已发送了部分前缀；数据库写入或事务提交在超时后的实际状态可能需要调用方进一步确认。当读取完成与超时同时发生时，已完成的读取结果优先返回。
- `Deadline.after(io, .zero)` 表示立即到期；多数可选 timeout 配置的零值或负值表示不设超时。HTTP 的 `timeout_ns` 若非空则优先于 `timeout`，即便其值为 0。

### 时钟源与 .awake 语义

`stdgo.io.Deadline` 内部统一基于 Zig 0.17 的 `std.Io.Clock.awake` 时钟。Zig 0.17 提供的各时钟源对比与底层实现映射如下：

| 时钟源 (`std.Io.Clock`) | 底层实现 (Linux / macOS) | 允许跳变/回退 | 计算系统休眠时间 | 典型适用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **`.real`** | `CLOCK_REALTIME` | **是**（NTP 突变、人工调时间） | 是 | 日历、日志时间戳、展示用时间 |
| **`.awake`** | `CLOCK_MONOTONIC` / `CLOCK_UPTIME_RAW` | **否**（严格单调递增） | **否**（休眠期间时钟暂停） | **I/O 超时、RPC 截止期、锁等待、耗时度量** |
| **`.boot`** | `CLOCK_BOOTTIME` / `CLOCK_MONOTONIC_RAW` | **否**（严格单调递增） | **是**（开机以来的绝对时长） | 机器在线运行时间（Uptime）、外部长周期任务对齐 |
| **`.cpu_process`** / **`.cpu_thread`** | 进程 / 线程 CPU 时间 | 否 | 否 | CPU Profiling、算力消耗统计 |

- **系统映射与特性**：
  - Linux 对应 `CLOCK_MONOTONIC`；macOS 对应 `CLOCK_UPTIME_RAW`。
  - **严格单调递增**：不受管理员调整系统时间、闰秒修正或 NTP 步进同步等墙钟跳变的影响，采样差值始终非负。
  - **排除系统挂起时间**：意在仅度量系统处于唤醒（awake）状态下的时间。系统处于休眠或待机挂起状态时，该时钟会暂停走动（与计算开机总时长的 `.boot` / `CLOCK_BOOTTIME` 不同）。
- **与 `.real` / `.boot` 对比**：
  - `.real`（`CLOCK_REALTIME`）：易受外部校时大幅突变影响，若用来计算超时，会导致请求在校时瞬间误报超时或无限挂起，严禁用于超时与耗时统计。
  - `.boot`（`CLOCK_BOOTTIME`）：包含休眠时间，适合机器总运行时间统计。但用于超时预算时，会导致笔记本合盖休眠数小时唤醒后，所有等待中的 I/O 请求在开盖瞬间全部因超时失败。
- **选择理由**：
  - 超时本质上是“活跃计算与网络 I/O 的有效时间预算”。使用 `.awake` 可确保系统休眠期间不消耗宝贵的超时额度，唤醒后依然保有预期的剩余等待时间。
  - 与 Zig 0.17 原生并发与网络原语（如 `std.Io.Timeout`、`std.Io.Event.waitTimeout`）的时钟基准完全一致。

## 与 Go 对照

| 场景 | stdgo | Go | 当前差异和限制 |
| --- | --- | --- | --- |
| 取消与期限 | 显式传递 `Deadline`；任务取消由 `std.Io.Future` / `Group` 管理 | `context.Context` 组合了取消与期限 | stdgo 不会自动向下层透传 deadline，也没有 context 到期广播机制。 |
| TCP 拨号 | `Dialer.timeout`、`Dialer.deadline` 与单次调用的 deadline 取最早值 | `net.Dialer.Timeout`、`Deadline` 和 `DialContext` | stdgo 的 DNS 解析与连接限时依赖后端协作；HTTP transport 暂未提供独立的 DNS 或 connect 超时配置。 |
| TCP 读写 | `Conn.readDeadline` / `writeDeadline` 按次传入期限 | `net.Conn.SetDeadline`、`SetReadDeadline`、`SetWriteDeadline` | stdgo 不设连接级的持久期限，无法通过设置新期限修改正在等待的调用；写入报错时不会同时返回部分写入的字节数。 |
| 接收连接 | `Listener.accept` 不接收期限 | `net.TCPListener.SetDeadline` | stdgo 的 accept 操作不支持指定 deadline。 |
| UDP | `UDPConn` 支持 `readFromDeadline`、`readDeadline` 以及连接目标的 `writeDeadline` | `net.PacketConn` 和 UDP 连接支持设置读写期限 | stdgo 的 `PacketConn` 接口未提供带期限的方法，`writeTo` 不支持 deadline；转换为通用 `Conn` 后也不暴露底层期限回调。 |
| 独立 DNS 查询 | `Resolver.timeout` 控制单次查询的预算 | `net.Resolver` 查询方法接收 `context.Context` | stdgo 查询方法无显式 deadline 参数；`lookupIP` 依次查询 A 与 AAAA 记录，共用同一份超时预算。 |
| HTTP 请求总期限 | `Client.timeout` / `timeout_ns` 与 `Client.do` 的 deadline 取较早值，覆盖重定向及 body 读取 | `http.Client.Timeout`、请求级 context | 两者均取决于具体 transport 实现；stdgo 无法强制打断自定义 RoundTripper 或非协作式 body reader。 |
| HTTP 阶段期限 | 支持 TLS 握手、响应头等待、`100-continue` 等待和空闲连接回收期限 | `http.Transport` 提供对应配置；支持通过 `DialContext` 定制拨号 | stdgo 没有 transport 级的自定义 dialer 或独立的 DNS/connect 期限；各阶段期限均受请求总期限约束。 |
| SQL 查询与池等待 | `DB`、`Conn`、`Stmt`、`Rows` 接收 deadline；SQLite 驱动与连接池支持期限检查 | `database/sql` 的 `*Context` 方法接收 context | 执行前会检查任务取消与期限是否超期；执行中是否支持打断取决于具体 driver 实现（如 SQLite 支持虚拟机执行中断）。与 Go 一致，驱动若未实现中断机制则尽力而为执行。 |
| SQL 事务 | `begin`、单次操作、`commit` 和 `rollback` 分别接收期限 | `BeginTx` 传入的 context 贯穿整个事务；取消后自动回滚 | stdgo 不继承 `begin` 的期限，也不会自动回滚；调用前超时的事务仍由调用方持有，须显式清理。 |
| semaphore / rate | `Weighted.acquire` 和 `Limiter.waitN` 接收 deadline | 对应 Go 扩展包的等待方法接收 context | stdgo 的等待包含锁竞争与退出清理，不能作为严格的完成时间上限；rate limiter 取消预约时不保证始终能退还全部 token。 |
| 子进程 | `Cmd.run(io)` 等待进程退出；等待期间推迟处理任务取消 | `exec.CommandContext` 默认在 context 结束时向进程发送 Kill 信号 | stdgo 目前不提供等价的执行超时强制终止；等待过程中的取消需等待子进程退出后处理。 |

## 网络和 DNS

TCP、UDP 和 HTTP 操作均使用注入的 `std.Io`。带有期限的网络操作可能启动内部并发任务；若任务完成与超时发生竞争，已完成的网络读写无法撤销。UDP 限时接收可能在取走数据报后才返回超时；限时发送返回超时也不代表数据报未发出。

`net.pipe` 采用内存队列，在等待数据或空间时通过轮询检查期限。它并非内核 socket，长期等待会产生调度与 CPU 开销。创建 pipe 时传入的 `io` 必须存活至两端均关闭。

独立 `Resolver` 的 A 和 AAAA 记录查询共享同一份预算。若 A 记录查询成功但后续 AAAA 查询超时，`lookupIP` 会返回超时错误，放弃已取得的 A 记录。HTTP 客户端拨号使用的是注入 I/O 后端的主机名解析，不读取该 `Resolver.timeout` 配置。

相关实现：[TCP 和 pipe](../src/net/conn.zig)、[UDP](../src/net/udp.zig)、[DNS](../src/net/dns.zig)、[拨号](../src/net/connect.zig)、[socket 等待](../src/net/io_util.zig)。

## HTTP

内置客户端的请求总期限从发起时开始计算，重定向及响应 body 读取共享该预算。`response_header_timeout` 从完整发送请求 body 后开始计时，不覆盖响应 body 读取；TLS 握手期限仅在握手阶段生效。目前没有单独的 body 空闲读取超时或请求体分段写入超时，需统一通过请求总期限控制。

`expect_continue_timeout` 为零、负值或未设置时，客户端会直接发送 body；若在等待期间收到了最终响应，则不再发送 body。等待到期意味着继续发送 body，并非请求失败。响应 `std.Io.Reader` 消费内部已缓冲的数据时，无需再次调用底层套接字，因此读取已缓存数据时不一定会重新检查 deadline。

空闲连接超时由后台任务主动回收。启用该配置后，`Transport` 从首次发起请求至 `deinit` 必须保持稳定的内存地址，且注入的 `io` 必须支持并发任务。当前代理连接不进入该连接池。自定义 RoundTripper 虽会接收 deadline 参数，但需自行实现期限控制；调用方传入的 body reader 也需配合响应取消。

相关实现：[client](../src/net/http/client.zig)、[transport](../src/net/http/transport.zig)、[连接池](../src/net/http/pool.zig)、[响应 body](../src/net/http/response.zig)。

## SQL 和事务

SQLite 在虚拟机（VM）执行期间通过 progress handler 大约每 1000 条指令检查一次期限与取消信号。打开数据库、文件系统 I/O、获取锁或其他未触发 progress handler 的操作可能在超过期限后才返回；耗时极短的操作也可能在检查间隙完成。连接池的条件等待支持 deadline，但获取互斥锁的过程仍可能引入延迟。

事务中的每个操作使用独立传入的期限；调用方若需统一预算，应复用同一个绝对 deadline。若在调用 `commit` 或 `rollback` 前发现期限已过，事务仍归调用方所有，此时可调用 `rollback(.none)` 清理连接。若驱动执行回调后返回错误，事务会被消费，连接会被直接丢弃，避免将状态未知的连接归还至连接池。

相关实现：[数据库池和事务](../src/database/sql.zig)、[驱动接口](../src/database/sql/driver.zig)、[SQLite 驱动](../src/database/sql/sqlite.zig)。

## 同步和限流

在 `Weighted` 信号量等待中，若授权与超时同时发生，可能优先返回成功；获取内部锁与取消后的队列清理也可能晚于 deadline。`Limiter` 限流器在取消预约时会结合后续预约与限流配置变更做出判断，因此不保证每次都能退还全部额度。

相关实现：[semaphore](../src/sync/semaphore.zig)、[rate limiter](../src/time/rate.zig)、[子进程](../src/os/exec.zig)。

## Go 接口参考

- [net.Conn 和 net.Dialer](https://pkg.go.dev/net)
- [net/http Client 和 Transport](https://pkg.go.dev/net/http)
- [database/sql](https://pkg.go.dev/database/sql) 和 [driver](https://pkg.go.dev/database/sql/driver)
- [os/exec](https://pkg.go.dev/os/exec)
- [x/sync/semaphore](https://pkg.go.dev/golang.org/x/sync/semaphore) 和 [x/time/rate](https://pkg.go.dev/golang.org/x/time/rate)
