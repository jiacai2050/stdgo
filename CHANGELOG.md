# Changelog

All notable changes to `stdgo` will be documented in this file.

## [0.1.0] - 2026-11-28

Initial release targeting **Zig 0.17.0**.

### Highlights
- **Explicit Dependency Injection & Zero Hidden Global State**: Every allocating or I/O-performing API takes `std.mem.Allocator` and `std.Io` explicitly; built on native Zig 0.17 `std.Io.Reader` / `std.Io.Writer` streams and `std.Io.Timeout` / `Deadline` budgets.
- **Networking & HTTP Client (`net`, `net.http`, `net.smtp`, `net.dns`, `net.url`, `net.mail`, `net.textproto`, `net.netip`)**:
  - Full HTTP/1.1 client with connection pooling, keep-alive, chunked transfer, gzip decompression, redirects, cookie jar, HTTP/HTTPS/SOCKS5 proxy support, and TLS certificate verification enabled by default.
  - Note: HTTP server is an explicit non-goal (see [lighting](https://github.com/jiacai2050/lighting/)).
- **Database (`database.sql`, `database.sql.sqlite`)**:
  - Connection pooling (`DB`), exclusive connections (`Conn` with `raw()`), transactions (`Tx`), prepared statements (`Stmt`), strict case-sensitive struct scanning (`scanStruct` / `nextStruct` and `Owned(T)` variants), and optional SQLite driver (`-Dsqlite=true`).
- **Concurrency, IO, OS & Time (`sync`, `io`, `os`, `time`, `bufio`, `log.slog`, `expvar`, `flag`, `testing`)**:
  - `WaitGroup`, `Once`, `Pool`, `Weighted` semaphore, `singleflight.Group`, `errgroup.Group`, `CancelSource`, `Deadline`, `rate.Limiter`, Go-layout `time.Time` & `Duration`, structured `slog` logging, `os.File` & concurrent-pumping `os.exec`.
- **Data Formats, Compression, Crypto & Media (`encoding`, `archive`, `compress`, `crypto`, `hash`, `mime`, `image`, `debug`)**:
  - `json`, `xml`, `csv`, `base32`, `base64`, `ascii85`, `hex`, `binary`; `tar`, `zip`; `flate`, `gzip`, `zlib`, `bzip2`, `lzw`; `hmac` (with constant-time `equal`), `sha256`, `md5`, `crc32`, `crc64`, `adler32`, `fnv`; `multipart`, `mediatype`, `quotedprintable`; `png`, `gif`; `elf`, `macho`, `pe`, `dwarf`, `plan9obj`.
- **Text, Templates & Core Utilities (`text`, `html`, `regexp`, `strings`, `bytes`, `strconv`, `unicode`, `path`, `math`, `container`, `slices`, `maps`, `index`)**:
  - Context-aware XSS-escaping `html.template`, `text.template`, linear-time NFA `regexp`, `bytes.Buffer`, `strconv`, `math.big`, `container.{heap,list,ring}`, `path.match`, `suffixarray`.
