const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Magic32: u32 = 0xfeedface;
pub const Magic64: u32 = 0xfeedfacf;
pub const MagicFat: u32 = 0xcafebabe;

const cpuArch64: u32 = 0x01000000;

pub const Cpu = enum(u32) {
    i386 = 7,
    amd64 = 7 | cpuArch64,
    arm = 12,
    arm64 = 12 | cpuArch64,
    ppc = 18,
    ppc64 = 18 | cpuArch64,
    _,
};

pub const Type = enum(u32) {
    obj = 1,
    exec = 2,
    dylib = 6,
    bundle = 8,
    _,
};

pub const LoadCmd = enum(u32) {
    segment = 0x1,
    symtab = 0x2,
    thread = 0x4,
    unix_thread = 0x5,
    dysymtab = 0xb,
    load_dylib = 0xc,
    id_dylib = 0xd,
    segment_64 = 0x19,
    rpath = 0x8000001c,
    _,
};

pub const FileHeader = struct {
    magic: u32,
    cpu: Cpu,
    subcpu: u32,
    type: Type,
    ncmd: u32,
    sizeofcmds: u32,
    flags: u32,
};

pub const SectionHeader = struct {
    name: []const u8,
    seg: []const u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
};

pub const Section = struct {
    header: SectionHeader,
    data: []const u8,

    pub fn dataAlloc(self: *const Section, alloc: Allocator) ![]u8 {
        return alloc.dupe(u8, self.data);
    }
};

pub const SegmentHeader = struct {
    cmd: LoadCmd,
    len: u32,
    name: []const u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: u32,
    initprot: u32,
    nsects: u32,
    flags: u32,
};

pub const Segment = struct {
    header: SegmentHeader,
    data: []const u8,
};

pub const Symbol = struct {
    name: []const u8,
    type: u8,
    sect: u8,
    desc: u16,
    value: u64,
};

pub const FatArch = struct {
    cpu: Cpu,
    subcpu: u32,
    offset: u32,
    size: u32,
    @"align": u32,
};

pub const FormatError = error{
    BadMagic,
    UnexpectedEOF,
    InvalidLoadCommand,
    InvalidSegment,
    InvalidSection,
};

pub const File = struct {
    allocator: Allocator,
    raw_data: []const u8,
    header: FileHeader,
    byte_order: std.builtin.Endian,
    segments: []Segment,
    sections: []Section,
    dylibs: [][]const u8,

    symtab_off: u32 = 0,
    symtab_num: u32 = 0,
    strtab_off: u32 = 0,
    strtab_size: u32 = 0,

    pub fn parse(allocator: Allocator, data: []const u8) !*File {
        if (data.len < 28) return FormatError.UnexpectedEOF;

        var endian: std.builtin.Endian = .little;
        const magic_le = mem.readInt(u32, data[0..4], .little);
        const magic_be = mem.readInt(u32, data[0..4], .big);

        var magic: u32 = undefined;
        var is64 = false;

        if (magic_le == Magic32) {
            magic = Magic32;
            endian = .little;
            is64 = false;
        } else if (magic_be == Magic32) {
            magic = Magic32;
            endian = .big;
            is64 = false;
        } else if (magic_le == Magic64) {
            magic = Magic64;
            endian = .little;
            is64 = true;
        } else if (magic_be == Magic64) {
            magic = Magic64;
            endian = .big;
            is64 = true;
        } else {
            return FormatError.BadMagic;
        }

        const min_header_size: usize = if (is64) 32 else 28;
        if (data.len < min_header_size) return FormatError.UnexpectedEOF;

        const cpu_raw = mem.readInt(u32, data[4..8], endian);
        const subcpu = mem.readInt(u32, data[8..12], endian);
        const type_raw = mem.readInt(u32, data[12..16], endian);
        const ncmd = mem.readInt(u32, data[16..20], endian);
        const sizeofcmds = mem.readInt(u32, data[20..24], endian);
        const flags = mem.readInt(u32, data[24..28], endian);

        var f = try allocator.create(File);
        f.* = .{
            .allocator = allocator,
            .raw_data = data,
            .header = .{
                .magic = magic,
                .cpu = @fromBackingInt(@intCast(cpu_raw)),
                .subcpu = subcpu,
                .type = @fromBackingInt(@intCast(type_raw)),
                .ncmd = ncmd,
                .sizeofcmds = sizeofcmds,
                .flags = flags,
            },
            .byte_order = endian,
            .segments = &.{},
            .sections = &.{},
            .dylibs = &.{},
        };
        errdefer f.deinit();

        var segments_list = std.ArrayListUnmanaged(Segment).empty;
        errdefer segments_list.deinit(allocator);

        var sections_list = std.ArrayListUnmanaged(Section).empty;
        errdefer sections_list.deinit(allocator);

        var dylibs_list = std.ArrayListUnmanaged([]const u8).empty;
        errdefer dylibs_list.deinit(allocator);

        var offset = min_header_size;
        for (0..ncmd) |_| {
            if (offset > data.len or data.len - offset < 8) break;
            const cmd_raw = mem.readInt(u32, data[offset..][0..4], endian);
            const cmd_len = mem.readInt(u32, data[offset + 4 ..][0..4], endian);
            if (cmd_len < 8 or cmd_len > data.len - offset) return FormatError.InvalidLoadCommand;

            const cmd: LoadCmd = @fromBackingInt(@intCast(cmd_raw));
            const cmd_data = data[offset .. offset + cmd_len];

            switch (cmd) {
                .segment => {
                    // 32-bit segment (56 bytes header)
                    if (cmd_data.len < 56) return FormatError.InvalidSegment;
                    const segname = cleanCString(cmd_data[8..24]);
                    const vmaddr = mem.readInt(u32, cmd_data[24..28], endian);
                    const vmsize = mem.readInt(u32, cmd_data[28..32], endian);
                    const fileoff = mem.readInt(u32, cmd_data[32..36], endian);
                    const filesize = mem.readInt(u32, cmd_data[36..40], endian);
                    const maxprot = mem.readInt(u32, cmd_data[40..44], endian);
                    const initprot = mem.readInt(u32, cmd_data[44..48], endian);
                    const nsects = mem.readInt(u32, cmd_data[48..52], endian);
                    const segflags = mem.readInt(u32, cmd_data[52..56], endian);

                    const seg_data = if (fileoff <= data.len and filesize <= data.len - fileoff)
                        data[fileoff .. @as(usize, fileoff) + @as(usize, filesize)]
                    else
                        &.{};

                    try segments_list.append(allocator, .{
                        .header = .{
                            .cmd = cmd,
                            .len = cmd_len,
                            .name = segname,
                            .vmaddr = vmaddr,
                            .vmsize = vmsize,
                            .fileoff = fileoff,
                            .filesize = filesize,
                            .maxprot = maxprot,
                            .initprot = initprot,
                            .nsects = nsects,
                            .flags = segflags,
                        },
                        .data = seg_data,
                    });

                    // Parse embedded 32-bit sections (68 bytes each)
                    var sec_off: usize = 56;
                    for (0..nsects) |_| {
                        if (sec_off > cmd_data.len or cmd_data.len - sec_off < 68) break;
                        const sec_bytes = cmd_data[sec_off .. sec_off + 68];
                        const secname = cleanCString(sec_bytes[0..16]);
                        const s_segname = cleanCString(sec_bytes[16..32]);
                        const addr = mem.readInt(u32, sec_bytes[32..36], endian);
                        const size = mem.readInt(u32, sec_bytes[36..40], endian);
                        const s_off = mem.readInt(u32, sec_bytes[40..44], endian);
                        const align_val = mem.readInt(u32, sec_bytes[44..48], endian);
                        const reloff = mem.readInt(u32, sec_bytes[48..52], endian);
                        const nreloc = mem.readInt(u32, sec_bytes[52..56], endian);
                        const s_flags = mem.readInt(u32, sec_bytes[56..60], endian);

                        const sec_data = if (s_off <= data.len and size <= data.len - s_off)
                            data[s_off .. @as(usize, s_off) + @as(usize, size)]
                        else
                            &.{};
                        try sections_list.append(allocator, .{
                            .header = .{
                                .name = secname,
                                .seg = s_segname,
                                .addr = addr,
                                .size = size,
                                .offset = s_off,
                                .@"align" = align_val,
                                .reloff = reloff,
                                .nreloc = nreloc,
                                .flags = s_flags,
                            },
                            .data = sec_data,
                        });
                        sec_off += 68;
                    }
                },
                .segment_64 => {
                    // 64-bit segment (72 bytes header)
                    if (cmd_data.len < 72) return FormatError.InvalidSegment;
                    const segname = cleanCString(cmd_data[8..24]);
                    const vmaddr = mem.readInt(u64, cmd_data[24..32], endian);
                    const vmsize = mem.readInt(u64, cmd_data[32..40], endian);
                    const fileoff = mem.readInt(u64, cmd_data[40..48], endian);
                    const filesize = mem.readInt(u64, cmd_data[48..56], endian);
                    const maxprot = mem.readInt(u32, cmd_data[56..60], endian);
                    const initprot = mem.readInt(u32, cmd_data[60..64], endian);
                    const nsects = mem.readInt(u32, cmd_data[64..68], endian);
                    const segflags = mem.readInt(u32, cmd_data[68..72], endian);

                    const seg_data = if (fileoff <= data.len and
                        filesize <= data.len - @as(usize, @intCast(fileoff)))
                    blk: {
                        const fo: usize = @intCast(fileoff);
                        const fs: usize = @intCast(filesize);
                        break :blk data[fo .. fo + fs];
                    } else &.{};

                    try segments_list.append(allocator, .{
                        .header = .{
                            .cmd = cmd,
                            .len = cmd_len,
                            .name = segname,
                            .vmaddr = vmaddr,
                            .vmsize = vmsize,
                            .fileoff = fileoff,
                            .filesize = filesize,
                            .maxprot = maxprot,
                            .initprot = initprot,
                            .nsects = nsects,
                            .flags = segflags,
                        },
                        .data = seg_data,
                    });

                    // Parse embedded 64-bit sections (80 bytes each)
                    var sec_off: usize = 72;
                    for (0..nsects) |_| {
                        if (sec_off > cmd_data.len or cmd_data.len - sec_off < 80) break;
                        const sec_bytes = cmd_data[sec_off .. sec_off + 80];
                        const secname = cleanCString(sec_bytes[0..16]);
                        const s_segname = cleanCString(sec_bytes[16..32]);
                        const addr = mem.readInt(u64, sec_bytes[32..40], endian);
                        const size = mem.readInt(u64, sec_bytes[40..48], endian);
                        const s_off = mem.readInt(u32, sec_bytes[48..52], endian);
                        const align_val = mem.readInt(u32, sec_bytes[52..56], endian);
                        const reloff = mem.readInt(u32, sec_bytes[56..60], endian);
                        const nreloc = mem.readInt(u32, sec_bytes[60..64], endian);
                        const s_flags = mem.readInt(u32, sec_bytes[64..68], endian);

                        const sec_data = if (s_off <= data.len and
                            size <= data.len - @as(usize, s_off))
                        blk: {
                            const so: usize = s_off;
                            const sz: usize = @intCast(size);
                            break :blk data[so .. so + sz];
                        } else &.{};
                        try sections_list.append(allocator, .{
                            .header = .{
                                .name = secname,
                                .seg = s_segname,
                                .addr = addr,
                                .size = size,
                                .offset = s_off,
                                .@"align" = align_val,
                                .reloff = reloff,
                                .nreloc = nreloc,
                                .flags = s_flags,
                            },
                            .data = sec_data,
                        });
                        sec_off += 80;
                    }
                },
                .symtab => {
                    if (cmd_data.len >= 24) {
                        f.symtab_off = mem.readInt(u32, cmd_data[8..12], endian);
                        f.symtab_num = mem.readInt(u32, cmd_data[12..16], endian);
                        f.strtab_off = mem.readInt(u32, cmd_data[16..20], endian);
                        f.strtab_size = mem.readInt(u32, cmd_data[20..24], endian);
                    }
                },
                .load_dylib => {
                    // LC_LOAD_DYLIB: dylib string offset is at 8..12
                    if (cmd_data.len >= 24) {
                        const name_offset = mem.readInt(u32, cmd_data[8..12], endian);
                        if (name_offset < cmd_data.len) {
                            const dylib_name = cleanCString(cmd_data[name_offset..]);
                            try dylibs_list.append(allocator, dylib_name);
                        }
                    }
                },
                else => {},
            }
            offset += cmd_len;
        }

        f.segments = try segments_list.toOwnedSlice(allocator);
        f.sections = try sections_list.toOwnedSlice(allocator);
        f.dylibs = try dylibs_list.toOwnedSlice(allocator);
        return f;
    }

    pub fn deinit(self: *File) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.sections);
        self.allocator.free(self.dylibs);
        self.allocator.destroy(self);
    }

    pub fn segment(self: *const File, name: []const u8) ?*const Segment {
        for (self.segments) |*seg| {
            if (mem.eql(u8, seg.header.name, name)) return seg;
        }
        return null;
    }

    pub fn section(self: *const File, name: []const u8) ?*const Section {
        for (self.sections) |*sec| {
            if (mem.eql(u8, sec.header.name, name)) return sec;
        }
        return null;
    }

    pub fn importedLibraries(self: *const File) [][]const u8 {
        return self.dylibs;
    }

    pub fn symbols(self: *const File, alloc: Allocator) ![]Symbol {
        if (self.symtab_num == 0 or self.symtab_off == 0) return alloc.alloc(Symbol, 0);

        const endian = self.byte_order;
        const is64 = (self.header.magic == Magic64);
        const entsize: usize = if (is64) 16 else 12;

        const total_size = std.math.mul(usize, self.symtab_num, entsize) catch {
            return FormatError.UnexpectedEOF;
        };
        if (self.symtab_off > self.raw_data.len or
            self.raw_data.len - self.symtab_off < total_size)
        {
            return FormatError.UnexpectedEOF;
        }
        if (self.strtab_off > self.raw_data.len or
            self.raw_data.len - self.strtab_off < self.strtab_size)
        {
            return FormatError.UnexpectedEOF;
        }

        const strtab = self.raw_data[self.strtab_off .. self.strtab_off + self.strtab_size];
        var syms = try alloc.alloc(Symbol, self.symtab_num);
        errdefer alloc.free(syms);

        for (0..self.symtab_num) |i| {
            const entry_start = self.symtab_off + i * entsize;
            const raw = self.raw_data[entry_start .. entry_start + entsize];
            const strx = mem.readInt(u32, raw[0..4], endian);
            const n_type = raw[4];
            const n_sect = raw[5];
            const n_desc = mem.readInt(u16, raw[6..8], endian);
            const n_value = if (is64)
                mem.readInt(u64, raw[8..16], endian)
            else
                mem.readInt(u32, raw[8..12], endian);

            const name = if (strx < strtab.len) mem.sliceTo(strtab[strx..], 0) else "";
            syms[i] = .{
                .name = name,
                .type = n_type,
                .sect = n_sect,
                .desc = n_desc,
                .value = n_value,
            };
        }

        return syms;
    }
};

pub const FatFile = struct {
    allocator: Allocator,
    raw_data: []const u8,
    arches: []FatArch,

    pub fn parse(allocator: Allocator, data: []const u8) !*FatFile {
        if (data.len < 8) return FormatError.UnexpectedEOF;
        const magic = mem.readInt(u32, data[0..4], .big);
        if (magic != MagicFat) return FormatError.BadMagic;

        const narch: usize = mem.readInt(u32, data[4..8], .big);
        const req_size = std.math.mul(usize, narch, 20) catch return FormatError.UnexpectedEOF;
        if (data.len < 8 or data.len - 8 < req_size) return FormatError.UnexpectedEOF;

        var arches = try allocator.alloc(FatArch, narch);
        errdefer allocator.free(arches);

        for (0..narch) |i| {
            const raw = data[8 + i * 20 .. 8 + (i + 1) * 20];
            arches[i] = .{
                .cpu = @fromBackingInt(@intCast(mem.readInt(u32, raw[0..4], .big))),
                .subcpu = mem.readInt(u32, raw[4..8], .big),
                .offset = mem.readInt(u32, raw[8..12], .big),
                .size = mem.readInt(u32, raw[12..16], .big),
                .@"align" = mem.readInt(u32, raw[16..20], .big),
            };
        }

        const fat = try allocator.create(FatFile);
        fat.* = .{
            .allocator = allocator,
            .raw_data = data,
            .arches = arches,
        };
        return fat;
    }

    pub fn deinit(self: *FatFile) void {
        self.allocator.free(self.arches);
        self.allocator.destroy(self);
    }

    pub fn openArch(self: *const FatFile, index: usize) !*File {
        if (index >= self.arches.len) return error.IndexOutOfBounds;
        const arch = self.arches[index];
        if (arch.offset > self.raw_data.len or arch.size > self.raw_data.len - arch.offset) {
            return FormatError.UnexpectedEOF;
        }
        const start: usize = arch.offset;
        const end: usize = start + @as(usize, arch.size);
        return File.parse(self.allocator, self.raw_data[start..end]);
    }
};

fn cleanCString(raw: []const u8) []const u8 {
    return mem.sliceTo(raw, 0);
}

test "parse minimal synthetic 64-bit Mach-O file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: [512]u8 = @splat(0);

    // FileHeader (32 bytes for 64-bit)
    mem.writeInt(u32, buf[0..4], Magic64, .little);
    mem.writeInt(u32, buf[4..8], @backingInt(Cpu.arm64), .little);
    mem.writeInt(u32, buf[8..12], 0, .little); // subcpu
    mem.writeInt(u32, buf[12..16], @backingInt(Type.exec), .little);
    mem.writeInt(u32, buf[16..20], 3, .little); // 3 load commands: segment_64, symtab, load_dylib
    mem.writeInt(u32, buf[20..24], 152 + 24 + 48, .little); // sizeofcmds
    mem.writeInt(u32, buf[24..28], 0x200085, .little); // flags

    // Command 1: LC_SEGMENT_64 (72 bytes + 1 section * 80 bytes = 152 bytes) at offset 32
    const seg_cmd = buf[32 .. 32 + 152];
    mem.writeInt(u32, seg_cmd[0..4], @backingInt(LoadCmd.segment_64), .little);
    mem.writeInt(u32, seg_cmd[4..8], 152, .little); // cmdsize
    @memcpy(seg_cmd[8..14], "__TEXT");
    mem.writeInt(u64, seg_cmd[24..32], 0x100000000, .little); // vmaddr
    mem.writeInt(u64, seg_cmd[32..40], 0x4000, .little); // vmsize
    mem.writeInt(u64, seg_cmd[40..48], 0, .little); // fileoff
    mem.writeInt(u64, seg_cmd[48..56], 0x4000, .little); // filesize
    mem.writeInt(u32, seg_cmd[64..68], 1, .little); // nsects = 1

    // Section 1: __text inside __TEXT at seg_cmd[72 .. 152]
    const sec1 = seg_cmd[72..152];
    @memcpy(sec1[0..6], "__text");
    @memcpy(sec1[16..22], "__TEXT");
    mem.writeInt(u64, sec1[32..40], 0x100000f00, .little); // addr
    mem.writeInt(u64, sec1[40..48], 64, .little); // size
    mem.writeInt(u32, sec1[48..52], 256, .little); // offset

    // Command 2: LC_SYMTAB (24 bytes) at offset 32 + 152 = 184
    const sym_cmd = buf[184 .. 184 + 24];
    mem.writeInt(u32, sym_cmd[0..4], @backingInt(LoadCmd.symtab), .little);
    mem.writeInt(u32, sym_cmd[4..8], 24, .little);
    mem.writeInt(u32, sym_cmd[8..12], 300, .little); // symoff
    mem.writeInt(u32, sym_cmd[12..16], 1, .little); // nsyms = 1
    mem.writeInt(u32, sym_cmd[16..20], 350, .little); // stroff
    mem.writeInt(u32, sym_cmd[20..24], 32, .little); // strsize

    // Command 3: LC_LOAD_DYLIB (48 bytes) at offset 208
    const dylib_cmd = buf[208 .. 208 + 48];
    mem.writeInt(u32, dylib_cmd[0..4], @backingInt(LoadCmd.load_dylib), .little);
    mem.writeInt(u32, dylib_cmd[4..8], 48, .little);
    mem.writeInt(u32, dylib_cmd[8..12], 16, .little); // name offset = 16
    const dylib_name = "/usr/lib/libSystem.B.dylib\x00";
    @memcpy(dylib_cmd[16 .. 16 + dylib_name.len], dylib_name);

    // Symtab entry at 300 (16 bytes): strx = 1 ("_main"), type = 0x0f (N_SECT | N_EXT),
    // sect = 1, desc = 0, val = 0x100000f00
    const sym_entry = buf[300..316];
    mem.writeInt(u32, sym_entry[0..4], 1, .little);
    sym_entry[4] = 0x0f;
    sym_entry[5] = 1;
    mem.writeInt(u64, sym_entry[8..16], 0x100000f00, .little);

    // Strtab at 350: "\x00_main\x00"
    const strtab = "\x00_main\x00";
    @memcpy(buf[350 .. 350 + strtab.len], strtab);

    var f = try File.parse(alloc, &buf);
    defer f.deinit();

    try testing.expectEqual(Magic64, f.header.magic);
    try testing.expectEqual(Cpu.arm64, f.header.cpu);
    try testing.expectEqual(Type.exec, f.header.type);

    try testing.expectEqual(@as(usize, 1), f.segments.len);
    const text_seg = f.segment("__TEXT");
    try testing.expect(text_seg != null);
    try testing.expectEqual(@as(u64, 0x100000000), text_seg.?.header.vmaddr);

    try testing.expectEqual(@as(usize, 1), f.sections.len);
    const text_sec = f.section("__text");
    try testing.expect(text_sec != null);
    try testing.expectEqual(@as(u64, 0x100000f00), text_sec.?.header.addr);

    try testing.expectEqual(@as(usize, 1), f.importedLibraries().len);
    try testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", f.importedLibraries()[0]);

    const syms = try f.symbols(alloc);
    defer alloc.free(syms);

    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("_main", syms[0].name);
    try testing.expectEqual(@as(u64, 0x100000f00), syms[0].value);
}

test "parse minimal Fat / Universal binary header" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: [128]u8 = @splat(0);

    // MagicFat
    mem.writeInt(u32, buf[0..4], MagicFat, .big);
    mem.writeInt(u32, buf[4..8], 2, .big); // 2 architectures (x86_64 and arm64)

    // Arch 0: x86_64
    mem.writeInt(u32, buf[8..12], @backingInt(Cpu.amd64), .big);
    mem.writeInt(u32, buf[12..16], 3, .big); // subcpu
    mem.writeInt(u32, buf[16..20], 4096, .big); // offset
    mem.writeInt(u32, buf[20..24], 8192, .big); // size
    mem.writeInt(u32, buf[24..28], 12, .big); // align

    // Arch 1: arm64
    mem.writeInt(u32, buf[28..32], @backingInt(Cpu.arm64), .big);
    mem.writeInt(u32, buf[32..36], 0, .big);
    mem.writeInt(u32, buf[36..40], 16384, .big);
    mem.writeInt(u32, buf[40..44], 8192, .big);
    mem.writeInt(u32, buf[44..48], 14, .big);

    var fat = try FatFile.parse(alloc, &buf);
    defer fat.deinit();

    try testing.expectEqual(@as(usize, 2), fat.arches.len);
    try testing.expectEqual(Cpu.amd64, fat.arches[0].cpu);
    try testing.expectEqual(@as(u32, 4096), fat.arches[0].offset);

    try testing.expectEqual(Cpu.arm64, fat.arches[1].cpu);
    try testing.expectEqual(@as(u32, 16384), fat.arches[1].offset);
}
