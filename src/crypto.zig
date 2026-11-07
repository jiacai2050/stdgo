pub const md5 = @import("crypto/md5.zig");
pub const sha256 = @import("crypto/sha256.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = md5;
    _ = sha256;
}
