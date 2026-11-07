pub const tabwriter = @import("text/tabwriter.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = tabwriter;
}
