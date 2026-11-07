pub const flag = @import("flag/flag.zig");

pub const FlagSet = flag.FlagSet;
pub const Flag = flag.Flag;
pub const ValueType = flag.ValueType;
pub const Error = flag.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = flag;
}
