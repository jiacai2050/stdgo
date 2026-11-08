# stdgo

[![CI](https://github.com/jiacai2050/stdgo/actions/workflows/ci.yml/badge.svg)](https://github.com/jiacai2050/stdgo/actions/workflows/ci.yml)
[![Docs](https://github.com/jiacai2050/stdgo/actions/workflows/docs.yml/badge.svg)](https://jiacai2050.github.io/stdgo/)
[![Zig Version](https://img.shields.io/badge/zig-0.17.0-blue.svg)](https://ziglang.org/download/0.17.0/release-notes.html)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**stdgo** is a standard library extension for **Zig (0.17.0)**, designed to bring the **battle-tested ergonomics, stream abstractions, and high-utility packages of the Go Standard Library** into the Zig ecosystem.

It specifically addresses domains where the current Zig official standard library is **missing, incomplete, or cumbersome** (such as RFC 4180 CSV parsing, ZIP/TAR archive extraction and packaging, linear-time regular expressions via Pike VM, CLI flag parsing, elastic tabstop column alignment, high-level concurrency primitives, and duration string parsing). All packages are verified against official Go test suites.

📖 **API Documentation**: [https://jiacai2050.github.io/stdgo/](https://jiacai2050.github.io/stdgo/)

---

## Features & Package Overview

| Package (`stdgo.*`) | Go Equivalent | Key Capabilities & Highlights |
| :--- | :--- | :--- |
| **`io`** | `io` | Type-erased VTable streams: `Reader`, `Writer`, `Closer`, `Seeker`, `LimitReader`, `TeeReader`, `copy`, `readFull`, `readAtLeast`. |
| **`bytes`** | `bytes` | Mutable `Buffer` with sliding-window read recycling (TigerStyle leak-safe), slice `Reader` (implements `Reader` & `Seeker`), and byte slice utility functions. |
| **`strings`** | `strings` | High-performance `Builder`, string `Reader`, and text routines: `Split`, `Join`, `Fields`, `Trim`, `TrimSpace`, `TrimPrefix`, `TrimSuffix`, `ReplaceAll`, `Repeat`. |
| **`bufio`** | `bufio` | Buffered `Reader` and `Writer` with large-payload bypass optimization; customizable token `Scanner` with built-in `scanLines` and `scanWords`. |
| **`encoding.binary`** | `encoding/binary` | `LittleEndian`, `BigEndian`, `NativeEndian` fixed-size encoders; Protocol Buffers Leb128 `Uvarint` and ZigZag `Varint` variable-length integer encoding. |
| **`encoding.csv`** | `encoding/csv` | *Missing in Zig std*. Strict RFC 4180 CSV reader and writer; handles escaped quotes (`""`), multi-line fields, custom delimiters, and comment filtering. |
| **`encoding.base64`** | `encoding/base64` | RFC 4648 Base64: standard, URL-safe, raw without padding; streaming & string encoding/decoding. |
| **`encoding.hex`** | `encoding/hex` | Hexadecimal encoding, decoding, and canonical Go-style 16-byte `hex.Dump` table formatting. |
| **`context`** | `context` | Lifecycle cancellation tree: `background()`, `todo()`, `withCancel()`, `withDeadline()`, `withValue()`. |
| **`math.rand`** | `math/rand` | Deterministic pseudo-random number generator (SplitMix64): `uint64`, `intn`, `float64`, and `shuffle`. |
| **`net.url`** | `net/url` | RFC 3986 URL parsing; `QueryEscape` and `QueryUnescape` (`+` and `%XX` handling); `Values` multi-value query map with deterministic encoding. |
| **`net.http`** | `net/http` | *First-principles HTTP/HTTPS client without `std.http`*. Ergonomic Go-aligned `Client`, `get`, `post`, `head`, `put`, `delete`, `patch`; HTTP proxy, HTTPS CONNECT tunneling, environment proxy detection (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) & Basic Auth; Keep-Alive idle connection pool (`ConnPool`), `CookieJar`, automatic redirect tracking with `CheckRedirect` and cross-origin header sanitization, streaming request uploads (`io.Reader` & Chunked Transfer-Encoding), transparent response Gzip decompression, end-to-end `Client.Timeout`, and `context.Context` cancellation. |
| **`path.filepath`** | `path/filepath` | *Missing in Zig std*. Shell file pattern matching (`Match`) supporting `*`, `?`, `[a-z]`, `[^0-9]`, `\\` escapes, and cross-platform path separators. |
| **`archive.zip`** | `archive/zip` | *Missing in Zig std*. ZIP archive reader and writer; tail EOCD discovery, Central Directory table indexing, local header generation, and CRC-32 verification. |
| **`archive.tar`** | `archive/tar` | Complete POSIX USTAR TAR archive reader and writer with strict 512-byte block alignment, octal header serialization, and trailer EOF handling. |
| **`compress.gzip`** | `compress/gzip` | RFC 1952 Gzip format reader and writer; 10-byte header, filename metadata, CRC-32 checksum and uncompressed `ISIZE` verification. Seamlessly pipes into `tar` for `.tar.gz`. |
| **`regexp`** | `regexp` | *Deliberately omitted in Zig std*. Linear-time regular expression engine based on Thompson NFA / Pike VM bytecode execution. Guarantees $O(N \times L)$ execution time with zero exponential backtracking. |
| **`flag`** | `flag` | *Missing in Zig std*. Command-line flag parsing with `FlagSet`; pointer-binding for `bool`, `int`, `string`, `float`; supports `-flag`, `--flag`, `-flag=val`, `-flag val`; automatic `--help` generation. |
| **`text.tabwriter`** | `text/tabwriter` | *Missing in Zig std*. Column alignment filter using the Elastic Tabstops algorithm; calculates optimal column widths; supports custom padding, `Debug` vertical separators, and right alignment. |
| **`sync`** | `sync` | High-level concurrency coordination: lock-free atomic `WaitGroup`, 3-state atomic `Once`, lightweight `Mutex`, generic object `Pool(T)`, and Go-aligned `errgroup.Group` (`withContext`, task error propagation, concurrency limit). |
| **`mime.multipart`** | `mime/multipart` | *Missing in Zig std*. RFC 2046 Multipart form data `Writer` (file upload fields) and streaming `Reader` (token boundary scanning and `Part` extraction). |
| **`log.slog`** | `log/slog` | Structured logging with Go 1.21 semantics: severity `Level`, key-value `Attr`, `Handler` VTable (`TextHandler`, `JSONHandler`), and contextual `Logger`. |
| **`time`** | `time` | Duration string parser `parseDuration` supporting composite units (e.g., `"2h45m"`), `Duration.string()`, `Time`, and explicit `sleep(io, d)`. |
| **`container`** | `container` | Generic bidirectional circular list `Ring(T)` (ideal for sliding windows and round-robin scheduling); generic binary heap `Heap(T, lessFn)`. |
| **`slices`** | `slices` | Go 1.21+ generic slice algorithms: `sort`, `binarySearch`, `reverse`, `compact`, `clone`, `equal`, `contains`, `index`. |
| **`crypto` / `hash`** | `crypto` / `hash` | Stream hashing via `hash.Hash` (implements `io.Writer`, enabling `io.copy(hasher.writer(), reader, &buf)`); includes `crypto.md5`, `crypto.sha256`, and RFC 2104 `crypto.hmac`. |

---

## Quick Start

### 1. Add to `build.zig.zon`

Add `stdgo` as a dependency in your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .dependencies = .{
        .stdgo = .{
            .url = "git+https://github.com/jiacai2050/stdgo.git#main",
            // Run `zig build` to compute the hash automatically
        },
    },
    .paths = .{""},
}
```

In your `build.zig`:

```zig
const stdgo = b.dependency("stdgo", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("stdgo", stdgo.module("stdgo"));
```

---

### 2. Code Example

```zig
const std = @import("std");
const stdgo = @import("stdgo");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Command-line flag parsing (flag)
    var fs = stdgo.flag.FlagSet.init(allocator, "server");
    defer fs.deinit();

    var port: i64 = 8080;
    var host: []const u8 = "127.0.0.1";
    try fs.intVar(&port, "port", 8080, "listen port");
    try fs.stringVar(&host, "host", "127.0.0.1", "bind address");

    const argv = [_][]const u8{ "--port=9090", "-host", "0.0.0.0" };
    try fs.parse(&argv);

    // 2. Parse human-friendly duration strings (time.Duration)
    const timeout = try stdgo.time.parseDuration("1h30m");
    std.debug.print("Timeout in seconds: {d}s\n", .{@as(i64, @intFromFloat(timeout.seconds()))});

    // 3. Linear-time regular expression search (regexp)
    var re = try stdgo.regexp.compile(allocator, "https?://[^\\s]+");
    defer re.deinit();

    const sample_text = "Repository: https://github.com/jiacai2050/stdgo";
    if (re.findString(sample_text)) |matched_url| {
        std.debug.print("Matched URL: {s}\n", .{matched_url});

        // 4. URL component parsing (net.url)
        const u = try stdgo.net.url.parse(matched_url);
        std.debug.print("Scheme: {s}, Host: {s}, Path: {s}\n", .{ u.scheme, u.host, u.path });
    }

    // 5. Ergonomic HTTP/HTTPS Client (net.http)
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resp = try stdgo.net.http.get(allocator, threaded.io(), "https://edgebin.liujiacai.net/get");
    defer resp.close();
    const body = try resp.readAllAlloc(64 * 1024);
    defer allocator.free(body);
    std.debug.print("HTTP Status: {d}, Body bytes: {d}\n", .{ resp.status_code, body.len });

    // 6. Concurrency coordination (sync.WaitGroup)
    var wg = stdgo.sync.WaitGroup.init();
    const Worker = struct {
        fn run(group: *stdgo.sync.WaitGroup) void {
            defer group.done();
            // Perform background work...
        }
    };
    wg.add(2);
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&wg});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&wg});
    wg.wait();
    t1.join();
    t2.join();
}
```

---

## Building & Testing

This project targets **Zig 0.17.0** with strict memory leak detection and assertions enabled:

```bash
# Run all unit and integration tests (including ported Go official test suites)
zig build test --summary all

# Run all modular examples
zig build run-examples

# Run a specific modular example (e.g. http, slog, errgroup, multipart, etc.)
zig build run-http
zig build run-slog
zig build run-archive
zig build run-context
zig build run-encoding

# Run the overview demonstration executable
zig build run

# Generate interactive web API documentation (emitted to zig-out/docs)
zig build docs
```

---

## License

This project is licensed under the [MIT License](LICENSE).
