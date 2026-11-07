pub const header = @import("tar/header.zig");
pub const writer = @import("tar/writer.zig");
pub const reader = @import("tar/reader.zig");

pub const Header = header.Header;
pub const TypeFlag = header.TypeFlag;
pub const block_size = header.block_size;

pub const Writer = writer.Writer;
pub const Reader = reader.Reader;

test {
    @import("std").testing.refAllDecls(@This());
    _ = header;
    _ = writer;
    _ = reader;
}
