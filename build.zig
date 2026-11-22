const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_sqlite = b.option(
        bool,
        "sqlite",
        "Enable SQLite database driver (default: false)",
    ) orelse false;
    const enable_tsan = b.option(
        bool,
        "tsan",
        "Enable ThreadSanitizer (default: false)",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "have_sqlite", enable_sqlite);

    // ThreadSanitizer is supported by Clang/LLVM on POSIX platforms (Linux, macOS, BSDs),
    // but unsupported on Windows.
    const sanitize_thread = enable_tsan and target.result.os.tag != .windows;

    const mod = b.addModule("stdgo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    mod.addOptions("build_options", build_options);

    if (enable_sqlite) {
        if (b.lazyDependency("sqlite", .{
            .target = target,
            .optimize = optimize,
        })) |sqlite_dep| {
            mod.addImport("sqlite", sqlite_dep.module("sqlite"));
        }
    }

    // Examples
    const examples = .{
        .{ .name = "overview", .file = "examples/overview.zig" },
        .{ .name = "http", .file = "examples/http_client.zig" },
        .{ .name = "slog", .file = "examples/slog.zig" },
        .{ .name = "errgroup", .file = "examples/errgroup.zig" },
        .{ .name = "multipart", .file = "examples/multipart.zig" },
        .{ .name = "hmac", .file = "examples/hmac.zig" },
        .{ .name = "archive", .file = "examples/archive.zig" },
        .{ .name = "bufio", .file = "examples/bufio.zig" },
        .{ .name = "io", .file = "examples/io.zig" },
        .{ .name = "bytes-strings", .file = "examples/bytes_strings.zig" },
        .{ .name = "compress", .file = "examples/compress.zig" },
        .{ .name = "container", .file = "examples/container.zig" },
        .{ .name = "sql", .file = "examples/sql.zig" },
        .{ .name = "crypto", .file = "examples/crypto.zig" },
        .{ .name = "encoding", .file = "examples/encoding.zig" },
        .{ .name = "base32", .file = "examples/base32.zig" },
        .{ .name = "exec", .file = "examples/exec.zig" },
        .{ .name = "flag", .file = "examples/flag.zig" },
        .{ .name = "json", .file = "examples/json.zig" },
        .{ .name = "net", .file = "examples/net.zig" },
        .{ .name = "os", .file = "examples/os.zig" },
        .{ .name = "hash-math", .file = "examples/hash_math.zig" },
        .{ .name = "path", .file = "examples/path.zig" },
        .{ .name = "regexp", .file = "examples/regexp.zig" },
        .{ .name = "slices", .file = "examples/slices.zig" },
        .{ .name = "sync", .file = "examples/sync.zig" },
        .{ .name = "semaphore", .file = "examples/semaphore.zig" },
        .{ .name = "tabwriter", .file = "examples/tabwriter.zig" },
        .{ .name = "textproto", .file = "examples/textproto.zig" },
        .{ .name = "template", .file = "examples/template.zig" },
        .{ .name = "html-template", .file = "examples/html_template.zig" },
        .{ .name = "time", .file = "examples/time.zig" },
        .{ .name = "time-formatting", .file = "examples/time_formatting.zig" },
        .{ .name = "rate-limiter", .file = "examples/rate_limiter.zig" },
        .{ .name = "mime", .file = "examples/mime.zig" },
        .{ .name = "mail", .file = "examples/mail.zig" },
        .{ .name = "url", .file = "examples/url.zig" },
        .{ .name = "utf8", .file = "examples/utf8.zig" },
        .{ .name = "hash-checksums", .file = "examples/hash_checksums.zig" },
        .{ .name = "singleflight", .file = "examples/singleflight.zig" },
        .{ .name = "smtp-udp-dns", .file = "examples/smtp_udp_dns.zig" },
        .{ .name = "non-crypto-suite", .file = "examples/non_crypto_suite.zig" },
        .{ .name = "data-media-suite", .file = "examples/data_media_suite.zig" },
        .{ .name = "debug-compress-suite", .file = "examples/debug_compress_suite.zig" },
        .{ .name = "binary-formats-suite", .file = "examples/binary_formats_suite.zig" },
        .{ .name = "dwarf-plan9-suite", .file = "examples/dwarf_plan9_suite.zig" },
        .{ .name = "core-foundations-suite", .file = "examples/core_foundations_suite.zig" },
        .{ .name = "extended-suite", .file = "examples/extended_suite.zig" },
    };

    const run_all_step = b.step("run-examples", "Run all examples");

    inline for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = "example-" ++ ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "stdgo", .module = mod },
                },
            }),
        });
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addPassthruArgs();

        const run_step = b.step("run-" ++ ex.name, "Run the " ++ ex.name ++ " example");
        run_step.dependOn(&run_cmd.step);
        run_all_step.dependOn(&run_cmd.step);

        if (comptime std.mem.eql(u8, ex.name, "overview")) {
            const default_run_step = b.step("run", "Run the overview demo");
            default_run_step.dependOn(&run_cmd.step);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Emit documentation");
    docs_step.dependOn(&install_docs.step);
}
