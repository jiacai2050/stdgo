const std = @import("std");
const match_mod = @import("match.zig");

pub const match = match_mod.match;
pub const Error = match_mod.Error;

/// separator is the OS-specific path separator.
pub const separator: u8 = if (@import("builtin").os.tag == .windows) '\\' else '/';

test "filepath match" {
    const testing = std.testing;
    try testing.expect(try match("*.tar.gz", "archive.tar.gz"));
    try testing.expect(!try match("*.tar.gz", "archive.zip"));
}
