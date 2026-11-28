//! Package debug/dwarf provides access to DWARF debugging information loaded from executable files.
//!
//! Implements DWARF 2 through DWARF 5 standards, LEB128 decoding, .debug_abbrev parsing,
//! Compilation Unit (CU) headers, DIE tree navigation (Reader, next, skipChildren, seek),
//! and attribute extraction with .debug_str resolution.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// DWARF Tags
pub const TagArrayType: u32 = 0x01;
pub const TagClassType: u32 = 0x02;
pub const TagEntryPoint: u32 = 0x03;
pub const TagEnumerationType: u32 = 0x04;
pub const TagFormalParameter: u32 = 0x05;
pub const TagImportedDeclaration: u32 = 0x08;
pub const TagLabel: u32 = 0x0a;
pub const TagLexicalBlock: u32 = 0x0b;
pub const TagMember: u32 = 0x0d;
pub const TagPointerType: u32 = 0x0f;
pub const TagReferenceType: u32 = 0x10;
pub const TagCompileUnit: u32 = 0x11;
pub const TagStringType: u32 = 0x12;
pub const TagStructType: u32 = 0x13;
pub const TagSubroutineType: u32 = 0x15;
pub const TagTypedef: u32 = 0x16;
pub const TagUnionType: u32 = 0x17;
pub const TagUnspecifiedParameters: u32 = 0x18;
pub const TagVariant: u32 = 0x19;
pub const TagCommonBlock: u32 = 0x1a;
pub const TagCommonInclusion: u32 = 0x1b;
pub const TagInheritance: u32 = 0x1c;
pub const TagInlinedSubroutine: u32 = 0x1d;
pub const TagModule: u32 = 0x1e;
pub const TagPtrToMemberType: u32 = 0x1f;
pub const TagSetType: u32 = 0x20;
pub const TagSubrangeType: u32 = 0x21;
pub const TagWithStmt: u32 = 0x22;
pub const TagAccessDeclaration: u32 = 0x23;
pub const TagBaseType: u32 = 0x24;
pub const TagCatchBlock: u32 = 0x25;
pub const TagConstType: u32 = 0x26;
pub const TagConstant: u32 = 0x27;
pub const TagEnumerator: u32 = 0x28;
pub const TagFileType: u32 = 0x29;
pub const TagFriend: u32 = 0x2a;
pub const TagNamelist: u32 = 0x2b;
pub const TagNamelistItem: u32 = 0x2c;
pub const TagPackedType: u32 = 0x2d;
pub const TagSubprogram: u32 = 0x2e;
pub const TagTemplateTypeParameter: u32 = 0x2f;
pub const TagTemplateValueParameter: u32 = 0x30;
pub const TagThrownType: u32 = 0x31;
pub const TagTryBlock: u32 = 0x32;
pub const TagVariantPart: u32 = 0x33;
pub const TagVariable: u32 = 0x34;
pub const TagVolatileType: u32 = 0x35;
pub const TagDwarfProcedure: u32 = 0x36;
pub const TagRestrictType: u32 = 0x37;
pub const TagInterfaceType: u32 = 0x38;
pub const TagNamespace: u32 = 0x39;
pub const TagImportedModule: u32 = 0x3a;
pub const TagUnspecifiedType: u32 = 0x3b;
pub const TagPartialUnit: u32 = 0x3c;
pub const TagImportedUnit: u32 = 0x3d;
pub const TagCondition: u32 = 0x3f;
pub const TagSharedType: u32 = 0x40;
pub const TagTypeUnit: u32 = 0x41;
pub const TagRvalueReferenceType: u32 = 0x42;
pub const TagTemplateAlias: u32 = 0x43;

// DWARF Attributes
pub const AttrSibling: u32 = 0x01;
pub const AttrLocation: u32 = 0x02;
pub const AttrName: u32 = 0x03;
pub const AttrOrdering: u32 = 0x09;
pub const AttrByteSize: u32 = 0x0b;
pub const AttrBitOffset: u32 = 0x0c;
pub const AttrBitSize: u32 = 0x0d;
pub const AttrStmtList: u32 = 0x10;
pub const AttrLowpc: u32 = 0x11;
pub const AttrHighpc: u32 = 0x12;
pub const AttrLanguage: u32 = 0x13;
pub const AttrDiscr: u32 = 0x15;
pub const AttrDiscrValue: u32 = 0x16;
pub const AttrVisibility: u32 = 0x17;
pub const AttrImport: u32 = 0x18;
pub const AttrStringLength: u32 = 0x19;
pub const AttrCommonRef: u32 = 0x1a;
pub const AttrCompDir: u32 = 0x1b;
pub const AttrConstValue: u32 = 0x1c;
pub const AttrContainingType: u32 = 0x1d;
pub const AttrDefaultValue: u32 = 0x1e;
pub const AttrInline: u32 = 0x20;
pub const AttrIsOptional: u32 = 0x21;
pub const AttrLowerBound: u32 = 0x22;
pub const AttrProducer: u32 = 0x25;
pub const AttrPrototyped: u32 = 0x27;
pub const AttrReturnAddr: u32 = 0x2a;
pub const AttrStartScope: u32 = 0x2c;
pub const AttrBitStride: u32 = 0x2e;
pub const AttrUpperBound: u32 = 0x2f;
pub const AttrAbstractOrigin: u32 = 0x31;
pub const AttrAccessibility: u32 = 0x32;
pub const AttrAddressClass: u32 = 0x33;
pub const AttrArtificial: u32 = 0x34;
pub const AttrBaseTypes: u32 = 0x35;
pub const AttrCallingConvention: u32 = 0x36;
pub const AttrCount: u32 = 0x37;
pub const AttrDataMemberLoc: u32 = 0x38;
pub const AttrDeclColumn: u32 = 0x39;
pub const AttrDeclFile: u32 = 0x3a;
pub const AttrDeclLine: u32 = 0x3b;
pub const AttrDeclaration: u32 = 0x3c;
pub const AttrDiscrList: u32 = 0x3d;
pub const AttrEncoding: u32 = 0x3e;
pub const AttrExternal: u32 = 0x3f;
pub const AttrFrameBase: u32 = 0x40;
pub const AttrFriend: u32 = 0x41;
pub const AttrIdentifierCase: u32 = 0x42;
pub const AttrMacroInfo: u32 = 0x43;
pub const AttrNamelistItem: u32 = 0x44;
pub const AttrPriority: u32 = 0x45;
pub const AttrSegment: u32 = 0x46;
pub const AttrSpecification: u32 = 0x47;
pub const AttrStaticLink: u32 = 0x48;
pub const AttrType: u32 = 0x49;
pub const AttrUseLocation: u32 = 0x4a;
pub const AttrVariableParameter: u32 = 0x4b;
pub const AttrVirtuality: u32 = 0x4c;
pub const AttrVtableElemLoc: u32 = 0x4d;
pub const AttrAllocated: u32 = 0x4e;
pub const AttrAssociated: u32 = 0x4f;
pub const AttrDataLocation: u32 = 0x50;
pub const AttrByteStride: u32 = 0x51;
pub const AttrEntrypc: u32 = 0x52;
pub const AttrUseUTF8: u32 = 0x53;
pub const AttrExtension: u32 = 0x54;
pub const AttrRanges: u32 = 0x55;
pub const AttrTrampoline: u32 = 0x56;
pub const AttrCallColumn: u32 = 0x57;
pub const AttrCallFile: u32 = 0x58;
pub const AttrCallLine: u32 = 0x59;
pub const AttrDescription: u32 = 0x5a;

// DWARF Forms
pub const FormAddr: u32 = 0x01;
pub const FormBlock2: u32 = 0x03;
pub const FormBlock4: u32 = 0x04;
pub const FormData2: u32 = 0x05;
pub const FormData4: u32 = 0x06;
pub const FormData8: u32 = 0x07;
pub const FormString: u32 = 0x08;
pub const FormBlock: u32 = 0x09;
pub const FormBlock1: u32 = 0x0a;
pub const FormData1: u32 = 0x0b;
pub const FormFlag: u32 = 0x0c;
pub const FormSdata: u32 = 0x0d;
pub const FormStrp: u32 = 0x0e;
pub const FormUdata: u32 = 0x0f;
pub const FormRefAddr: u32 = 0x10;
pub const FormRef1: u32 = 0x11;
pub const FormRef2: u32 = 0x12;
pub const FormRef4: u32 = 0x13;
pub const FormRef8: u32 = 0x14;
pub const FormRefUdata: u32 = 0x15;
pub const FormIndirect: u32 = 0x16;
pub const FormSecOffset: u32 = 0x17;
pub const FormExprloc: u32 = 0x18;
pub const FormFlagPresent: u32 = 0x19;
pub const FormImplicitConst: u32 = 0x21;

/// ReadUleb128 decodes an unsigned LEB128 integer from data at pos.
pub fn readUleb128(data: []const u8, pos: *usize) error{ UnexpectedEof, Overflow }!u64 {
    var result: u64 = 0;
    var shift: usize = 0;
    while (true) {
        if (pos.* >= data.len) return error.UnexpectedEof;
        const b = data[pos.*];
        pos.* += 1;
        const slice: u64 = b & 0x7f;
        if (shift >= 64 or (shift == 63 and slice > 1)) return error.Overflow;
        result |= slice << @as(u6, @intCast(shift));
        if ((b & 0x80) == 0) break;
        shift += 7;
    }
    return result;
}

/// ReadSleb128 decodes a signed LEB128 integer from data at pos.
pub fn readSleb128(data: []const u8, pos: *usize) error{ UnexpectedEof, Overflow }!i64 {
    var result: u64 = 0;
    var shift: usize = 0;
    var b: u8 = 0;
    while (true) {
        if (pos.* >= data.len) return error.UnexpectedEof;
        b = data[pos.*];
        pos.* += 1;
        if (shift == 63) {
            if (b != 0x00 and b != 0x7f) return error.Overflow;
        } else if (shift >= 64) {
            return error.Overflow;
        }
        const slice: u64 = b & 0x7f;
        result |= slice << @as(u6, @intCast(shift));
        shift += 7;
        if ((b & 0x80) == 0) break;
    }
    if (shift < 64 and (b & 0x40) != 0) {
        result |= (~@as(u64, 0)) << @as(u6, @intCast(shift));
    }
    return @bitCast(result);
}

pub const Value = union(enum) {
    addr: u64,
    bytes: []const u8,
    sint: i64,
    uint: u64,
    flag: bool,
    string: []const u8,
    reference: u64,
};

/// Field is a single attribute/value pair in an Entry.
pub const Field = struct {
    attr: u32,
    val: Value,
};

/// Entry represents a single DWARF Debugging Information Entry (DIE).
pub const Entry = struct {
    offset: u64,
    tag: u32,
    children: bool,
    fields: []Field,
    allocator: Allocator,

    pub fn deinit(self: *Entry) void {
        self.allocator.free(self.fields);
        self.* = undefined;
    }

    pub fn attr(self: Entry, a: u32) ?Value {
        for (self.fields) |f| {
            if (f.attr == a) return f.val;
        }
        return null;
    }

    pub fn attrString(self: Entry, a: u32) ?[]const u8 {
        if (self.attr(a)) |val| {
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn attrAddr(self: Entry, a: u32) ?u64 {
        if (self.attr(a)) |val| {
            return switch (val) {
                .addr => |addr| addr,
                .uint => |u| u,
                else => null,
            };
        }
        return null;
    }

    pub fn attrInt(self: Entry, a: u32) ?i64 {
        if (self.attr(a)) |val| {
            return switch (val) {
                .sint => |s| s,
                .uint => |u| @as(i64, @bitCast(u)),
                .addr => |addr| @as(i64, @bitCast(addr)),
                else => null,
            };
        }
        return null;
    }
};

const AttrSpec = struct {
    attr: u32,
    form: u32,
    val: i64 = 0,
};

const Abbrev = struct {
    code: u32,
    tag: u32,
    children: bool,
    attrs: []AttrSpec,
};

const AbbrevTable = struct {
    abbrevs: std.AutoHashMap(u32, Abbrev),
    allocator: Allocator,

    fn deinit(self: *AbbrevTable) void {
        var it = self.abbrevs.valueIterator();
        while (it.next()) |ab| {
            self.allocator.free(ab.attrs);
        }
        self.abbrevs.deinit();
    }
};

pub const Unit = struct {
    offset: u64,
    length: u64,
    version: u16,
    abbrev_offset: u64,
    address_size: u8,
    is_64: bool,
    data: []const u8,
};

/// Sections holds slices of raw DWARF debug sections loaded from an executable.
pub const Sections = struct {
    abbrev: []const u8 = "",
    aranges: []const u8 = "",
    frame: []const u8 = "",
    info: []const u8 = "",
    line: []const u8 = "",
    pubnames: []const u8 = "",
    ranges: []const u8 = "",
    str: []const u8 = "",
};

/// Data represents the parsed DWARF debugging information from an object file.
pub const Data = struct {
    sections: Sections,
    units: []Unit,
    endian: std.builtin.Endian,
    allocator: Allocator,

    /// Init initializes a new Data structure from the provided debug sections.
    pub fn init(allocator: Allocator, sec: Sections) !Data {
        if (sec.info.len < 6) return error.InfoTooShort;

        var is_64 = false;
        var off: usize = 4;
        if (sec.info[0] == 0xff and sec.info[1] == 0xff and
            sec.info[2] == 0xff and sec.info[3] == 0xff)
        {
            if (sec.info.len < 14) return error.InfoTooShort;
            off = 12;
            is_64 = true;
        }

        const b0 = sec.info[off];
        const b1 = sec.info[off + 1];
        const endian: std.builtin.Endian = if (b0 == 0 and b1 == 0)
            return error.UnsupportedVersion
        else if (b0 == 0)
            .big
        else if (b1 == 0)
            .little
        else
            .little;

        // Parse compilation units
        var unit_list = std.ArrayList(Unit).empty;
        defer unit_list.deinit(allocator);

        var cur_pos: usize = 0;
        while (cur_pos < sec.info.len) {
            const start_cu = cur_pos;
            if (sec.info.len - cur_pos < 4) break;

            const len32 = mem.readInt(u32, sec.info[cur_pos..][0..4], endian);
            cur_pos += 4;

            var cu_len: u64 = len32;
            var cu_is_64 = false;
            if (len32 == 0xffffffff) {
                if (sec.info.len - cur_pos < 8) return error.UnexpectedEof;
                cu_len = mem.readInt(u64, sec.info[cur_pos..][0..8], endian);
                cur_pos += 8;
                cu_is_64 = true;
            }

            if (cu_len > sec.info.len - cur_pos) return error.UnexpectedEof;
            const cu_end = cur_pos + @as(usize, @intCast(cu_len));

            if (cu_end - cur_pos < 2) return error.UnexpectedEof;
            const vers = mem.readInt(u16, sec.info[cur_pos..][0..2], endian);
            cur_pos += 2;

            var abbrev_off: u64 = 0;
            var addr_sz: u8 = 4;

            if (vers >= 5) {
                if (cu_end - cur_pos < 2) return error.UnexpectedEof;
                _ = sec.info[cur_pos]; // unit_type
                addr_sz = sec.info[cur_pos + 1];
                cur_pos += 2;

                if (cu_is_64) {
                    if (cu_end - cur_pos < 8) return error.UnexpectedEof;
                    abbrev_off = mem.readInt(u64, sec.info[cur_pos..][0..8], endian);
                    cur_pos += 8;
                } else {
                    if (cu_end - cur_pos < 4) return error.UnexpectedEof;
                    abbrev_off = mem.readInt(u32, sec.info[cur_pos..][0..4], endian);
                    cur_pos += 4;
                }
            } else {
                if (cu_is_64) {
                    if (cu_end - cur_pos < 8) return error.UnexpectedEof;
                    abbrev_off = mem.readInt(u64, sec.info[cur_pos..][0..8], endian);
                    cur_pos += 8;
                } else {
                    if (cu_end - cur_pos < 4) return error.UnexpectedEof;
                    abbrev_off = mem.readInt(u32, sec.info[cur_pos..][0..4], endian);
                    cur_pos += 4;
                }

                if (cur_pos >= cu_end) return error.UnexpectedEof;
                addr_sz = sec.info[cur_pos];
                cur_pos += 1;
            }

            const cu_data = sec.info[cur_pos..cu_end];
            try unit_list.append(allocator, Unit{
                .offset = start_cu,
                .length = cu_len,
                .version = vers,
                .abbrev_offset = abbrev_off,
                .address_size = addr_sz,
                .is_64 = cu_is_64,
                .data = cu_data,
            });

            cur_pos = cu_end;
        }

        return Data{
            .sections = sec,
            .units = try unit_list.toOwnedSlice(allocator),
            .endian = endian,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Data) void {
        self.allocator.free(self.units);
        self.* = undefined;
    }

    pub fn parseAbbrevTable(self: Data, offset: u64) !AbbrevTable {
        var table = AbbrevTable{
            .abbrevs = std.AutoHashMap(u32, Abbrev).init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer table.deinit();

        if (offset >= self.sections.abbrev.len) return table;
        var pos: usize = @intCast(offset);
        const data = self.sections.abbrev;

        while (pos < data.len) {
            const code_u64 = try readUleb128(data, &pos);
            if (code_u64 == 0) break; // Table end
            const code = std.math.cast(u32, code_u64) orelse return error.Overflow;

            const tag_u64 = try readUleb128(data, &pos);
            const tag = std.math.cast(u32, tag_u64) orelse return error.Overflow;
            if (pos >= data.len) return error.UnexpectedEof;
            const children = (data[pos] != 0);
            pos += 1;

            var attr_list = std.ArrayList(AttrSpec).empty;
            defer attr_list.deinit(self.allocator);

            while (true) {
                const attr_id = try readUleb128(data, &pos);
                const form_id = try readUleb128(data, &pos);
                if (attr_id == 0 and form_id == 0) break;

                const attr_u32 = std.math.cast(u32, attr_id) orelse return error.Overflow;
                const form_u32 = std.math.cast(u32, form_id) orelse return error.Overflow;

                var implicit_val: i64 = 0;
                if (form_u32 == FormImplicitConst) {
                    implicit_val = try readSleb128(data, &pos);
                }

                try attr_list.append(self.allocator, AttrSpec{
                    .attr = attr_u32,
                    .form = form_u32,
                    .val = implicit_val,
                });
            }

            const attrs = try attr_list.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(attrs);

            const gop = try table.abbrevs.getOrPut(code);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.attrs);
            }
            gop.value_ptr.* = Abbrev{
                .code = code,
                .tag = tag,
                .children = children,
                .attrs = attrs,
            };
        }

        return table;
    }

    /// Reader returns a new Reader for iterating DIEs across all compilation units.
    pub fn reader(self: *const Data) Reader {
        return Reader.init(self);
    }
};

/// Reader provides sequential access to the stream of DIEs across compilation units.
pub const Reader = struct {
    data: *const Data,
    unit_index: usize = 0,
    unit_pos: usize = 0,
    cur_abbrevs: ?AbbrevTable = null,
    depth: usize = 0,

    /// Init initializes a Reader starting at byte offset 0.
    pub fn init(data: *const Data) Reader {
        return Reader{
            .data = data,
        };
    }

    pub fn deinit(self: *Reader) void {
        if (self.cur_abbrevs) |*tab| {
            tab.deinit();
            self.cur_abbrevs = null;
        }
        self.* = undefined;
    }

    /// Seek positions the Reader at the specified unit and byte offset within the unit.
    pub fn seek(self: *Reader, unit_idx: usize, pos_in_unit: usize) !void {
        if (unit_idx >= self.data.units.len) return error.UnitOutOfRange;
        if (self.cur_abbrevs) |*tab| {
            tab.deinit();
            self.cur_abbrevs = null;
        }
        self.unit_index = unit_idx;
        self.unit_pos = pos_in_unit;
        self.depth = 0;
    }

    fn ensureUnitAbbrevs(self: *Reader) !*AbbrevTable {
        if (self.cur_abbrevs == null) {
            const u = &self.data.units[self.unit_index];
            self.cur_abbrevs = try self.data.parseAbbrevTable(u.abbrev_offset);
        }
        return &self.cur_abbrevs.?;
    }

    /// Next reads and decodes the next Entry. Returns null upon reaching EOF.
    /// An Entry with Tag == 0 denotes the end of a children list.
    pub fn next(self: *Reader, allocator: Allocator) !?Entry {
        while (true) {
            if (self.unit_index >= self.data.units.len) return null;
            const u = &self.data.units[self.unit_index];

            if (self.unit_pos >= u.data.len) {
                // Advance to next unit
                if (self.cur_abbrevs) |*tab| {
                    tab.deinit();
                    self.cur_abbrevs = null;
                }
                self.unit_index += 1;
                self.unit_pos = 0;
                continue;
            }

            const abs_offset = u.offset + (u.length - u.data.len) + self.unit_pos;
            const code_u64 = try readUleb128(u.data, &self.unit_pos);

            if (code_u64 == 0) {
                if (self.depth > 0) self.depth -= 1;
                return Entry{
                    .offset = abs_offset,
                    .tag = 0, // Tag 0 denotes end of children
                    .children = false,
                    .fields = &[_]Field{},
                    .allocator = allocator,
                };
            }

            const abbrev_tab = try self.ensureUnitAbbrevs();
            const code_u32 = std.math.cast(u32, code_u64) orelse {
                return error.UnknownAbbreviationCode;
            };
            const abbrev = abbrev_tab.abbrevs.get(code_u32) orelse {
                return error.UnknownAbbreviationCode;
            };

            if (abbrev.children) {
                self.depth += 1;
            }

            var field_list = std.ArrayList(Field).empty;
            defer field_list.deinit(allocator);

            for (abbrev.attrs) |spec| {
                const val = try self.decodeValue(u, spec);
                try field_list.append(allocator, Field{
                    .attr = spec.attr,
                    .val = val,
                });
            }

            return Entry{
                .offset = abs_offset,
                .tag = abbrev.tag,
                .children = abbrev.children,
                .fields = try field_list.toOwnedSlice(allocator),
                .allocator = allocator,
            };
        }
    }

    pub fn skipChildren(self: *Reader, allocator: Allocator) !void {
        var level: usize = 1;
        while (level > 0) {
            var ent = (try self.next(allocator)) orelse return;
            defer ent.deinit();

            if (ent.tag == 0) {
                level -= 1;
            } else if (ent.children) {
                level += 1;
            }
        }
    }

    fn decodeValue(self: *Reader, u: *const Unit, spec: AttrSpec) !Value {
        const endian = self.data.endian;
        var form = spec.form;

        while (form == FormIndirect) {
            form = std.math.cast(u32, try readUleb128(u.data, &self.unit_pos)) orelse {
                return error.UnsupportedDwarfForm;
            };
        }

        switch (form) {
            FormAddr => {
                if (u.address_size == 8) {
                    if (u.data.len - self.unit_pos < 8) return error.UnexpectedEof;
                    const v = mem.readInt(u64, u.data[self.unit_pos..][0..8], endian);
                    self.unit_pos += 8;
                    return Value{ .addr = v };
                } else {
                    if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                    const v = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                    self.unit_pos += 4;
                    return Value{ .addr = v };
                }
            },
            FormBlock1 => {
                if (self.unit_pos >= u.data.len) return error.UnexpectedEof;
                const len = u.data[self.unit_pos];
                self.unit_pos += 1;
                if (len > u.data.len - self.unit_pos) return error.UnexpectedEof;
                const slice = u.data[self.unit_pos .. self.unit_pos + len];
                self.unit_pos += len;
                return Value{ .bytes = slice };
            },
            FormBlock2 => {
                if (u.data.len - self.unit_pos < 2) return error.UnexpectedEof;
                const len = mem.readInt(u16, u.data[self.unit_pos..][0..2], endian);
                self.unit_pos += 2;
                if (len > u.data.len - self.unit_pos) return error.UnexpectedEof;
                const slice = u.data[self.unit_pos .. self.unit_pos + len];
                self.unit_pos += len;
                return Value{ .bytes = slice };
            },
            FormBlock4 => {
                if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                const len = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                self.unit_pos += 4;
                if (len > u.data.len - self.unit_pos) return error.UnexpectedEof;
                const slice = u.data[self.unit_pos .. self.unit_pos + len];
                self.unit_pos += len;
                return Value{ .bytes = slice };
            },
            FormBlock, FormExprloc => {
                const len = try readUleb128(u.data, &self.unit_pos);
                const usize_len = std.math.cast(usize, len) orelse return error.UnexpectedEof;
                if (usize_len > u.data.len - self.unit_pos) return error.UnexpectedEof;
                const slice = u.data[self.unit_pos .. self.unit_pos + usize_len];
                self.unit_pos += usize_len;
                return Value{ .bytes = slice };
            },
            FormData1 => {
                if (self.unit_pos >= u.data.len) return error.UnexpectedEof;
                const v = u.data[self.unit_pos];
                self.unit_pos += 1;
                return Value{ .uint = v };
            },
            FormData2 => {
                if (u.data.len - self.unit_pos < 2) return error.UnexpectedEof;
                const v = mem.readInt(u16, u.data[self.unit_pos..][0..2], endian);
                self.unit_pos += 2;
                return Value{ .uint = v };
            },
            FormData4 => {
                if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                const v = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                self.unit_pos += 4;
                return Value{ .uint = v };
            },
            FormData8 => {
                if (u.data.len - self.unit_pos < 8) return error.UnexpectedEof;
                const v = mem.readInt(u64, u.data[self.unit_pos..][0..8], endian);
                self.unit_pos += 8;
                return Value{ .uint = v };
            },
            FormSdata => {
                const v = try readSleb128(u.data, &self.unit_pos);
                return Value{ .sint = v };
            },
            FormUdata => {
                const v = try readUleb128(u.data, &self.unit_pos);
                return Value{ .uint = v };
            },
            FormFlag => {
                if (self.unit_pos >= u.data.len) return error.UnexpectedEof;
                const v = (u.data[self.unit_pos] != 0);
                self.unit_pos += 1;
                return Value{ .flag = v };
            },
            FormFlagPresent => {
                return Value{ .flag = true };
            },
            FormString => {
                const start = self.unit_pos;
                while (self.unit_pos < u.data.len and u.data[self.unit_pos] != 0) {
                    self.unit_pos += 1;
                }
                if (self.unit_pos >= u.data.len) return error.UnexpectedEof;
                const str = u.data[start..self.unit_pos];
                self.unit_pos += 1; // skip null
                return Value{ .string = str };
            },
            FormStrp => {
                var str_offset: u64 = 0;
                if (u.is_64) {
                    if (u.data.len - self.unit_pos < 8) return error.UnexpectedEof;
                    str_offset = mem.readInt(u64, u.data[self.unit_pos..][0..8], endian);
                    self.unit_pos += 8;
                } else {
                    if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                    str_offset = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                    self.unit_pos += 4;
                }

                if (str_offset >= self.data.sections.str.len) return error.StringOffsetOutOfRange;
                const str_slice = self.data.sections.str[@intCast(str_offset)..];
                var end: usize = 0;
                while (end < str_slice.len and str_slice[end] != 0) : (end += 1) {}
                return Value{ .string = str_slice[0..end] };
            },
            FormRef1 => {
                if (self.unit_pos >= u.data.len) return error.UnexpectedEof;
                const v = u.data[self.unit_pos];
                self.unit_pos += 1;
                return Value{ .reference = std.math.add(u64, u.offset, v) catch return error.Overflow };
            },
            FormRef2 => {
                if (u.data.len - self.unit_pos < 2) return error.UnexpectedEof;
                const v = mem.readInt(u16, u.data[self.unit_pos..][0..2], endian);
                self.unit_pos += 2;
                return Value{ .reference = std.math.add(u64, u.offset, v) catch return error.Overflow };
            },
            FormRef4 => {
                if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                const v = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                self.unit_pos += 4;
                return Value{ .reference = std.math.add(u64, u.offset, v) catch return error.Overflow };
            },
            FormRef8 => {
                if (u.data.len - self.unit_pos < 8) return error.UnexpectedEof;
                const v = mem.readInt(u64, u.data[self.unit_pos..][0..8], endian);
                self.unit_pos += 8;
                return Value{ .reference = std.math.add(u64, u.offset, v) catch return error.Overflow };
            },
            FormRefUdata => {
                const v = try readUleb128(u.data, &self.unit_pos);
                return Value{ .reference = std.math.add(u64, u.offset, v) catch return error.Overflow };
            },
            FormRefAddr, FormSecOffset => {
                if (u.is_64) {
                    if (u.data.len - self.unit_pos < 8) return error.UnexpectedEof;
                    const v = mem.readInt(u64, u.data[self.unit_pos..][0..8], endian);
                    self.unit_pos += 8;
                    return Value{ .reference = v };
                } else {
                    if (u.data.len - self.unit_pos < 4) return error.UnexpectedEof;
                    const v = mem.readInt(u32, u.data[self.unit_pos..][0..4], endian);
                    self.unit_pos += 4;
                    return Value{ .reference = v };
                }
            },
            FormImplicitConst => {
                return Value{ .sint = spec.val };
            },
            else => return error.UnsupportedDwarfForm,
        }
    }
};

test "dwarf leb128 encoding and decoding" {
    const testing = std.testing;

    // Test ULEB128
    const uleb_cases = [_]struct { val: u64, bytes: []const u8 }{
        .{ .val = 0, .bytes = &[_]u8{0x00} },
        .{ .val = 1, .bytes = &[_]u8{0x01} },
        .{ .val = 127, .bytes = &[_]u8{0x7f} },
        .{ .val = 128, .bytes = &[_]u8{ 0x80, 0x01 } },
        .{ .val = 624485, .bytes = &[_]u8{ 0xe5, 0x8e, 0x26 } },
    };

    for (uleb_cases) |tc| {
        var pos: usize = 0;
        const res = try readUleb128(tc.bytes, &pos);
        try testing.expectEqual(tc.val, res);
        try testing.expectEqual(tc.bytes.len, pos);
    }

    // Test SLEB128
    const sleb_cases = [_]struct { val: i64, bytes: []const u8 }{
        .{ .val = 0, .bytes = &[_]u8{0x00} },
        .{ .val = 1, .bytes = &[_]u8{0x01} },
        .{ .val = -1, .bytes = &[_]u8{0x7f} },
        .{ .val = -2, .bytes = &[_]u8{0x7e} },
        .{ .val = 63, .bytes = &[_]u8{0x3f} },
        .{ .val = -64, .bytes = &[_]u8{0x40} },
        .{ .val = -624485, .bytes = &[_]u8{ 0x9b, 0xf1, 0x59 } },
        .{ .val = std.math.minInt(i64), .bytes = &[_]u8{
            0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f,
        } },
        .{ .val = std.math.maxInt(i64), .bytes = &[_]u8{
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00,
        } },
    };

    for (sleb_cases) |tc| {
        var pos: usize = 0;
        const res = try readSleb128(tc.bytes, &pos);
        try testing.expectEqual(tc.val, res);
        try testing.expectEqual(tc.bytes.len, pos);
    }
}

test "dwarf abbrev, info, and reader end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 1. Build .debug_str:
    // Offset 0: "hello.c\0"
    // Offset 8: "main\0"
    var str_sec = std.ArrayList(u8).empty;
    defer str_sec.deinit(allocator);
    try str_sec.appendSlice(allocator, "hello.c\x00");
    try str_sec.appendSlice(allocator, "main\x00");

    // 2. Build .debug_abbrev:
    // Entry 1: TagCompileUnit (0x11), children = 1
    //   - AttrName (0x03) -> FormStrp (0x0e)
    //   - AttrLowpc (0x11) -> FormAddr (0x01)
    //   - AttrHighpc (0x12) -> FormData4 (0x06)
    //   - 0, 0
    // Entry 2: TagSubprogram (0x2e), children = 0
    //   - AttrName (0x03) -> FormStrp (0x0e)
    //   - AttrLowpc (0x11) -> FormAddr (0x01)
    //   - 0, 0
    // 0 (end of table)
    var abbrev_sec = std.ArrayList(u8).empty;
    defer abbrev_sec.deinit(allocator);

    // Entry 1
    try abbrev_sec.append(allocator, 1); // code = 1
    try abbrev_sec.append(allocator, TagCompileUnit); // 0x11
    try abbrev_sec.append(allocator, 1); // children = true
    try abbrev_sec.append(allocator, AttrName);
    try abbrev_sec.append(allocator, FormStrp);
    try abbrev_sec.append(allocator, AttrLowpc);
    try abbrev_sec.append(allocator, FormAddr);
    try abbrev_sec.append(allocator, AttrHighpc);
    try abbrev_sec.append(allocator, FormData4);
    try abbrev_sec.appendSlice(allocator, &[_]u8{ 0, 0 });

    // Entry 2
    try abbrev_sec.append(allocator, 2); // code = 2
    try abbrev_sec.append(allocator, TagSubprogram); // 0x2e
    try abbrev_sec.append(allocator, 0); // children = false
    try abbrev_sec.append(allocator, AttrName);
    try abbrev_sec.append(allocator, FormStrp);
    try abbrev_sec.append(allocator, AttrLowpc);
    try abbrev_sec.append(allocator, FormAddr);
    try abbrev_sec.appendSlice(allocator, &[_]u8{ 0, 0 });

    // End of table
    try abbrev_sec.append(allocator, 0);

    // 3. Build .debug_info:
    // CU header:
    //   length: u32 (little endian)
    //   version: 4 (u16)
    //   abbrev_offset: 0 (u32)
    //   address_size: 4 (u8)
    // CU body:
    //   DIE 1 (code 1):
    //     AttrName -> FormStrp: 0 (hello.c)
    //     AttrLowpc -> FormAddr: 0x1000
    //     AttrHighpc -> FormData4: 0x200
    //   DIE 2 (code 2):
    //     AttrName -> FormStrp: 8 (main)
    //     AttrLowpc -> FormAddr: 0x1000
    //   0 (null terminator for DIE 1 children)
    var info_body = std.ArrayList(u8).empty;
    defer info_body.deinit(allocator);

    // DIE 1
    try info_body.append(allocator, 1); // code 1
    try info_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // strp offset 0
    try info_body.appendSlice(allocator, &[_]u8{ 0x00, 0x10, 0x00, 0x00 }); // addr 0x1000
    try info_body.appendSlice(allocator, &[_]u8{ 0x00, 0x02, 0x00, 0x00 }); // highpc 0x200

    // DIE 2
    try info_body.append(allocator, 2); // code 2
    try info_body.appendSlice(allocator, &[_]u8{ 8, 0, 0, 0 }); // strp offset 8
    try info_body.appendSlice(allocator, &[_]u8{ 0x00, 0x10, 0x00, 0x00 }); // addr 0x1000

    // Null terminator for children of DIE 1
    try info_body.append(allocator, 0);

    // Construct full .debug_info with header
    var info_sec = std.ArrayList(u8).empty;
    defer info_sec.deinit(allocator);

    const cu_payload_len: u32 = 2 + 4 + 1 + @as(u32, @intCast(info_body.items.len));
    var hdr: [11]u8 = undefined;
    mem.writeInt(u32, hdr[0..4], cu_payload_len, .little);
    mem.writeInt(u16, hdr[4..6], 4, .little); // version 4
    mem.writeInt(u32, hdr[6..10], 0, .little); // abbrev offset 0
    hdr[10] = 4; // address size = 4

    try info_sec.appendSlice(allocator, &hdr);
    try info_sec.appendSlice(allocator, info_body.items);

    // Initialize DWARF data
    var dwarf_data = try Data.init(allocator, .{
        .abbrev = abbrev_sec.items,
        .info = info_sec.items,
        .str = str_sec.items,
    });
    defer dwarf_data.deinit();

    try testing.expectEqual(@as(usize, 1), dwarf_data.units.len);
    try testing.expectEqual(@as(u16, 4), dwarf_data.units[0].version);
    try testing.expectEqual(@as(u8, 4), dwarf_data.units[0].address_size);

    var reader_inst = dwarf_data.reader();
    defer reader_inst.deinit();

    // First entry: CompileUnit
    var ent1 = (try reader_inst.next(allocator)) orelse return error.TestExpectedNotNull;
    defer ent1.deinit();

    try testing.expectEqual(TagCompileUnit, ent1.tag);
    try testing.expect(ent1.children);
    try testing.expectEqualStrings("hello.c", ent1.attrString(AttrName).?);
    try testing.expectEqual(@as(u64, 0x1000), ent1.attrAddr(AttrLowpc).?);
    try testing.expectEqual(@as(i64, 0x200), ent1.attrInt(AttrHighpc).?);

    // Second entry: Subprogram main
    var ent2 = (try reader_inst.next(allocator)) orelse return error.TestExpectedNotNull;
    defer ent2.deinit();

    try testing.expectEqual(TagSubprogram, ent2.tag);
    try testing.expect(!ent2.children);
    try testing.expectEqualStrings("main", ent2.attrString(AttrName).?);
    try testing.expectEqual(@as(u64, 0x1000), ent2.attrAddr(AttrLowpc).?);

    // Third entry: End of children (Tag 0)
    var ent3 = (try reader_inst.next(allocator)) orelse return error.TestExpectedNotNull;
    defer ent3.deinit();
    try testing.expectEqual(@as(u32, 0), ent3.tag);

    // Fourth: EOF
    const ent4 = try reader_inst.next(allocator);
    try testing.expect(ent4 == null);

    // Test seek back to beginning and skipChildren
    try reader_inst.seek(0, 0);
    var ent_re = (try reader_inst.next(allocator)) orelse return error.TestExpectedNotNull;
    defer ent_re.deinit();
    try testing.expectEqual(TagCompileUnit, ent_re.tag);

    // Skip children of CompileUnit
    try reader_inst.skipChildren(allocator);

    // After skipping children of CU, next should be EOF
    const ent_after = try reader_inst.next(allocator);
    try testing.expect(ent_after == null);
}
