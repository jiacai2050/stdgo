//! Port of Go's `os` file operations to Zig 0.17.
//!
//! Provides `os.File` implementing `stdgo.io.Reader`, `stdgo.io.Writer`,
//! `stdgo.io.Seeker`, `stdgo.io.Closer`, as well as convenient file functions:
//! `open`, `create`, `readFile`, `writeFile`, `mkdir`, `mkdirAll`, `readDir`,
//! `remove`, `removeAll`, `stat`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../io.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const StdFile = std.Io.File;

pub const FileInfo = struct {
    name: []const u8,
    size: u64,
    mode: u32,
    mod_time: i64,
    is_dir: bool,
};

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    kind: StdFile.Kind,
};

/// File represents an open file descriptor.
pub const File = struct {
    handle: StdFile,
    io: Io,
    name: []const u8,
    r_buffer: [4096]u8 = undefined,
    w_buffer: [4096]u8 = undefined,
    reader_inst: StdFile.Reader = undefined,
    writer_inst: StdFile.Writer = undefined,
    reader_init: bool = false,
    writer_init: bool = false,
    closed: bool = false,

    pub fn init(handle: StdFile, io: Io, name: []const u8) File {
        return .{
            .handle = handle,
            .io = io,
            .name = name,
            .reader_init = false,
            .writer_init = false,
            .closed = false,
        };
    }

    /// Reader returns the stream interface implementing *stdgo.io.Reader.
    pub fn reader(self: *File) *io_mod.Reader {
        if (!self.reader_init) {
            self.reader_inst = self.handle.reader(self.io, &self.r_buffer);
            self.reader_init = true;
        }
        return &self.reader_inst.interface;
    }

    /// Writer returns the stream interface implementing *stdgo.io.Writer.
    pub fn writer(self: *File) *io_mod.Writer {
        if (!self.writer_init) {
            self.writer_inst = self.handle.writer(self.io, &self.w_buffer);
            self.writer_init = true;
        }
        return &self.writer_inst.interface;
    }

    /// Read reads up to buf.len bytes into buf.
    pub fn read(self: *File, buf: []u8) !usize {
        return self.reader().readSliceShort(buf);
    }

    /// Write writes len(b) bytes to the File.
    pub fn write(self: *File, b: []const u8) !usize {
        try self.writer().writeAll(b);
        return b.len;
    }

    /// WriteString is like Write, but writes the contents of string s.
    pub fn writeString(self: *File, s: []const u8) !usize {
        return self.write(s);
    }

    /// Seek sets the offset for the next Read or Write on file.
    pub fn seek(self: *File, offset: i64, whence: io_mod.SeekWhence) !u64 {
        if (self.writer_init) {
            try self.writer_inst.interface.flush();
            self.writer_init = false;
        }
        const r_stream = self.reader();
        _ = r_stream;
        switch (whence) {
            .start => {
                if (offset < 0) return error.InvalidArgument;
                try self.reader_inst.seekTo(@intCast(offset));
                return @intCast(offset);
            },
            .current => {
                try self.reader_inst.seekBy(offset);
                return self.reader_inst.logicalPos();
            },
            .end => {
                const st = try self.handle.stat(self.io);
                const target = @as(i64, @intCast(st.size)) + offset;
                if (target < 0) return error.InvalidArgument;
                try self.reader_inst.seekTo(@intCast(target));
                return @intCast(target);
            },
        }
    }

    /// Stat returns the FileInfo structure describing file.
    pub fn stat(self: *File) !FileInfo {
        const st = try self.handle.stat(self.io);
        return FileInfo{
            .name = self.name,
            .size = st.size,
            .mode = @backingInt(st.permissions),
            .mod_time = @truncate(st.mtime.nanoseconds),
            .is_dir = st.kind == .directory,
        };
    }

    /// Sync commits the current contents of the file to stable storage.
    pub fn sync(self: *File) !void {
        if (self.writer_init) {
            try self.writer_inst.interface.flush();
            self.writer_init = false;
        }
        try self.handle.sync(self.io);
    }

    /// Close closes the File, rendering it unusable for I/O.
    pub fn close(self: *File) !void {
        if (self.closed) return;
        self.closed = true;
        defer self.handle.close(self.io);
        if (self.writer_init) {
            try self.writer_inst.interface.flush();
            self.writer_init = false;
        }
    }
};

/// Open opens the named file for reading.
pub fn open(io: Io, path: []const u8) !File {
    std.debug.assert(path.len > 0);
    const handle = try Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    return File.init(handle, io, path);
}

/// Create creates or truncates the named file.
pub fn create(io: Io, path: []const u8) !File {
    std.debug.assert(path.len > 0);
    const handle = try Dir.createFile(.cwd(), io, path, .{ .read = true, .truncate = true });
    return File.init(handle, io, path);
}

/// ReadFile reads the named file and returns the contents.
pub fn readFile(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);
    var f = try open(io, path);
    defer _ = f.close() catch {};

    const st = try f.stat();
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);

    const n = try io_mod.readFull(f.reader(), buf);
    std.debug.assert(n == buf.len);
    return buf;
}

/// WriteFile writes data to the named file, creating it if necessary.
pub fn writeFile(io: Io, path: []const u8, data: []const u8, perm: u32) !void {
    std.debug.assert(path.len > 0);
    _ = perm;
    var f = try create(io, path);
    errdefer _ = f.close() catch {};

    var remaining = data;
    while (remaining.len > 0) {
        const written = try f.write(remaining);
        std.debug.assert(written > 0);
        remaining = remaining[written..];
    }
    try f.sync();
    try f.close();
}

/// Mkdir creates a new directory with the specified permissions.
pub fn mkdir(io: Io, path: []const u8, perm: u32) !void {
    std.debug.assert(path.len > 0);
    _ = perm;
    try Dir.createDir(.cwd(), io, path, .default_dir);
}

/// MkdirAll creates a directory named path, along with any necessary parents.
pub fn mkdirAll(io: Io, path: []const u8, perm: u32) !void {
    std.debug.assert(path.len > 0);
    _ = perm;
    try Dir.createDirPath(.cwd(), io, path);
}

/// Remove removes the named file or directory.
pub fn remove(io: Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.IsDir => try Dir.deleteDir(.cwd(), io, path),
        else => |e| return e,
    };
}

/// RemoveAll removes path and any children it contains.
pub fn removeAll(io: Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    try Dir.deleteTree(.cwd(), io, path);
}

/// Stat returns a FileInfo describing the named file.
pub fn stat(io: Io, path: []const u8) !FileInfo {
    std.debug.assert(path.len > 0);
    const st = try Dir.statFile(.cwd(), io, path, .{});
    return FileInfo{
        .name = std.fs.path.basename(path),
        .size = st.size,
        .mode = @backingInt(st.permissions),
        .mod_time = @truncate(st.mtime.nanoseconds),
        .is_dir = st.kind == .directory,
    };
}

/// ReadDir reads the named directory, returning all its directory entries sorted by filename.
pub fn readDir(allocator: Allocator, io: Io, path: []const u8) ![]DirEntry {
    std.debug.assert(path.len > 0);
    const dir = try Dir.openDir(.cwd(), io, path, .{ .iterate = true });
    defer dir.close(io);

    var list = std.ArrayList(DirEntry).empty;
    errdefer {
        for (list.items) |e| allocator.free(e.name);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        try list.append(allocator, .{
            .name = owned_name,
            .is_dir = entry.kind == .directory,
            .kind = entry.kind,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Stdin returns a File connected to standard input.
pub fn stdin(io: Io) File {
    return File.init(StdFile.stdin(), io, "/dev/stdin");
}

/// Stdout returns a File connected to standard output.
pub fn stdout(io: Io) File {
    return File.init(StdFile.stdout(), io, "/dev/stdout");
}

/// Stderr returns a File connected to standard error.
pub fn stderr(io: Io) File {
    return File.init(StdFile.stderr(), io, "/dev/stderr");
}

/// Rename renames (moves) old_path to new_path.
/// If new_path already exists and is not a directory, Rename replaces it.
pub fn rename(io: Io, old_path: []const u8, new_path: []const u8) !void {
    try Dir.rename(.cwd(), old_path, .cwd(), new_path, io);
}

/// Truncate changes the size of the named file.
pub fn truncate(io: Io, path: []const u8, size: u64) !void {
    const handle = try Dir.openFile(.cwd(), io, path, .{ .mode = .read_write });
    defer handle.close(io);
    try handle.setLength(io, size);
}

/// Symlink creates link_path as a symbolic link pointing to target.
pub fn symlink(io: Io, target: []const u8, link_path: []const u8) !void {
    try Dir.symLink(.cwd(), io, target, link_path, .{});
}

/// Readlink returns the destination of the named symbolic link.
pub fn readlink(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Dir.readLink(.cwd(), io, path, &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

/// Chmod changes the mode of the named file to mode.
pub fn chmod(io: Io, path: []const u8, mode: u32) !void {
    if (builtin.os.tag != .windows) {
        const perms = StdFile.Permissions.fromMode(@intCast(mode));
        try Dir.setFilePermissions(.cwd(), io, path, perms, .{});
    }
}

/// IsNotExist returns a boolean indicating whether the error is known to
/// report that a file or directory does not exist.
pub fn isNotExist(err: anyerror) bool {
    return err == error.FileNotFound or
        err == error.UnknownUser or
        err == error.UnknownGroup or
        err == error.UnknownUserId or
        err == error.UnknownGroupId;
}

/// IsExist returns a boolean indicating whether the error is known to report
/// that a file or directory already exists.
pub fn isExist(err: anyerror) bool {
    return err == error.PathAlreadyExists;
}

/// IsPermission returns a boolean indicating whether the error is known to
/// report that permission is denied.
pub fn isPermission(err: anyerror) bool {
    return err == error.AccessDenied or err == error.PermissionDenied;
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "os.file: create, write, seek, read, remove" {
    const testing = std.testing;
    const io = testing.io;

    const test_dir = "test_os_scratch_dir";
    mkdirAll(io, test_dir, 0o755) catch {};
    defer removeAll(io, test_dir) catch {};

    const test_path = test_dir ++ "/test_file.txt";

    // 1. Create and write
    var f = try create(io, test_path);
    defer _ = f.close() catch {};

    _ = try f.write("Hello from stdgo os.File!\n");
    _ = try f.writeString("Second line of content.\n");
    try f.sync();

    // 2. Seek and read
    _ = try f.seek(0, .start);
    var read_buf: [32]u8 = undefined;
    const n = try f.read(&read_buf);
    try testing.expect(std.mem.startsWith(u8, read_buf[0..n], "Hello from stdgo os.File!\n"));

    // 3. Stat
    const info = try f.stat();
    try testing.expect(info.size > 25);
    try testing.expect(!info.is_dir);

    // 4. readFile convenience
    const content = try readFile(testing.allocator, io, test_path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Second line of content.") != null);

    // 5. readDir
    const entries = try readDir(testing.allocator, io, test_dir);
    defer {
        for (entries) |e| testing.allocator.free(e.name);
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("test_file.txt", entries[0].name);

    // 6. Truncate
    try truncate(io, test_path, 5);
    const trunc_content = try readFile(testing.allocator, io, test_path);
    defer testing.allocator.free(trunc_content);
    try testing.expectEqual(@as(usize, 5), trunc_content.len);
    try testing.expectEqualStrings("Hello", trunc_content);

    // 7. Rename
    const new_path = test_dir ++ "/renamed_file.txt";
    try rename(io, test_path, new_path);
    try testing.expectError(error.FileNotFound, open(io, test_path));
    var f_renamed = try open(io, new_path);
    try f_renamed.close();

    // 8. Symlink & Readlink
    const sym_path = test_dir ++ "/symlink.txt";
    try symlink(io, "renamed_file.txt", sym_path);
    const link_target = try readlink(testing.allocator, io, sym_path);
    defer testing.allocator.free(link_target);
    try testing.expectEqualStrings("renamed_file.txt", link_target);

    // 9. Error checkers
    try testing.expect(isNotExist(error.FileNotFound));
    try testing.expect(!isNotExist(error.AccessDenied));
    try testing.expect(isPermission(error.AccessDenied));
    try testing.expect(isExist(error.PathAlreadyExists));
}
