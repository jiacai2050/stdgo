const std = @import("std");

pub const file_header_signature = 0x04034b50;
pub const directory_header_signature = 0x02014b50;
pub const directory_end_signature = 0x06054b50;

pub const file_header_len = 30;
pub const directory_header_len = 46;
pub const directory_end_len = 22;

pub const Method = enum(u16) {
    store = 0,
    deflate = 8,
};

pub const FileHeader = struct {
    name: []const u8,
    comment: []const u8 = "",
    method: Method = .store,
    crc32: u32 = 0,
    compressed_size: u32 = 0,
    uncompressed_size: u32 = 0,
    offset: u32 = 0, // offset of local file header
};
