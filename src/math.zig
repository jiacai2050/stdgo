pub const rand = @import("math/rand.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = rand;
}
