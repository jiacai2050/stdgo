pub const url = @import("net/url.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = url;
}
