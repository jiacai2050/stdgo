//! Package image/draw provides Porter-Duff image compositing operators and drawing primitives.
//!
//! Implements Over and Src operators with pre-multiplied alpha channel blending,
//! supporting boundary clipping and arbitrary sub-rectangle alignment.

const std = @import("std");
const image = @import("../image.zig");
const color = image.color;
const Point = image.Point;
const Rectangle = image.Rectangle;
const RGBAImage = image.RGBAImage;

/// Op represents a Porter-Duff compositing operator.
pub const Op = enum {
    Over,
    Src,
};

/// Draw aligns src with sp and composites the result into r of dst using op.
fn blendComponent(src: u8, dst: u8, inv_a: u32) u8 {
    const term = (@as(u32, dst) * inv_a + 127) / 255;
    return @intCast(@min(255, @as(u32, src) + term));
}

pub fn draw(dst: *RGBAImage, r: Rectangle, src: *const RGBAImage, sp: Point, op: Op) void {
    const clip_r = r.intersect(dst.bounds());
    if (clip_r.empty()) return;

    var y = clip_r.min.y;
    while (y < clip_r.max.y) : (y += 1) {
        var x = clip_r.min.x;
        while (x < clip_r.max.x) : (x += 1) {
            const sx = sp.x + (x - r.min.x);
            const sy = sp.y + (y - r.min.y);

            const src_c = src.at(sx, sy);
            if (op == .Src) {
                dst.set(x, y, src_c);
            } else {
                // Porter-Duff Over operator with pre-multiplied alpha
                const dst_c = dst.at(x, y);
                const inv_a: u32 = 255 - @as(u32, src_c.a);

                const out_r = blendComponent(src_c.r, dst_c.r, inv_a);
                const out_g = blendComponent(src_c.g, dst_c.g, inv_a);
                const out_b = blendComponent(src_c.b, dst_c.b, inv_a);
                const out_a = blendComponent(src_c.a, dst_c.a, inv_a);

                dst.set(x, y, color.RGBA{
                    .r = out_r,
                    .g = out_g,
                    .b = out_b,
                    .a = out_a,
                });
            }
        }
    }
}

pub fn drawColor(dst: *RGBAImage, r: Rectangle, c: color.RGBA, op: Op) void {
    const clip_r = r.intersect(dst.bounds());
    if (clip_r.empty()) return;

    var y = clip_r.min.y;
    while (y < clip_r.max.y) : (y += 1) {
        var x = clip_r.min.x;
        while (x < clip_r.max.x) : (x += 1) {
            if (op == .Src) {
                dst.set(x, y, c);
            } else {
                const dst_c = dst.at(x, y);
                const inv_a: u32 = 255 - @as(u32, c.a);

                const out_r = blendComponent(c.r, dst_c.r, inv_a);
                const out_g = blendComponent(c.g, dst_c.g, inv_a);
                const out_b = blendComponent(c.b, dst_c.b, inv_a);
                const out_a = blendComponent(c.a, dst_c.a, inv_a);

                dst.set(x, y, color.RGBA{
                    .r = out_r,
                    .g = out_g,
                    .b = out_b,
                    .a = out_a,
                });
            }
        }
    }
}

test "image/draw Src and Over compositing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dst = try RGBAImage.init(allocator, Rectangle.rect(0, 0, 4, 4));
    defer dst.deinit();

    // Fill dst with opaque blue
    drawColor(dst, dst.bounds(), color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }, .Src);
    try testing.expectEqual(color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }, dst.at(0, 0));

    // Create src with semi-transparent red (50% red pre-multiplied: r=128, a=128)
    var src = try RGBAImage.init(allocator, Rectangle.rect(0, 0, 2, 2));
    defer src.deinit();
    drawColor(src, src.bounds(), color.RGBA{ .r = 128, .g = 0, .b = 0, .a = 128 }, .Src);

    // Composite src over top-left quadrant of dst
    draw(dst, Rectangle.rect(0, 0, 2, 2), src, Point.pt(0, 0), .Over);

    // Pixel at (0, 0) should blend red (128) and blue (255 * (127/255) = 127)
    const blended = dst.at(0, 0);
    try testing.expectEqual(@as(u8, 128), blended.r);
    try testing.expectEqual(@as(u8, 0), blended.g);
    try testing.expectEqual(@as(u8, 127), blended.b);
    try testing.expectEqual(@as(u8, 255), blended.a);

    // Untouched pixel at (3, 3) must remain solid blue
    try testing.expectEqual(color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }, dst.at(3, 3));
}
