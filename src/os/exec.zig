const std = @import("std");
const io_mod = @import("../io.zig");
const bytes_mod = @import("../bytes.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;

pub const Error = anyerror;

fn pumpStdin(task_io: Io, in_file: std.Io.File, r_in: *io_mod.Reader) anyerror!void {
    defer in_file.close(task_io);
    var w_scratch: [2048]u8 = undefined;
    var file_w = in_file.writerStreaming(task_io, &w_scratch);
    _ = try io_mod.copy(&file_w.interface, r_in);
    try file_w.interface.flush();
}

fn pumpOutput(task_io: Io, out_file: std.Io.File, w_out: *io_mod.Writer) anyerror!void {
    defer out_file.close(task_io);
    var r_scratch: [2048]u8 = undefined;
    var file_r = out_file.readerStreaming(task_io, &r_scratch);
    var chunk: [2048]u8 = undefined;
    while (true) {
        const n = try file_r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try w_out.writeAll(chunk[0..n]);
    }
    try w_out.flush();
}

const LockedWriter = struct {
    mu: *Mutex,
    inner: *io_mod.Writer,
    buf: [2048]u8 = undefined,
    writer_inst: std.Io.Writer = undefined,

    fn writer(self: *LockedWriter) *io_mod.Writer {
        self.writer_inst = .{
            .buffer = &self.buf,
            .end = 0,
            .vtable = &.{
                .drain = drainImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *LockedWriter = @alignCast(@fieldParentPtr("writer_inst", w));
        self.mu.lock();
        defer self.mu.unlock();
        if (w.end > 0) {
            try self.inner.writeAll(w.buffer[0..w.end]);
            w.end = 0;
        }
        var total: usize = 0;
        if (data.len > 1) {
            for (data[0 .. data.len - 1]) |chunk| {
                try self.inner.writeAll(chunk);
                total += chunk.len;
            }
        }
        if (data.len > 0) {
            const last = data[data.len - 1];
            for (0..splat) |_| {
                try self.inner.writeAll(last);
                total += last.len;
            }
        }
        return total;
    }
};

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

        const stdin_mode: std.process.SpawnOptions.StdIo = if (self.stdin != null)
            .pipe
        else
            .inherit;
        const stdout_mode: std.process.SpawnOptions.StdIo = if (self.stdout != null)
            .pipe
        else
            .inherit;
        const stderr_mode: std.process.SpawnOptions.StdIo = if (self.stderr != null)
            .pipe
        else
            .inherit;

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

        // Pump stdin, stdout, and stderr concurrently to avoid pipe buffer deadlocks.
        var stdin_fut: ?Io.Future(anyerror!void) = null;
        var stdout_fut: ?Io.Future(anyerror!void) = null;
        var stderr_fut: ?Io.Future(anyerror!void) = null;

        defer {
            if (stdin_fut) |*f| _ = f.cancel(io) catch {};
            if (stdout_fut) |*f| _ = f.cancel(io) catch {};
            if (stderr_fut) |*f| _ = f.cancel(io) catch {};
        }

        if (self.stdin) |r_in| {
            if (child.stdin) |in_file| {
                child.stdin = null;
                stdin_fut = io.concurrent(pumpStdin, .{ io, in_file, r_in }) catch |err| {
                    in_file.close(io);
                    return err;
                };
            }
        }

        if (self.stdout) |w_out| {
            if (child.stdout) |out_file| {
                child.stdout = null;
                stdout_fut = io.concurrent(pumpOutput, .{ io, out_file, w_out }) catch |err| {
                    out_file.close(io);
                    return err;
                };
            }
        }

        if (self.stderr) |w_err| {
            if (child.stderr) |err_file| {
                child.stderr = null;
                stderr_fut = io.concurrent(pumpOutput, .{ io, err_file, w_err }) catch |err| {
                    err_file.close(io);
                    return err;
                };
            }
        }

        var pump_err: ?anyerror = null;
        if (stdin_fut) |*f| {
            if (f.await(io)) |_| {} else |err| {
                if (pump_err == null) pump_err = err;
            }
            stdin_fut = null;
        }
        if (stdout_fut) |*f| {
            if (f.await(io)) |_| {} else |err| {
                if (pump_err == null) pump_err = err;
            }
            stdout_fut = null;
        }
        if (stderr_fut) |*f| {
            if (f.await(io)) |_| {} else |err| {
                if (pump_err == null) pump_err = err;
            }
            stderr_fut = null;
        }
        if (pump_err) |err| return err;

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
        defer self.stdout = null;
        _ = try self.run(io);

        return try out_buf.toOwnedSlice();
    }

    /// CombinedOutput runs the command and returns its combined standard output and standard error.
    pub fn combinedOutput(self: *Cmd, io: Io) Error![]u8 {
        var combined_buf = bytes_mod.Buffer.init(self.allocator);
        errdefer combined_buf.deinit();

        var mu: Mutex = .{};
        const inner_w = combined_buf.writer();
        var out_locked = LockedWriter{ .mu = &mu, .inner = inner_w };
        var err_locked = LockedWriter{ .mu = &mu, .inner = inner_w };

        self.stdout = out_locked.writer();
        self.stderr = err_locked.writer();
        defer {
            self.stdout = null;
            self.stderr = null;
        }
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
    const io = testing.io;

    const argv = [_][]const u8{ "echo", "hello stdgo exec" };
    var cmd = command(testing.allocator, &argv);
    const out = try cmd.output(io);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "hello stdgo exec") != null);
}

test "os.exec: stdin piping via bytes.Reader" {
    const testing = std.testing;
    const io = testing.io;

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
    const io = testing.io;

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

test "os.exec: concurrent large stdin/stdout and combinedOutput clears pointers" {
    const testing = std.testing;
    const io = testing.io;

    // 128 KiB exceeds typical OS pipe buffer (64 KiB), verifying concurrent pumping avoids deadlock.
    const payload = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'Z');

    var r = bytes_mod.Reader.init(payload);
    const argv = [_][]const u8{"cat"};
    var cmd = command(testing.allocator, &argv);
    cmd.stdin = r.reader();

    const out = try cmd.output(io);
    defer testing.allocator.free(out);
    try testing.expectEqual(payload.len, out.len);
    try testing.expect(cmd.stdout == null);

    // Verify combinedOutput captures both stdout and stderr and clears pointers.
    const sh_argv = [_][]const u8{ "sh", "-c", "echo out_msg; echo err_msg >&2" };
    var sh_cmd = command(testing.allocator, &sh_argv);
    const combined = try sh_cmd.combinedOutput(io);
    defer testing.allocator.free(combined);
    try testing.expect(std.mem.indexOf(u8, combined, "out_msg") != null);
    try testing.expect(std.mem.indexOf(u8, combined, "err_msg") != null);
    try testing.expect(sh_cmd.stdout == null);
    try testing.expect(sh_cmd.stderr == null);
}
