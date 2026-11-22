# Agent Guidelines for stdgo

This document outlines the project scope, architectural conventions, and development guidelines for AI agents working on `stdgo`.

---

## 1. Project Scope & Non-Goals

- **Scope**: Bring Go standard library ergonomics, native stream abstractions (`stdgo.io.Reader` = `std.Io.Reader` / `stdgo.io.Writer` = `std.Io.Writer`), and high-utility packages into the Zig (0.17.0) ecosystem, especially where the Zig standard library is missing or incomplete.
- **Explicit Non-Goals**:
  - **HTTP Server**: **Do not implement an HTTP server in `stdgo`**. A high-performance, ergonomic HTTP server is already fully implemented in the dedicated standalone project [lighting](https://github.com/jiacai2050/lighting/). The `stdgo.net.http` package is **strictly focused on the HTTP client** (`Client`, `Transport`, `ConnPool`, `CookieJar`, `Request`, `Response`, etc.).

---

## 2. Core Architecture & Design Conventions

1. **Unified Streaming Abstraction**:
   - Stream processing must be built around native Zig 0.17 stream abstractions (`stdgo.io.Reader` / `stdgo.io.Writer` aliased to `std.Io.Reader` / `std.Io.Writer`) to avoid buffering entire payloads into memory or coupling to raw byte slices. Direct streaming delegates to `src.stream(dst, limit)` with native zero-copy and kernel `sendFileAll` support.
2. **Explicit Dependency Injection (No Implicit Global State or C Functions)**:
   - While porting Go APIs and striving for Go ergonomic conventions, **never introduce hidden global state, implicit memory allocations, or C runtime functions (`std.c.*`, `getenv`, etc.)**.
   - Zig does not have a hidden runtime, GC, or global implicit context. All resources—specifically `std.mem.Allocator` and `std.Io`—**must be explicitly passed from the outside** into constructors (`init`), structs, and functions that allocate memory or perform I/O.
   - **Strict Prohibition on Single-Threaded IO Shims**: **Never use or instantiate `std.Io.Threaded.init_single_threaded` anywhere in the codebase**. In library modules, `std.Io` must be explicitly passed into constructors and functions. In unit tests requiring I/O or clocks, use `std.testing.io` directly instead of manually instantiating threaded I/O.
   - **Strict Prohibition on Raw POSIX / C APIs**: **Never rely on raw POSIX system calls (`std.posix.*`) or C runtime APIs (`std.c.*`) when an abstraction exists in `std.Io`**. All I/O, sleep (`io.sleep`), clock/time reading (`io.clock`), socket timeouts (`std.Io.Timeout`), and stream operations must strictly go through the injected `std.Io` and `stdgo.io` interfaces rather than raw file descriptors or POSIX primitives.
   - For environment variables, configuration, or credentials, pass them explicitly via options structs (`*const std.process.Environ.Map`, `std.process.Environ`, or lookup function pointers) rather than assuming global access.
3. **I/O Timeouts & Networking**:
   - Never use low-level POSIX `setsockopt(SO_RCVTIMEO/SO_SNDTIMEO)`. Timeouts must always be driven by Zig 0.17's native `std.Io.Timeout` abstractions (`options.timeout` on `IpAddress.connect` / `HostName.connect`).
4. **Memory Safety & Ownership**:
   - Follow TigerStyle memory safety practices: dynamically allocated resources (e.g. `Request.extra_strings`) must have clearly tracked lifetimes and be explicitly cleaned up on `deinit` without leaving dangling pointers.
5. **Project Structure**:
   - `src/`: Pure library modules only.
   - `examples/`: Runnable example programs (e.g., `examples/overview.zig`).

---

## 3. Development & Testing Rules

- **Testing Standard**: Every module must have comprehensive unit tests verified against official Go test suites and corner cases.
- **Safety Boundaries**: Never execute destructive commands (`git push`, `git add`, `git commit`, `git reset --hard`, `rm`, `truncate`, etc.) without explicit user confirmation.
- **Environment Isolation**: Never read from or write to `/tmp`. Temporary artifacts must be placed in a repository-local directory that is ignored by `.gitignore`.
- **Documentation Paths**: Never use local machine absolute paths (e.g., `file:///Users/...`) in `devlogs/` or other docs; always use relative paths.
- **Verification Commands**:
  - Run all tests: `zig build test --summary all`
  - Run example demo: `zig build run`
