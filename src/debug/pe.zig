const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D; // "MZ"
pub const IMAGE_NT_SIGNATURE: u32 = 0x00004550; // "PE\0\0"

pub const Machine = enum(u16) {
    unknown = 0x0,
    am33 = 0x1d3,
    amd64 = 0x8664,
    arm = 0x1c0,
    armnt = 0x1c4,
    arm64 = 0xaa64,
    ebc = 0xebc,
    i386 = 0x14c,
    ia64 = 0x200,
    loongarch32 = 0x6232,
    loongarch64 = 0x6264,
    riscv32 = 0x5032,
    riscv64 = 0x5064,
    _,
};

pub const Subsystem = enum(u16) {
    unknown = 0,
    native = 1,
    windows_gui = 2,
    windows_cui = 3,
    posix_cui = 7,
    windows_ce_gui = 9,
    efi_application = 10,
    efi_boot_service_driver = 11,
    efi_runtime_driver = 12,
    efi_rom = 13,
    xbox = 14,
    _,
};

pub const OptionalHeaderMagic = enum(u16) {
    pe32 = 0x10b,
    pe32_plus = 0x20b, // 64-bit
    rom = 0x107,
    _,
};

pub const FileHeader = struct {
    machine: Machine,
    number_of_sections: u16,
    time_date_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

pub const DataDirectory = struct {
    virtual_address: u32,
    size: u32,
};

pub const OptionalHeader = struct {
    magic: OptionalHeaderMagic,
    major_linker_version: u8,
    minor_linker_version: u8,
    size_of_code: u32,
    size_of_initialized_data: u32,
    size_of_uninitialized_data: u32,
    address_of_entry_point: u32,
    base_of_code: u32,
    image_base: u64,
    section_alignment: u32,
    file_alignment: u32,
    subsystem: Subsystem,
    dll_characteristics: u16,
    data_directories: [16]DataDirectory,
};

pub const SectionHeader = struct {
    name: []const u8,
    virtual_size: u32,
    virtual_address: u32,
    size: u32,
    offset: u32,
    pointer_to_relocations: u32,
    pointer_to_linenumbers: u32,
    number_of_relocations: u16,
    number_of_linenumbers: u16,
    characteristics: u32,
};

pub const Section = struct {
    header: SectionHeader,
    data: []const u8,

    pub fn dataAlloc(self: *const Section, alloc: Allocator) ![]u8 {
        return alloc.dupe(u8, self.data);
    }
};

pub const COFFSymbol = struct {
    name: []const u8,
    value: u32,
    section_number: i16,
    type: u16,
    storage_class: u8,
};

pub const FormatError = error{
    BadDosSignature,
    BadPeSignature,
    InvalidOptionalHeader,
    InvalidSectionHeader,
    UnexpectedEOF,
};

pub const File = struct {
    allocator: Allocator,
    raw_data: []const u8,
    file_header: FileHeader,
    optional_header: ?OptionalHeader,
    sections: []Section,

    pub fn parse(allocator: Allocator, data: []const u8) !*File {
        if (data.len < 64) return FormatError.UnexpectedEOF;

        // Check DOS Header ("MZ")
        const dos_magic = mem.readInt(u16, data[0..2], .little);
        if (dos_magic != IMAGE_DOS_SIGNATURE) return FormatError.BadDosSignature;

        // e_lfanew is at 0x3c (60)
        const pe_offset = mem.readInt(u32, data[0x3c..0x40], .little);
        if (pe_offset > data.len or data.len - pe_offset < 24) return FormatError.UnexpectedEOF;

        // Check PE signature ("PE\0\0")
        const pe_sig = mem.readInt(u32, data[pe_offset..][0..4], .little);
        if (pe_sig != IMAGE_NT_SIGNATURE) return FormatError.BadPeSignature;

        // COFF File Header (20 bytes starting at pe_offset + 4)
        const coff_raw = data[@as(usize, pe_offset) + 4 .. @as(usize, pe_offset) + 24];
        const machine_raw = mem.readInt(u16, coff_raw[0..2], .little);
        const num_sections = mem.readInt(u16, coff_raw[2..4], .little);
        const time_date = mem.readInt(u32, coff_raw[4..8], .little);
        const symtab_ptr = mem.readInt(u32, coff_raw[8..12], .little);
        const num_syms = mem.readInt(u32, coff_raw[12..16], .little);
        const opt_size = mem.readInt(u16, coff_raw[16..18], .little);
        const chars = mem.readInt(u16, coff_raw[18..20], .little);

        const file_hdr = FileHeader{
            .machine = @fromBackingInt(@intCast(machine_raw)),
            .number_of_sections = num_sections,
            .time_date_stamp = time_date,
            .pointer_to_symbol_table = symtab_ptr,
            .number_of_symbols = num_syms,
            .size_of_optional_header = opt_size,
            .characteristics = chars,
        };

        var opt_header: ?OptionalHeader = null;
        const opt_offset: usize = @as(usize, pe_offset) + 24;

        if (opt_size >= 28 and opt_offset <= data.len and opt_size <= data.len - opt_offset) {
            const opt_data = data[opt_offset .. opt_offset + opt_size];
            const magic_raw = mem.readInt(u16, opt_data[0..2], .little);
            const opt_magic: OptionalHeaderMagic = @fromBackingInt(@intCast(magic_raw));

            const major_linker = opt_data[2];
            const minor_linker = opt_data[3];
            const size_of_code = mem.readInt(u32, opt_data[4..8], .little);
            const size_of_init = mem.readInt(u32, opt_data[8..12], .little);
            const size_of_uninit = mem.readInt(u32, opt_data[12..16], .little);
            const entry_point = mem.readInt(u32, opt_data[16..20], .little);
            const base_of_code = mem.readInt(u32, opt_data[20..24], .little);

            var image_base: u64 = 0;
            var sec_align: u32 = 0;
            var file_align: u32 = 0;
            var subsystem: Subsystem = .unknown;
            var dll_chars: u16 = 0;
            var ddir: [16]DataDirectory = @splat(.{ .virtual_address = 0, .size = 0 });

            if (opt_magic == .pe32) {
                // PE32 (32-bit)
                if (opt_data.len >= 72) {
                    image_base = mem.readInt(u32, opt_data[28..32], .little);
                    sec_align = mem.readInt(u32, opt_data[32..36], .little);
                    file_align = mem.readInt(u32, opt_data[36..40], .little);
                    const raw_subsys = mem.readInt(u16, opt_data[68..70], .little);
                    subsystem = @fromBackingInt(@intCast(raw_subsys));
                    dll_chars = mem.readInt(u16, opt_data[70..72], .little);

                    // Data directories at offset 96 (each 8 bytes)
                    if (opt_data.len >= 96) {
                        const num_rva = mem.readInt(u32, opt_data[92..96], .little);
                        const count = @min(16, num_rva);
                        for (0..count) |i| {
                            const d_off = 96 + i * 8;
                            if (d_off <= opt_data.len and opt_data.len - d_off >= 8) {
                                ddir[i] = .{
                                    .virtual_address = mem.readInt(
                                        u32,
                                        opt_data[d_off..][0..4],
                                        .little,
                                    ),
                                    .size = mem.readInt(u32, opt_data[d_off + 4 ..][0..4], .little),
                                };
                            }
                        }
                    }
                }
            } else if (opt_magic == .pe32_plus) {
                // PE32+ (64-bit)
                if (opt_data.len >= 72) {
                    image_base = mem.readInt(u64, opt_data[24..32], .little);
                    sec_align = mem.readInt(u32, opt_data[32..36], .little);
                    file_align = mem.readInt(u32, opt_data[36..40], .little);
                    const raw_subsys = mem.readInt(u16, opt_data[68..70], .little);
                    subsystem = @fromBackingInt(@intCast(raw_subsys));
                    dll_chars = mem.readInt(u16, opt_data[70..72], .little);

                    // Data directories at offset 112 (each 8 bytes)
                    if (opt_data.len >= 112) {
                        const num_rva = mem.readInt(u32, opt_data[108..112], .little);
                        const count = @min(16, num_rva);
                        for (0..count) |i| {
                            const d_off = 112 + i * 8;
                            if (d_off <= opt_data.len and opt_data.len - d_off >= 8) {
                                ddir[i] = .{
                                    .virtual_address = mem.readInt(
                                        u32,
                                        opt_data[d_off..][0..4],
                                        .little,
                                    ),
                                    .size = mem.readInt(u32, opt_data[d_off + 4 ..][0..4], .little),
                                };
                            }
                        }
                    }
                }
            }

            opt_header = .{
                .magic = opt_magic,
                .major_linker_version = major_linker,
                .minor_linker_version = minor_linker,
                .size_of_code = size_of_code,
                .size_of_initialized_data = size_of_init,
                .size_of_uninitialized_data = size_of_uninit,
                .address_of_entry_point = entry_point,
                .base_of_code = base_of_code,
                .image_base = image_base,
                .section_alignment = sec_align,
                .file_alignment = file_align,
                .subsystem = subsystem,
                .dll_characteristics = dll_chars,
                .data_directories = ddir,
            };
        }

        // Section Headers (40 bytes each) right after Optional Header
        const sec_headers_off = std.math.add(usize, opt_offset, opt_size) catch {
            return FormatError.InvalidSectionHeader;
        };
        var sections = try allocator.alloc(Section, num_sections);
        errdefer allocator.free(sections);

        for (0..num_sections) |i| {
            const sh_off = std.math.add(usize, sec_headers_off, i * 40) catch {
                return FormatError.InvalidSectionHeader;
            };
            if (sh_off > data.len or data.len - sh_off < 40) {
                return FormatError.InvalidSectionHeader;
            }
            const sh_data = data[sh_off .. sh_off + 40];

            const sec_name = cleanString(sh_data[0..8]);
            const virt_size = mem.readInt(u32, sh_data[8..12], .little);
            const virt_addr = mem.readInt(u32, sh_data[12..16], .little);
            const raw_size = mem.readInt(u32, sh_data[16..20], .little);
            const raw_off = mem.readInt(u32, sh_data[20..24], .little);
            const relocs_ptr = mem.readInt(u32, sh_data[24..28], .little);
            const linenums_ptr = mem.readInt(u32, sh_data[28..32], .little);
            const num_relocs = mem.readInt(u16, sh_data[32..34], .little);
            const num_linenums = mem.readInt(u16, sh_data[34..36], .little);
            const sec_chars = mem.readInt(u32, sh_data[36..40], .little);

            const sec_payload = if (raw_off <= data.len and raw_size <= data.len - raw_off)
                data[raw_off .. @as(usize, raw_off) + @as(usize, raw_size)]
            else
                &.{};

            sections[i] = .{
                .header = .{
                    .name = sec_name,
                    .virtual_size = virt_size,
                    .virtual_address = virt_addr,
                    .size = raw_size,
                    .offset = raw_off,
                    .pointer_to_relocations = relocs_ptr,
                    .pointer_to_linenumbers = linenums_ptr,
                    .number_of_relocations = num_relocs,
                    .number_of_linenumbers = num_linenums,
                    .characteristics = sec_chars,
                },
                .data = sec_payload,
            };
        }

        const f = try allocator.create(File);
        f.* = .{
            .allocator = allocator,
            .raw_data = data,
            .file_header = file_hdr,
            .optional_header = opt_header,
            .sections = sections,
        };
        return f;
    }

    pub fn deinit(self: *File) void {
        self.allocator.free(self.sections);
        self.allocator.destroy(self);
    }

    pub fn section(self: *const File, name: []const u8) ?*const Section {
        for (self.sections) |*sec| {
            if (mem.eql(u8, sec.header.name, name)) return sec;
        }
        return null;
    }

    /// Read COFF symbol table
    pub fn symbols(self: *const File, alloc: Allocator) ![]COFFSymbol {
        if (self.file_header.number_of_symbols == 0 or
            self.file_header.pointer_to_symbol_table == 0)
        {
            return alloc.alloc(COFFSymbol, 0);
        }

        const sym_off: usize = self.file_header.pointer_to_symbol_table;
        const sym_cnt: usize = self.file_header.number_of_symbols;
        const total_size = std.math.mul(usize, sym_cnt, 18) catch return FormatError.UnexpectedEOF;

        if (sym_off > self.raw_data.len or total_size > self.raw_data.len - sym_off) {
            return FormatError.UnexpectedEOF;
        }

        // String table is immediately after the COFF symbols
        const strtab_off = sym_off + total_size;
        var strtab: []const u8 = &.{};
        if (strtab_off <= self.raw_data.len and self.raw_data.len - strtab_off >= 4) {
            const strtab_size = mem.readInt(u32, self.raw_data[strtab_off..][0..4], .little);
            if (strtab_size >= 4 and strtab_size <= self.raw_data.len - strtab_off) {
                strtab = self.raw_data[strtab_off .. strtab_off + strtab_size];
            }
        }

        var syms = try alloc.alloc(COFFSymbol, sym_cnt);
        errdefer alloc.free(syms);

        for (0..sym_cnt) |i| {
            const raw = self.raw_data[sym_off + i * 18 .. sym_off + (i + 1) * 18];
            var sym_name: []const u8 = "";

            if (raw[0] == 0 and raw[1] == 0 and raw[2] == 0 and raw[3] == 0) {
                // Name is offset into string table
                const name_offset = mem.readInt(u32, raw[4..8], .little);
                if (name_offset < strtab.len) {
                    sym_name = mem.sliceTo(strtab[name_offset..], 0);
                }
            } else {
                sym_name = cleanString(raw[0..8]);
            }

            const val = mem.readInt(u32, raw[8..12], .little);
            const sec_num = mem.readInt(i16, raw[12..14], .little);
            const sym_type = mem.readInt(u16, raw[14..16], .little);
            const storage = raw[16];

            syms[i] = .{
                .name = sym_name,
                .value = val,
                .section_number = sec_num,
                .type = sym_type,
                .storage_class = storage,
            };
        }

        return syms;
    }
};

fn cleanString(raw: []const u8) []const u8 {
    return mem.sliceTo(raw, 0);
}

test "parse minimal synthetic Windows PE64 file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: [512]u8 = @splat(0);

    // DOS Header: "MZ" at 0, e_lfanew = 128 at 0x3c
    mem.writeInt(u16, buf[0..2], IMAGE_DOS_SIGNATURE, .little);
    mem.writeInt(u32, buf[0x3c..0x40], 128, .little);

    // PE Header at offset 128: "PE\0\0"
    mem.writeInt(u32, buf[128..132], IMAGE_NT_SIGNATURE, .little);

    // COFF Header (20 bytes) at 132
    mem.writeInt(u16, buf[132..134], @backingInt(Machine.amd64), .little); // Machine AMD64
    mem.writeInt(u16, buf[134..136], 1, .little); // 1 section
    mem.writeInt(u32, buf[136..140], 1700000000, .little); // Timestamp
    mem.writeInt(u16, buf[148..150], 112, .little); // opt header size = 112 (PE32+)
    mem.writeInt(u16, buf[150..152], 0x0022, .little); // Executable + Large address aware

    // Optional Header (PE32+ magic = 0x20b) at 152
    mem.writeInt(u16, buf[152..154], @backingInt(OptionalHeaderMagic.pe32_plus), .little);
    mem.writeInt(u32, buf[168..172], 0x1000, .little); // Address of entry point = 0x1000
    mem.writeInt(u64, buf[176..184], 0x140000000, .little); // ImageBase = 0x140000000
    mem.writeInt(u32, buf[184..188], 0x1000, .little); // Section alignment = 4096
    mem.writeInt(u32, buf[188..192], 0x200, .little); // File alignment = 512
    mem.writeInt(u16, buf[220..222], @backingInt(Subsystem.windows_cui), .little); // Windows CUI

    // Section 1 Header at 152 + 112 = 264 (40 bytes)
    const sec = buf[264..304];
    @memcpy(sec[0..5], ".text");
    mem.writeInt(u32, sec[8..12], 0x200, .little); // VirtualSize
    mem.writeInt(u32, sec[12..16], 0x1000, .little); // VirtualAddress
    mem.writeInt(u32, sec[16..20], 64, .little); // SizeOfRawData = 64
    mem.writeInt(u32, sec[20..24], 320, .little); // PointerToRawData
    // Characteristics: Code + Executable + Readable
    mem.writeInt(u32, sec[36..40], 0x60000020, .little);

    // Section data at offset 320 (e.g. x86_64 nop ret: 0x90, 0xc3)
    buf[320] = 0x90;
    buf[321] = 0xc3;

    var pe_file = try File.parse(alloc, &buf);
    defer pe_file.deinit();

    try testing.expectEqual(Machine.amd64, pe_file.file_header.machine);
    try testing.expectEqual(@as(u16, 1), pe_file.file_header.number_of_sections);

    try testing.expect(pe_file.optional_header != null);
    const opt = pe_file.optional_header.?;
    try testing.expectEqual(OptionalHeaderMagic.pe32_plus, opt.magic);
    try testing.expectEqual(@as(u64, 0x140000000), opt.image_base);
    try testing.expectEqual(@as(u32, 0x1000), opt.address_of_entry_point);
    try testing.expectEqual(Subsystem.windows_cui, opt.subsystem);

    try testing.expectEqual(@as(usize, 1), pe_file.sections.len);
    const text_sec = pe_file.section(".text");
    try testing.expect(text_sec != null);
    try testing.expectEqual(@as(u32, 0x1000), text_sec.?.header.virtual_address);
    try testing.expectEqual(@as(u8, 0x90), text_sec.?.data[0]);
    try testing.expectEqual(@as(u8, 0xc3), text_sec.?.data[1]);
}
