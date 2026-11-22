const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const ELFMAG = "\x7fELF";

pub const Class = enum(u8) {
    none = 0,
    elf32 = 1,
    elf64 = 2,
    _,
};

pub const Data = enum(u8) {
    none = 0,
    lsb = 1, // Little-Endian (2's complement)
    msb = 2, // Big-Endian (2's complement)
    _,
};

pub const Version = enum(u8) {
    none = 0,
    current = 1,
    _,
};

pub const OSABI = enum(u8) {
    none = 0, // System V
    hpux = 1,
    netbsd = 2,
    linux = 3,
    solaris = 6,
    aix = 7,
    irix = 8,
    freebsd = 9,
    openbsd = 12,
    arm = 97,
    standalone = 255,
    _,
};

pub const Type = enum(u16) {
    none = 0,
    rel = 1,
    exec = 2,
    dyn = 3,
    core = 4,
    _,
};

pub const Machine = enum(u16) {
    none = 0,
    sparc = 2,
    i386 = 3,
    mips = 8,
    ppc = 20,
    ppc64 = 21,
    s390 = 22,
    arm = 40,
    ia64 = 50,
    x86_64 = 62,
    aarch64 = 183,
    riscv = 243,
    bpf = 247,
    loongarch = 258,
    _,
};

pub const SectionType = enum(u32) {
    null = 0,
    progbits = 1,
    symtab = 2,
    strtab = 3,
    rela = 4,
    hash = 5,
    dynamic = 6,
    note = 7,
    nobits = 8,
    rel = 9,
    shlib = 10,
    dynsym = 11,
    init_array = 14,
    fini_array = 15,
    _,
};

pub const SectionFlag = u64;
pub const SHF_WRITE: SectionFlag = 0x1;
pub const SHF_ALLOC: SectionFlag = 0x2;
pub const SHF_EXECINSTR: SectionFlag = 0x4;
pub const SHF_MERGE: SectionFlag = 0x10;
pub const SHF_STRINGS: SectionFlag = 0x20;
pub const SHF_INFO_LINK: SectionFlag = 0x40;

pub const ProgType = enum(u32) {
    null = 0,
    load = 1,
    dynamic = 2,
    interp = 3,
    note = 4,
    shlib = 5,
    phdr = 6,
    tls = 7,
    gnu_eh_frame = 0x6474e550,
    gnu_stack = 0x6474e551,
    gnu_relro = 0x6474e552,
    _,
};

pub const ProgFlag = u32;
pub const PF_X: ProgFlag = 0x1;
pub const PF_W: ProgFlag = 0x2;
pub const PF_R: ProgFlag = 0x4;

pub const SymBind = enum(u4) {
    local = 0,
    global = 1,
    weak = 2,
    _,
};

pub const SymType = enum(u4) {
    notype = 0,
    object = 1,
    func = 2,
    section = 3,
    file = 4,
    common = 5,
    tls = 6,
    _,
};

pub const FileHeader = struct {
    class: Class,
    data: Data,
    version: Version,
    osabi: OSABI,
    abiversion: u8,
    byte_order: std.builtin.Endian,
    type: Type,
    machine: Machine,
    entry: u64,
};

pub const SectionHeader = struct {
    name: []const u8,
    type: SectionType,
    flags: SectionFlag,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

pub const Section = struct {
    header: SectionHeader,
    data: []const u8,

    pub fn dataAlloc(self: *const Section, alloc: Allocator) ![]u8 {
        return alloc.dupe(u8, self.data);
    }
};

pub const ProgHeader = struct {
    type: ProgType,
    flags: ProgFlag,
    off: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};

pub const Prog = struct {
    header: ProgHeader,
    data: []const u8,
};

pub const Symbol = struct {
    name: []const u8,
    info: u8,
    other: u8,
    section_index: u16,
    value: u64,
    size: u64,
    version: []const u8 = "",
    library: []const u8 = "",

    pub fn bind(self: Symbol) SymBind {
        return @fromBackingInt(@intCast(@as(u4, @truncate(self.info >> 4))));
    }

    pub fn symType(self: Symbol) SymType {
        return @fromBackingInt(@intCast(@as(u4, @truncate(self.info & 0x0f))));
    }
};

pub const FormatError = error{
    BadMagic,
    InvalidClass,
    InvalidData,
    InvalidVersion,
    UnexpectedEOF,
    InvalidSectionHeader,
    InvalidProgramHeader,
    InvalidStringTable,
};

pub const File = struct {
    allocator: Allocator,
    raw_data: []const u8,
    header: FileHeader,
    sections: []Section,
    progs: []Prog,

    pub fn parse(allocator: Allocator, data: []const u8) !*File {
        if (data.len < 16) return FormatError.UnexpectedEOF;
        if (!mem.eql(u8, data[0..4], ELFMAG)) return FormatError.BadMagic;

        const class: Class = @fromBackingInt(@intCast(data[4]));
        if (class != .elf32 and class != .elf64) return FormatError.InvalidClass;

        const data_enc: Data = @fromBackingInt(@intCast(data[5]));
        const endian: std.builtin.Endian = switch (data_enc) {
            .lsb => .little,
            .msb => .big,
            else => return FormatError.InvalidData,
        };

        const version: Version = @fromBackingInt(@intCast(data[6]));
        const osabi: OSABI = @fromBackingInt(@intCast(data[7]));
        const abiversion: u8 = data[8];

        var f = try allocator.create(File);
        errdefer allocator.destroy(f);

        f.* = .{
            .allocator = allocator,
            .raw_data = data,
            .header = undefined,
            .sections = &.{},
            .progs = &.{},
        };

        var type_raw: u16 = undefined;
        var machine_raw: u16 = undefined;
        var entry: u64 = 0;
        var phoff: u64 = 0;
        var shoff: u64 = 0;
        var phentsize: u16 = 0;
        var phnum: u16 = 0;
        var shentsize: u16 = 0;
        var shnum: u16 = 0;
        var shstrndx: u16 = 0;

        if (class == .elf32) {
            if (data.len < 52) return FormatError.UnexpectedEOF;
            type_raw = mem.readInt(u16, data[16..18], endian);
            machine_raw = mem.readInt(u16, data[18..20], endian);
            entry = mem.readInt(u32, data[24..28], endian);
            phoff = mem.readInt(u32, data[28..32], endian);
            shoff = mem.readInt(u32, data[32..36], endian);
            phentsize = mem.readInt(u16, data[42..44], endian);
            phnum = mem.readInt(u16, data[44..46], endian);
            shentsize = mem.readInt(u16, data[46..48], endian);
            shnum = mem.readInt(u16, data[48..50], endian);
            shstrndx = mem.readInt(u16, data[50..52], endian);
        } else {
            // elf64
            if (data.len < 64) return FormatError.UnexpectedEOF;
            type_raw = mem.readInt(u16, data[16..18], endian);
            machine_raw = mem.readInt(u16, data[18..20], endian);
            entry = mem.readInt(u64, data[24..32], endian);
            phoff = mem.readInt(u64, data[32..40], endian);
            shoff = mem.readInt(u64, data[40..48], endian);
            phentsize = mem.readInt(u16, data[54..56], endian);
            phnum = mem.readInt(u16, data[56..58], endian);
            shentsize = mem.readInt(u16, data[58..60], endian);
            shnum = mem.readInt(u16, data[60..62], endian);
            shstrndx = mem.readInt(u16, data[62..64], endian);
        }

        f.header = .{
            .class = class,
            .data = data_enc,
            .version = version,
            .osabi = osabi,
            .abiversion = abiversion,
            .byte_order = endian,
            .type = @fromBackingInt(@intCast(type_raw)),
            .machine = @fromBackingInt(@intCast(machine_raw)),
            .entry = entry,
        };

        // Parse section headers
        const total_sh_size = std.math.mul(usize, shnum, shentsize) catch {
            return FormatError.UnexpectedEOF;
        };
        if (shoff > data.len or data.len - shoff < total_sh_size) return FormatError.UnexpectedEOF;

        const sections = try allocator.alloc(Section, shnum);
        errdefer allocator.free(sections);

        var sh_name_offsets = try allocator.alloc(u32, shnum);
        defer allocator.free(sh_name_offsets);

        for (0..shnum) |i| {
            const off = shoff + i * shentsize;
            if (class == .elf32) {
                if (off + 40 > data.len) return FormatError.InvalidSectionHeader;
                const sh = data[off .. off + 40];
                const name_off = mem.readInt(u32, sh[0..4], endian);
                const raw_shtype = mem.readInt(u32, sh[4..8], endian);
                const shtype: SectionType = @fromBackingInt(@intCast(raw_shtype));
                const flags = mem.readInt(u32, sh[8..12], endian);
                const addr = mem.readInt(u32, sh[12..16], endian);
                const offset = mem.readInt(u32, sh[16..20], endian);
                const size = mem.readInt(u32, sh[20..24], endian);
                const link = mem.readInt(u32, sh[24..28], endian);
                const info = mem.readInt(u32, sh[28..32], endian);
                const addralign = mem.readInt(u32, sh[32..36], endian);
                const entsize = mem.readInt(u32, sh[36..40], endian);

                const has_data = shtype != .nobits and
                    offset <= data.len and
                    size <= data.len - offset;
                const sec_data = if (has_data)
                    data[offset .. offset + size]
                else
                    &.{};

                sections[i] = .{
                    .header = .{
                        .name = "",
                        .type = shtype,
                        .flags = flags,
                        .addr = addr,
                        .offset = offset,
                        .size = size,
                        .link = link,
                        .info = info,
                        .addralign = addralign,
                        .entsize = entsize,
                    },
                    .data = sec_data,
                };
                sh_name_offsets[i] = name_off;
            } else {
                // elf64
                if (off + 64 > data.len) return FormatError.InvalidSectionHeader;
                const sh = data[off .. off + 64];
                const name_off = mem.readInt(u32, sh[0..4], endian);
                const raw_shtype = mem.readInt(u32, sh[4..8], endian);
                const shtype: SectionType = @fromBackingInt(@intCast(raw_shtype));
                const flags = mem.readInt(u64, sh[8..16], endian);
                const addr = mem.readInt(u64, sh[16..24], endian);
                const offset = mem.readInt(u64, sh[24..32], endian);
                const size = mem.readInt(u64, sh[32..40], endian);
                const link = mem.readInt(u32, sh[40..44], endian);
                const info = mem.readInt(u32, sh[44..48], endian);
                const addralign = mem.readInt(u64, sh[48..56], endian);
                const entsize = mem.readInt(u64, sh[56..64], endian);

                const has_data = shtype != .nobits and
                    offset <= data.len and
                    size <= data.len - offset;
                const sec_data = if (has_data)
                    data[offset .. offset + size]
                else
                    &.{};

                sections[i] = .{
                    .header = .{
                        .name = "",
                        .type = shtype,
                        .flags = flags,
                        .addr = addr,
                        .offset = offset,
                        .size = size,
                        .link = link,
                        .info = info,
                        .addralign = addralign,
                        .entsize = entsize,
                    },
                    .data = sec_data,
                };
                sh_name_offsets[i] = name_off;
            }
        }

        // Resolve section names via shstrtab
        if (shstrndx < shnum) {
            const shstrtab = sections[shstrndx].data;
            for (sections, 0..) |*sec, i| {
                const name_off = sh_name_offsets[i];
                if (name_off < shstrtab.len) {
                    sec.header.name = mem.sliceTo(shstrtab[name_off..], 0);
                }
            }
        }

        f.sections = sections;

        // Parse program headers
        const total_ph_size = std.math.mul(usize, phnum, phentsize) catch {
            return FormatError.UnexpectedEOF;
        };
        if (phoff > data.len or data.len - phoff < total_ph_size) return FormatError.UnexpectedEOF;

        const progs = try allocator.alloc(Prog, phnum);
        errdefer allocator.free(progs);

        for (0..phnum) |i| {
            const off = phoff + i * phentsize;
            if (class == .elf32) {
                if (off + 32 > data.len) return FormatError.InvalidProgramHeader;
                const ph = data[off .. off + 32];
                const raw_ptype = mem.readInt(u32, ph[0..4], endian);
                const ptype: ProgType = @fromBackingInt(@intCast(raw_ptype));
                const poffset = mem.readInt(u32, ph[4..8], endian);
                const vaddr = mem.readInt(u32, ph[8..12], endian);
                const paddr = mem.readInt(u32, ph[12..16], endian);
                const filesz = mem.readInt(u32, ph[16..20], endian);
                const memsz = mem.readInt(u32, ph[20..24], endian);
                const flags = mem.readInt(u32, ph[24..28], endian);
                const palign = mem.readInt(u32, ph[28..32], endian);

                const prog_data = if (poffset <= data.len and filesz <= data.len - poffset)
                    data[poffset .. poffset + filesz]
                else
                    &.{};
                progs[i] = .{
                    .header = .{
                        .type = ptype,
                        .flags = flags,
                        .off = poffset,
                        .vaddr = vaddr,
                        .paddr = paddr,
                        .filesz = filesz,
                        .memsz = memsz,
                        .@"align" = palign,
                    },
                    .data = prog_data,
                };
            } else {
                // elf64
                if (off + 56 > data.len) return FormatError.InvalidProgramHeader;
                const ph = data[off .. off + 56];
                const raw_ptype = mem.readInt(u32, ph[0..4], endian);
                const ptype: ProgType = @fromBackingInt(@intCast(raw_ptype));
                const flags = mem.readInt(u32, ph[4..8], endian);
                const poffset = mem.readInt(u64, ph[8..16], endian);
                const vaddr = mem.readInt(u64, ph[16..24], endian);
                const paddr = mem.readInt(u64, ph[24..32], endian);
                const filesz = mem.readInt(u64, ph[32..40], endian);
                const memsz = mem.readInt(u64, ph[40..48], endian);
                const palign = mem.readInt(u64, ph[48..56], endian);

                const prog_data = if (poffset <= data.len and filesz <= data.len - poffset)
                    data[poffset .. poffset + filesz]
                else
                    &.{};
                progs[i] = .{
                    .header = .{
                        .type = ptype,
                        .flags = flags,
                        .off = poffset,
                        .vaddr = vaddr,
                        .paddr = paddr,
                        .filesz = filesz,
                        .memsz = memsz,
                        .@"align" = palign,
                    },
                    .data = prog_data,
                };
            }
        }

        f.progs = progs;
        return f;
    }

    pub fn deinit(self: *File) void {
        self.allocator.free(self.sections);
        self.allocator.free(self.progs);
        self.allocator.destroy(self);
    }

    pub fn section(self: *const File, name: []const u8) ?*const Section {
        for (self.sections) |*sec| {
            if (mem.eql(u8, sec.header.name, name)) {
                return sec;
            }
        }
        return null;
    }

    /// Read static symbol table (.symtab with .strtab)
    pub fn symbols(self: *const File, alloc: Allocator) ![]Symbol {
        return self.getSymbols(alloc, .symtab);
    }

    /// Read dynamic symbol table (.dynsym with .dynstr)
    pub fn dynamicSymbols(self: *const File, alloc: Allocator) ![]Symbol {
        return self.getSymbols(alloc, .dynsym);
    }

    fn getSymbols(self: *const File, alloc: Allocator, sym_type: SectionType) ![]Symbol {
        var sym_sec: ?*const Section = null;
        for (self.sections) |*sec| {
            if (sec.header.type == sym_type) {
                sym_sec = sec;
                break;
            }
        }
        const s = sym_sec orelse return alloc.alloc(Symbol, 0);

        if (s.header.link >= self.sections.len) return FormatError.InvalidStringTable;
        const strtab = self.sections[s.header.link].data;

        const endian = self.header.byte_order;
        const is64 = (self.header.class == .elf64);
        const entsize: usize = if (is64) 24 else 16;
        if (s.data.len % entsize != 0) return FormatError.UnexpectedEOF;

        const count = s.data.len / entsize;
        var syms = try alloc.alloc(Symbol, count);
        errdefer alloc.free(syms);

        for (0..count) |i| {
            const raw = s.data[i * entsize .. (i + 1) * entsize];
            if (is64) {
                const name_off = mem.readInt(u32, raw[0..4], endian);
                const info = raw[4];
                const other = raw[5];
                const shndx = mem.readInt(u16, raw[6..8], endian);
                const value = mem.readInt(u64, raw[8..16], endian);
                const size = mem.readInt(u64, raw[16..24], endian);
                const name = if (name_off < strtab.len) mem.sliceTo(strtab[name_off..], 0) else "";

                syms[i] = .{
                    .name = name,
                    .info = info,
                    .other = other,
                    .section_index = shndx,
                    .value = value,
                    .size = size,
                };
            } else {
                const name_off = mem.readInt(u32, raw[0..4], endian);
                const value = mem.readInt(u32, raw[4..8], endian);
                const size = mem.readInt(u32, raw[8..12], endian);
                const info = raw[12];
                const other = raw[13];
                const shndx = mem.readInt(u16, raw[14..16], endian);
                const name = if (name_off < strtab.len) mem.sliceTo(strtab[name_off..], 0) else "";

                syms[i] = .{
                    .name = name,
                    .info = info,
                    .other = other,
                    .section_index = shndx,
                    .value = value,
                    .size = size,
                };
            }
        }

        return syms;
    }
};

test "parse minimal synthetic ELF64 file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Build a minimal valid 64-bit Little-Endian ELF buffer
    var elf_buf: [512]u8 = @splat(0);

    // Ident
    @memcpy(elf_buf[0..4], ELFMAG);
    elf_buf[4] = 2; // ELFCLASS64
    elf_buf[5] = 1; // ELFDATA2LSB
    elf_buf[6] = 1; // EV_CURRENT
    elf_buf[7] = 3; // ELFOSABI_LINUX
    elf_buf[8] = 0; // ABIVersion

    // Type ET_EXEC (2), Machine EM_X86_64 (62)
    mem.writeInt(u16, elf_buf[16..18], 2, .little);
    mem.writeInt(u16, elf_buf[18..20], 62, .little);
    // Version 1
    mem.writeInt(u32, elf_buf[20..24], 1, .little);
    // Entry point 0x401000
    mem.writeInt(u64, elf_buf[24..32], 0x401000, .little);

    // Section header offset = 64, shentsize = 64, shnum = 4, shstrndx = 1
    mem.writeInt(u64, elf_buf[40..48], 64, .little);
    mem.writeInt(u16, elf_buf[58..60], 64, .little);
    mem.writeInt(u16, elf_buf[60..62], 4, .little);
    mem.writeInt(u16, elf_buf[62..64], 1, .little);

    // Section 0: SHT_NULL (offset 64..128)
    // Section 1: .shstrtab (offset 128..192) -> located at 320, size 32
    const s1 = elf_buf[128..192];
    mem.writeInt(u32, s1[0..4], 1, .little); // name offset = 1 (".shstrtab")
    mem.writeInt(u32, s1[4..8], 3, .little); // SHT_STRTAB = 3
    mem.writeInt(u64, s1[24..32], 320, .little); // offset = 320
    mem.writeInt(u64, s1[32..40], 32, .little); // size = 32

    // Section 2: .symtab (offset 192..256) -> located at 360, size 48 (2 syms: null + main),
    // link = 3 (.strtab)
    const s2 = elf_buf[192..256];
    mem.writeInt(u32, s2[0..4], 11, .little); // name offset = 11 (".symtab")
    mem.writeInt(u32, s2[4..8], 2, .little); // SHT_SYMTAB = 2
    mem.writeInt(u64, s2[24..32], 360, .little); // offset = 360
    mem.writeInt(u64, s2[32..40], 48, .little); // size = 48 (2 * 24 bytes)
    mem.writeInt(u32, s2[40..44], 3, .little); // link = 3 (.strtab)
    mem.writeInt(u64, s2[56..64], 24, .little); // entsize = 24

    // Section 3: .strtab (offset 256..320) -> located at 420, size 16
    const s3 = elf_buf[256..320];
    mem.writeInt(u32, s3[0..4], 19, .little); // name offset = 19 (".strtab")
    mem.writeInt(u32, s3[4..8], 3, .little); // SHT_STRTAB = 3
    mem.writeInt(u64, s3[24..32], 420, .little); // offset = 420
    mem.writeInt(u64, s3[32..40], 16, .little); // size = 16

    // shstrtab content at offset 320: "\x00.shstrtab\x00.symtab\x00.strtab\x00"
    const shstrtab_data = "\x00.shstrtab\x00.symtab\x00.strtab\x00";
    @memcpy(elf_buf[320 .. 320 + shstrtab_data.len], shstrtab_data);

    // .symtab content at offset 360:
    // Sym 0: null (24 bytes zero)
    // Sym 1: name_off = 1 ("main"), info = 0x12 (STB_GLOBAL << 4 | STT_FUNC),
    // shndx = 1, value = 0x401000, size = 64
    const sym1 = elf_buf[384..408];
    mem.writeInt(u32, sym1[0..4], 1, .little); // name offset = 1
    sym1[4] = 0x12; // STB_GLOBAL (1) + STT_FUNC (2)
    mem.writeInt(u16, sym1[6..8], 1, .little); // shndx = 1
    mem.writeInt(u64, sym1[8..16], 0x401000, .little); // value
    mem.writeInt(u64, sym1[16..24], 64, .little); // size

    // .strtab content at offset 420: "\x00main\x00"
    const strtab_data = "\x00main\x00";
    @memcpy(elf_buf[420 .. 420 + strtab_data.len], strtab_data);

    var f = try File.parse(alloc, &elf_buf);
    defer f.deinit();

    try testing.expectEqual(Class.elf64, f.header.class);
    try testing.expectEqual(Data.lsb, f.header.data);
    try testing.expectEqual(Type.exec, f.header.type);
    try testing.expectEqual(Machine.x86_64, f.header.machine);
    try testing.expectEqual(@as(u64, 0x401000), f.header.entry);

    try testing.expectEqual(@as(usize, 4), f.sections.len);
    const shstrtab_sec = f.section(".shstrtab");
    try testing.expect(shstrtab_sec != null);

    const symtab_sec = f.section(".symtab");
    try testing.expect(symtab_sec != null);

    // Test Symbol extraction
    const syms = try f.symbols(alloc);
    defer alloc.free(syms);

    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("main", syms[1].name);
    try testing.expectEqual(SymBind.global, syms[1].bind());
    try testing.expectEqual(SymType.func, syms[1].symType());
    try testing.expectEqual(@as(u64, 0x401000), syms[1].value);
    try testing.expectEqual(@as(u64, 64), syms[1].size);
}

test "parse minimal synthetic ELF32 file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var elf_buf: [256]u8 = @splat(0);

    // Ident
    @memcpy(elf_buf[0..4], ELFMAG);
    elf_buf[4] = 1; // ELFCLASS32
    elf_buf[5] = 1; // ELFDATA2LSB
    elf_buf[6] = 1; // EV_CURRENT
    elf_buf[7] = 0; // ELFOSABI_NONE

    // Type ET_DYN (3), Machine EM_ARM (40)
    mem.writeInt(u16, elf_buf[16..18], 3, .little);
    mem.writeInt(u16, elf_buf[18..20], 40, .little);
    mem.writeInt(u32, elf_buf[20..24], 1, .little);
    mem.writeInt(u32, elf_buf[24..28], 0x8000, .little);

    // Section header offset = 52, shentsize = 40, shnum = 1, shstrndx = 0
    mem.writeInt(u32, elf_buf[32..36], 52, .little);
    mem.writeInt(u16, elf_buf[46..48], 40, .little);
    mem.writeInt(u16, elf_buf[48..50], 1, .little);
    mem.writeInt(u16, elf_buf[50..52], 0, .little);

    var f = try File.parse(alloc, &elf_buf);
    defer f.deinit();

    try testing.expectEqual(Class.elf32, f.header.class);
    try testing.expectEqual(Type.dyn, f.header.type);
    try testing.expectEqual(Machine.arm, f.header.machine);
    try testing.expectEqual(@as(u64, 0x8000), f.header.entry);
}
