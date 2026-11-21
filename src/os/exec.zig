const std = @import("std");
const io_mod = @import("../io.zig");
const bytes_mod = @import("../bytes.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;

pub const Error = anyerror;

/// Cmd represents an external command being prepared or run.
pub const Cmd = struct {
    allocator: Allocator,
    argv: []const []const u8,
    dir: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,

    stdin: ?*io_mod.Reader = null,
    stdout: ?*io_mod.Writer = null,
    stderr: ?*io_mod.Writer = null,

    /// Run starts the command and waits for it to complete.
    /// Once waiting for the child, cancellation is deferred until the child exits.
    pub fn run(self: *Cmd, io: Io) Error!Child.Term {
        std.debug.assert(self.argv.len > 0);
        std.debug.assert(self.argv[0].len > 0);

        try io.checkCancel();

        const stdin_mode: std.process.SpawnOptions.StdIo = if (self.stdin != null) .pipe else .inherit;
        const stdout_mode: std.process.SpawnOptions.StdIo = if (self.stdout != null) .pipe else .inherit;
        const stderr_mode: std.process.SpawnOptions.StdIo = if (self.stderr != null) .pipe else .inherit;

        const cwd_mode: Child.Cwd = if (self.dir) |d| .{ .path = d } else .inherit;

        var child = try std.process.spawn(io, .{
            .argv = self.argv,
            .cwd = cwd_mode,
            .environ_map = self.environ_map,
            .stdin = stdin_mode,
            .stdout = stdout_mode,
            .stderr = stderr_mode,
        });
        errdefer child.kill(io);

        // Pipe stdin if provided
        if (self.stdin) |r_in| {
            if (child.stdin) |*in_file| {
                var w_scratch: [2048]u8 = undefined;
                var file_w = in_file.writerStreaming(io, &w_scratch);
                _ = try io_mod.copy(&file_w.interface, r_in);
                try file_w.interface.flush();
                in_file.close(io);
                child.stdin = null;
            }
        }

        // Pipe stdout if provided
        if (self.stdout) |w_out| {
            if (child.stdout) |*out_file| {
                var r_scratch: [2048]u8 = undefined;
                var file_r = out_file.readerStreaming(io, &r_scratch);
                _ = try io_mod.copy(w_out, &file_r.interface);
                try w_out.flush();
                out_file.close(io);
                child.stdout = null;
            }
        }

        // Pipe stderr if provided
        if (self.stderr) |w_err| {
            if (child.stderr) |*err_file| {
                var r_scratch: [2048]u8 = undefined;
                var file_r = err_file.readerStreaming(io, &r_scratch);
                _ = try io_mod.copy(w_err, &file_r.interface);
                try w_err.flush();
                err_file.close(io);
                child.stderr = null;
            }
        }

        const term = blk: {
            const previous = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(previous);
            break :blk try child.wait(io);
        };
        try io.checkCancel();

        if (!term.success()) {
            return Error.ExitError;
        }

        return term;
    }

    /// Output runs the command and returns its standard output.
    pub fn output(self: *Cmd, io: Io) Error![]u8 {
        var out_buf = bytes_mod.Buffer.init(self.allocator);
        errdefer out_buf.deinit();

        self.stdout = out_buf.writer();
        _ = try self.run(io);

        return try out_buf.toOwnedSlice();
    }

    /// CombinedOutput runs the command and returns its combined standard output and standard error.
    pub fn combinedOutput(self: *Cmd, io: Io) Error![]u8 {
        var combined_buf = bytes_mod.Buffer.init(self.allocator);
        errdefer combined_buf.deinit();

        self.stdout = combined_buf.writer();
        self.stderr = combined_buf.writer();
        _ = try self.run(io);

        return try combined_buf.toOwnedSlice();
    }
};

/// Command returns the Cmd struct to execute the named program with the given arguments.
pub fn command(allocator: Allocator, argv: []const []const u8) Cmd {
    std.debug.assert(argv.len > 0);
    std.debug.assert(argv[0].len > 0);
    return .{
        .allocator = allocator,
        .argv = argv,
    };
}

test "os.exec: command and output" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv = [_][]const u8{ "echo", "hello stdgo exec" };
    var cmd = command(testing.allocator, &argv);
    const out = try cmd.output(io);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "hello stdgo exec") != null);
}

test "os.exec: stdin piping via bytes.Reader" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const input_text = "pipe through standard input into cat\n";
    var r = bytes_mod.Reader.init(input_text);

    const argv = [_][]const u8{"cat"};
    var cmd = command(testing.allocator, &argv);
    cmd.stdin = r.reader();

    const out = try cmd.output(io);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(input_text, out);
}

test "os.exec: task cancellation" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv = [_][]const u8{ "sleep", "0.1" };
    var cmd = command(testing.allocator, &argv);
    var started: Io.Event = .unset;
    const Worker = struct {
        fn run(c: *Cmd, task_io: Io, ready: *Io.Event) !Child.Term {
            ready.set(task_io);
            return c.run(task_io);
        }
    };
    var future = try io.concurrent(Worker.run, .{ &cmd, io, &started });
    try started.wait(io);
    try testing.expectError(error.Canceled, future.cancel(io));
}
