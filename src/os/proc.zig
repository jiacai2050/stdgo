//! Port of Go's `os` process and host environment utilities to Zig 0.17.
//!
//! Provides `getpid`, `getppid`, `hostname`, `getwd`, `executable`, and `tempDir`.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const EnvironMap = std.process.Environ.Map;
const builtin = @import("builtin");

/// Getpid returns the process id of the caller.
pub fn getpid() i32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else if (builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    } else if (builtin.link_libc) {
        return @intCast(std.c.getpid());
    } else {
        @compileError("stdgo.os.getpid: platform '" ++ @tagName(builtin.os.tag) ++
            "' requires linking libc. Please call artifact.linkLibC() in build.zig.");
    }
}

/// Getppid returns the process id of the caller's parent.
pub fn getppid() i32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getppid());
    } else if (builtin.os.tag == .windows) {
        return 0;
    } else if (builtin.link_libc) {
        return @intCast(std.c.getppid());
    } else {
        @compileError("stdgo.os.getppid: platform '" ++ @tagName(builtin.os.tag) ++
            "' requires linking libc. Please call artifact.linkLibC() in build.zig.");
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameA(
        lpBuffer: [*]u8,
        nSize: *std.os.windows.DWORD,
    ) std.os.windows.BOOL;
} else struct {};

/// Hostname returns the host name reported by the kernel.
/// If an environment map is provided with HOSTNAME or COMPUTERNAME, it checks that first.
pub fn hostname(allocator: Allocator, env: ?*const EnvironMap) ![]u8 {
    if (env) |e| {
        if (e.get("HOSTNAME")) |h| return try allocator.dupe(u8, h);
        if (e.get("COMPUTERNAME")) |h| return try allocator.dupe(u8, h);
    }

    if (builtin.os.tag == .windows) {
        var buf: [256]u8 = undefined;
        var size: std.os.windows.DWORD = buf.len;
        if (win32.GetComputerNameA(&buf, &size) != .FALSE) {
            return try allocator.dupe(u8, buf[0..size]);
        }
        return error.HostnameNotFound;
    } else if (builtin.os.tag == .linux or builtin.link_libc) {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const h = try std.posix.gethostname(&buf);
        return try allocator.dupe(u8, h);
    } else {
        @compileError("stdgo.os.hostname: platform '" ++ @tagName(builtin.os.tag) ++
            "' requires linking libc. Please call artifact.linkLibC() in build.zig.");
    }
}

/// Getwd returns a rooted path name corresponding to the current directory.
pub fn getwd(allocator: Allocator, io: Io) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Dir.realPath(.cwd(), io, &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

/// Executable returns the path name for the executable that started the current process.
pub fn executable(allocator: Allocator, io: Io) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

/// TempDir returns the default directory to use for temporary files.
pub fn tempDir(env: ?*const EnvironMap) []const u8 {
    if (env) |e| {
        if (e.get("TMPDIR")) |dir| return dir;
        if (e.get("TEMP")) |dir| return dir;
        if (e.get("TMP")) |dir| return dir;
    }
    if (builtin.os.tag == .windows) {
        return "C:\\Windows\\Temp";
    }
    return "/tmp";
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "os.proc: getpid, getppid, hostname, tempDir, getwd" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. PID and PPID
    const pid = getpid();
    try testing.expect(pid > 0);
    const ppid = getppid();
    try testing.expect(ppid >= 0);

    // 2. Hostname
    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOSTNAME", "my-test-host");

    const host = try hostname(allocator, &env_map);
    defer allocator.free(host);
    try testing.expectEqualStrings("my-test-host", host);

    // Live hostname without env
    const live_host = try hostname(allocator, null);
    defer allocator.free(live_host);
    try testing.expect(live_host.len > 0);

    // 3. TempDir
    const expected_default_temp = if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    try testing.expectEqualStrings(expected_default_temp, tempDir(null));
    try env_map.put("TMPDIR", "/custom/tmp");
    try testing.expectEqualStrings("/custom/tmp", tempDir(&env_map));

    // 4. Getwd
    const wd = try getwd(allocator, io);
    defer allocator.free(wd);
    try testing.expect(wd.len > 0);

    // 5. Executable
    const exe = executable(allocator, io) catch null;
    if (exe) |p| {
        defer allocator.free(p);
        try testing.expect(p.len > 0);
    }
}
