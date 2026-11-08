pub const slog = @import("log/slog.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = slog;
}
