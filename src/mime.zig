pub const multipart = @import("mime/multipart.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = multipart;
}
