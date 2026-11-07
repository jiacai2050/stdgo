# 第一性原理 HTTP/HTTPS Client 实现与真实网络踩坑排查实录

**日期**: 2026-11-07  
**作者**: stdgo 团队  
**目标**: 摆脱对 Zig `std.http` 的依赖，从第一性原理使用 `std.Io` 与 `std.crypto.tls.Client` 实现轻量高效的 HTTP/HTTPS Client，并通过 `https://edgebin.liujiacai.net/` 的真实 GET 和 POST 请求验证。

---

## 1. 背景

Go 语言标准库中的 `net/http` 拥有简洁易用的客户端抽象，而在 Zig 0.17 中，标准库自带的 `std.http.Client` 架构复杂且性能偏重。为了在 `stdgo` 中提供极简、高效、符合 Go 习惯的 HTTP 客户端，我们从第一性原理基于底层 TCP Socket (`std.Io.net.Stream`) 与 TLS 1.3/1.2 (`std.crypto.tls.Client`) 自研 HTTP 传输层。

在对真实线上环境 `https://edgebin.liujiacai.net/` 进行端到端测试时，遭遇了一系列复杂的卡顿、连接中断和数据读取异常。本文记录完整的排查与解决过程。

---

## 2. 核心问题与排查过程

### 2.1 卡点一：macOS 钥匙串全量扫描导致初次握手严重卡死（~7秒）

- **现象**：测试启动后长时间无响应，打印日志显示在 `Client.init` 阶段停滞 6~7 秒。
- **根因**：`std.crypto.Certificate.Bundle.rescan` 在 macOS 平台会通过 Security 框架遍历全系统 Keychain（包括 Root、System、User 钥匙串）。如果每次创建 Client 都全量 rescan，开销极大。
- **解决**：在 Transport 级别按需缓存 `ca_bundle`，测试与免验证模式下指定 `.ca = .no_verification`，连接初始化耗时瞬间从 7 秒下降到微秒级。

---

### 2.2 卡点二：Zig Optional 解包导致的值拷贝与悬挂指针

- **现象**：TLS 握手成功后，后续调用 `conn.read` 发生数据错乱或非法内存访问。
- **根因**：在 Zig 中，若 `HttpConn` 内部字段为 `tls_client: ?std.crypto.tls.Client`，当执行 `self.tls_client.?` 时，若未注意引用语义，会生成一个栈上的临时值拷贝。`tls.Client` 内部的 `reader` 和 `writer` 的 vtable 依赖内部指针，浅拷贝后导致指向非法内存。
- **解决**：将 `tls_client` 改为堆上显式分配的指针类型：
  ```zig
  tls_client: ?*std.crypto.tls.Client = null,
  ```
  在握手成功后通过 `allocator.create(std.crypto.tls.Client)` 存放，确保生命周期内内存地址绝对稳定。

---

### 2.3 卡点三：TLS 与 Socket Writer 的两级缓冲未完全刷新

- **现象**：TLS 握手已完成，发送 HTTP 请求后服务端迟迟不给响应，客户端阻塞在读取端。
- **根因**：Zig 0.17 的 `std.crypto.tls.Client.writer` 本身是有缓冲的：
  - 调用 `tls_client.writer.writeAll(data)` 仅将明文暂存到 TLS write buffer。
  - 调用 `tls_client.writer.flush()` 时，内部仅将明文加密并追加到物理输出流 `stream_writer.interface` 的缓冲区中（调用了 `output.advance()`），并**不会**直接把字节写到底层 TCP socket。
- **解决**：在 `HttpConn.writeAll` 中必须显式执行两级刷新：
  ```zig
  try self.tls_client.?.writer.writeAll(data);
  try self.tls_client.?.writer.flush();       // 1. 加密写入 stream_writer 缓冲区
  try self.stream_writer.interface.flush();    // 2. 将密文推入物理 Socket
  ```

---

### 2.4 卡点四：`tls.Client.reader` 的缓冲特性与残余字节（Leftover）丢失

- **现象**：
  - GET 请求能读到 Header，但读 Body 时卡死或报错 `ReadFailed`。
  - 或 `conn.read` 读到 0，报错 `ConnectionClosedPrematurely`。
- **根因深入剖析**：
  1. **`readVec` 的特殊语义**：查阅 Zig 标准库 `Client.zig` 源码发现：
     ```zig
     fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
         // This function writes exclusively to the buffer.
         _ = data;
         const c: *Client = @alignCast(@fieldParentPtr("reader", r));
         return readIndirect(c);
     }
     ```
     `tls.Client.reader` 的 `readVec` **完全忽略**调用方传入的切片，只负责把网络收到的 TLS 记录解密到其内部的 `r.buffer` 中！直接对它使用常规的 `readSliceShort` 会导致空读和指针不同步。
  2. **头体同包（Leftover）切片截断**：网络传输中，Server 往往将 HTTP 响应头和前几百字节的 Body 打包在同一个 TLS Application Record 中下发。我们最初手写了 `conn.read` 读到固定 4KB 缓冲并截取字符串，导致残留在内存中的 Body 字节无法正确与后续网络读取无缝对接。

---

### 2.5 卡点五：参考 `std.http.Client` 架构的最佳实践重构

为了彻底解决卡点四，我们深入研读了 Zig 官方 `std/http/Client.zig` 的设计，进行了关键重构：

1. **统一流抽象为 `*std.Io.Reader`**：
   无论底层是 TLS 还是普通 TCP 流，`HttpConn` 均暴露标准的 `reader() *std.Io.Reader`。
2. **利用 `in.buffered()` 与 `in.toss()` 零拷贝处理报头**：
   ```zig
   const in = conn.reader();
   var head_len: usize = 0;
   const max_head_len = 16 * 1024;

   while (true) {
       const buffered = in.buffered();
       if (std.mem.indexOf(u8, buffered, "\r\n\r\n")) |idx| {
           head_len = idx + 4;
           break;
       }
       if (buffered.len >= max_head_len) return error.ResponseHeaderTooLarge;
       try in.fillMore();
   }

   const raw_head = try self.allocator.dupe(u8, in.buffered()[0..head_len]);
   errdefer self.allocator.free(raw_head);
   in.toss(head_len); // 关键：仅消耗 Header 部分！
   ```
3. **Body 读取自然衔接**：
   调用 `in.toss(head_len)` 后，已经从同一个 TLS Record 中解密出来的 Body 字节依然完好保留在 `in.buffer[seek..end]` 中。后续 `ResponseBodyReader` 读取 Body 时，直接消费缓冲区剩余字节，缓冲区耗尽时自动调用 `fillMore()` 从网卡解密下一帧，**彻底消除了手工维护 `leftover` 切片的需求**。

---

### 2.6 卡点六：真实网络环境诊断（IPv6 丢包与 Cloudflare Anycast）

- **现象**：即便逻辑完全正确，访问 `https://edgebin.liujiacai.net/` 依然偶尔发生 10~20 秒的长等待或突然被中断。
- **抓包与网络采样**：
  - 使用 macOS `sample` 工具对测试进程进行采样，堆栈显示停留在 `recvmsg` 阻塞。
  - 使用 `ping` 对解析出的 Cloudflare Anycast IP 测试：
    ```
    PING 172.67.165.195 (172.67.165.195): 56 data bytes
    64 bytes from 172.67.165.195: icmp_seq=1 ttl=53 time=306.779 ms
    --- 172.67.165.195 ping statistics ---
    2 packets transmitted, 1 packets received, 50.0% packet loss
    ```
  - **网络丢包率高达 50%**，RTT 超过 300ms。
  - 此外，Zig 默认开启的 TLS 1.3 ML-KEM-768（后量子密匙交换）使得 ClientHello 达到 1.8KB，在跨国高丢包网络下大包重传极易导致握手耗时膨胀。
- **优化对策**：
  在 `connectStream` 中优化 DNS 解析调度，优先匹配并连接稳定的 IPv4 节点，避免 IPv6 路由空洞。

---

## 3. 最终架构与测试成果

### 3.1 模块分工

- `src/net/http/conn.zig`: 统一管理 Plain TCP 与 TLS 1.3/1.2 连接，维护专属的双向缓冲池。
- `src/net/http/transport.zig`: 负责序列化 HTTP/1.1 请求、驱动 DNS、连接池复用、以及基于 `in.toss()` 解析响应头。
- `src/net/http/response.zig`: 实现 `fixed` (Content-Length), `chunked` (分块编码), `close_eof` 三种传输模式的响应体读取流。
- `src/net/http/client.zig`: 对标 Go 标准库风格的客户端，提供 `get`、`post`、`postForm`、`head` 等高层 API。

### 3.2 测试验证与 API 全覆盖

在 `src/net/http/client.zig` 中构建了针对 `https://edgebin.liujiacai.net/` 的 13 项全面真实 API 自动化集成测试：

1. `GET /ip`: 验证公网 IP 与地理位置响应
2. `GET /headers`: 验证自定义请求头往返
3. `POST /post`: 验证 JSON 负载传输与自动 Content-Length
4. `PUT /put`: 验证 PUT 方法与文本负载
5. `DELETE /delete`: 验证 DELETE 方法
6. `PATCH /patch`: 验证 PATCH 方法与 JSON 负载
7. `GET /status/418`: 验证标准状态码与响应体排空（I'm a teapot）
8. `GET /status/500`: 验证错误状态码
9. `GET /bytes/64`: 验证固定大小二进制流传输（准确接收 64 字节）
10. `GET /json`: 验证标准复杂 JSON 响应
11. `GET /qrcode?text=stdgo`: 验证 SVG 矢量图响应
12. `POST /md2html`: 验证 Markdown 到 HTML 在线转换
13. `GET /user-agent`: 验证自定义 User-Agent

此外在深检中发现并修复了以下边界缺陷：
- **相对重定向 URL 截断**：原先截取 `current_url[7..]`，在 `https://`（8字节）下会导致首字符匹配到 `'/'` 把域名截断为 `"https:/"`，现已改为动态寻找 `://` 后的首个 `'/'`。
- **自动补齐 Content-Length**：对于自定义 Request 或 PUT/PATCH 请求体，自动在未提供时补充 `Content-Length: {d}`，避免 HTTP/1.1 违规。
- **无斜杠 Query URL 解析**：`parseUrlTarget` 增强对 `https://example.com?foo=bar` 格式的解析支持。
- **超时模型与 `std.Io` 兼容**：严禁在 `std.Io.Threaded` 下手动通过 POSIX `setsockopt` 设置 `SO_RCVTIMEO`（否则触发超时会产生 `EAGAIN` 导致 `programmer bug caused syscall error: AGAIN` 崩溃），超时应完全由 `std.Io.Timeout` 原生驱动。

全量单元测试通过：
```bash
$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 90/90 tests passed
test success
+- run test 89 pass (89 total)
+- run test 1 pass (1 total)
```
