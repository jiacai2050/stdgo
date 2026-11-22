//! Package user allows user account lookups by name or id, conforming to Go's os/user package.
//!
//! Provides User and Group definitions, Lookup, LookupId, LookupGroup, LookupGroupId,
//! and Current. On Unix-like systems, it parses /etc/passwd and /etc/group or leverages
//! environment variables ($USER, $HOME, etc.) with TigerStyle memory safety.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const EnvironMap = std.process.Environ.Map;
const builtin = @import("builtin");
const io_mod = @import("../io.zig");

pub const UnknownUserError = error{UnknownUser};
pub const UnknownUserIdError = error{UnknownUserId};
pub const UnknownGroupError = error{UnknownGroup};
pub const UnknownGroupIdError = error{UnknownGroupId};

pub const Error = error{
    UnknownUser,
    UnknownUserId,
    UnknownGroup,
    UnknownGroupId,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
};

/// User represents a user account.
pub const User = struct {
    uid: []const u8,
    gid: []const u8,
    username: []const u8,
    name: []const u8,
    home_dir: []const u8,
    allocator: ?Allocator = null,

    pub fn deinit(self: *User) void {
        if (self.allocator) |alloc| {
            alloc.free(self.uid);
            alloc.free(self.gid);
            alloc.free(self.username);
            alloc.free(self.name);
            alloc.free(self.home_dir);
            alloc.destroy(self);
        }
    }

    /// GroupIds returns the list of group IDs that the user belongs to.
    pub fn groupIds(self: *const User, allocator: Allocator, options: Options) ![]const []const u8 {
        var gids_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (gids_list.items) |item| allocator.free(item);
            gids_list.deinit(allocator);
        }

        // 1. Primary gid is always included
        try gids_list.append(allocator, try allocator.dupe(u8, self.gid));

        // 2. Read group database to find additional groups
        const group_data = try readGroupData(allocator, options);
        defer if (group_data.allocated) allocator.free(group_data.data);

        var line_it = mem.splitScalar(u8, group_data.data, '\n');
        while (line_it.next()) |raw_line| {
            const line = mem.trim(u8, raw_line, "\r \t");
            if (line.len == 0 or line[0] == '#') continue;

            // Format: group_name:password:gid:user_list
            var part_it = mem.splitScalar(u8, line, ':');
            _ = part_it.next() orelse continue; // name
            _ = part_it.next() orelse continue; // password
            const gid_str = part_it.next() orelse continue;
            const users_str = part_it.next() orelse continue;

            var user_it = mem.splitScalar(u8, users_str, ',');
            var belongs = false;
            while (user_it.next()) |u| {
                if (mem.eql(u8, mem.trim(u8, u, " \t"), self.username)) {
                    belongs = true;
                    break;
                }
            }

            if (belongs) {
                // Ensure uniqueness
                var already_in = false;
                for (gids_list.items) |existing| {
                    if (mem.eql(u8, existing, gid_str)) {
                        already_in = true;
                        break;
                    }
                }
                if (!already_in) {
                    try gids_list.append(allocator, try allocator.dupe(u8, gid_str));
                }
            }
        }

        return try gids_list.toOwnedSlice(allocator);
    }
};

/// Group represents a grouping of users.
pub const Group = struct {
    gid: []const u8,
    name: []const u8,
    allocator: ?Allocator = null,

    pub fn deinit(self: *Group) void {
        if (self.allocator) |alloc| {
            alloc.free(self.gid);
            alloc.free(self.name);
            alloc.destroy(self);
        }
    }
};

/// Options for configuring user and group lookups.
pub const Options = struct {
    io: ?std.Io = null,
    env: ?*const EnvironMap = null,
    passwd_path: ?[]const u8 = "/etc/passwd",
    group_path: ?[]const u8 = "/etc/group",
    passwd_content: ?[]const u8 = null,
    group_content: ?[]const u8 = null,
};

const ReadResult = struct {
    data: []const u8,
    allocated: bool,
};

fn readPasswdData(allocator: Allocator, options: Options) Error!ReadResult {
    if (options.passwd_content) |c| {
        return .{ .data = c, .allocated = false };
    }
    if (options.io) |io| {
        if (options.passwd_path) |path| {
            const handle = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.UnknownUser,
                error.AccessDenied => return error.AccessDenied,
                else => return error.Unexpected,
            };
            defer handle.close(io);

            const st = handle.stat(io) catch return error.Unexpected;
            const buf = allocator.alloc(u8, @intCast(st.size)) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            var r_buf: [4096]u8 = undefined;
            var r = handle.reader(io, &r_buf);
            _ = io_mod.readFull(&r.interface, buf) catch return error.Unexpected;
            return .{ .data = buf, .allocated = true };
        }
    }
    return error.UnknownUser;
}

fn readGroupData(allocator: Allocator, options: Options) Error!ReadResult {
    if (options.group_content) |c| {
        return .{ .data = c, .allocated = false };
    }
    if (options.io) |io| {
        if (options.group_path) |path| {
            const handle = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.UnknownGroup,
                error.AccessDenied => return error.AccessDenied,
                else => return error.Unexpected,
            };
            defer handle.close(io);

            const st = handle.stat(io) catch return error.Unexpected;
            const buf = allocator.alloc(u8, @intCast(st.size)) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            var r_buf: [4096]u8 = undefined;
            var r = handle.reader(io, &r_buf);
            _ = io_mod.readFull(&r.interface, buf) catch return error.Unexpected;
            return .{ .data = buf, .allocated = true };
        }
    }
    return error.UnknownGroup;
}

fn currentUid() ?u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getuid());
    } else if (builtin.os.tag == .windows) {
        return null;
    } else if (builtin.link_libc) {
        return @intCast(std.c.getuid());
    } else {
        @compileError("stdgo.os.user: platform '" ++ @tagName(builtin.os.tag) ++
            "' requires linking libc. Please call artifact.linkLibC() in build.zig.");
    }
}

fn currentGid() ?u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getgid());
    } else if (builtin.os.tag == .windows) {
        return null;
    } else if (builtin.link_libc) {
        return @intCast(std.c.getgid());
    } else {
        @compileError("stdgo.os.user: platform '" ++ @tagName(builtin.os.tag) ++
            "' requires linking libc. Please call artifact.linkLibC() in build.zig.");
    }
}

/// Lookup looks up a user by username.
/// If the user cannot be found, the returned error is UnknownUser.
pub fn lookup(allocator: Allocator, username: []const u8, options: Options) Error!*User {
    const passwd = try readPasswdData(allocator, options);
    defer if (passwd.allocated) allocator.free(passwd.data);

    var it = mem.splitScalar(u8, passwd.data, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;

        // Format: username:password:uid:gid:gecos:home_dir:shell
        var part_it = mem.splitScalar(u8, line, ':');
        const u = part_it.next() orelse continue;
        if (!mem.eql(u8, u, username)) continue;

        _ = part_it.next() orelse continue; // password
        const uid_str = part_it.next() orelse continue;
        const gid_str = part_it.next() orelse continue;
        const gecos = part_it.next() orelse "";
        const home = part_it.next() orelse "/";

        var name = gecos;
        if (mem.indexOfScalar(u8, gecos, ',')) |comma_idx| {
            name = gecos[0..comma_idx];
        }
        if (name.len == 0) name = u;

        const user_ptr = try allocator.create(User);
        errdefer allocator.destroy(user_ptr);

        user_ptr.* = .{
            .uid = try allocator.dupe(u8, uid_str),
            .gid = try allocator.dupe(u8, gid_str),
            .username = try allocator.dupe(u8, u),
            .name = try allocator.dupe(u8, name),
            .home_dir = try allocator.dupe(u8, home),
            .allocator = allocator,
        };
        return user_ptr;
    }

    return error.UnknownUser;
}

/// LookupId looks up a user by userid.
/// If the user cannot be found, the returned error is UnknownUserId.
pub fn lookupId(allocator: Allocator, uid: []const u8, options: Options) Error!*User {
    const passwd = try readPasswdData(allocator, options);
    defer if (passwd.allocated) allocator.free(passwd.data);

    var it = mem.splitScalar(u8, passwd.data, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;

        var part_it = mem.splitScalar(u8, line, ':');
        const u = part_it.next() orelse continue;
        _ = part_it.next() orelse continue; // password
        const line_uid = part_it.next() orelse continue;
        if (!mem.eql(u8, line_uid, uid)) continue;

        const gid_str = part_it.next() orelse continue;
        const gecos = part_it.next() orelse "";
        const home = part_it.next() orelse "/";

        var name = gecos;
        if (mem.indexOfScalar(u8, gecos, ',')) |comma_idx| {
            name = gecos[0..comma_idx];
        }
        if (name.len == 0) name = u;

        const user_ptr = try allocator.create(User);
        errdefer allocator.destroy(user_ptr);

        user_ptr.* = .{
            .uid = try allocator.dupe(u8, line_uid),
            .gid = try allocator.dupe(u8, gid_str),
            .username = try allocator.dupe(u8, u),
            .name = try allocator.dupe(u8, name),
            .home_dir = try allocator.dupe(u8, home),
            .allocator = allocator,
        };
        return user_ptr;
    }

    return error.UnknownUserId;
}

/// LookupGroup looks up a group by name.
/// If the group cannot be found, the returned error is UnknownGroup.
pub fn lookupGroup(allocator: Allocator, name: []const u8, options: Options) Error!*Group {
    const group_data = try readGroupData(allocator, options);
    defer if (group_data.allocated) allocator.free(group_data.data);

    var it = mem.splitScalar(u8, group_data.data, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;

        var part_it = mem.splitScalar(u8, line, ':');
        const gname = part_it.next() orelse continue;
        if (!mem.eql(u8, gname, name)) continue;

        _ = part_it.next() orelse continue; // password
        const gid_str = part_it.next() orelse continue;

        const grp_ptr = try allocator.create(Group);
        errdefer allocator.destroy(grp_ptr);

        grp_ptr.* = .{
            .gid = try allocator.dupe(u8, gid_str),
            .name = try allocator.dupe(u8, gname),
            .allocator = allocator,
        };
        return grp_ptr;
    }

    return error.UnknownGroup;
}

/// LookupGroupId looks up a group by groupid.
/// If the group cannot be found, the returned error is UnknownGroupId.
pub fn lookupGroupId(allocator: Allocator, gid: []const u8, options: Options) Error!*Group {
    const group_data = try readGroupData(allocator, options);
    defer if (group_data.allocated) allocator.free(group_data.data);

    var it = mem.splitScalar(u8, group_data.data, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;

        var part_it = mem.splitScalar(u8, line, ':');
        const gname = part_it.next() orelse continue;
        _ = part_it.next() orelse continue; // password
        const line_gid = part_it.next() orelse continue;
        if (!mem.eql(u8, line_gid, gid)) continue;

        const grp_ptr = try allocator.create(Group);
        errdefer allocator.destroy(grp_ptr);

        grp_ptr.* = .{
            .gid = try allocator.dupe(u8, line_gid),
            .name = try allocator.dupe(u8, gname),
            .allocator = allocator,
        };
        return grp_ptr;
    }

    return error.UnknownGroupId;
}

/// Current returns the current user.
pub fn current(allocator: Allocator, options: Options) Error!*User {
    // 1. Try environment variables ($USER, $LOGNAME, $HOME) first
    // (matching Go's currentFromEnvironment)
    if (options.env) |env| {
        const env_user = env.get("USER") orelse env.get("LOGNAME") orelse env.get("USERNAME");
        const env_home = env.get("HOME") orelse env.get("USERPROFILE");

        if (env_user) |u| {
            if (lookup(allocator, u, options)) |usr| {
                if (env_home) |h| {
                    if (h.len > 0 and !mem.eql(u8, usr.home_dir, h)) {
                        allocator.free(usr.home_dir);
                        usr.home_dir = try allocator.dupe(u8, h);
                    }
                }
                return usr;
            } else |_| {
                // If not in passwd file, synthesize from environment
                const uid_num = currentUid() orelse 1000;
                const gid_num = currentGid() orelse 1000;

                var uid_buf: [16]u8 = undefined;
                var gid_buf: [16]u8 = undefined;
                const uid_s = std.fmt.bufPrint(&uid_buf, "{d}", .{uid_num}) catch "1000";
                const gid_s = std.fmt.bufPrint(&gid_buf, "{d}", .{gid_num}) catch "1000";

                const usr = try allocator.create(User);
                errdefer allocator.destroy(usr);

                usr.* = .{
                    .uid = try allocator.dupe(u8, uid_s),
                    .gid = try allocator.dupe(u8, gid_s),
                    .username = try allocator.dupe(u8, u),
                    .name = try allocator.dupe(u8, u),
                    .home_dir = try allocator.dupe(u8, env_home orelse "/"),
                    .allocator = allocator,
                };
                return usr;
            }
        }
    }

    // 2. Try current numeric UID lookup
    if (currentUid()) |c_uid| {
        var uid_buf: [16]u8 = undefined;
        const uid_s = std.fmt.bufPrint(&uid_buf, "{d}", .{c_uid}) catch "0";
        if (lookupId(allocator, uid_s, options)) |usr| {
            return usr;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }

    // 3. Fallback to root or default user
    if (lookup(allocator, "root", options)) |root_usr| {
        return root_usr;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    return error.UnknownUser;
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

const mock_passwd =
    \\# This is a comment
    \\root:x:0:0:System Administrator,Room 101,555-1234:/root:/bin/bash
    \\daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
    \\bin:x:2:2:bin:/bin:/usr/sbin/nologin
    \\gopher:x:1000:1000:Go Gopher,Gopher HQ:/home/gopher:/bin/zsh
    \\alice:x:1001:1000:Alice Smith:/home/alice:/bin/bash
    \\
;

const mock_group =
    \\# Group database
    \\root:x:0:
    \\daemon:x:1:
    \\gophers:x:1000:gopher,alice
    \\developers:x:1002:alice,bob
    \\docker:x:999:gopher
    \\
;

test "os/user lookup and lookupId" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const opts = Options{
        .passwd_content = mock_passwd,
        .group_content = mock_group,
    };

    // Lookup gopher
    const u = try lookup(allocator, "gopher", opts);
    defer u.deinit();

    try testing.expectEqualStrings("1000", u.uid);
    try testing.expectEqualStrings("1000", u.gid);
    try testing.expectEqualStrings("gopher", u.username);
    try testing.expectEqualStrings("Go Gopher", u.name); // trimmed at comma
    try testing.expectEqualStrings("/home/gopher", u.home_dir);

    // LookupId 0 (root)
    const root_u = try lookupId(allocator, "0", opts);
    defer root_u.deinit();

    try testing.expectEqualStrings("0", root_u.uid);
    try testing.expectEqualStrings("root", root_u.username);
    try testing.expectEqualStrings("System Administrator", root_u.name);
    try testing.expectEqualStrings("/root", root_u.home_dir);

    // Unknown user
    try testing.expectError(error.UnknownUser, lookup(allocator, "nonexistent", opts));
    try testing.expectError(error.UnknownUserId, lookupId(allocator, "9999", opts));
}

test "os/user lookupGroup and lookupGroupId" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const opts = Options{
        .passwd_content = mock_passwd,
        .group_content = mock_group,
    };

    const g = try lookupGroup(allocator, "developers", opts);
    defer g.deinit();

    try testing.expectEqualStrings("1002", g.gid);
    try testing.expectEqualStrings("developers", g.name);

    const g_id = try lookupGroupId(allocator, "999", opts);
    defer g_id.deinit();

    try testing.expectEqualStrings("999", g_id.gid);
    try testing.expectEqualStrings("docker", g_id.name);

    try testing.expectError(error.UnknownGroup, lookupGroup(allocator, "nonexistent", opts));
    try testing.expectError(error.UnknownGroupId, lookupGroupId(allocator, "12345", opts));
}

test "os/user User.groupIds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const opts = Options{
        .passwd_content = mock_passwd,
        .group_content = mock_group,
    };

    const u = try lookup(allocator, "gopher", opts);
    defer u.deinit();

    const gids = try u.groupIds(allocator, opts);
    defer {
        for (gids) |item| allocator.free(item);
        allocator.free(gids);
    }

    // gopher is primary in 1000, and listed in 1000 (gophers) and 999 (docker)
    try testing.expectEqual(@as(usize, 2), gids.len);
    try testing.expectEqualStrings("1000", gids[0]);
    try testing.expectEqualStrings("999", gids[1]);
}

test "os/user current with environment fallback" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("USER", "ziguser");
    try env_map.put("HOME", "/home/ziguser");

    const opts = Options{
        .env = &env_map,
        .passwd_content = mock_passwd,
        .group_content = mock_group,
    };

    const curr = try current(allocator, opts);
    defer curr.deinit();

    try testing.expectEqualStrings("ziguser", curr.username);
    try testing.expectEqualStrings("/home/ziguser", curr.home_dir);
}

test "os/user live system root lookup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const opts = Options{
        .io = threaded.io(),
    };

    if (builtin.os.tag == .windows) return;

    const root_u = try lookupId(allocator, "0", opts);
    defer root_u.deinit();
    try testing.expectEqualStrings("0", root_u.uid);
    try testing.expectEqualStrings("root", root_u.username);
}
