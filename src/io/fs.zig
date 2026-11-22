//! Package io/fs defines basic interfaces and abstractions to a tree of files.
//!
//! Provides virtual filesystem abstractions (FileInfo, DirEntry, FileMode),
//! tree walking (walkDir), and the pure in-memory MapFS.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// ModeDir indicates a file is a directory.
pub const ModeDir: u32 = 1 << 31;

/// FileInfo describes a file and is returned by stat.
pub const FileInfo = struct {
    name: []const u8,
    size: u64,
    mode: u32,
    is_dir: bool,
};

/// DirEntry is an entry read from a directory.
pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64 = 0,
    mode: u32 = 0,

    /// Info returns the FileInfo for the file or subdirectory described by the entry.
    pub fn info(self: DirEntry) FileInfo {
        return .{
            .name = self.name,
            .size = self.size,
            .mode = self.mode | (if (self.is_dir) ModeDir else 0),
            .is_dir = self.is_dir,
        };
    }
};

/// MapFile describes a single file in a MapFS.
pub const MapFile = struct {
    data: []const u8 = "",
    is_dir: bool = false,
    mode: u32 = 0o644,
};

/// MapFS is an in-memory virtual filesystem implemented using a hash map of paths to files.
pub const MapFS = struct {
    files: std.StringHashMap(MapFile),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MapFS {
        return .{
            .files = std.StringHashMap(MapFile).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MapFS) void {
        self.files.deinit();
        self.* = undefined;
    }

    pub fn addFile(self: *MapFS, path: []const u8, data: []const u8) !void {
        try self.files.put(path, .{
            .data = data,
            .is_dir = false,
            .mode = 0o644,
        });
    }

    pub fn addDir(self: *MapFS, path: []const u8) !void {
        try self.files.put(path, .{
            .data = "",
            .is_dir = true,
            .mode = ModeDir | 0o755,
        });
    }

    pub fn stat(self: MapFS, path: []const u8) !FileInfo {
        const clean = cleanPath(path);
        if (clean.len == 0 or mem.eql(u8, clean, ".")) {
            return FileInfo{
                .name = ".",
                .size = 0,
                .mode = ModeDir | 0o755,
                .is_dir = true,
            };
        }

        if (self.files.get(clean)) |mf| {
            return FileInfo{
                .name = baseName(clean),
                .size = mf.data.len,
                .mode = mf.mode,
                .is_dir = mf.is_dir,
            };
        }

        // Check if path is an implicit directory
        var it = self.files.keyIterator();
        while (it.next()) |k| {
            if (k.len > clean.len and mem.startsWith(u8, k.*, clean) and k.*[clean.len] == '/') {
                return FileInfo{
                    .name = baseName(clean),
                    .size = 0,
                    .mode = ModeDir | 0o755,
                    .is_dir = true,
                };
            }
        }

        return error.FileNotFound;
    }

    pub fn readFile(self: MapFS, path: []const u8) ![]const u8 {
        const clean = cleanPath(path);
        const mf = self.files.get(clean) orelse return error.FileNotFound;
        if (mf.is_dir) return error.IsDir;
        return mf.data;
    }

    pub fn readDir(self: MapFS, allocator: Allocator, dir_path: []const u8) ![]DirEntry {
        const clean = cleanPath(dir_path);
        const prefix = if (clean.len == 0 or mem.eql(u8, clean, ".")) "" else clean;

        var entries = std.ArrayList(DirEntry).empty;
        defer entries.deinit(allocator);

        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        var it = self.files.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (prefix.len == 0) {
                // Root entries
                if (mem.indexOfScalar(u8, k, '/')) |slash_idx| {
                    const top_dir = k[0..slash_idx];
                    if (!seen_dirs.contains(top_dir)) {
                        try seen_dirs.put(top_dir, {});
                        try entries.append(allocator, .{
                            .name = top_dir,
                            .is_dir = true,
                            .size = 0,
                        });
                    }
                } else {
                    try entries.append(allocator, .{
                        .name = k,
                        .is_dir = entry.value_ptr.is_dir,
                        .size = entry.value_ptr.data.len,
                        .mode = entry.value_ptr.mode,
                    });
                }
            } else {
                if (k.len > prefix.len and mem.startsWith(u8, k, prefix) and k[prefix.len] == '/') {
                    const rest = k[prefix.len + 1 ..];
                    if (mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
                        const sub_dir = rest[0..slash_idx];
                        if (!seen_dirs.contains(sub_dir)) {
                            try seen_dirs.put(sub_dir, {});
                            try entries.append(allocator, .{
                                .name = sub_dir,
                                .is_dir = true,
                                .size = 0,
                            });
                        }
                    } else {
                        try entries.append(allocator, .{
                            .name = rest,
                            .is_dir = entry.value_ptr.is_dir,
                            .size = entry.value_ptr.data.len,
                            .mode = entry.value_ptr.mode,
                        });
                    }
                }
            }
        }

        return try entries.toOwnedSlice(allocator);
    }
};

pub const WalkFn = *const fn (path: []const u8, d: DirEntry) anyerror!void;

pub fn walkDir(fs: MapFS, allocator: Allocator, root: []const u8, walk_fn: WalkFn) !void {
    const root_clean = cleanPath(root);
    const root_info = try fs.stat(root_clean);
    const root_entry = DirEntry{
        .name = root_info.name,
        .is_dir = root_info.is_dir,
        .size = root_info.size,
        .mode = root_info.mode,
    };

    try walk_fn(root_clean, root_entry);

    if (root_entry.is_dir) {
        try walkDirInternal(fs, allocator, root_clean, walk_fn);
    }
}

fn walkDirInternal(
    fs: MapFS,
    allocator: Allocator,
    current_dir: []const u8,
    walk_fn: WalkFn,
) !void {
    const entries = try fs.readDir(allocator, current_dir);
    defer allocator.free(entries);

    for (entries) |e| {
        const full_path = if (mem.eql(u8, current_dir, ".") or current_dir.len == 0)
            e.name
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, e.name });
        defer {
            if (current_dir.len > 0 and !mem.eql(u8, current_dir, ".")) {
                allocator.free(full_path);
            }
        }

        try walk_fn(full_path, e);

        if (e.is_dir) {
            try walkDirInternal(fs, allocator, full_path, walk_fn);
        }
    }
}

fn cleanPath(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and (p[0] == '/' or p[0] == '.')) {
        if (p.len >= 2 and p[0] == '.' and p[1] == '/') {
            p = p[2..];
        } else if (p[0] == '/') {
            p = p[1..];
        } else {
            break;
        }
    }
    while (p.len > 0 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }
    return p;
}

fn baseName(path: []const u8) []const u8 {
    if (mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

test "io/fs MapFS read, stat, and walkDir" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mfs = MapFS.init(allocator);
    defer mfs.deinit();

    try mfs.addFile("README.md", "# Project Documentation");
    try mfs.addFile("src/main.zig", "pub fn main() void {}");
    try mfs.addFile("src/util/helper.zig", "pub fn help() void {}");
    try mfs.addFile("assets/config.json", "{\"port\": 8080}");

    // Test readFile
    const content = try mfs.readFile("README.md");
    try testing.expectEqualStrings("# Project Documentation", content);

    const helper = try mfs.readFile("src/util/helper.zig");
    try testing.expectEqualStrings("pub fn help() void {}", helper);

    // Test stat
    const st_file = try mfs.stat("assets/config.json");
    try testing.expectEqualStrings("config.json", st_file.name);
    try testing.expect(!st_file.is_dir);
    try testing.expectEqual(@as(u64, 14), st_file.size);

    const st_dir = try mfs.stat("src");
    try testing.expectEqualStrings("src", st_dir.name);
    try testing.expect(st_dir.is_dir);

    // Test readDir root
    const root_entries = try mfs.readDir(allocator, ".");
    defer allocator.free(root_entries);
    try testing.expectEqual(@as(usize, 3), root_entries.len); // README.md, src, assets

    // Test walkDir
    const Walker = struct {
        var count: usize = 0;
        fn walk(_: []const u8, _: DirEntry) anyerror!void {
            count += 1;
        }
    };
    Walker.count = 0;
    try walkDir(mfs, allocator, ".", Walker.walk);
    // Root (.) + README.md + src + main.zig + util + helper.zig + assets + config.json = 8 items
    try testing.expectEqual(@as(usize, 8), Walker.count);
}
