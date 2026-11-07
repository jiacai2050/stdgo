pub const hash = @import("hash/hash.zig");

pub const Hash = hash.Hash;

test {
    @import("std").testing.refAllDecls(@This());
    _ = hash;
}
