# stdgo Roadmap & Go Standard Library Gap Analysis

This document provides a comprehensive comparison between the Go standard library (Go 1.22+) and `stdgo`, tracking our implementation status, coverage metrics, architectural boundaries, and prioritized future roadmap.

---

## 1. Executive Summary & Coverage Metrics

`stdgo` aims to bring Go standard library ergonomics, unified streaming abstractions (`io.Reader` / `io.Writer` VTable), and high-utility packages to the Zig (0.17.0) ecosystem.

- **Core Practical / High-Utility Coverage**: **~60%**
  - Essential streaming I/O (`io`, `bytes`, `strings`, `bufio`), context trees (`context`), concurrency primitives (`sync.WaitGroup`, `sync.Once`, `sync.Mutex`, `sync.Pool`, `sync.errgroup`), structured logging (`log/slog`), HTTP client (`net/http`), multipart forms (`mime/multipart`), and linear-time regex (`regexp`) are production-ready with comprehensive test suites.
- **Explicit Non-Goals Excluded**: ~20% (Go runtime internals, GC, compiler tools, standalone HTTP server).
- **Remaining Target Gap**: **~20%** (Streaming `encoding/json`, `os/exec` command pipeline, symmetric/asymmetric cryptography, advanced IP/CIDR networking, `container/list`).

```
[========================== 60% Implemented ==========================>][==== 20% Target Gap ====][== 20% Non-Goals ==]
```

---

## 2. Scope Boundaries & Explicit Non-Goals

Per `AGENTS.md`, certain Go packages are intentionally excluded from `stdgo`:

1. **HTTP Server (`net/http.Server`, `Handler`, `ServeMux`)**:
   - **Explicit Non-Goal**: A standalone, high-performance, multithreaded HTTP server is already fully implemented in [lighting](https://github.com/jiacai2050/lighting/). `stdgo.net.http` is **strictly focused on the HTTP client** (`Client`, `Transport`, `ConnPool`, `CookieJar`, `Request`, `Response`).
2. **Go Compiler & AST Toolchain**:
   - `go/ast`, `go/parser`, `go/token`, `go/types`, `go/printer`, `go/build`, `go/doc`.
3. **Go Runtime & Garbage Collector Internals**:
   - `runtime`, `runtime/debug`, `runtime/pprof`, `runtime/trace`, `runtime/metrics`, `runtime/cgo`.
4. **Platform-Specific System Call Duplication**:
   - `syscall` (fully handled by Zig's native `std.posix` and `std.os.windows`).

---

## 3. Current Implementation Status (Completed Modules)

| Go Package | `stdgo` Package | Status | Key Features |
| :--- | :--- | :--- | :--- |
| **`io`** | `stdgo.io` | **100%** | VTable `Reader`, `Writer`, `Closer`, `Seeker`, `LimitReader`, `TeeReader`, `copy`, `readFull`, `readAtLeast` |
| **`bytes`** | `stdgo.bytes` | **95%** | Sliding-window `Buffer`, slice `Reader`, `Split`, `Join`, `Fields`, `Compare`, `Contains`, `HasPrefix`, `HasSuffix` |
| **`strings`** | `stdgo.strings` | **95%** | High-performance `Builder`, string `Reader`, `Split`, `Join`, `Fields`, `Trim`, `TrimSpace`, `TrimPrefix`, `ReplaceAll`, `Repeat` |
| **`bufio`** | `stdgo.bufio` | **95%** | `Reader` (with large payload bypass), `Writer`, `Scanner`, `ScanLines`, `ScanWords`, `ScanBytes` |
| **`encoding/binary`** | `stdgo.encoding.binary` | **100%** | `BigEndian`, `LittleEndian`, `NativeEndian`, Protobuf Leb128 `Uvarint` & ZigZag `Varint` |
| **`encoding/base64`** | `stdgo.encoding.base64` | **100%** | RFC 4648 standard, URL-safe, raw without padding; streaming & string encode/decode |
| **`encoding/hex`** | `stdgo.encoding.hex` | **100%** | Fast Hex encode/decode, canonical 16-byte `hex.Dump` table formatter |
| **`encoding/csv`** | `stdgo.encoding.csv` | **100%** | Strict RFC 4180 CSV reader/writer; quote escapes (`""`), multiline records, custom delimiters |
| **`context`** | `stdgo.context` | **90%** | `Background()`, `TODO()`, `WithCancel()`, `WithDeadline()`, `WithValue()`, `Canceled`, `DeadlineExceeded` |
| **`net/url`** | `stdgo.net.url` | **90%** | RFC 3986 URL parser, `QueryEscape` / `QueryUnescape`, `Values` multi-value query map |
| **`net/http` (Client)** | `stdgo.net.http` | **85%** | Ergonomic `Client`, `Get`, `Post`, `PostForm`, `Head`, `Put`, `Delete`, `Patch`; HTTP forward proxy, HTTPS CONNECT tunneling, environment proxy detection (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) & Basic Auth, `ConnPool` (Keep-Alive), `CookieJar`, `CheckRedirect` with cross-origin sanitization, streaming request body (`io.Reader` & Chunked Transfer-Encoding), transparent Gzip decompression, end-to-end `Client.Timeout`, `Request.WithContext` |
| **`mime/multipart`** | `stdgo.mime.multipart` | **90%** | RFC 2046 `Writer` (form fields & file uploads), streaming token scanning `Reader`, `Part` extraction |
| **`path/filepath`** | `stdgo.path` | **85%** | Glob pattern `Match` (`*`, `?`, `[a-z]`, `\\` escapes), cross-platform path separators |
| **`archive/tar`** | `stdgo.archive.tar` | **90%** | POSIX USTAR archive `Reader` and `Writer`, 512-byte alignment, octal headers, trailer handling |
| **`archive/zip`** | `stdgo.archive.zip` | **90%** | ZIP archive `Reader` and `Writer`, tail EOCD locator, Central Directory index, CRC-32 verification |
| **`compress/gzip`** | `stdgo.compress.gzip` | **90%** | RFC 1952 Gzip `Writer` and `Reader`, header metadata, CRC-32 and `ISIZE` verification |
| **`crypto/sha256`** | `stdgo.crypto.sha256` | **100%** | RFC 6234 SHA-256, `Sum256`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/md5`** | `stdgo.crypto.md5` | **100%** | RFC 1321 MD5, `Sum`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/hmac`** | `stdgo.crypto.hmac` | **100%** | RFC 2104 Keyed-Hash Message Authentication Code; `New(h1, h2, key)`, `sha256`, `md5` shortcuts |
| **`hash`** | `stdgo.hash` | **100%** | `Hash`, `Hash32`, `Hash64` VTable interfaces conforming to Go's streaming hash model |
| **`math/rand`** | `stdgo.math.rand` | **85%** | Pseudo-random number generator (SplitMix64): `Uint64`, `Intn`, `Float64`, `Shuffle` |
| **`time`** | `stdgo.time` | **80%** | Composite unit string parser `ParseDuration` (`"2h45m"`), `Duration`, `Time`, `Sleep` |
| **`slices`** | `stdgo.slices` | **95%** | Go 1.21+ generic algorithms: `Sort`, `BinarySearch`, `Reverse`, `Compact`, `Clone`, `Equal`, `Contains`, `Index` |
| **`sync`** | `stdgo.sync` | **90%** | Atomic lock-free `WaitGroup`, atomic 3-state `Once`, `Mutex`, generic `Pool(T)` |
| **`sync/errgroup`** | `stdgo.sync.errgroup` | **95%** | Task concurrency, first-error capture, `WithContext` broadcast cancellation, `SetLimit` limiter |
| **`log/slog`** | `stdgo.log.slog` | **90%** | Go 1.21 structured logging: `Level`, `Attr`, `Handler` VTable (`TextHandler`, `JSONHandler`), `Logger.With` |
| **`regexp`** | `stdgo.regexp` | **85%** | Linear-time Pike VM / Thompson NFA bytecode execution with $O(N \times L)$ guarantee |
| **`flag`** | `stdgo.flag` | **90%** | `FlagSet`, flag pointers (`Bool`, `Int`, `String`, `Float`), `--help` generation |
| **`text/tabwriter`** | `stdgo.text.tabwriter`| **90%** | Elastic Tabstops column alignment, padding, right-align, vertical `Debug` bar separator |
| **`container/ring`** | `stdgo.container.ring`| **100%** | Bidirectional circular buffer `Ring(T)` |
| **`container/heap`** | `stdgo.container.heap`| **100%** | Min/Max binary heap `Heap(T, lessFn)` |

---

## 4. Gap Analysis: Missing Packages by Domain

### 4.1 Data Formats & Serialization
- [ ] **`encoding/json`**:
  - *Current State*: Zig has `std.json`, but lacks Go-style streaming `json.Decoder` and `json.Encoder` operating directly over `stdgo.io.Reader` and `stdgo.io.Writer`.
  - *Missing*: `json.Decoder` (streaming parse), `json.Encoder` (streaming output), `json.RawMessage`, `json.Valid`.
- [ ] **`compress/zlib` & `compress/flate`**:
  - *Current State*: Gzip is implemented; raw zlib (RFC 1950) and raw flate wrappers over `stdgo.io.Reader`/`stdgo.io.Writer` are not yet standalone exported modules.
- [ ] **`encoding/xml` & `encoding/asn1`**:
  - *Current State*: Not implemented. (Lower priority, XML usage is declining).

### 4.2 Cryptography & Security
- [ ] **`crypto/cipher` & `crypto/aes`**:
  - *Current State*: Missing symmetric encryption stream abstractions.
  - *Target*: `cipher.Block`, `cipher.Stream`, `cipher.AEAD` (GCM mode, CBC mode, CTR mode).
- [ ] **`crypto/ed25519`**:
  - *Current State*: Missing standalone Go-style API (though Zig std has underlying primitive).
  - *Target*: `GenerateKey`, `Sign`, `Verify`.
- [ ] **`crypto/rsa` & `crypto/ecdsa`**:
  - *Current State*: Not implemented.
- [ ] **`crypto/x509`**:
  - *Current State*: Basic root bundle verification in TLS; lacks full X.509 certificate parser and CSR generator.

### 4.3 Operating System & Subprocesses
- [ ] **`os/exec`**:
  - *Current State*: Not implemented in `stdgo`.
  - *Target*: `exec.Command(name, args...)`, attaching `stdin: io.Reader`, `stdout: io.Writer`, `stderr: io.Writer`, `CombinedOutput()`, `Run()`, and `Start()` with `context.Context` timeout/cancellation.
- [ ] **`os` Helpers**:
  - *Current State*: Basic file operations handled by Zig std.
  - *Target*: `os.File` implementing `stdgo.io.Reader`, `stdgo.io.Writer`, `stdgo.io.Seeker`, `stdgo.io.Closer`; environment manipulation (`os.Getenv`, `os.Setenv`).

### 4.4 Networking Primitives
- [ ] **`net` (IP/CIDR Utilities)**:
  - *Current State*: Basic IPv4/IPv6 socket dialing in `net/http`.
  - *Target*: `net.ParseCIDR`, `net.IPNet.Contains`, `net.JoinHostPort`, `net.SplitHostPort`, `net.LookupHost`.
- [ ] **`net.http` (HTTP/2)**:
  - *Current State*: HTTP/1.1 complete; HTTP/2 (ALPN framing/multiplexing) is intentionally deferred.

### 4.5 Data Structures & Algorithms
- [ ] **`container/list`**:
  - *Current State*: `container/ring` and `container/heap` are complete; doubly linked list is missing.
  - *Target*: Generic `List(T)` (`PushBack`, `PushFront`, `InsertBefore`, `InsertAfter`, `Remove`, `MoveToFront`).
- [ ] **`maps`**:
  - *Current State*: `slices` is complete; Go 1.21 generic map utilities are missing.
  - *Target*: `maps.Clone`, `maps.Copy`, `maps.Equal`, `maps.DeleteFunc`.

### 4.6 Templating & Text
- [ ] **`text/template` & `html/template`**:
  - *Current State*: Not implemented.
  - *Target*: Pipeline-based data-driven templating engine (`{{ .Field }}`, `{{ range }}`, `{{ if }}`).

---

## 5. Prioritized Implementation Roadmap

### Phase 1: High-Utility Core (P0 - Immediate Next Steps)
These packages provide the highest return on ergonomics and eliminate remaining common pain points:

1. **`container/list`**:
   - Double-linked list `List(T)` with node pooling and element iterators.
2. **`os/exec`**:
   - Subprocess execution wrapper with piped `io.Reader` (stdin) and `io.Writer` (stdout/stderr), complete with `context.Context` process-tree termination.
3. **`encoding/json` (Streaming)**:
   - Token-based streaming `Decoder` and `Encoder` plugged into `stdgo.io.Reader` and `stdgo.io.Writer` VTables.
4. **`maps` (Generic)**:
   - Go 1.21+ map utilities (`Equal`, `Clone`, `Copy`, `Keys`, `Values`).
5. **`net` (IP & CIDR Primitives)**:
   - `ParseCIDR`, `IPNet.Contains`, `SplitHostPort`, `JoinHostPort`.

### Phase 2: Security & Compression Extensions (P1)
1. **`crypto/cipher` & `crypto/aes`**:
   - Standard block cipher modes (GCM, CBC, CTR) wrapping TigerStyle-verified memory boundaries.
2. **`crypto/ed25519`**:
   - Fast, high-security Ed25519 signature generation and verification.
3. **`compress/zlib` & `compress/flate`**:
   - Standalone RFC 1950 zlib and raw deflate streaming wrappers.
4. **`net/http` Client Advanced TLS**:
   - mTLS client certificate configuration and custom verification callbacks.

### Phase 3: Specialized Ecosystem Packages (P2)
1. **`text/template`**:
   - Data-driven text templating with piped functions.
2. **`database/sql` driver abstraction**:
   - Generic database connection pool, statement caching, and transaction interfaces.
3. **`testing` (Table-Driven Helpers)**:
   - Go-style subtest organization and assertions.
4. **`net/http` HTTP/2 Transport**:
   - Multiplexed framing layer for HTTP/2 client connections.
