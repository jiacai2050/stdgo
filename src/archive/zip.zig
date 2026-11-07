pub const struct_mod = @import("zip/struct.zig");
pub const reader = @import("zip/reader.zig");
pub const writer = @import("zip/writer.zig");

pub const Method = struct_mod.Method;
pub const FileHeader = struct_mod.FileHeader;
pub const Reader = reader.Reader;
pub const File = reader.File;
pub const Writer = writer.Writer;
pub const Error = reader.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = struct_mod;
    _ = reader;
    _ = writer;
}
