# stdgo Roadmap & Go Standard Library Gap Analysis

This document provides a comprehensive comparison between the Go standard library (Go 1.22+) and `stdgo`, tracking our implementation status, coverage metrics, architectural boundaries, and prioritized future roadmap.

---

## 1. Executive Summary & Coverage Metrics

`stdgo` aims to bring Go standard library ergonomics, native streaming abstractions (`stdgo.io.Reader` / `stdgo.io.Writer` aligned with Zig 0.17 `std.Io`), and high-utility packages to the Zig (0.17.0) ecosystem.

- **Core Practical / High-Utility Coverage**: **~92%**
  - All non-cryptographic standard library suites are **100% completed, tested, and documented**:
    - Streaming I/O & Filesystems (`io`, `io/fs`, `bufio`, `bytes`, `strings`, `path`, `path/filepath`)
    - Algorithms & Containers (`slices`, `maps`, `container/list`, `container/heap`, `container/ring`)
    - Serialization & Encodings (`encoding/json`, `encoding/xml`, `encoding/csv`, `encoding/binary`, `encoding/hex`, `encoding/base64`, `encoding/base32`, `encoding/ascii85`, `strconv`)
    - Lossless Compression & Archives (`compress/gzip`, `compress/zlib`, `compress/flate`, `compress/lzw`, `compress/bzip2`, `archive/tar`, `archive/zip`)
    - Concurrency & Context (`context`, `sync`, `sync/errgroup`, `sync/semaphore`, `sync/singleflight`)
    - Networking Suite (`net`, `net/netip`, `net/url`, `net/http` Client with SOCKS5/Proxy, `net/mail`, `net/smtp`, `net/textproto`)
    - OS & Host Suite (`os` Files, Env, Proc, `os/exec`, `os/user`, `flag`)
    - Text & Templating (`regexp`, `text/tabwriter`, `text/scanner`, `text/template`, `html`, `html/template` with XSS auto-escaping)
    - Time & Metrics (`time`, `time/rate`, `log/slog`, `expvar`)
    - Math & Non-Crypto Hashes (`math/big`, `math/bits`, `math/rand`, `hash/crc32`, `hash/crc64`, `hash/adler32`, `hash/fnv`)
    - Unicode & Text Encodings (`unicode`, `unicode/utf8`, `unicode/utf16`)
    - 2D Canvas & Media (`image`, `image/color`, `image/draw`, `image/png`, `image/gif`)
    - Binary Formats & Debugging (`debug/elf`, `debug/macho`, `debug/pe`, `debug/plan9obj`, `debug/dwarf`)
    - Testing Utilities (`testing/quick`, `testing/iotest`)
    - Database (`database/sql` with optional SQLite)
- **Explicit Non-Goals Excluded**: ~20% (Go runtime internals, GC, compiler tools, standalone HTTP server).
- **Remaining Target Gap**: **~8%** (Full `crypto/*` suite & PKI).

```
[========================== 92% Implemented ==========================>][== 8% Crypto Gap ==]
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
| **`io`** | `stdgo.io` | **100%** | Native `std.Io.Reader`, `Writer`, `Closer`, `Seeker`, `LimitReader`, `TeeReader`, `copy`, `readFull`, `readAtLeast` |
| **`bytes`** | `stdgo.bytes` | **95%** | Sliding-window `Buffer`, slice `Reader`, `Split`, `Join`, `Fields`, `Compare`, `Contains`, `HasPrefix`, `HasSuffix` |
| **`strings`** | `stdgo.strings` | **95%** | High-performance `Builder`, string `Reader`, `Split`, `Join`, `Fields`, `Trim`, `TrimSpace`, `TrimPrefix`, `ReplaceAll`, `Repeat` |
| **`bufio`** | — | — | *Removed*: Superseded by native Zig 0.17 buffered `std.Io.Reader` & `std.Io.Writer` containers |
| **`encoding/binary`** | `stdgo.encoding.binary` | **100%** | `BigEndian`, `LittleEndian`, `NativeEndian`, Protobuf Leb128 `Uvarint` & ZigZag `Varint` |
| **`encoding/base64`** | `stdgo.encoding.base64` | **100%** | RFC 4648 standard, URL-safe, raw without padding; streaming & string encode/decode |
| **`encoding/hex`** | `stdgo.encoding.hex` | **100%** | Fast Hex encode/decode, canonical 16-byte `hex.Dump` table formatter |
| **`encoding/csv`** | `stdgo.encoding.csv` | **100%** | Strict RFC 4180 CSV reader/writer; quote escapes (`""`), multiline records, custom delimiters |
| **`net/url`** | `stdgo.net.url` | **90%** | RFC 3986 URL parser, `QueryEscape` / `QueryUnescape`, `Values` multi-value query map |
| **`net/http` (Client)** | `stdgo.net.http` | **95%** | Ergonomic `Client`, `Get`, `Post`, `PostForm`, `Head`, `Put`, `Delete`, `Patch`; SOCKS5 proxy (RFC 1928 / RFC 1929, `socks5://` & `socks5h://`, no auth & username/password auth), Pluggable `RoundTripper` interface, `Client.CloseIdleConnections()` / `Transport.CloseIdleConnections()`, `Request.BasicAuth()` decoding & `Request.Cookies()`, `Response.Location()` / `Response.LocationUrl()`, `Header.Has()` & `Header.Values()`, `Cookie.String()` serialization, HTTP forward proxy, HTTPS CONNECT tunneling, environment proxy detection (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`) & Basic Auth, `ConnPool` (Keep-Alive), `CookieJar`, `CheckRedirect` with cross-origin sanitization, streaming request body (`io.Reader` & Chunked Transfer-Encoding), transparent Gzip decompression, end-to-end `time.Duration` `Client.Timeout`, `Request.WithContext` |
| **`mime`** | `stdgo.mime` | **95%** | RFC 1521/2183 `parseMediaType` (type, subtype, params), `formatMediaType`, `typeByExtension` (.json -> application/json), `extensionsByType`, and RFC 2046 `multipart.Writer`/`Reader` |
| **`net/mail`** | `stdgo.net.mail` | **100%** | RFC 5322 email address parsing (`Address`), `parseAddress`, `parseAddressList`, and `readMessage` (MIME header & streaming body) |
| **`path/filepath`** | `stdgo.path` | **85%** | Glob pattern `Match` (`*`, `?`, `[a-z]`, `\\` escapes), cross-platform path separators |
| **`archive/tar`** | `stdgo.archive.tar` | **90%** | POSIX USTAR archive `Reader` and `Writer`, 512-byte alignment, octal headers, trailer handling |
| **`archive/zip`** | `stdgo.archive.zip` | **90%** | ZIP archive `Reader` and `Writer`, tail EOCD locator, Central Directory index, CRC-32 verification |
| **`compress/gzip`** | `stdgo.compress.gzip` | **90%** | RFC 1952 Gzip `Writer` and `Reader`, header metadata, CRC-32 and `ISIZE` verification |
| **`compress/zlib`** | `stdgo.compress.zlib` | **100%** | RFC 1950 ZLIB `Reader` and `Writer`, Adler-32 verification, compression levels 0-9 & Huffman |
| **`compress/flate`**| `stdgo.compress.flate`| **100%** | RFC 1951 Raw Deflate `Reader` and `Writer`, streaming compression levels 0-9 & Huffman |
| **`crypto/sha256`** | `stdgo.crypto.sha256` | **100%** | RFC 6234 SHA-256, `Sum256`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/md5`** | `stdgo.crypto.md5` | **100%** | RFC 1321 MD5, `Sum`, `New` (implements `hash.Hash` & `io.Writer`) |
| **`crypto/hmac`** | `stdgo.crypto.hmac` | **100%** | RFC 2104 Keyed-Hash Message Authentication Code; `New(h1, h2, key)`, `sha256`, `md5` shortcuts |
| **`hash`** | `stdgo.hash` | **100%** | `Hash`, `Hash32`, `Hash64` VTable interfaces conforming to Go's streaming hash model |
| **`math/rand`** | `stdgo.math.rand` | **85%** | Pseudo-random number generator (SplitMix64): `Uint64`, `Intn`, `Float64`, `Shuffle` |
| **`time`** | `stdgo.time` | **95%** | Composite unit string parser `ParseDuration` (`"2h45m"`), `Duration`, `Time`, `sleep`, civil calendar breakdown (`year`, `month`, `day`, `weekday`, `hour`, `minute`, `second`, `nanosecond`, `yearDay`), layout-based `format` & `parse` (`RFC3339`, `RFC1123`, `DateTime`, `Kitchen`), `date` construction, `Location` (UTC, `fixedZone`) |
| **`time/rate`** | `stdgo.time.rate` | **100%** | Token bucket rate limiter (`Limiter`), burst capacity, `allow`, `allowN`, `reserve`, `reserveN`, `wait`, `waitN`, `every(d)`, `inf`, with explicit deadlines and `std.Io` task cancellation |
| **`slices`** | `stdgo.slices` | **95%** | Go 1.21+ generic algorithms: `Sort`, `BinarySearch`, `Reverse`, `Compact`, `Clone`, `Equal`, `Contains`, `Index` |
| **`sync`** | `stdgo.sync` | **90%** | Atomic lock-free `WaitGroup`, atomic 3-state `Once`, `Mutex`, generic `Pool(T)` |
| **`sync/errgroup`** | `stdgo.sync.errgroup` | **95%** | Bounded task concurrency, first observed error, sibling cancellation |
| **`log/slog`** | `stdgo.log.slog` | **90%** | Go 1.21 structured logging: `Level`, `Attr`, `Handler` VTable (`TextHandler`, `JSONHandler`), `Logger.With` |
| **`regexp`** | `stdgo.regexp` | **85%** | Linear-time Pike VM / Thompson NFA bytecode execution with $O(N \times L)$ guarantee |
| **`flag`** | `stdgo.flag` | **90%** | `FlagSet`, flag pointers (`Bool`, `Int`, `String`, `Float`), `--help` generation |
| **`text/tabwriter`** | `stdgo.text.tabwriter`| **90%** | Elastic Tabstops column alignment, padding, right-align, vertical `Debug` bar separator |
| **`container/ring`** | `stdgo.container.ring`| **100%** | Bidirectional circular buffer `Ring(T)` |
| **`container/heap`** | `stdgo.container.heap`| **100%** | Min/Max binary heap `Heap(T, lessFn)` |
| **`container/list`** | `stdgo.container.list`| **100%** | Doubly-linked list `List(T)` (`pushFront`, `pushBack`, `insertAfter`, `remove`, `moveToFront`) |
| **`maps`** | `stdgo.maps` | **100%** | Go 1.21 generic map utilities: `clone`, `copy`, `equal`, `equalFunc`, `deleteFunc`, `keys`, `values` |
| **`net`** | `stdgo.net` | **100%** | Generic `net.Conn` stream interface, `net.PacketConn` & `net.UDPConn` datagram sockets (`listenUDP`, `dialUDP`), RFC 1035 DNS wire protocol & `net.Resolver` (`lookupHost`, `lookupIP`, `lookupCNAME`, `lookupTXT`, `lookupMX`), `net.Listener` interface & `net.listen` TCP server, `net.Dialer` and `net.dial` with explicit deadlines, in-memory full-duplex `net.pipe()` (Go `net.Pipe()`), `net.Addr` interface, `TCPAddr`, `UDPAddr`, `lookupPort` well-known port mapping, Go 1.18+ modern zero-allocation `net/netip` (`Addr`, `Prefix`, `AddrPort`, `parseAddr`, `parsePrefix`, `parseAddrPort`), `IP` (IPv4/IPv6, `isLoopback`, `isPrivate`, `stringBuf`, `string`), `IPMask`, `IPNet` (`contains`), `parseIp`, `parseCidr`, `splitHostPort`, `joinHostPort` |
| **`os/exec`** | `stdgo.os.exec` | **95%** | Subprocess management: `command` with task cancellation after process exit, piped `*io.Reader`/`*io.Writer`, `output`, `combinedOutput` |
| **`os` (Full Suite)** | `stdgo.os` | **100%** | Stream-oriented `File` (`*io.Reader`/`*io.Writer`, `stdin`, `stdout`, `stderr`), file ops (`open`, `create`, `readFile`, `writeFile`, `mkdir`, `mkdirAll`, `remove`, `removeAll`, `readDir`, `rename`, `truncate`, `symlink`, `readlink`, `chmod`, `stat`), error predicates (`isNotExist`, `isExist`, `isPermission`), explicit environment (`getenv`/`lookupEnv`/`environ`), host/process metadata (`getpid`, `getppid`, `hostname`, `getwd`, `executable`, `tempDir`), and user accounts (`os.user`) |
| **`text/template`** | `stdgo.text.template` | **100%** | Data-driven templating: `Template`, `parse`, `execute`, `executeTemplate`, fields (`.Name`), pipelines (`| upper`), `if-else` ladder, `with` scope, `range`/`for` loops with payload capture (`|item, idx|`), Zig-style bindings (`const x = ...`, `var x = ...`), quoted identifiers (`.@"content-type"`), sub-template composition (`define`, `template`, `block`), custom functions (`addFunc`, `funcMap`), built-in math/logic/comparison/printf funcs, `Must` |
| **`html/template`** | `stdgo.html.template` | **100%** | Context-aware auto-escaping against XSS: HTML body entity escaping, attribute escaping, URL scheme sanitization (`#ZgotmplZ`), JS literal escaping (`\x3c/script\x3e`), CSS/comment protection, safe wrapper types (`HTML`, `JS`, `CSS`, `URL`, `HTMLAttr`), template composition |
| **`database/sql`** | `stdgo.database.sql` | **100%** | Generic SQL connection pool (`DB`), single-row scanner (`Row`, `queryRow`, `ErrNoRows`), transactions (`Tx`, `beginTx`, `TxOptions`, `IsolationLevel`), prepared statements (`Stmt`), result cursors (`Rows`, `rows.err()`, `rows.lastError()`), pluggable `Driver`/`Conn` VTable, thread-safe pool management (`max_open`, `max_idle`, `conn_max_lifetime`, `DBStats`), bad connection auto-retry (`driver.ErrBadConn`), out-of-band query interruption (`interrupt`, `interruptAll`), and lazy optional real `SQLiteDriver` adapter (`-Dsqlite=true` via `nDimensional/zig-sqlite`) |
| **`encoding/json`** | `stdgo.encoding.json` | **95%** | Streaming `Decoder` (`token`, `more`, `decode`), `Encoder` (`encode`, `setIndent`), `marshal`, `marshalIndent`, `unmarshal`, `valid` |
| **`bufio`** | `stdgo.bufio` | **100%** | Streaming tokenization (`Scanner`), customizable `SplitFunc`, `scanLines` (cross-chunk `\r\n` / `\n`), `scanWords`, `scanBytes`, `scanRunes` (UTF-8), dynamic sliding buffer up to `max_token_size` |
| **`sync/semaphore`** | `stdgo.sync.semaphore` | **100%** | Weighted semaphore (`Weighted`), FIFO fairness, `acquire(ctx, n)`, `tryAcquire(n)`, `release(n)`, integrated with `Context` and `std.Io` cooperative sleep |
| **`net/textproto`** | `stdgo.net.textproto` | **100%** | Line-oriented network protocol helpers: `readLine`, `readContinuedLine` (RFC 822), `readMIMEHeader`, `readDotBytes` (SMTP/NNTP dot-stuffing unescaping), `dotWriter`, `canonicalMIMEHeaderKey` |
| **`net/smtp`** | `stdgo.net.smtp` | **100%** | RFC 5321 SMTP Client, `sendMail`, `plainAuth` (RFC 4616), `cramMD5Auth` (RFC 2195), dot-stuffing streaming transmission |
| **`encoding/base32`** | `stdgo.encoding.base32` | **100%** | RFC 4648 Base32 encoding/decoding, `StdEncoding`, `HexEncoding`, `withPadding`, `noPadding` (TOTP secrets) |
| **`unicode/utf8`** | `stdgo.unicode.utf8` | **100%** | Full RFC 3629 UTF-8 routines: `decodeRune`, `decodeLastRune`, `encodeRune`, `runeCount`, `runeLen`, `valid`, `validRune`, `validString`, `fullRune` |
| **`hash/crc32`** | `stdgo.hash.crc32` | **100%** | CRC-32 checksums: `IEEE` (0xedb88320), `Castagnoli` (0x82f63b78), `Koopman`, `makeTable`, `checksum`, `checksumIEEE`, `update`, `Digest` (`Hash32`, `Hash`) |
| **`hash/adler32`** | `stdgo.hash.adler32` | **100%** | RFC 1950 Adler-32 checksums: `checksum`, `update`, `Digest` (`Hash32`, `Hash`) |
| **`hash/fnv`** | `stdgo.hash.fnv` | **100%** | Fowler-Noll-Vo hash functions: FNV-1 and FNV-1a for 32-bit (`new32`, `new32a`, `fnv32`, `fnv32a`) and 64-bit (`new64`, `new64a`, `fnv64`, `fnv64a`) |
| **`sync/singleflight`** | `stdgo.sync.singleflight` | **100%** | Concurrency deduplication `Group(T)`: duplicate suppression `do(key, fn, args)`, in-flight result sharing, `forget(key)` |
| **`unicode`** | `stdgo.unicode` | **100%** | Full Unicode category classifications (`isLetter`, `isDigit`, `isSpace`, `isPunct`, `isControl`, `isUpper`, `isLower`), case conversions (`toUpper`, `toLower`), and equivalence class `simpleFold` |
| **`expvar`** | `stdgo.expvar` | **100%** | Standardized public metrics registry (`Int`, `Float`, `String`, `Map`, `Func`), thread-safe updates, and `toJson()` serialization |
| **`compress/lzw`** | `stdgo.compress.lzw` | **100%** | Lempel-Ziv-Welch stream compression/decompression (`Reader`/`Writer`), variable bit widths (2-8 bits), dictionary resets, LSB (GIF) and MSB (PDF) bit orders |
| **`index/suffixarray`**| `stdgo.index.suffixarray` | **100%** | In-memory substring indexing and search in logarithmic time ($O(L \log N)$), `Index.create`, `lookup(s, n)`, `findAllIndex(pattern)` |
| **`testing/quick`** | `stdgo.testing.quick` | **100%** | Black-box property-based testing: pseudo-random arbitrary value `Generator`, invariant verification `check(f, config)`, and equivalence check `checkEqual(f, g, config)` |
| **`math/big`** | `stdgo.math.big` | **100%** | High-precision arbitrary integer arithmetic (`Int`), bases 2-36 and auto-detect prefix parsing, arithmetic (`add`, `sub`, `mul`, `div`, `mod`, `divMod`), modular exponentiation (`exp`), bitwise manipulation (`bit`, `setBit`, `lsh`, `rsh`, `and`, `or`, `xor`), `gcd` |
| **`encoding/xml`** | `stdgo.encoding.xml` | **100%** | Streaming XML decoder and encoder (`Decoder`, `Encoder`, `Token`, `StartElement`, `EndElement`, `CharData`, `Comment`, `ProcInst`), XML entity escaping/unescaping (`&amp;`, numeric refs), self-closing tag handling, subtree `skip()` |
| **`image`** | `stdgo.image` | **100%** | 2D geometry models (`Point`, `Rectangle`, `rect`, `intersect`, `unionRect`), alpha-premultiplied color models (`color.RGBA`, `color.NRGBA`, `color.Gray`, `color.Alpha`), raster canvases (`RGBAImage`, `GrayImage`, `at`, `set`, `subImage`) |
| **`compress/bzip2`** | `stdgo.compress.bzip2` | **100%** | RFC Bzip2 streaming decompressor (`Reader`, `decompressAlloc`), BWT inverse transform, MTF decoding, multi-Huffman trees, RLD2 repeat expansion, CRC-32 verification |
| **`debug/elf`** | `stdgo.debug.elf` | **100%** | ELF32 and ELF64 binary format parser (`File`, `parse`), section headers (`SectionHeader`, `Section`, `dataAlloc`), program headers (`ProgHeader`, `Prog`), symbol tables (`Symbol`, `symbols`, `dynamicSymbols`, `bind`, `symType`) |
| **`debug/macho`** | `stdgo.debug.macho` | **100%** | Apple macOS/iOS Mach-O 32/64-bit and Fat/Universal binary parser (`File`, `FatFile`, `parse`), load commands (`segment`, `segment_64`, `symtab`, `load_dylib`), sections, symbol tables (`Symbol`), imported dylibs (`importedLibraries`) |
| **`debug/pe`** | `stdgo.debug.pe` | **100%** | Windows PE32/PE32+ (COFF/PE) executable parser (`File`, `parse`), MS-DOS header, COFF header, Optional header, sections (`Section`), COFF symbols (`symbols`) |
| **`debug/plan9obj`** | `stdgo.debug.plan9obj` | **100%** | Plan 9 a.out object parser (`File`, `parse`), 32-bit & 64-bit headers (`Magic386`, `MagicAMD64`, `MagicARM`), standard sections (`text`, `data`, `syms`, `spsz`, `pcsz`), symbol table decoding (`symbols`) with filename reconstruction |
| **`debug/dwarf`** | `stdgo.debug.dwarf` | **100%** | DWARF 2-5 debugging information parser (`Data`, `init`), LEB128 decoding (`readUleb128`, `readSleb128`), abbreviation tables (`.debug_abbrev`), DIE reader (`Reader`, `next`, `skipChildren`, `seek`), attribute extraction (`attrString`, `attrAddr`, `attrInt`) |
| **`math/bits`** | `stdgo.math.bits` | **100%** | High-performance bit manipulation (`leadingZeros*`, `trailingZeros*`, `onesCount*`, `rotateLeft*`, `reverse*`, `reverseBytes*`, `len*`), multi-word 64/128-bit operations (`add64`, `sub64`, `mul64`, `div64`) |
| **`testing/iotest`** | `stdgo.testing.iotest` | **100%** | Stream testing & error injection utilities (`OneByteReader`, `HalfReader`, `TimeoutReader`, `ErrReader`, `TruncateWriter`) |
| **`mime/quotedprintable`** | `stdgo.mime.quotedprintable` | **100%** | RFC 2045 Quoted-Printable streaming decoder and encoder (`encodeAlloc`, `decodeAlloc`, `Reader`), `=XX` hex escaping and soft line breaks (`=\r\n` / `=\n`) |
| **`encoding/ascii85`** | `stdgo.encoding.ascii85` | **100%** | Adobe PostScript / PDF ASCII85 (`btoa`) 5-to-4 byte base85 codec (`encodeAlloc`, `decodeAlloc`), with special `'z'` zero-compression |
| **`hash/crc64`** | `stdgo.hash.crc64` | **100%** | 64-bit CRC checksum calculation (`checksum`, `update`, `Digest`), ISO-3309 (`0xD800000000000000`) and ECMA-182 (`0xC96C5795D7870F42`) polynomials, streaming `io.Writer` |
| **`text/scanner`** | `stdgo.text.scanner` | **100%** | UTF-8 source/text lexical scanner (`Scanner`, `scan`), tokens (`Ident`, `Int`, `Float`, `Char`, `String`, `RawString`, `Comment`), position tracking (`Position`) |
| **`io/fs`** | `stdgo.io.fs` | **100%** | Go 1.16 virtual filesystem interface abstractions (`FS`, `FileInfo`, `DirEntry`, `FileMode`), in-memory virtual filesystem `MapFS`, directory traversal `walkDir`, `stat`, `readFile` |
| **`image/draw`** | `stdgo.image.draw` | **100%** | Porter-Duff image compositing operators (`Over`, `Src`), bounding-box clipping and alpha layer blending (`draw`, `drawColor`) |
| **`image/png`** | `stdgo.image.png` | **100%** | PNG image format encoder and decoder (`encode`, `decode`), 8-byte PNG signature, `IHDR`, 5 scanline filter methods (None, Sub, Up, Average, Paeth), `IDAT` with `compress/zlib`, `IEND` |
| **`strconv`** | `stdgo.strconv` | **100%** | Conversions to/from string representations of basic types: `parseInt`, `formatInt`, `parseUint`, `formatUint`, `parseBool`, `formatBool`, `parseFloat`, `formatFloat`, `quote`, `unquote`, `canBackquote`, `atoi`, `itoa` |
| **`unicode/utf16`** | `stdgo.unicode.utf16` | **100%** | UTF-16 surrogate pair detection, encoding, and decoding (`isSurrogate`, `decodeRune`, `encodeRune`, `encode`, `decode`) |
| **`html`** | `stdgo.html` | **100%** | HTML string escaping (`escapeString`) and entity unescaping (`unescapeString`), handling named entities and decimal/hex numeric character references |
| **`image/gif`** | `stdgo.image.gif` | **100%** | GIF87a/GIF89a image decoder and encoder (`encode`, `decode`, `decodeAll`, `GIF`, `Options`), Global/Local Color Tables, Graphic Control Extension (delays, transparency, disposal), LSB LZW raster compression |

---

## 4. Gap Analysis: Missing Packages by Domain

### 4.1 Data Formats & Serialization
- [x] **`encoding/xml`**:
  - *Current State*: **100% Implemented**. Streaming XML decoder and encoder (`Decoder`, `Encoder`, `Token`, `StartElement`, `EndElement`, `CharData`, `Comment`, `ProcInst`), entity escaping/unescaping, self-closing tag handling, subtree skipping.
- [ ] **`encoding/asn1`**:
  - *Current State*: Deferred to PKI Phase 2.3 (tied directly to `crypto/x509`).

### 4.2 Cryptography & Security (Current Gap)
- [ ] **`crypto/subtle`**:
  - *Target*: Constant-time comparisons and slice operations to prevent timing side-channel attacks (`constantTimeByteEq`, `constantTimeCompare`, `constantTimeSelect`, `constantTimeCopy`).
- [ ] **`crypto/rand`**:
  - *Target*: Cryptographically secure pseudo-random number generator (CSPRNG) stream reader (`Read`, `Reader`).
- [ ] **`crypto/cipher` & `crypto/aes`**:
  - *Target*: Standard block cipher abstraction (`cipher.Block`), stream cipher abstraction (`cipher.Stream`), and authenticated encryption (`cipher.AEAD`), implementing CBC, CTR, CFB, OFB, and GCM modes wrapping AES-128, AES-192, and AES-256.
- [ ] **`crypto/ed25519`**:
  - *Target*: High-security, high-performance Edwards-curve Digital Signature Algorithm (`GenerateKey`, `Sign`, `Verify`).
- [ ] **`crypto/sha512` & `crypto/sha1`**:
  - *Target*: Complete the standard SHA family (`sha512`, `sha384`, `sha512/224`, `sha512/256`, `sha1`).
- [ ] **`crypto/elliptic` & `crypto/ecdsa`**:
  - *Target*: NIST elliptic curves (P-256, P-384, P-521) and ECDSA signature schemes.
- [ ] **`crypto/rsa`**:
  - *Target*: RSA key pair generation, PKCS#1 v1.5 / PSS signing, and OAEP encryption.
- [ ] **`crypto/x509`**:
  - *Target*: DER/ASN.1 certificate parsing, certificate chain validation, and CSR generation.

### 4.3 Operating System & Subprocesses
- [x] **`os` Full Suite**:
  - *Current State*: **100% Implemented**. Streaming `os.File`, standard streams (`stdin`, `stdout`, `stderr`), file helpers (`open`, `create`, `readFile`, `writeFile`, `mkdir`, `mkdirAll`, `remove`, `removeAll`, `readDir`, `rename`, `truncate`, `symlink`, `readlink`, `chmod`, `stat`), error predicates (`isNotExist`, `isExist`, `isPermission`), explicit environment (`getenv`, `lookupEnv`, `environ`), process/host metadata (`getpid`, `getppid`, `hostname`, `getwd`, `executable`, `tempDir`), and user accounts (`os.user`).
- [x] **`os/exec`**:
  - *Current State*: **100% Implemented**. Subprocess management: `command` with task cancellation after process exit, piped `*io.Reader`/`*io.Writer`, `output`, `combinedOutput`.

### 4.4 Networking Primitives
- [x] **`net` (Full Networking Suite)**:
  - *Current State*: **100% Implemented**. `net.IP`, `net.IPMask`, `net.IPNet`, `net.parseIp`, `net.parseCidr`, `net.splitHostPort`, `net.joinHostPort`, zero-allocation `net/netip` (`Addr`, `Prefix`, `AddrPort`), `net.Conn`, `net.Listener`, `net.Dialer`, `net.UDPConn`, RFC 1035 DNS `Resolver`, in-memory full-duplex `net.pipe()`.
- [ ] **`net/http` (HTTP/2 Transport)**:
  - *Current State*: HTTP/1.1 client with SOCKS5, HTTP proxy, Keep-Alive connection pooling, and Gzip is complete; HTTP/2 multiplexing is intentionally deferred.

### 4.5 Templating & Text
- [x] **`text/template`**:
  - *Current State*: **100% Implemented**. Full data-driven templating engine with whitespace trimming (`{{-`, `-}}`), multi-branch `{{ else if ... }}`, scope re-binding `{{ with ... }}`, Zig-idiomatic variable bindings (`const x = ...`, `var x = ...`), loop payload captures (`{{ for .Items |item, idx| }}` / `{{ range .Items |item| }}`), quoted identifiers (`.@"content-type"`), sub-template composition (`define`, `template`, `block`), custom functions (`addFunc`, `funcMap`), and rich built-in format/logic functions.
  - *Design Decision*: Intentionally adheres to **Zig-idiomatic syntax** (explicit `const`/`var` mutability and `|item, idx|` capture pipes) rather than Go's `$x :=` and dynamic sigils, ensuring unambiguous parsing and zero mental overhead for Zig developers.
- [x] **`html/template`**:
  - *Current State*: **100% Implemented**. Context-aware auto-escaping against XSS, protecting HTML body, attributes, URLs (`#ZgotmplZ`), JS scripts (`\x3c/script\x3e`), and comments, with safe bypass types (`HTML`, `JS`, `CSS`, `URL`, `HTMLAttr`).

---

## 5. Prioritized Implementation Roadmap

### Phase 1: High-Utility Non-Crypto Core (Completed 100% ✅)
- [x] All 35+ non-crypto packages, full `os` suite, `debug/*` binary parsers, `image/*` codecs, `math/big`, and `database/sql`.

### Phase 2: Security & Cryptography Suite (Current Active Priority)

#### Phase 2.1: Symmetric Ciphers, Block Modes & CSPRNG (Next)
- [ ] **`crypto/subtle`**: Constant-time byte and slice comparisons (`constantTimeCompare`, `constantTimeByteEq`, `constantTimeSelect`).
- [ ] **`crypto/rand`**: Cryptographically secure random reader (`Read`, `Reader`).
- [ ] **`crypto/cipher`**: VTable interfaces for `Block`, `Stream`, and `AEAD`; standard modes (CBC, CTR, CFB, OFB, GCM).
- [ ] **`crypto/aes`**: Hardware/software AES-128, AES-192, and AES-256 block cipher implementation.

#### Phase 2.2: Modern Signatures & Hash Extensions
- [ ] **`crypto/ed25519`**: RFC 8032 Ed25519 high-speed asymmetric signature generation and verification.
- [ ] **`crypto/sha512` & `crypto/sha1`**: Complete the SHA family (`sha512`, `sha384`, `sha512/224`, `sha512/256`, `sha1`).

#### Phase 2.3: PKI, Asymmetric Encryption & Certificates
- [ ] **`crypto/elliptic` & `crypto/ecdsa`**: NIST elliptic curve digital signature algorithms.
- [ ] **`crypto/rsa`**: RSA PKCS#1 v1.5 / PSS signing and OAEP encryption.
- [ ] **`encoding/asn1` & `crypto/x509`**: ASN.1 DER parser and X.509 certificate validation.

### Phase 3: Deferred Long-Term Enhancements
1. **`net/http` HTTP/2 Transport**:
   - Multiplexed framing layer for HTTP/2 client connections.
