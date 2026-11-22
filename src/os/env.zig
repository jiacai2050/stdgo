//! Port of Go's `os` environment functions with explicit dependency injection.
//!
//! Follows TigerStyle and AGENTS.md guidelines: no hidden global C `getenv()`.
//! All environment lookups require an explicit `*const std.process.Environ.Map`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

/// Getenv retrieves the value of the environment variable named by the key.
/// It returns the value, which will be empty if the variable is not present.
pub fn getenv(env: *const EnvironMap, key: []const u8) []const u8 {
    return env.get(key) orelse "";
}

/// LookupEnv retrieves the value of the environment variable named by the key.
/// If the variable is present in the environment the value (which may be empty)
/// is returned and the boolean is true. Otherwise the returned value will be empty
/// and the boolean will be false.
pub fn lookupEnv(env: *const EnvironMap, key: []const u8) ?[]const u8 {
    return env.get(key);
}

/// Environ returns a copy of strings representing the environment,
/// in the form "key=value".
pub fn environ(allocator: Allocator, env: *const EnvironMap) Allocator.Error![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var it = env.iterator();
    while (it.next()) |entry| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}={s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
        try list.append(allocator, line);
    }

    return try list.toOwnedSlice(allocator);
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "os.env: getenv and lookupEnv" {
    const testing = std.testing;

    var map = EnvironMap.init(testing.allocator);
    defer map.deinit();

    try map.put("GOPATH", "/home/gopher/go");
    try map.put("EMPTY_VAR", "");

    try testing.expectEqualStrings("/home/gopher/go", getenv(&map, "GOPATH"));
    try testing.expectEqualStrings("", getenv(&map, "NON_EXISTENT"));
    try testing.expectEqualStrings("", getenv(&map, "EMPTY_VAR"));

    try testing.expectEqualStrings("/home/gopher/go", lookupEnv(&map, "GOPATH").?);
    try testing.expectEqualStrings("", lookupEnv(&map, "EMPTY_VAR").?);
    try testing.expect(lookupEnv(&map, "NON_EXISTENT") == null);

    const env_lines = try environ(testing.allocator, &map);
    defer {
        for (env_lines) |line| testing.allocator.free(line);
        testing.allocator.free(env_lines);
    }

    try testing.expectEqual(@as(usize, 2), env_lines.len);
}
