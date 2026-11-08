# stdgo

[![CI](https://github.com/jiacai2050/stdgo/actions/workflows/ci.yml/badge.svg)](https://github.com/jiacai2050/stdgo/actions/workflows/ci.yml)
[![Docs](https://github.com/jiacai2050/stdgo/actions/workflows/docs.yml/badge.svg)](https://jiacai2050.github.io/stdgo/)
[![Zig Version](https://img.shields.io/badge/zig-0.17.0-blue.svg)](https://ziglang.org/download/0.17.0/release-notes.html)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Bring Go standard library ergonomics, unified streaming abstractions (`io.Reader` / `io.Writer`), and high-utility packages to **Zig 0.17** — with zero hidden global state, explicit dependency injection, and no C dependencies.

- 📖 **API Documentation**: [https://jiacai2050.github.io/stdgo/](https://jiacai2050.github.io/stdgo/)
- 🗺️ **Roadmap & Status**: [roadmap.md](roadmap.md)

---

## Quick Start

### 1. Add Dependency

Add `stdgo` to your project using `zig fetch`:

```bash
zig fetch --save git+https://github.com/jiacai2050/stdgo.git
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    // 1. Command-line flag parsing (flag)
    var fs = stdgo.flag.FlagSet.init(gpa, "server");
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
    var re = try stdgo.regexp.compile(gpa, "https?://[^\\s]+");
    defer re.deinit();

    const sample_text = "Repository: https://github.com/jiacai2050/stdgo";
    if (re.findString(sample_text)) |matched_url| {
        std.debug.print("Matched URL: {s}\n", .{matched_url});

        // 4. URL component parsing (net.url)
        const u = try stdgo.net.url.parse(matched_url);
        std.debug.print("Scheme: {s}, Host: {s}, Path: {s}\n", .{ u.scheme, u.host, u.path });
    }

    // 5. Structured logging (log.slog)
    var log_buf = stdgo.bytes.Buffer.init(gpa);
    defer log_buf.deinit();

    var text_handler = stdgo.log.slog.TextHandler.init(log_buf.writer(), .Info);
    var logger = stdgo.log.slog.Logger.init(text_handler.handler());
    try logger.info("server initialized", &.{
        stdgo.log.slog.Attr.int("port", port),
        stdgo.log.slog.Attr.string("host", host),
    });
    std.debug.print("Log output: {s}", .{log_buf.string()});

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

## Modular Examples

Every single module in `stdgo` is accompanied by a dedicated, runnable example in the `examples/` directory:

| Example Step | Source File | Description |
| :--- | :--- | :--- |
| `zig build run` | [`examples/overview.zig`](examples/overview.zig) | Comprehensive cross-module tour |
| `zig build run-http` | [`examples/http_client.zig`](examples/http_client.zig) | HTTP Client with timeout, chunked upload, gzip & context cancellation |
| `zig build run-slog` | [`examples/slog.zig`](examples/slog.zig) | Structured logging with `TextHandler`, `JSONHandler`, and attributes |
| `zig build run-errgroup` | [`examples/errgroup.zig`](examples/errgroup.zig) | Concurrent task group with error propagation, cancellation, & rate limiting |
| `zig build run-multipart` | [`examples/multipart.zig`](examples/multipart.zig) | RFC 2046 multipart form-data writer and streaming reader |
| `zig build run-hmac` | [`examples/hmac.zig`](examples/hmac.zig) | HMAC-SHA256, HMAC-MD5 signing and constant-time verification |
| `zig build run-archive` | [`examples/archive.zig`](examples/archive.zig) | In-memory TAR and ZIP archive creation and inspection |
| `zig build run-bufio-io` | [`examples/bufio_io.zig`](examples/bufio_io.zig) | Token scanner (lines, words), `io.copy`, `LimitReader`, `TeeReader` |
| `zig build run-bytes-strings` | [`examples/bytes_strings.zig`](examples/bytes_strings.zig) | `bytes.Buffer`, `strings.Builder`, trimming, splitting, and join |
| `zig build run-compress` | [`examples/compress.zig`](examples/compress.zig) | Gzip archive header serialization, streaming compression & CRC-32 |
| `zig build run-container` | [`examples/container.zig`](examples/container.zig) | Min-heap priority queue (`Heap`) and circular ring buffer (`Ring`) |
| `zig build run-context` | [`examples/context.zig`](examples/context.zig) | Context trees, `withValue` metadata, `withCancel`, `withDeadline` |
| `zig build run-crypto` | [`examples/crypto.zig`](examples/crypto.zig) | One-shot and streaming SHA-256 and MD5 cryptographic digests |
| `zig build run-encoding` | [`examples/encoding.zig`](examples/encoding.zig) | RFC 4180 CSV reader/writer, Protobuf Varint, Base64, and Hex dump |
| `zig build run-flag` | [`examples/flag.zig`](examples/flag.zig) | Command-line flag parsing (`FlagSet`), argument bindings, and defaults |
| `zig build run-hash-math` | [`examples/hash_math.zig`](examples/hash_math.zig) | SplitMix64 PRNG (`math.rand`) and VTable `hash.Hash` streaming |
| `zig build run-path` | [`examples/path.zig`](examples/path.zig) | Glob pattern matching (`*`, `?`, `[a-z]`) and OS path separators |
| `zig build run-regexp` | [`examples/regexp.zig`](examples/regexp.zig) | Linear-time regex search, URL extraction, and pattern replacement |
| `zig build run-slices` | [`examples/slices.zig`](examples/slices.zig) | Generic slice algorithms: `sort`, `binarySearch`, `reverse`, `compact` |
| `zig build run-sync` | [`examples/sync.zig`](examples/sync.zig) | Concurrency primitives: `WaitGroup`, `Once`, `Mutex`, and `Pool(T)` |
| `zig build run-tabwriter` | [`examples/tabwriter.zig`](examples/tabwriter.zig) | Elastic Tabstops column alignment for terminal tables |
| `zig build run-time` | [`examples/time.zig`](examples/time.zig) | Duration parsing (`parseDuration`), timestamp arithmetic, cooperative sleep |
| `zig build run-url` | [`examples/url.zig`](examples/url.zig) | RFC 3986 URL parsing, query parameter mutation (`Values`), escaping |

To execute **all examples at once**:

```bash
zig build run-examples
```

---

## Building & Testing

This project targets **Zig 0.17.0** with strict memory leak detection and assertions enabled:

```bash
# Run all unit and integration tests (including ported Go official test suites)
zig build test --summary all

# Run all modular examples
zig build run-examples

# Run a specific modular example
zig build run-http
zig build run-slog
zig build run-errgroup

# Run the overview demonstration executable
zig build run

# Generate interactive web API documentation (emitted to zig-out/docs)
zig build docs
```

---

## Roadmap & Status

See [roadmap.md](roadmap.md) for the detailed implementation status, domain-by-domain coverage metrics (~60% high-utility Go standard library covered), non-goals (standalone HTTP server is implemented in [lighting](https://github.com/jiacai2050/lighting/)), and prioritized milestones.

---

## License

This project is licensed under the [MIT License](LICENSE).
