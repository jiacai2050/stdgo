const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stdgo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Examples
    const examples = .{
        .{ .name = "overview", .file = "examples/overview.zig" },
        .{ .name = "http", .file = "examples/http_client.zig" },
        .{ .name = "slog", .file = "examples/slog.zig" },
        .{ .name = "errgroup", .file = "examples/errgroup.zig" },
        .{ .name = "multipart", .file = "examples/multipart.zig" },
        .{ .name = "hmac", .file = "examples/hmac.zig" },
        .{ .name = "archive", .file = "examples/archive.zig" },
        .{ .name = "bufio-io", .file = "examples/bufio_io.zig" },
        .{ .name = "bytes-strings", .file = "examples/bytes_strings.zig" },
        .{ .name = "compress", .file = "examples/compress.zig" },
        .{ .name = "container", .file = "examples/container.zig" },
        .{ .name = "context", .file = "examples/context.zig" },
        .{ .name = "crypto", .file = "examples/crypto.zig" },
        .{ .name = "encoding", .file = "examples/encoding.zig" },
        .{ .name = "flag", .file = "examples/flag.zig" },
        .{ .name = "hash-math", .file = "examples/hash_math.zig" },
        .{ .name = "path", .file = "examples/path.zig" },
        .{ .name = "regexp", .file = "examples/regexp.zig" },
        .{ .name = "slices", .file = "examples/slices.zig" },
        .{ .name = "sync", .file = "examples/sync.zig" },
        .{ .name = "tabwriter", .file = "examples/tabwriter.zig" },
        .{ .name = "time", .file = "examples/time.zig" },
        .{ .name = "url", .file = "examples/url.zig" },
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
