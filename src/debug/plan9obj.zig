//! Package debug/plan9obj implements access to Plan 9 a.out object files.
//!
//! Provides parsing of 32-bit and 64-bit Plan 9 executable and object binaries,
//! extraction of standard sections (text, data, syms, spsz, pcsz),
//! and reconstruction of Plan 9 symbol tables and filename hierarchies.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Magic64 indicates an expanded 64-bit header.
pub const Magic64: u32 = 0x8000;
pub const Magic386: u32 = (4 * 11 + 0) * 11 + 7; // 0x1eb (491)
pub const MagicAMD64: u32 = (4 * 26 + 0) * 26 + 7 + Magic64; // 0x8a97
pub const MagicARM: u32 = (4 * 20 + 0) * 20 + 7; // 0x647

/// FileHeader represents a Plan 9 a.out file header.
pub const FileHeader = struct {
    magic: u32,
    bss: u32,
    entry: u64,
    ptr_size: u8,
    load_address: u64,
    hdr_size: u64,
};

/// SectionHeader represents metadata for a single Plan 9 section.
pub const SectionHeader = struct {
    name: []const u8,
    size: u32,
    offset: u32,
};

/// Section represents a single section in a Plan 9 a.out file.
pub const Section = struct {
    header: SectionHeader,
    data: []const u8,

    pub fn dataAlloc(self: Section, allocator: Allocator) ![]u8 {
        return try allocator.dupe(u8, self.data);
    }
};

/// Sym represents an entry in a Plan 9 a.out symbol table.
pub const Sym = struct {
    value: u64,
    typ: u8,
    name: []const u8,

    pub fn deinit(self: *Sym, allocator: Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// File represents an opened Plan 9 a.out binary.
pub const File = struct {
    header: FileHeader,
    sections: []Section,
    allocator: Allocator,

    pub fn deinit(self: *File) void {
        self.allocator.free(self.sections);
        self.* = undefined;
    }

    /// Parse parses a Plan 9 binary from bytes.
    pub fn parse(allocator: Allocator, bytes: []const u8) !File {
        if (bytes.len < 32) return error.UnexpectedEof;

        const magic = mem.readInt(u32, bytes[0..4], .big);
        switch (magic) {
            Magic386, MagicAMD64, MagicARM => {},
            else => return error.BadMagicNumber,
        }

        const text_sz = mem.readInt(u32, bytes[4..8], .big);
        const data_sz = mem.readInt(u32, bytes[8..12], .big);
        const bss_sz = mem.readInt(u32, bytes[12..16], .big);
        const syms_sz = mem.readInt(u32, bytes[16..20], .big);
        const entry32 = mem.readInt(u32, bytes[20..24], .big);
        const spsz_sz = mem.readInt(u32, bytes[24..28], .big);
        const pcsz_sz = mem.readInt(u32, bytes[28..32], .big);

        var entry: u64 = entry32;
        var ptr_size: u8 = 4;
        var load_address: u64 = 0x1000;
        var hdr_size: u64 = 32;

        if ((magic & Magic64) != 0) {
            if (bytes.len < 40) return error.UnexpectedEof;
            entry = mem.readInt(u64, bytes[32..40], .big);
            ptr_size = 8;
            load_address = 0x200000;
            hdr_size = 40;
        }

        const sect_meta = [_]struct { name: []const u8, size: u32 }{
            .{ .name = "text", .size = text_sz },
            .{ .name = "data", .size = data_sz },
            .{ .name = "syms", .size = syms_sz },
            .{ .name = "spsz", .size = spsz_sz },
            .{ .name = "pcsz", .size = pcsz_sz },
        };

        var sections = try allocator.alloc(Section, sect_meta.len);
        errdefer allocator.free(sections);

        var cur_offset: u32 = @intCast(hdr_size);
        for (sect_meta, 0..) |m, i| {
            const start = cur_offset;
            const end = start + m.size;
            const sect_data = if (start >= bytes.len)
                &[_]u8{}
            else if (end <= bytes.len)
                bytes[start..end]
            else
                bytes[start..bytes.len];

            sections[i] = Section{
                .header = .{
                    .name = m.name,
                    .size = m.size,
                    .offset = start,
                },
                .data = sect_data,
            };
            cur_offset = end;
        }

        return File{
            .header = .{
                .magic = magic,
                .bss = bss_sz,
                .entry = entry,
                .ptr_size = ptr_size,
                .load_address = load_address,
                .hdr_size = hdr_size,
            },
            .sections = sections,
            .allocator = allocator,
        };
    }

    pub fn section(self: File, name: []const u8) ?Section {
        for (self.sections) |s| {
            if (mem.eql(u8, s.header.name, name)) return s;
        }
        return null;
    }

    pub fn symbols(self: File, allocator: Allocator) ![]Sym {
        const sym_sec = self.section("syms") orelse return error.NoSymbols;
        return decodeSymbols(allocator, sym_sec.data, self.header.ptr_size);
    }
};

const RawSym = struct {
    value: u64,
    typ: u8,
    name: []const u8,
};

fn walksymtab(
    data: []const u8,
    ptr_size: u8,
    ctx: anytype,
    on_sym: fn (@TypeOf(ctx), RawSym) anyerror!void,
) !void {
    var p = data;
    while (p.len >= 4) {
        if (p.len < ptr_size) return error.UnexpectedEof;
        const val: u64 = if (ptr_size == 8) blk: {
            const v = mem.readInt(u64, p[0..8], .big);
            p = p[8..];
            break :blk v;
        } else blk: {
            const v = mem.readInt(u32, p[0..4], .big);
            p = p[4..];
            break :blk v;
        };

        if (p.len < 1) return error.UnexpectedEof;
        const typ = p[0] & 0x7f;
        p = p[1..];

        var i: usize = 0;
        var nnul: usize = 0;
        while (i < p.len) : (i += 1) {
            if (p[i] == 0) {
                nnul = 1;
                break;
            }
        }

        switch (typ) {
            'z', 'Z' => {
                p = p[i + nnul ..];
                i = 0;
                while (i + 2 <= p.len) : (i += 2) {
                    if (p[i] == 0 and p[i + 1] == 0) {
                        nnul = 2;
                        break;
                    }
                }
            },
            else => {},
        }

        if (p.len < i + nnul) return error.UnexpectedEof;
        const sym_name = p[0..i];
        p = p[i + nnul ..];

        try on_sym(ctx, RawSym{
            .value = val,
            .typ = typ,
            .name = sym_name,
        });
    }
}

const CountContext = struct {
    count: usize = 0,
    fn add(self: *CountContext, _: RawSym) anyerror!void {
        self.count += 1;
    }
};

const DecodeContext = struct {
    allocator: Allocator,
    syms: std.ArrayList(Sym),
    fname: std.AutoHashMap(u16, []const u8),

    fn consume(self: *DecodeContext, s: RawSym) !void {
        var name_buf = std.ArrayList(u8).empty;
        defer name_buf.deinit(self.allocator);

        switch (s.typ) {
            'z', 'Z' => {
                var idx: usize = 0;
                while (idx + 2 <= s.name.len) : (idx += 2) {
                    const elt_idx = mem.readInt(u16, s.name[idx..][0..2], .big);
                    const elt = self.fname.get(elt_idx) orelse return error.BadFilenameCode;
                    if (name_buf.items.len > 0 and name_buf.items[name_buf.items.len - 1] != '/') {
                        try name_buf.append(self.allocator, '/');
                    }
                    try name_buf.appendSlice(self.allocator, elt);
                }
            },
            else => {
                try name_buf.appendSlice(self.allocator, s.name);
            },
        }

        const final_name = try name_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(final_name);

        if (s.typ == 'f') {
            try self.fname.put(@intCast(s.value), final_name);
        }

        try self.syms.append(self.allocator, Sym{
            .value = s.value,
            .typ = s.typ,
            .name = final_name,
        });
    }
};

fn decodeSymbols(allocator: Allocator, data: []const u8, ptr_size: u8) ![]Sym {
    var count_ctx = CountContext{};
    try walksymtab(data, ptr_size, &count_ctx, CountContext.add);

    var decode_ctx = DecodeContext{
        .allocator = allocator,
        .syms = std.ArrayList(Sym).empty,
        .fname = std.AutoHashMap(u16, []const u8).init(allocator),
    };
    defer decode_ctx.fname.deinit();
    try decode_ctx.syms.ensureTotalCapacity(allocator, count_ctx.count);
    errdefer {
        for (decode_ctx.syms.items) |*s| {
            s.deinit(allocator);
        }
        decode_ctx.syms.deinit(allocator);
    }

    try walksymtab(data, ptr_size, &decode_ctx, DecodeContext.consume);
    return try decode_ctx.syms.toOwnedSlice(allocator);
}

test "plan9obj 386 header and sections parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [128]u8 = undefined;
    @memset(&buf, 0);

    // 386 magic: 0x01eb
    mem.writeInt(u32, buf[0..4], Magic386, .big);
    mem.writeInt(u32, buf[4..8], 0x4c5f, .big); // text
    mem.writeInt(u32, buf[8..12], 0x094c, .big); // data
    mem.writeInt(u32, buf[12..16], 0x0324, .big); // bss
    mem.writeInt(u32, buf[16..20], 0x20, .big); // syms
    mem.writeInt(u32, buf[20..24], 0x0014, .big); // entry
    mem.writeInt(u32, buf[24..28], 0x0000, .big); // spsz
    mem.writeInt(u32, buf[28..32], 0x0f7a, .big); // pcsz

    var file = try File.parse(allocator, &buf);
    defer file.deinit();

    try testing.expectEqual(Magic386, file.header.magic);
    try testing.expectEqual(@as(u32, 0x0324), file.header.bss);
    try testing.expectEqual(@as(u64, 0x0014), file.header.entry);
    try testing.expectEqual(@as(u8, 4), file.header.ptr_size);
    try testing.expectEqual(@as(u64, 0x1000), file.header.load_address);
    try testing.expectEqual(@as(u64, 32), file.header.hdr_size);

    try testing.expectEqual(@as(usize, 5), file.sections.len);
    const text = file.section("text") orelse return error.TestExpectedNotNull;
    try testing.expectEqual(@as(u32, 0x4c5f), text.header.size);
    try testing.expectEqual(@as(u32, 0x20), text.header.offset);

    const data = file.section("data") orelse return error.TestExpectedNotNull;
    try testing.expectEqual(@as(u32, 0x094c), data.header.size);
    try testing.expectEqual(@as(u32, 0x20 + 0x4c5f), data.header.offset);
}

test "plan9obj amd64 header parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [128]u8 = undefined;
    @memset(&buf, 0);

    // AMD64 magic: 0x8a97
    mem.writeInt(u32, buf[0..4], MagicAMD64, .big);
    mem.writeInt(u32, buf[4..8], 0x4213, .big); // text
    mem.writeInt(u32, buf[8..12], 0x0a80, .big); // data
    mem.writeInt(u32, buf[12..16], 0x0618, .big); // bss
    mem.writeInt(u32, buf[16..20], 0x10, .big); // syms
    mem.writeInt(u32, buf[20..24], 0x0013, .big); // entry (lower)
    mem.writeInt(u32, buf[24..28], 0x0000, .big); // spsz
    mem.writeInt(u32, buf[28..32], 0x0ca0, .big); // pcsz
    mem.writeInt(u64, buf[32..40], 0x0013, .big); // 64-bit entry

    var file = try File.parse(allocator, &buf);
    defer file.deinit();

    try testing.expectEqual(MagicAMD64, file.header.magic);
    try testing.expectEqual(@as(u32, 0x0618), file.header.bss);
    try testing.expectEqual(@as(u64, 0x0013), file.header.entry);
    try testing.expectEqual(@as(u8, 8), file.header.ptr_size);
    try testing.expectEqual(@as(u64, 0x200000), file.header.load_address);
    try testing.expectEqual(@as(u64, 40), file.header.hdr_size);
}

test "plan9obj symbols decoding and path resolution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Build synthetic symbol table in 32-bit mode
    var sym_buf = std.ArrayList(u8).empty;
    defer sym_buf.deinit(allocator);

    // 1. Symbol 'T' (text function main): value = 0x1020, name = "main\0"
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x10, 0x20 }); // val
    try sym_buf.append(allocator, 'T');
    try sym_buf.appendSlice(allocator, "main\x00");

    // 2. Symbol 'f' (file path component 1): value = 1, name = "src\0"
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 });
    try sym_buf.append(allocator, 'f');
    try sym_buf.appendSlice(allocator, "src\x00");

    // 3. Symbol 'f' (file path component 2): value = 2, name = "main.go\0"
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x02 });
    try sym_buf.append(allocator, 'f');
    try sym_buf.appendSlice(allocator, "main.go\x00");

    // 4. Symbol 'z' (path concatenation of 1 and 2):
    // value = 0, initial nul, then uint16(1), uint16(2), then double nul (0x00, 0x00)
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try sym_buf.append(allocator, 'z');
    try sym_buf.append(allocator, 0x00); // initial nul
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x01, 0x00, 0x02 }); // indices 1, 2
    try sym_buf.appendSlice(allocator, &[_]u8{ 0x00, 0x00 }); // double nul

    const syms = try decodeSymbols(allocator, sym_buf.items, 4);
    defer {
        for (syms) |*s| s.deinit(allocator);
        allocator.free(syms);
    }

    try testing.expectEqual(@as(usize, 4), syms.len);
    try testing.expectEqualStrings("main", syms[0].name);
    try testing.expectEqual(@as(u64, 0x1020), syms[0].value);
    try testing.expectEqual(@as(u8, 'T'), syms[0].typ);

    try testing.expectEqualStrings("src", syms[1].name);
    try testing.expectEqualStrings("main.go", syms[2].name);
    try testing.expectEqualStrings("src/main.go", syms[3].name);
}

test "plan9obj arm and file.symbols() end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_buf = std.ArrayList(u8).empty;
    defer file_buf.deinit(allocator);

    // Build complete ARM Plan 9 binary
    // Header: 32 bytes
    var hdr_buf: [32]u8 = undefined;
    @memset(&hdr_buf, 0);
    mem.writeInt(u32, hdr_buf[0..4], MagicARM, .big);
    mem.writeInt(u32, hdr_buf[4..8], 16, .big); // text 16 bytes
    mem.writeInt(u32, hdr_buf[8..12], 8, .big); // data 8 bytes
    mem.writeInt(u32, hdr_buf[12..16], 32, .big); // bss 32 bytes

    // Prepare syms section data
    var sym_raw = std.ArrayList(u8).empty;
    defer sym_raw.deinit(allocator);

    // Symbol 'd' (data): value = 0x2000, name = "g_val\0"
    try sym_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x20, 0x00 });
    try sym_raw.append(allocator, 'd');
    try sym_raw.appendSlice(allocator, "g_val\x00");

    mem.writeInt(u32, hdr_buf[16..20], @intCast(sym_raw.items.len), .big); // syms length
    mem.writeInt(u32, hdr_buf[20..24], 0x1000, .big); // entry
    mem.writeInt(u32, hdr_buf[24..28], 0, .big); // spsz
    mem.writeInt(u32, hdr_buf[28..32], 0, .big); // pcsz

    try file_buf.appendSlice(allocator, &hdr_buf);
    try file_buf.appendSlice(allocator, "0123456789abcdef"); // 16 bytes text
    try file_buf.appendSlice(allocator, "data1234"); // 8 bytes data
    try file_buf.appendSlice(allocator, sym_raw.items); // syms data

    var file = try File.parse(allocator, file_buf.items);
    defer file.deinit();

    try testing.expectEqual(MagicARM, file.header.magic);
    try testing.expectEqual(@as(u64, 0x1000), file.header.entry);

    const syms = try file.symbols(allocator);
    defer {
        for (syms) |*s| s.deinit(allocator);
        allocator.free(syms);
    }

    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("g_val", syms[0].name);
    try testing.expectEqual(@as(u64, 0x2000), syms[0].value);
    try testing.expectEqual(@as(u8, 'd'), syms[0].typ);
}
