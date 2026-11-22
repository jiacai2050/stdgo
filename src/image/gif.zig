//! Package image/gif implements a GIF image decoder and encoder.
//!
//! Supports GIF87a and GIF89a specifications, Logical Screen Descriptor,
//! Global and Local Color Tables, Graphic Control Extensions (frame delays,
//! transparency, disposal methods), animated GIFs, interlaced and non-interlaced
//! images, and LSB LZW raster compression/decompression.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const image = @import("../image.zig");
const color = image.color;
const Rectangle = image.Rectangle;
const RGBAImage = image.RGBAImage;
const bytes = @import("../bytes.zig");
const lzw = @import("../compress/lzw.zig");

/// Disposal methods for GIF animation frames.
pub const DisposalNone: u8 = 0;
pub const DisposalPreserve: u8 = 1;
pub const DisposalBackground: u8 = 2;
pub const DisposalPrevious: u8 = 3;

pub const Options = struct {
    num_colors: usize = 256,
};

/// GIF represents an animated or multi-frame GIF image.
pub const GIF = struct {
    images: std.ArrayList(*RGBAImage),
    delays: std.ArrayList(i32),
    disposals: std.ArrayList(u8),
    loop_count: i32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) GIF {
        return .{
            .images = std.ArrayList(*RGBAImage).empty,
            .delays = std.ArrayList(i32).empty,
            .disposals = std.ArrayList(u8).empty,
            .loop_count = 0,
            .width = 0,
            .height = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GIF) void {
        for (self.images.items) |img| {
            img.deinit();
        }
        self.images.deinit(self.allocator);
        self.delays.deinit(self.allocator);
        self.disposals.deinit(self.allocator);
    }
};

pub const GifError = error{
    BadGIFHeader,
    CorruptGIFData,
    UnexpectedEof,
    OutOfMemory,
    NoFrames,
    InvalidDimensions,
};

/// Decode decodes a GIF image and returns the first frame as an RGBAImage.
pub fn decode(allocator: Allocator, data: []const u8) !*RGBAImage {
    var g = try decodeAll(allocator, data);
    defer {
        // Free remaining frames if more than 1
        if (g.images.items.len > 1) {
            for (g.images.items[1..]) |img| {
                img.deinit();
            }
        }
        g.delays.deinit(allocator);
        g.disposals.deinit(allocator);
        g.images.deinit(allocator);
    }

    if (g.images.items.len == 0) return error.NoFrames;
    return g.images.items[0];
}

/// DecodeAll decodes all frames and animation metadata from a GIF data stream.
pub fn decodeAll(allocator: Allocator, data: []const u8) !GIF {
    if (data.len < 13) return error.BadGIFHeader;

    // 1. Signature & Version: "GIF87a" or "GIF89a"
    if (!mem.eql(u8, data[0..6], "GIF87a") and !mem.eql(u8, data[0..6], "GIF89a")) {
        return error.BadGIFHeader;
    }

    var pos: usize = 6;
    const screen_w = mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    const screen_h = mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (screen_w > 10000 or screen_h > 10000) return error.InvalidDimensions;
    const lsd_packed = data[pos];
    pos += 1;
    _ = data[pos]; // bg_index
    pos += 1;
    _ = data[pos]; // aspect_ratio
    pos += 1;

    var result = GIF.init(allocator);
    errdefer result.deinit();

    result.width = screen_w;
    result.height = screen_h;

    // Global Color Table
    var global_palette: [256]color.RGBA = undefined;
    var global_palette_len: usize = 0;
    const has_gct = (lsd_packed & 0x80) != 0;
    if (has_gct) {
        const gct_entries = @as(usize, 1) << @intCast((lsd_packed & 0x07) + 1);
        if (pos + gct_entries * 3 > data.len) return error.UnexpectedEof;
        for (0..gct_entries) |i| {
            global_palette[i] = color.RGBA{
                .r = data[pos],
                .g = data[pos + 1],
                .b = data[pos + 2],
                .a = 255,
            };
            pos += 3;
        }
        global_palette_len = gct_entries;
    }

    // Graphic Control state for upcoming frame
    var gc_transparent: ?u8 = null;
    var gc_delay: i32 = 0;
    var gc_disposal: u8 = DisposalNone;

    while (pos < data.len) {
        const block_type = data[pos];
        pos += 1;

        if (block_type == 0x3B) {
            // Trailer: End of GIF
            break;
        } else if (block_type == 0x21) {
            // Extension
            if (pos >= data.len) return error.UnexpectedEof;
            const ext_label = data[pos];
            pos += 1;

            if (ext_label == 0xF9) {
                // Graphic Control Extension
                if (pos >= data.len) return error.UnexpectedEof;
                const block_size = data[pos];
                pos += 1;
                if (block_size == 4 and pos + 4 <= data.len) {
                    const packed_byte = data[pos];
                    gc_disposal = (packed_byte >> 2) & 0x07;
                    const has_transparency = (packed_byte & 0x01) != 0;
                    gc_delay = mem.readInt(u16, data[pos + 1 ..][0..2], .little);
                    if (has_transparency) {
                        gc_transparent = data[pos + 3];
                    } else {
                        gc_transparent = null;
                    }
                    pos += 4;
                } else {
                    pos += block_size;
                }
                // Skip terminator
                while (pos < data.len and data[pos] != 0) {
                    const skip_len = data[pos];
                    pos += 1 + skip_len;
                }
                if (pos < data.len and data[pos] == 0) pos += 1;
            } else if (ext_label == 0xFF) {
                // Application Extension (e.g. NETSCAPE2.0)
                if (pos >= data.len) return error.UnexpectedEof;
                const block_size = data[pos];
                pos += 1;
                const app_id = if (pos + block_size <= data.len)
                    data[pos .. pos + block_size]
                else
                    "";
                pos += block_size;

                if (mem.startsWith(u8, app_id, "NETSCAPE2.0")) {
                    while (pos < data.len and data[pos] != 0) {
                        const sub_len = data[pos];
                        pos += 1;
                        if (sub_len == 3 and pos + 3 <= data.len and data[pos] == 1) {
                            result.loop_count = mem.readInt(u16, data[pos + 1 ..][0..2], .little);
                        }
                        pos += sub_len;
                    }
                    if (pos < data.len and data[pos] == 0) pos += 1;
                } else {
                    while (pos < data.len and data[pos] != 0) {
                        const skip_len = data[pos];
                        pos += 1 + skip_len;
                    }
                    if (pos < data.len and data[pos] == 0) pos += 1;
                }
            } else {
                // Other extensions (Comment, Plain Text, etc.): skip sub-blocks
                while (pos < data.len and data[pos] != 0) {
                    const skip_len = data[pos];
                    pos += 1 + skip_len;
                }
                if (pos < data.len and data[pos] == 0) pos += 1;
            }
        } else if (block_type == 0x2C) {
            // Image Descriptor
            if (pos + 9 > data.len) return error.UnexpectedEof;
            _ = mem.readInt(u16, data[pos..][0..2], .little); // left
            pos += 2;
            _ = mem.readInt(u16, data[pos..][0..2], .little); // top
            pos += 2;
            const img_w = mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            const img_h = mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            const id_packed = data[pos];
            pos += 1;

            if (img_w == 0 or img_h == 0 or img_w > 10000 or img_h > 10000) {
                return error.InvalidDimensions;
            }

            const has_lct = (id_packed & 0x80) != 0;
            const interlaced = (id_packed & 0x40) != 0;

            var local_palette: [256]color.RGBA = undefined;
            var active_palette: []const color.RGBA = global_palette[0..global_palette_len];

            if (has_lct) {
                const lct_entries = @as(usize, 1) << @intCast((id_packed & 0x07) + 1);
                if (pos + lct_entries * 3 > data.len) return error.UnexpectedEof;
                for (0..lct_entries) |i| {
                    local_palette[i] = color.RGBA{
                        .r = data[pos],
                        .g = data[pos + 1],
                        .b = data[pos + 2],
                        .a = 255,
                    };
                    pos += 3;
                }
                active_palette = local_palette[0..lct_entries];
            }

            if (pos >= data.len) return error.UnexpectedEof;
            const lit_width = data[pos];
            pos += 1;

            // Collect all sub-block compressed bytes
            var lzw_bytes = std.ArrayList(u8).empty;
            defer lzw_bytes.deinit(allocator);

            while (pos < data.len and data[pos] != 0) {
                const blk_len = data[pos];
                pos += 1;
                if (pos + blk_len > data.len) return error.UnexpectedEof;
                try lzw_bytes.appendSlice(allocator, data[pos .. pos + blk_len]);
                pos += blk_len;
            }
            if (pos < data.len and data[pos] == 0) pos += 1;

            // Decompress LZW stream
            const total_pixels = std.math.mul(
                usize,
                @as(usize, img_w),
                @as(usize, img_h),
            ) catch return error.InvalidDimensions;
            const decoded_indices = try allocator.alloc(u8, total_pixels);
            defer allocator.free(decoded_indices);

            var in_stream = bytes.Reader.init(lzw_bytes.items);
            const min_code_size: u4 = @intCast(@max(2, lit_width));
            var lzw_r = lzw.Reader.init(
                in_stream.reader(),
                .LSB,
                min_code_size,
            ) catch return error.CorruptGIFData;

            var total_decoded: usize = 0;
            while (total_decoded < total_pixels) {
                const n = lzw_r.read(decoded_indices[total_decoded..]) catch |err| {
                    if (err == error.EndOfStream) break;
                    return error.CorruptGIFData;
                };
                if (n == 0) break;
                total_decoded += n;
            }

            // Create RGBA image frame
            const frame = try RGBAImage.init(allocator, Rectangle.rect(0, 0, img_w, img_h));
            errdefer frame.deinit();

            if (interlaced) {
                var p_idx: usize = 0;
                const passes = [_]struct { start: usize, step: usize }{
                    .{ .start = 0, .step = 8 },
                    .{ .start = 4, .step = 8 },
                    .{ .start = 2, .step = 4 },
                    .{ .start = 1, .step = 2 },
                };
                for (passes) |p| {
                    var y: usize = p.start;
                    while (y < img_h) : (y += p.step) {
                        for (0..img_w) |x| {
                            if (p_idx < total_decoded) {
                                const c_idx = decoded_indices[p_idx];
                                p_idx += 1;
                                const default_c = color.RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 };
                                var c = if (c_idx < active_palette.len)
                                    active_palette[c_idx]
                                else
                                    default_c;
                                if (gc_transparent) |t_idx| {
                                    if (c_idx == t_idx) c.a = 0;
                                }
                                frame.set(@intCast(x), @intCast(y), c);
                            }
                        }
                    }
                }
            } else {
                for (0..img_h) |y| {
                    for (0..img_w) |x| {
                        const p_idx = y * img_w + x;
                        if (p_idx < total_decoded) {
                            const c_idx = decoded_indices[p_idx];
                            const default_c = color.RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 };
                            var c = if (c_idx < active_palette.len)
                                active_palette[c_idx]
                            else
                                default_c;
                            if (gc_transparent) |t_idx| {
                                if (c_idx == t_idx) c.a = 0;
                            }
                            frame.set(@intCast(x), @intCast(y), c);
                        }
                    }
                }
            }

            try result.images.append(allocator, frame);
            try result.delays.append(allocator, gc_delay);
            try result.disposals.append(allocator, gc_disposal);

            // Reset Graphic Control state for next frame
            gc_transparent = null;
            gc_delay = 0;
            gc_disposal = DisposalNone;
        } else {
            // Unknown block
            return error.CorruptGIFData;
        }
    }

    if (result.images.items.len == 0) return error.NoFrames;
    return result;
}

/// Encode writes a single RGBAImage as a GIF89a encoded byte slice.
pub fn encode(allocator: Allocator, img: *const RGBAImage) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const w: u16 = @intCast(@max(0, img.rect.dx()));
    const h: u16 = @intCast(@max(0, img.rect.dy()));

    if (w == 0 or h == 0) return error.InvalidDimensions;

    // 1. Header: "GIF89a"
    try out.appendSlice(allocator, "GIF89a");

    // 2. Logical Screen Descriptor
    var lsd: [7]u8 = undefined;
    mem.writeInt(u16, lsd[0..2], w, .little);
    mem.writeInt(u16, lsd[2..4], h, .little);
    lsd[4] = 0xF7; // Global Color Table Flag = 1, 256 colors (2^(7+1))
    lsd[5] = 0; // Background color index = 0
    lsd[6] = 0; // Pixel aspect ratio = 0
    try out.appendSlice(allocator, &lsd);

    // 3. Build Palette (up to 256 colors) & Quantize
    var palette = try allocator.alloc(color.RGBA, 256);
    defer allocator.free(palette);
    @memset(palette, color.RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 });

    var unique_count: usize = 0;
    const num_pixels = @as(usize, w) * @as(usize, h);
    var pixel_indices = try allocator.alloc(u8, num_pixels);
    defer allocator.free(pixel_indices);

    var idx: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const c = img.at(@intCast(x), @intCast(y));
            // Find existing color
            var found_idx: ?usize = null;
            for (0..unique_count) |p_i| {
                const pc = palette[p_i];
                if (pc.r == c.r and pc.g == c.g and pc.b == c.b and pc.a == c.a) {
                    found_idx = p_i;
                    break;
                }
            }

            if (found_idx) |fi| {
                pixel_indices[idx] = @intCast(fi);
            } else if (unique_count < 256) {
                palette[unique_count] = c;
                pixel_indices[idx] = @intCast(unique_count);
                unique_count += 1;
            } else {
                // Find closest match
                var best_dist: u64 = std.math.maxInt(u64);
                var best_i: usize = 0;
                for (0..256) |p_i| {
                    const pc = palette[p_i];
                    const dr = @as(i64, pc.r) - @as(i64, c.r);
                    const dg = @as(i64, pc.g) - @as(i64, c.g);
                    const db = @as(i64, pc.b) - @as(i64, c.b);
                    const dist: u64 = @intCast(dr * dr + dg * dg + db * db);
                    if (dist < best_dist) {
                        best_dist = dist;
                        best_i = p_i;
                    }
                }
                pixel_indices[idx] = @intCast(best_i);
            }
            idx += 1;
        }
    }

    // Write Global Color Table (256 * 3 bytes)
    for (palette) |c| {
        try out.append(allocator, c.r);
        try out.append(allocator, c.g);
        try out.append(allocator, c.b);
    }

    // 4. Image Descriptor
    try out.append(allocator, 0x2C); // Image separator
    var id: [9]u8 = undefined;
    mem.writeInt(u16, id[0..2], 0, .little); // left = 0
    mem.writeInt(u16, id[2..4], 0, .little); // top = 0
    mem.writeInt(u16, id[4..6], w, .little);
    mem.writeInt(u16, id[6..8], h, .little);
    id[8] = 0x00; // No local color table, non-interlaced
    try out.appendSlice(allocator, &id);

    // 5. LZW Minimum Code Size
    const lit_width: u4 = 8;
    try out.append(allocator, lit_width);

    // Compress pixel indices via LZW
    var lzw_buffer = bytes.Buffer.init(allocator);
    defer lzw_buffer.deinit();

    var lzw_w = try lzw.newWriter(lzw_buffer.writer(), .LSB, lit_width);
    const written = try lzw_w.write(pixel_indices);
    std.debug.assert(written == pixel_indices.len);
    try lzw_w.close();

    // Write LZW sub-blocks (each max 255 bytes)
    const compressed_bytes = lzw_buffer.bytes();
    var offset: usize = 0;
    while (offset < compressed_bytes.len) {
        const chunk = @min(255, compressed_bytes.len - offset);
        try out.append(allocator, @intCast(chunk));
        try out.appendSlice(allocator, compressed_bytes[offset .. offset + chunk]);
        offset += chunk;
    }
    // Block terminator
    try out.append(allocator, 0x00);

    // 6. Trailer: 0x3B
    try out.append(allocator, 0x3B);

    return try out.toOwnedSlice(allocator);
}

test "gif encode and decode roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create 4x4 test image with red, green, blue, yellow pixels
    const img = try RGBAImage.init(allocator, Rectangle.rect(0, 0, 4, 4));
    defer img.deinit();

    const red = color.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const green = color.RGBA{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const blue = color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const white = color.RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 };

    img.set(0, 0, red);
    img.set(1, 0, green);
    img.set(2, 0, blue);
    img.set(3, 0, white);

    // Encode to GIF
    const gif_data = try encode(allocator, img);
    defer allocator.free(gif_data);

    try testing.expect(gif_data.len > 0);
    try testing.expectEqualStrings("GIF89a", gif_data[0..6]);
    try testing.expectEqual(@as(u8, 0x3B), gif_data[gif_data.len - 1]);

    // Decode back
    const decoded = try decode(allocator, gif_data);
    defer decoded.deinit();

    try testing.expectEqual(@as(i32, 4), decoded.rect.dx());
    try testing.expectEqual(@as(i32, 4), decoded.rect.dy());

    // Verify colors
    try testing.expectEqual(red.r, decoded.at(0, 0).r);
    try testing.expectEqual(red.g, decoded.at(0, 0).g);
    try testing.expectEqual(red.b, decoded.at(0, 0).b);

    try testing.expectEqual(green.r, decoded.at(1, 0).r);
    try testing.expectEqual(green.g, decoded.at(1, 0).g);
    try testing.expectEqual(green.b, decoded.at(1, 0).b);

    try testing.expectEqual(blue.r, decoded.at(2, 0).r);
    try testing.expectEqual(blue.g, decoded.at(2, 0).g);
    try testing.expectEqual(blue.b, decoded.at(2, 0).b);
}

test "gif decode invalid header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const invalid = "NOTAGIF";
    try testing.expectError(error.BadGIFHeader, decode(allocator, invalid));
}
