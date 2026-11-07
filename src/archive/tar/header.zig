const std = @import("std");

pub const block_size: usize = 512;

pub const TypeFlag = enum(u8) {
    reg = '0',
    link = '1',
    symlink = '2',
    char = '3',
    block = '4',
    dir = '5',
    fifo = '6',
    cont = '7',
    _,
};

pub const Header = struct {
    name: []const u8,
    mode: u32 = 0o644,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    mtime: i64 = 0,
    typeflag: TypeFlag = .reg,
    linkname: []const u8 = "",
    uname: []const u8 = "",
    gname: []const u8 = "",

    pub fn formatBlock(self: *const Header, block: *[block_size]u8) void {
        @memset(block, 0);

        // Name (100)
        const name_len = @min(self.name.len, 100);
        @memcpy(block[0..name_len], self.name[0..name_len]);

        // Mode (8)
        formatOctal(block[100..108], self.mode);
        // UID (8)
        formatOctal(block[108..116], self.uid);
        // GID (8)
        formatOctal(block[116..124], self.gid);
        // Size (12)
        formatOctal(block[124..136], self.size);
        // Mtime (12)
        formatOctal(block[136..148], @as(u64, @intCast(@max(0, self.mtime))));

        // Typeflag
        block[156] = @intFromEnum(self.typeflag);

        // Linkname (100)
        const link_len = @min(self.linkname.len, 100);
        const link_start: usize = 157;
        @memcpy(block[link_start .. link_start + link_len], self.linkname[0..link_len]);

        // Magic "ustar\0"
        @memcpy(block[257..263], "ustar\x00");
        // Version "00"
        @memcpy(block[263..265], "00");

        // Checksum calculation (treat chksum field 148..156 as 8 spaces)
        @memset(block[148..156], ' ');
        var sum: u32 = 0;
        for (block) |b| {
            sum += b;
        }

        // Format checksum into block[148..156]: 6 octal digits + null + space
        formatChecksum(block[148..156], sum);
    }

    pub fn parseBlock(block: *const [block_size]u8, name_buf: *[100]u8) ?Header {
        // Check if all zero block
        var all_zero = true;
        for (block) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return null;

        // Parse name
        var name_len: usize = 0;
        while (name_len < 100 and block[name_len] != 0) : (name_len += 1) {}
        @memcpy(name_buf[0..name_len], block[0..name_len]);

        const mode = parseOctal(block[100..108]) orelse 0o644;
        const uid = parseOctal(block[108..116]) orelse 0;
        const gid = parseOctal(block[116..124]) orelse 0;
        const size = parseOctal(block[124..136]) orelse 0;
        const mtime = parseOctal(block[136..148]) orelse 0;
        const typeflag: TypeFlag = @enumFromInt(block[156]);

        return Header{
            .name = name_buf[0..name_len],
            .mode = @intCast(mode),
            .uid = @intCast(uid),
            .gid = @intCast(gid),
            .size = size,
            .mtime = @intCast(mtime),
            .typeflag = typeflag,
        };
    }
};

fn formatOctal(dest: []u8, val: u64) void {
    @memset(dest, 0);
    if (dest.len == 0) return;
    var v = val;
    var i = dest.len - 1;
    dest[i] = 0; // null terminator or space
    while (i > 0) {
        i -= 1;
        dest[i] = @as(u8, @intCast(v & 7)) + '0';
        v >>= 3;
    }
}

fn formatChecksum(dest: []u8, val: u32) void {
    @memset(dest, 0);
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{o:0>6}\x00 ", .{val}) catch return;
    const n = @min(dest.len, str.len);
    @memcpy(dest[0..n], str[0..n]);
}

fn parseOctal(src: []const u8) ?u64 {
    const s = std.mem.trim(u8, src, " \x00");
    if (s.len == 0) return 0;
    var val: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') break;
        val = (val << 3) | (c - '0');
    }
    return val;
}
