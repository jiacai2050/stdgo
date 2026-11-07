pub const gzip = @import("compress/gzip.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = gzip;
}
