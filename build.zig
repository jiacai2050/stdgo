const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stdgo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const demo_exe = b.addExecutable(.{
        .name = "stdgo-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/overview.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stdgo", .module = mod },
            },
        }),
    });

    const run_step = b.step("run", "Run the overview demo");

    const run_cmd = b.addRunArtifact(demo_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();

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
