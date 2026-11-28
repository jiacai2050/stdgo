const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const bytes = @import("../bytes.zig");

pub const StructuralError = error{
    BadMagic,
    NonHuffmanEncoding,
    InvalidCompressionLevel,
    BlockChecksumMismatch,
    StreamChecksumMismatch,
    EmptyHuffmanTree,
    EqualSymbolsInHuffmanTree,
    InvalidNode,
    OrigPtrOutOfBounds,
    DataExceedsBlockSize,
    RepeatPastEndOfBlock,
    RepeatCountTooLarge,
    TreeSelectorOutOfRange,
    InsufficientSelectors,
    NoTreeSelectors,
    UnexpectedEOF,
    HuffmanLengthOutOfRange,
};

pub const BitReader = struct {
    r: *std.Io.Reader,
    buf: u64 = 0,
    bits: u8 = 0,

    pub fn init(r: *std.Io.Reader) BitReader {
        return .{ .r = r };
    }

    pub fn readBits(self: *BitReader, comptime T: type, num_bits: u8) !T {
        while (self.bits < num_bits) {
            const b = self.r.takeByte() catch |err| {
                if (err == error.EndOfStream) return StructuralError.UnexpectedEOF;
                return err;
            };
            self.buf = (self.buf << 8) | b;
            self.bits += 8;
        }
        const shift: std.math.Log2Int(u64) = @intCast(self.bits - num_bits);
        const mask = (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(num_bits))) - 1;
        const res = (self.buf >> shift) & mask;
        self.bits -= num_bits;
        return @intCast(res);
    }

    pub fn readBit(self: *BitReader) !bool {
        return (try self.readBits(u1, 1)) == 1;
    }
};

const invalidNodeValue: u16 = 0xffff;

const HuffmanNode = struct {
    left: u16 = invalidNodeValue,
    right: u16 = invalidNodeValue,
    left_value: u16 = 0,
    right_value: u16 = 0,
};

const HuffmanTree = struct {
    nodes: []HuffmanNode,
    next_node: usize = 0,

    pub fn deinit(self: *HuffmanTree, alloc: Allocator) void {
        alloc.free(self.nodes);
    }

    pub fn decode(self: *const HuffmanTree, br: *BitReader) !u16 {
        var node_index: u16 = 0;
        while (true) {
            if (node_index >= self.nodes.len) return StructuralError.InvalidNode;
            const node = self.nodes[node_index];
            const bit = try br.readBit();

            if (bit) {
                if (node.left == invalidNodeValue) {
                    return node.left_value;
                }
                node_index = node.left;
            } else {
                if (node.right == invalidNodeValue) {
                    return node.right_value;
                }
                node_index = node.right;
            }
        }
    }
};

const SymbolLengthPair = struct {
    value: u16,
    length: u8,
};

const HuffmanCode = struct {
    code: u32,
    code_len: u8,
    value: u16,
};

fn lessSymbolLength(_: void, a: SymbolLengthPair, b: SymbolLengthPair) bool {
    if (a.length != b.length) return a.length < b.length;
    return a.value < b.value;
}

fn lessHuffmanCode(_: void, a: HuffmanCode, b: HuffmanCode) bool {
    return a.code < b.code;
}

fn newHuffmanTree(alloc: Allocator, lengths: []const u8) !HuffmanTree {
    if (lengths.len < 2) return StructuralError.EmptyHuffmanTree;

    var pairs = try alloc.alloc(SymbolLengthPair, lengths.len);
    defer alloc.free(pairs);
    for (lengths, 0..) |len, i| {
        pairs[i] = .{ .value = @intCast(i), .length = len };
    }

    std.sort.insertion(SymbolLengthPair, pairs, {}, lessSymbolLength);

    var code: u32 = 0;
    var length: u8 = 32;

    var codes = try alloc.alloc(HuffmanCode, lengths.len);
    defer alloc.free(codes);

    var idx: usize = pairs.len;
    while (idx > 0) {
        idx -= 1;
        if (length > pairs[idx].length) {
            length = pairs[idx].length;
        }
        codes[idx] = .{
            .code = code,
            .code_len = length,
            .value = pairs[idx].value,
        };
        code +%= @as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(32 - length));
    }

    std.sort.insertion(HuffmanCode, codes, {}, lessHuffmanCode);

    var t = HuffmanTree{
        .nodes = try alloc.alloc(HuffmanNode, codes.len),
        .next_node = 0,
    };
    errdefer t.deinit(alloc);

    _ = try buildHuffmanNode(&t, codes, 0);
    return t;
}

fn buildHuffmanNode(t: *HuffmanTree, codes: []const HuffmanCode, level: u5) !u16 {
    const test_bit: u32 = @as(u32, 1) << (31 - level);

    var first_right: usize = codes.len;
    for (codes, 0..) |c, i| {
        if ((c.code & test_bit) != 0) {
            first_right = i;
            break;
        }
    }

    const left = codes[0..first_right];
    const right = codes[first_right..];

    if (left.len == 0 or right.len == 0) {
        if (codes.len < 2) return StructuralError.EmptyHuffmanTree;
        if (level == 31) return StructuralError.EqualSymbolsInHuffmanTree;

        if (left.len == 0) {
            return buildHuffmanNode(t, right, level + 1);
        }
        return buildHuffmanNode(t, left, level + 1);
    }

    const node_index: u16 = @intCast(t.next_node);
    t.next_node += 1;

    if (left.len == 1) {
        t.nodes[node_index].left = invalidNodeValue;
        t.nodes[node_index].left_value = left[0].value;
    } else {
        t.nodes[node_index].left = try buildHuffmanNode(t, left, level + 1);
    }

    if (right.len == 1) {
        t.nodes[node_index].right = invalidNodeValue;
        t.nodes[node_index].right_value = right[0].value;
    } else {
        t.nodes[node_index].right = try buildHuffmanNode(t, right, level + 1);
    }

    return node_index;
}

const MoveToFront = struct {
    table: [256]u8,
    len: usize,

    pub fn init(byte_map: []const u8) MoveToFront {
        var mtf = MoveToFront{
            .table = undefined,
            .len = byte_map.len,
        };
        @memcpy(mtf.table[0..byte_map.len], byte_map);
        return mtf;
    }

    pub fn first(self: *const MoveToFront) u8 {
        return self.table[0];
    }

    pub fn decode(self: *MoveToFront, idx: usize) u8 {
        const b = self.table[idx];
        var i = idx;
        while (i > 0) : (i -= 1) {
            self.table[i] = self.table[i - 1];
        }
        self.table[0] = b;
        return b;
    }
};

pub const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            if ((c & 0x80000000) != 0) {
                c = (c << 1) ^ 0x04C11DB7;
            } else {
                c <<= 1;
            }
        }
        t[i] = c;
    }
    break :blk t;
};

pub fn updateCRC(val: u32, buf: []const u8) u32 {
    var crc = ~val;
    for (buf) |b| {
        crc = crc_table[@as(u8, @truncate(crc >> 24)) ^ b] ^ (crc << 8);
    }
    return ~crc;
}

const bzip2FileMagic: u16 = 0x425a; // "BZ"
const bzip2BlockMagic: u48 = 0x314159265359;
const bzip2FinalMagic: u48 = 0x177245385090;

pub const Reader = struct {
    allocator: Allocator,
    br: BitReader,
    block_size: usize = 0,
    setup_done: bool = false,
    eof: bool = false,

    block_crc: u32 = 0,
    want_block_crc: u32 = 0,
    file_crc: u32 = 0,

    tt: []u32 = &.{},
    c: [256]usize = @splat(0),
    t_pos: u32 = 0,

    pre_rle_len: usize = 0,
    pre_rle_used: usize = 0,
    last_byte: i32 = -1,
    byte_repeats: usize = 0,
    repeats: usize = 0,

    pub fn init(allocator: Allocator, r: *std.Io.Reader) Reader {
        return .{
            .allocator = allocator,
            .br = BitReader.init(r),
        };
    }

    pub fn deinit(self: *Reader) void {
        if (self.tt.len > 0) {
            self.allocator.free(self.tt);
            self.tt = &.{};
        }
    }

    fn setup(self: *Reader) !void {
        const magic = try self.br.readBits(u16, 16);
        if (magic != bzip2FileMagic) return StructuralError.BadMagic;

        const h = try self.br.readBits(u8, 8);
        if (h != 'h') return StructuralError.NonHuffmanEncoding;

        const level = try self.br.readBits(u8, 8);
        if (level < '1' or level > '9') return StructuralError.InvalidCompressionLevel;

        self.block_size = @as(usize, 100_000) * @as(usize, level - '0');
        if (self.block_size > self.tt.len) {
            if (self.tt.len > 0) {
                self.allocator.free(self.tt);
                self.tt = &.{};
            }
            self.tt = try self.allocator.alloc(u32, self.block_size);
        }
    }

    fn readFromBlock(self: *Reader, buf: []u8) usize {
        var n: usize = 0;
        while ((self.repeats > 0 or self.pre_rle_used < self.pre_rle_len) and n < buf.len) {
            if (self.repeats > 0) {
                buf[n] = @intCast(self.last_byte);
                n += 1;
                self.repeats -= 1;
                if (self.repeats == 0) {
                    self.last_byte = -1;
                }
                continue;
            }

            self.t_pos = self.tt[self.t_pos];
            const b: u8 = @truncate(self.t_pos);
            self.t_pos >>= 8;
            self.pre_rle_used += 1;

            if (self.byte_repeats == 3) {
                self.repeats = b;
                self.byte_repeats = 0;
                if (self.repeats == 0) {
                    self.last_byte = -1;
                }
                continue;
            }

            if (self.last_byte == b) {
                self.byte_repeats += 1;
            } else {
                self.byte_repeats = 0;
            }
            self.last_byte = b;

            buf[n] = b;
            n += 1;
        }
        return n;
    }

    pub fn read(self: *Reader, buf: []u8) !usize {
        if (self.eof) return 0;

        if (!self.setup_done) {
            try self.setup();
            self.setup_done = true;
        }

        while (true) {
            const n = self.readFromBlock(buf);
            if (n > 0 or buf.len == 0) {
                self.block_crc = updateCRC(self.block_crc, buf[0..n]);
                return n;
            }

            if (self.block_crc != self.want_block_crc) {
                return StructuralError.BlockChecksumMismatch;
            }

            // Find next block or footer
            const magic = try self.br.readBits(u48, 48);
            if (magic == bzip2FinalMagic) {
                const want_file_crc = try self.br.readBits(u32, 32);
                if (self.file_crc != want_file_crc) {
                    return StructuralError.StreamChecksumMismatch;
                }
                self.eof = true;
                return 0;
            }

            if (magic != bzip2BlockMagic) {
                return StructuralError.BadMagic;
            }

            try self.readBlock();
        }
    }

    fn readBlock(self: *Reader) !void {
        self.want_block_crc = try self.br.readBits(u32, 32);
        self.block_crc = 0;
        self.file_crc = ((self.file_crc << 1) | (self.file_crc >> 31)) ^ self.want_block_crc;

        _ = try self.br.readBits(u1, 1); // randomized
        const orig_ptr = try self.br.readBits(u24, 24);

        // Read in-use symbols
        const in_use16: u16 = try self.br.readBits(u16, 16);
        var in_use: [256]bool = @splat(false);
        var num_symbols: usize = 0;
        var byte_map: [256]u8 = undefined;

        for (0..16) |i| {
            if ((in_use16 & (@as(u16, 0x8000) >> @as(u4, @intCast(i)))) != 0) {
                const mask16 = try self.br.readBits(u16, 16);
                for (0..16) |j| {
                    if ((mask16 & (@as(u16, 0x8000) >> @as(u4, @intCast(j)))) != 0) {
                        const b: u8 = @intCast(i * 16 + j);
                        in_use[b] = true;
                        byte_map[num_symbols] = b;
                        num_symbols += 1;
                    }
                }
            }
        }

        if (num_symbols == 0) return StructuralError.EmptyHuffmanTree;
        var mtf = MoveToFront.init(byte_map[0..num_symbols]);
        const alpha_size = num_symbols + 2;

        const num_trees = try self.br.readBits(u3, 3);
        if (num_trees < 2 or num_trees > 6) return StructuralError.TreeSelectorOutOfRange;

        const num_selectors = try self.br.readBits(u15, 15);
        if (num_selectors == 0) return StructuralError.NoTreeSelectors;

        var mtf_selector: [6]u8 = @splat(0);
        for (0..num_trees) |i| {
            mtf_selector[i] = @intCast(i);
        }

        var tree_indexes = try self.allocator.alloc(u8, num_selectors);
        defer self.allocator.free(tree_indexes);

        for (0..num_selectors) |i| {
            var c: usize = 0;
            while (try self.br.readBit()) {
                c += 1;
                if (c >= num_trees) return StructuralError.TreeSelectorOutOfRange;
            }
            const b = mtf_selector[c];
            var j = c;
            while (j > 0) : (j -= 1) {
                mtf_selector[j] = mtf_selector[j - 1];
            }
            mtf_selector[0] = b;
            tree_indexes[i] = b;
        }

        // Read Huffman tree bit lengths
        var huffman_trees = try self.allocator.alloc(HuffmanTree, num_trees);
        var built_trees: usize = 0;
        defer {
            for (huffman_trees[0..built_trees]) |*t| t.deinit(self.allocator);
            self.allocator.free(huffman_trees);
        }

        var lengths = try self.allocator.alloc(u8, alpha_size);
        defer self.allocator.free(lengths);

        for (0..num_trees) |t_idx| {
            var length: i32 = @intCast(try self.br.readBits(u5, 5));
            for (0..alpha_size) |j| {
                while (try self.br.readBit()) {
                    if (try self.br.readBit()) {
                        length -= 1;
                    } else {
                        length += 1;
                    }
                }
                if (length < 1 or length > 20) {
                    return StructuralError.HuffmanLengthOutOfRange;
                }
                lengths[j] = @intCast(length);
            }
            huffman_trees[t_idx] = try newHuffmanTree(self.allocator, lengths);
            built_trees += 1;
        }

        // Decode block symbols
        var selector_index: usize = 1;
        var current_tree = &huffman_trees[tree_indexes[0]];
        var buf_index: usize = 0;
        var repeat: usize = 0;
        var repeat_power: usize = 0;

        @memset(&self.c, 0);

        var decoded: usize = 0;
        while (true) {
            if (decoded == 50) {
                if (selector_index >= num_selectors) return StructuralError.InsufficientSelectors;
                current_tree = &huffman_trees[tree_indexes[selector_index]];
                selector_index += 1;
                decoded = 0;
            }

            const v = try current_tree.decode(&self.br);
            decoded += 1;

            if (v < 2) {
                if (repeat == 0) {
                    repeat_power = 1;
                }
                repeat += repeat_power << @as(u1, @truncate(v));
                repeat_power <<= 1;
                if (repeat > 2 * 1024 * 1024) return StructuralError.RepeatCountTooLarge;
                continue;
            }

            if (repeat > 0) {
                if (repeat > self.block_size - buf_index) {
                    return StructuralError.RepeatPastEndOfBlock;
                }
                for (0..repeat) |_| {
                    const b = mtf.first();
                    self.tt[buf_index] = b;
                    self.c[b] += 1;
                    buf_index += 1;
                }
                repeat = 0;
            }

            if (v == num_symbols + 1) {
                // EOB
                break;
            }

            const b = mtf.decode(v - 1);
            if (buf_index >= self.block_size) return StructuralError.DataExceedsBlockSize;
            self.tt[buf_index] = b;
            self.c[b] += 1;
            buf_index += 1;
        }

        if (orig_ptr >= buf_index) return StructuralError.OrigPtrOutOfBounds;

        // Inverse BWT
        var sum: usize = 0;
        for (0..256) |i| {
            sum += self.c[i];
            self.c[i] = sum - self.c[i];
        }

        for (0..buf_index) |i| {
            const b: u8 = @truncate(self.tt[i]);
            self.tt[self.c[b]] |= @as(u32, @intCast(i)) << 8;
            self.c[b] += 1;
        }

        self.t_pos = self.tt[orig_ptr] >> 8;
        self.pre_rle_len = buf_index;
        self.pre_rle_used = 0;
        self.last_byte = -1;
        self.byte_repeats = 0;
        self.repeats = 0;
    }

    /// Read all uncompressed data into memory.
    pub fn readAllAlloc(self: *Reader, max_size: usize) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.allocator);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&chunk);
            if (n == 0) break;
            if (out.items.len + n > max_size) return error.StreamTooLarge;
            try out.appendSlice(self.allocator, chunk[0..n]);
        }
        return out.toOwnedSlice(self.allocator);
    }
};

/// Convenience function: Decompresses bzip2 compressed bytes.
pub fn decompressAlloc(allocator: Allocator, compressed: []const u8) ![]u8 {
    var rd = bytes.Reader.init(compressed);
    var bz_reader = Reader.init(allocator, rd.reader());
    defer bz_reader.deinit();
    return bz_reader.readAllAlloc(10 * 1024 * 1024);
}

test "bzip2 decompression of test vector" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const bz2_hex =
        "425a6839314159265359b98ead8e0000051f8060051000004000801ea6dc10200022a7e8" ++
        "a687e8a60d34281a686464c4098a8774d689eb3e84dc1bdd964a83fd2196292f36fb22ad" ++
        "8413c177245385090b98ead8e0";

    var raw: [100]u8 = undefined;
    const raw_slice = try std.fmt.hexToBytes(raw[0 .. bz2_hex.len / 2], bz2_hex);

    const decompressed = try decompressAlloc(alloc, raw_slice);
    defer alloc.free(decompressed);

    const expected = "Hello, World! Welcome to stdgo bzip2 decompressor.";
    try testing.expectEqualStrings(expected, decompressed);
}

test "bzip2 repeated bytes RLE decoding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Compressed string: "AAAAABBBBBCCCCCDDDDDEEEEE"
    const rep_hex =
        "425a6839314159265359211fd445000004440020003e002000223d23d20c02ef378a9122" ++
        "4a4f177245385090211fd445";
    var raw: [64]u8 = undefined;
    const raw_slice = try std.fmt.hexToBytes(raw[0 .. rep_hex.len / 2], rep_hex);

    const decompressed = try decompressAlloc(alloc, raw_slice);
    defer alloc.free(decompressed);

    try testing.expectEqualStrings("AAAAABBBBBCCCCCDDDDDEEEEE", decompressed);
}

test "bzip2 rejects empty symbol table" {
    const testing = std.testing;
    // "BZh9" + block magic 0x314159265359 + crc(4) + rand(1b)+orig_ptr(24b)+in_use16(16b=0)
    const empty_sym_bz2 = [_]u8{
        'B',  'Z',  'h',  '9',
        0x31, 0x41, 0x59, 0x26,
        0x53, 0x59, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectError(
        StructuralError.EmptyHuffmanTree,
        decompressAlloc(testing.allocator, &empty_sym_bz2),
    );
}
