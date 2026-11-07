pub const regexp = @import("regexp/regexp.zig");

pub const Regexp = regexp.Regexp;
pub const compile = regexp.Regexp.compile;
pub const mustCompile = regexp.Regexp.mustCompile;
pub const Error = regexp.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = regexp;
}
