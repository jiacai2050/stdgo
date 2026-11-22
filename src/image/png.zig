//! Package image/png implements a PNG (Portable Network Graphics) image decoder and encoder.
//!
//! Supports standard 8-byte PNG header validation, IHDR metadata, 5 scanline filter methods
//! (None, Sub, Up, Average, Paeth), zlib-compressed IDAT streaming, and IEND termination.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const image = @import("../image.zig");
const color = image.color;
const Rectangle = image.Rectangle;
const RGBAImage = image.RGBAImage;
const zlib = @import("../compress/zlib.zig");

/// PNG standard 8-byte file signature.
pub const png_magic = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Header represents the parsed PNG IHDR chunk metadata.
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression: u8,
    filter: u8,
    interlace: u8,
};

fn paethPredictor(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Decode decodes a PNG-encoded byte slice and returns a newly allocated RGBAImage.
pub fn decode(allocator: Allocator, bytes: []const u8) !*RGBAImage {
    if (bytes.len < 8) return error.FormatError;
    if (!mem.eql(u8, bytes[0..8], &png_magic)) return error.BadPNGHeader;

    var pos: usize = 8;
    var header_opt: ?Header = null;
    var idat_buf = std.ArrayList(u8).empty;
    defer idat_buf.deinit(allocator);

    while (pos + 8 <= bytes.len) {
        const length = mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;
        const chunk_type = bytes[pos .. pos + 4];
        pos += 4;

        if (pos + length + 4 > bytes.len) return error.UnexpectedEof;
        const chunk_data = bytes[pos .. pos + length];
        pos += length;
        const chunk_crc = mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;

        // Verify CRC-32 over chunk_type + chunk_data
        var crc_calc = std.hash.Crc32.init();
        crc_calc.update(chunk_type);
        crc_calc.update(chunk_data);
        if (crc_calc.final() != chunk_crc) {
            return error.ChecksumError;
        }

        if (mem.eql(u8, chunk_type, "IHDR")) {
            if (length < 13) return error.FormatError;
            header_opt = Header{
                .width = mem.readInt(u32, chunk_data[0..4], .big),
                .height = mem.readInt(u32, chunk_data[4..8], .big),
                .bit_depth = chunk_data[8],
                .color_type = chunk_data[9],
                .compression = chunk_data[10],
                .filter = chunk_data[11],
                .interlace = chunk_data[12],
            };
        } else if (mem.eql(u8, chunk_type, "IDAT")) {
            try idat_buf.appendSlice(allocator, chunk_data);
        } else if (mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    const hdr = header_opt orelse return error.NoIHDR;
    if (hdr.width == 0 or hdr.height == 0) return error.InvalidDimensions;
    if (hdr.bit_depth != 8) return error.UnsupportedBitDepth;

    const bpp: usize = switch (hdr.color_type) {
        6 => 4, // RGBA
        2 => 3, // RGB
        0 => 1, // Grayscale
        else => return error.UnsupportedColorType,
    };

    // Decompress IDAT via zlib
    var idat_reader = std.Io.Reader.fixed(idat_buf.items);
    var z_reader = try zlib.newReader(allocator, &idat_reader);
    defer z_reader.deinit();

    var decomp_buf = std.ArrayList(u8).empty;
    defer decomp_buf.deinit(allocator);

    var chunk_buf: [1024]u8 = undefined;
    while (true) {
        var w = std.Io.Writer.fixed(&chunk_buf);
        const n = z_reader.reader().stream(&w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        try decomp_buf.appendSlice(allocator, chunk_buf[0..n]);
    }
    const decompressed = decomp_buf.items;

    if (hdr.width > 10000 or hdr.height > 10000) return error.InvalidDimensions;
    const stride = std.math.mul(usize, @as(usize, hdr.width), bpp) catch {
        return error.InvalidDimensions;
    };
    const scanline_len = stride + 1;
    const total_scanline_bytes = std.math.mul(
        usize,
        @as(usize, hdr.height),
        scanline_len,
    ) catch return error.InvalidDimensions;
    if (decompressed.len < total_scanline_bytes) {
        return error.UnexpectedEof;
    }

    const bounds = Rectangle.rect(0, 0, @intCast(hdr.width), @intCast(hdr.height));
    var img = try RGBAImage.init(allocator, bounds);
    errdefer img.deinit();

    const prior_line = try allocator.alloc(u8, stride);
    defer allocator.free(prior_line);
    @memset(prior_line, 0);

    var cur_line = try allocator.alloc(u8, stride);
    defer allocator.free(cur_line);

    var y: u32 = 0;
    while (y < hdr.height) : (y += 1) {
        const offset = @as(usize, y) * scanline_len;
        const filter_type = decompressed[offset];
        const raw_scan = decompressed[offset + 1 .. offset + 1 + stride];

        switch (filter_type) {
            0 => { // None
                @memcpy(cur_line, raw_scan);
            },
            1 => { // Sub
                for (0..stride) |i| {
                    const left: u8 = if (i >= bpp) cur_line[i - bpp] else 0;
                    cur_line[i] = raw_scan[i] +% left;
                }
            },
            2 => { // Up
                for (0..stride) |i| {
                    const up: u8 = prior_line[i];
                    cur_line[i] = raw_scan[i] +% up;
                }
            },
            3 => { // Average
                for (0..stride) |i| {
                    const left: u32 = if (i >= bpp) cur_line[i - bpp] else 0;
                    const up: u32 = prior_line[i];
                    const avg: u8 = @intCast((left + up) / 2);
                    cur_line[i] = raw_scan[i] +% avg;
                }
            },
            4 => { // Paeth
                for (0..stride) |i| {
                    const a: i32 = if (i >= bpp) cur_line[i - bpp] else 0;
                    const b: i32 = prior_line[i];
                    const c: i32 = if (i >= bpp) prior_line[i - bpp] else 0;
                    const pr: u8 = @intCast(paethPredictor(a, b, c));
                    cur_line[i] = raw_scan[i] +% pr;
                }
            },
            else => return error.UnsupportedFilter,
        }

        // Write reconstructed line to RGBAImage
        var x: u32 = 0;
        while (x < hdr.width) : (x += 1) {
            const px_offset = @as(usize, x) * bpp;
            if (bpp == 4) {
                img.set(@intCast(x), @intCast(y), color.RGBA{
                    .r = cur_line[px_offset],
                    .g = cur_line[px_offset + 1],
                    .b = cur_line[px_offset + 2],
                    .a = cur_line[px_offset + 3],
                });
            } else if (bpp == 3) {
                img.set(@intCast(x), @intCast(y), color.RGBA{
                    .r = cur_line[px_offset],
                    .g = cur_line[px_offset + 1],
                    .b = cur_line[px_offset + 2],
                    .a = 255,
                });
            } else if (bpp == 1) {
                const gray = cur_line[px_offset];
                img.set(@intCast(x), @intCast(y), color.RGBA{
                    .r = gray,
                    .g = gray,
                    .b = gray,
                    .a = 255,
                });
            }
        }

        @memcpy(prior_line, cur_line);
    }

    return img;
}

/// Encode writes the Image img to w in PNG format using 8-bit RGBA color and zlib compression.
pub fn encode(allocator: Allocator, writer: *std.Io.Writer, img: *const RGBAImage) !void {
    const width = @as(u32, @intCast(img.rect.dx()));
    const height = @as(u32, @intCast(img.rect.dy()));

    // 1. Write PNG Signature
    try writer.writeAll(&png_magic);

    // 2. Write IHDR chunk
    var ihdr_data: [13]u8 = undefined;
    mem.writeInt(u32, ihdr_data[0..4], width, .big);
    mem.writeInt(u32, ihdr_data[4..8], height, .big);
    ihdr_data[8] = 8; // 8 bits per channel
    ihdr_data[9] = 6; // RGBA color type
    ihdr_data[10] = 0; // Deflate compression
    ihdr_data[11] = 0; // Standard filter
    ihdr_data[12] = 0; // No interlace
    try writeChunk(writer, "IHDR", &ihdr_data);

    // 3. Prepare raw scanlines with Filter None (0)
    const stride = @as(usize, width) * 4;
    const scanline_size = 1 + stride;
    const raw_len = @as(usize, height) * scanline_size;
    const raw_data = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw_data);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_offset = @as(usize, y) * scanline_size;
        raw_data[row_offset] = 0; // Filter 0 (None)

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const c = img.at(@intCast(x), @intCast(y));
            const px = row_offset + 1 + @as(usize, x) * 4;
            raw_data[px] = c.r;
            raw_data[px + 1] = c.g;
            raw_data[px + 2] = c.b;
            raw_data[px + 3] = c.a;
        }
    }

    // 4. Compress raw scanlines via zlib
    var bytes_buf = @import("../bytes.zig").Buffer.init(allocator);
    defer bytes_buf.deinit();

    var z_writer = try zlib.newWriter(allocator, bytes_buf.writer());
    defer z_writer.deinit();
    try z_writer.writer().writeAll(raw_data);
    try z_writer.close();

    // 5. Write IDAT chunk
    try writeChunk(writer, "IDAT", bytes_buf.bytes());

    // 6. Write IEND chunk
    try writeChunk(writer, "IEND", &.{});
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(chunk_type);
    if (data.len > 0) {
        try writer.writeAll(data);
    }

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try writer.writeAll(&crc_buf);
}

test "image/png encode and decode roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create 4x4 RGBA test pattern
    var orig = try RGBAImage.init(allocator, Rectangle.rect(0, 0, 4, 4));
    defer orig.deinit();

    orig.set(0, 0, color.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 }); // Red
    orig.set(1, 1, color.RGBA{ .r = 0, .g = 255, .b = 0, .a = 255 }); // Green
    orig.set(2, 2, color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }); // Blue
    orig.set(3, 3, color.RGBA{ .r = 255, .g = 255, .b = 0, .a = 128 }); // Translucent Yellow

    // Encode to PNG memory buffer
    var png_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&png_buf);
    try encode(allocator, &writer, orig);

    const encoded_bytes = writer.buffered();
    try testing.expect(encoded_bytes.len > 8);
    try testing.expectEqualStrings(&png_magic, encoded_bytes[0..8]);

    // Decode back
    var decoded = try decode(allocator, encoded_bytes);
    defer decoded.deinit();

    try testing.expectEqual(@as(i32, 4), decoded.rect.dx());
    try testing.expectEqual(@as(i32, 4), decoded.rect.dy());

    try testing.expectEqual(color.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 }, decoded.at(0, 0));
    try testing.expectEqual(color.RGBA{ .r = 0, .g = 255, .b = 0, .a = 255 }, decoded.at(1, 1));
    try testing.expectEqual(color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }, decoded.at(2, 2));
    try testing.expectEqual(color.RGBA{ .r = 255, .g = 255, .b = 0, .a = 128 }, decoded.at(3, 3));
    try testing.expectEqual(color.RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 }, decoded.at(0, 1));
}
