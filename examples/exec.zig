//! Example demonstrating stdgo os/exec package:
//! 1. Command execution and output capture
//! 2. Stdin piping via io.Reader into child process
//! 3. Task cancellation

const std = @import("std");
const stdgo = @import("stdgo");
const os = stdgo.os;
const bytes = stdgo.bytes;
const io_mod = stdgo.io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: os/exec Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Basic command output
    // -------------------------------------------------------------
    std.debug.print("1. os.exec.command with output():\n", .{});

    const echo_args = [_][]const u8{ "echo", "Hello from stdgo os/exec!" };
    var cmd1 = os.exec.command(gpa, &echo_args);
    const out1 = try cmd1.output(io);
    defer gpa.free(out1);
    std.debug.print("   Output: {s}", .{out1});

    // -------------------------------------------------------------
    // 2. Piping stdin to child process
    // -------------------------------------------------------------
    std.debug.print("\n2. Stdin piping via bytes.Reader into cat:\n", .{});

    const input_msg = "Piped standard input stream into child process\n";
    var in_reader = bytes.Reader.init(input_msg);

    const cat_args = [_][]const u8{"cat"};
    var cmd2 = os.exec.command(gpa, &cat_args);
    cmd2.stdin = in_reader.reader();

    const out2 = try cmd2.output(io);
    defer gpa.free(out2);
    std.debug.print("   Cat output: {s}", .{out2});

    // -------------------------------------------------------------
    // 3. Task cancellation
    // -------------------------------------------------------------
    std.debug.print("\n3. os.exec.command task cancellation:\n", .{});

    const sleep_args = [_][]const u8{ "sleep", "5" };
    var cmd3 = os.exec.command(gpa, &sleep_args);
    const Worker = struct {
        fn run(cmd: *os.exec.Cmd, task_io: std.Io) !std.process.Child.Term {
            return cmd.run(task_io);
        }
    };
    var future = try io.concurrent(Worker.run, .{ &cmd3, io });
    if (future.cancel(io)) |_| {
        std.debug.print("   Unexpected: sleep completed without cancellation\n", .{});
    } else |err| {
        std.debug.print("   Successfully canceled: {}\n", .{err});
    }

    std.debug.print("\nos/exec example finished successfully.\n", .{});
}
