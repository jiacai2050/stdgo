pub const match_mod = @import("path/match.zig");
pub const match = match_mod.match;
pub const Error = match_mod.Error;

pub const filepath = @import("path/filepath.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = match_mod;
    _ = filepath;
}
