pub const reader_mod = @import("bufio/reader.zig");
pub const writer_mod = @import("bufio/writer.zig");
pub const scan_mod = @import("bufio/scan.zig");

pub const Reader = reader_mod.Reader;
pub const default_buf_size = reader_mod.default_buf_size;
pub const Error = reader_mod.Error;

pub const Writer = writer_mod.Writer;

pub const Scanner = scan_mod.Scanner;
pub const SplitFunc = scan_mod.SplitFunc;
pub const SplitResult = scan_mod.SplitResult;
pub const scanLines = scan_mod.scanLines;
pub const scanWords = scan_mod.scanWords;

test {
    @import("std").testing.refAllDecls(@This());
    _ = reader_mod;
    _ = writer_mod;
    _ = scan_mod;
}
