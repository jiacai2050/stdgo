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

## Cancellation and deadlines

The former `stdgo.context` API has been removed. Own and join tasks with
`std.Io.Future` or `std.Io.Group`; use `stdgo.io.CancelSource` and its borrowed
token only for broadcasting a signal. Keep the source at a stable address until
all token users and concurrent cancellation calls have finished.

Semaphore and rate-limiter waits, network operations, HTTP requests, and SQL
operations accept a `Deadline` (`.none` or an `.awake` absolute deadline). TCP and
in-memory connections expose `readDeadline` and `writeDeadline`; `net.pipe`
requires an injected `std.Io`. HTTP client timeouts share one budget across
redirects and response body reads; transport options also support TLS handshake,
response-header, `100-continue`, and idle-connection timeouts.

SQL operations accept an optional `Deadline`. Whether an in-flight operation
can be interrupted before completion depends on the underlying driver implementation.
SQLite checks deadlines during VM execution and pool waits, but an uninterruptible
SQLite or filesystem call may delay return. Completed writes can have side effects
even when a timeout is reported. Transaction `commit` and `rollback` also take a deadline;
`rollback(.none)` remains available for cleanup after cancellation.

Timed network operations require a concurrent, cancelable `std.Io` backend.
Cancellation waits for the underlying operation to exit, so an uncooperative backend
or request body reader can delay return beyond the deadline. A timed-out network
write may have sent a prefix. Custom round trippers
must enforce the deadline they receive. A transport with an idle-connection timeout
must remain at a stable address after its first request until it is deinitialized.
Subprocess cancellation during child wait is deferred until the child exits.
See [timeout limitations and Go comparison](docs/timeouts.md) for details.

---

## Modular Examples

Every single module in `stdgo` is accompanied by a dedicated, runnable example in the `examples/` directory:

| Example Step | Source File | Description |
| :--- | :--- | :--- |
| `zig build run` | [`examples/overview.zig`](examples/overview.zig) | Comprehensive cross-module tour |
| `zig build run-http` | [`examples/http_client.zig`](examples/http_client.zig) | HTTP client with SOCKS5/HTTP proxy, chunked upload, and gzip |
| `zig build run-slog` | [`examples/slog.zig`](examples/slog.zig) | Structured logging with `TextHandler`, `JSONHandler`, and attributes |
| `zig build run-errgroup` | [`examples/errgroup.zig`](examples/errgroup.zig) | Bounded task group with error propagation and sibling cancellation |
| `zig build run-multipart` | [`examples/multipart.zig`](examples/multipart.zig) | RFC 2046 multipart form-data writer and streaming reader |
| `zig build run-hmac` | [`examples/hmac.zig`](examples/hmac.zig) | HMAC-SHA256, HMAC-MD5 signing and constant-time verification |
| `zig build run-archive` | [`examples/archive.zig`](examples/archive.zig) | In-memory TAR and ZIP archive creation and inspection |
| `zig build run-io` | [`examples/io.zig`](examples/io.zig) | Native buffered streaming (`takeDelimiterExclusive`), `io.copy`, `LimitReader`, `TeeReader` |
| `zig build run-bufio` | [`examples/bufio.zig`](examples/bufio.zig) | `bufio.Scanner` tokenization, `scanLines`, `scanWords`, `scanRunes` |
| `zig build run-bytes-strings` | [`examples/bytes_strings.zig`](examples/bytes_strings.zig) | `bytes.Buffer`, `strings.Builder`, trimming, splitting, and join |
| `zig build run-compress` | [`examples/compress.zig`](examples/compress.zig) | `compress.gzip` (RFC 1952), `compress.zlib` (RFC 1950 Adler-32), and `compress.flate` (RFC 1951 Deflate) |
| `zig build run-container` | [`examples/container.zig`](examples/container.zig) | Doubly-linked list (`List`), Min-heap (`Heap`), circular ring buffer (`Ring`) |
| `zig build run-crypto` | [`examples/crypto.zig`](examples/crypto.zig) | One-shot and streaming SHA-256 and MD5 cryptographic digests |
| `zig build run-encoding` | [`examples/encoding.zig`](examples/encoding.zig) | RFC 4180 CSV reader/writer, Protobuf Varint, Base64, and Hex dump |
| `zig build run-base32` | [`examples/base32.zig`](examples/base32.zig) | RFC 4648 Base32 encoding, `StdEncoding`, `HexEncoding`, TOTP unpadded |
| `zig build run-exec` | [`examples/exec.zig`](examples/exec.zig) | External command execution and piped standard I/O streams |
| `zig build run-flag` | [`examples/flag.zig`](examples/flag.zig) | Command-line flag parsing (`FlagSet`), argument bindings, and defaults |
| `zig build run-json` | [`examples/json.zig`](examples/json.zig) | RFC 8259 JSON streaming `Decoder`/`Encoder`, Token iterator, `marshal`/`unmarshal` |
| `zig build run-net` | [`examples/net.zig`](examples/net.zig) | IP address parsing (IPv4/IPv6), CIDR calculations, `net.listen`, `net.Dialer`, in-memory `net.pipe()`, `lookupPort` |
| `zig build run-textproto` | [`examples/textproto.zig`](examples/textproto.zig) | Line-oriented network protocol reader/writer, MIME headers, dot-stuffing |
| `zig build run-os` | [`examples/os.zig`](examples/os.zig) | File I/O streaming, directory operations, process environment variables |
| `zig build run-path` | [`examples/path.zig`](examples/path.zig) | Glob pattern matching (`*`, `?`, `[a-z]`) and OS path separators |
| `zig build run-regexp` | [`examples/regexp.zig`](examples/regexp.zig) | Linear-time regex search, URL extraction, and pattern replacement |
| `zig build run-slices` | [`examples/slices.zig`](examples/slices.zig) | Generic slice (`sort`, `compact`) and Go 1.21 generic `maps` utilities |
| `zig build run-sync` | [`examples/sync.zig`](examples/sync.zig) | Concurrency primitives: `WaitGroup`, `Once`, `Mutex`, and `Pool(T)` |
| `zig build run-semaphore` | [`examples/semaphore.zig`](examples/semaphore.zig) | Weighted semaphore rate limiting with FIFO queue and `std.Io` sleep |
| `zig build run-tabwriter` | [`examples/tabwriter.zig`](examples/tabwriter.zig) | Elastic Tabstops column alignment for terminal tables |
| `zig build run-template` | [`examples/template.zig`](examples/template.zig) | Data-driven template engine (`Template`), pipelines, conditions, range loops |
| `zig build run-html-template` | [`examples/html_template.zig`](examples/html_template.zig) | Context-aware auto-escaping against XSS, HTML/JS/CSS/URL sanitization |
| `zig build run-sql` | [`examples/sql.zig`](examples/sql.zig) | SQL connection pool (`DB`), transactions (`Tx`), prepared statements, comptime struct scanning, and SQLite (`-Dsqlite=true`) |
| `zig build run-time` | [`examples/time.zig`](examples/time.zig) | Duration parsing (`parseDuration`), timestamp arithmetic, cooperative sleep |
| `zig build run-time-formatting` | [`examples/time_formatting.zig`](examples/time_formatting.zig) | Go layout formatting & parsing (`RFC3339`, `RFC1123`, `DateTime`), civil calendar breakdown |
| `zig build run-rate-limiter` | [`examples/rate_limiter.zig`](examples/rate_limiter.zig) | `x/time/rate` token bucket rate limiter, burst capacity, paced requests with `wait(ctx, io)` |
| `zig build run-mime` | [`examples/mime.zig`](examples/mime.zig) | MIME type parsing (`parseMediaType`), formatting (`formatMediaType`), extension lookup |
| `zig build run-mail` | [`examples/mail.zig`](examples/mail.zig) | RFC 5322 email address parsing (`Address`), `parseAddressList`, `readMessage` |
| `zig build run-url` | [`examples/url.zig`](examples/url.zig) | RFC 3986 URL parsing, query parameter mutation (`Values`), escaping |
| `zig build run-utf8` | [`examples/utf8.zig`](examples/utf8.zig) | RFC 3629 UTF-8 decoding (`decodeRune`, `decodeLastRune`), encoding, rune counting & validation |
| `zig build run-hash-checksums` | [`examples/hash_checksums.zig`](examples/hash_checksums.zig) | CRC-32 (IEEE, Castagnoli), Adler-32 (RFC 1950), FNV-1/FNV-1a (32/64-bit) & streaming `io.Writer` |
| `zig build run-singleflight` | [`examples/singleflight.zig`](examples/singleflight.zig) | `sync.SingleFlight` duplicate suppression, thundering herd prevention, and result sharing |
| `zig build run-smtp-udp-dns` | [`examples/smtp_udp_dns.zig`](examples/smtp_udp_dns.zig) | UDP datagram `PacketConn`, RFC 1035 DNS `Resolver`, and RFC 5321 SMTP `sendMail` with `plainAuth` |
| `zig build run-non-crypto-suite` | [`examples/non_crypto_suite.zig`](examples/non_crypto_suite.zig) | `unicode` classifications/folding, `expvar` JSON metrics, `compress.lzw`, `index.suffixarray`, `testing.quick` |
| `zig build run-data-media-suite` | [`examples/data_media_suite.zig`](examples/data_media_suite.zig) | `math/big` arbitrary integers, `encoding/xml` streaming decoder/encoder, `image` & `image/color` 2D canvas |
| `zig build run-debug-compress-suite` | [`examples/debug_compress_suite.zig`](examples/debug_compress_suite.zig) | `compress.bzip2` BWT streaming decompressor, `debug.elf` ELF32/ELF64 headers, sections & symbol tables |
| `zig build run-binary-formats-suite` | [`examples/binary_formats_suite.zig`](examples/binary_formats_suite.zig) | Cross-platform inspection: `debug.elf` (Linux), `debug.macho` (macOS/Fat), `debug.pe` (Windows) |
| `zig build run-dwarf-plan9-suite` | [`examples/dwarf_plan9_suite.zig`](examples/dwarf_plan9_suite.zig) | `debug.plan9obj` a.out object and symbols parser, `debug.dwarf` DWARF 2-5 DIE tree reader |
| `zig build run-core-foundations-suite` | [`examples/core_foundations_suite.zig`](examples/core_foundations_suite.zig) | `math.bits`, `testing.iotest`, `mime.quotedprintable`, `encoding.ascii85`, `hash.crc64`, `text.scanner`, `io.fs`, `image.draw`/`png` |
| `zig build run-extended-suite` | [`examples/extended_suite.zig`](examples/extended_suite.zig) | `strconv` type conversions/quoting, `unicode.utf16` surrogate pairs, `html` escaping/unescaping, `image.gif` GIF89a LZW codec |

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
