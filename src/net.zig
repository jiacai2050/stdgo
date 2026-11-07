pub const url = @import("net/url.zig");
pub const http = @import("net/http.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = url;
    _ = http;
}
