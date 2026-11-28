const std = @import("std");
const Allocator = std.mem.Allocator;

pub const color = @import("image/color.zig");
pub const draw = @import("image/draw.zig");
pub const png = @import("image/png.zig");
pub const gif = @import("image/gif.zig");

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn pt(x: i32, y: i32) Point {
        return .{ .x = x, .y = y };
    }

    pub fn eq(self: Point, q: Point) bool {
        return self.x == q.x and self.y == q.y;
    }

    pub fn add(self: Point, q: Point) Point {
        return .{ .x = self.x + q.x, .y = self.y + q.y };
    }

    pub fn sub(self: Point, q: Point) Point {
        return .{ .x = self.x - q.x, .y = self.y - q.y };
    }

    pub fn mul(self: Point, k: i32) Point {
        return .{ .x = self.x * k, .y = self.y * k };
    }

    pub fn div(self: Point, k: i32) Point {
        return .{ .x = @divTrunc(self.x, k), .y = @divTrunc(self.y, k) };
    }

    pub fn in(self: Point, r: Rectangle) bool {
        return r.min.x <= self.x and self.x < r.max.x and r.min.y <= self.y and self.y < r.max.y;
    }
};

pub const pt = Point.pt;

pub const Rectangle = struct {
    min: Point = .{},
    max: Point = .{},

    pub fn rect(x0: i32, y0: i32, x1: i32, y1: i32) Rectangle {
        var x_min = x0;
        var x_max = x1;
        if (x0 > x1) {
            x_min = x1;
            x_max = x0;
        }
        var y_min = y0;
        var y_max = y1;
        if (y0 > y1) {
            y_min = y1;
            y_max = y0;
        }
        return .{
            .min = pt(x_min, y_min),
            .max = pt(x_max, y_max),
        };
    }

    pub fn dx(self: Rectangle) i32 {
        return self.max.x - self.min.x;
    }

    pub fn dy(self: Rectangle) i32 {
        return self.max.y - self.min.y;
    }

    pub fn size(self: Rectangle) Point {
        return pt(self.dx(), self.dy());
    }

    pub fn empty(self: Rectangle) bool {
        return self.min.x >= self.max.x or self.min.y >= self.max.y;
    }

    pub fn eq(self: Rectangle, s: Rectangle) bool {
        return self.min.eq(s.min) and self.max.eq(s.max);
    }

    pub fn intersect(self: Rectangle, s: Rectangle) Rectangle {
        if (self.empty()) return self;
        if (s.empty()) return s;
        const r = Rectangle{
            .min = pt(@max(self.min.x, s.min.x), @max(self.min.y, s.min.y)),
            .max = pt(@min(self.max.x, s.max.x), @min(self.max.y, s.max.y)),
        };
        if (r.empty()) return Rectangle{};
        return r;
    }

    pub fn unionRect(self: Rectangle, s: Rectangle) Rectangle {
        if (self.empty()) return s;
        if (s.empty()) return self;
        return Rectangle{
            .min = pt(@min(self.min.x, s.min.x), @min(self.min.y, s.min.y)),
            .max = pt(@max(self.max.x, s.max.x), @max(self.max.y, s.max.y)),
        };
    }

    pub fn inset(self: Rectangle, n: i32) Rectangle {
        var r = self;
        if (r.dx() < 2 * n) {
            r.min.x = @divTrunc(r.min.x + r.max.x, 2);
            r.max.x = r.min.x;
        } else {
            r.min.x += n;
            r.max.x -= n;
        }
        if (r.dy() < 2 * n) {
            r.min.y = @divTrunc(r.min.y + r.max.y, 2);
            r.max.y = r.min.y;
        } else {
            r.min.y += n;
            r.max.y -= n;
        }
        return r;
    }
};

pub const rect = Rectangle.rect;

pub const RGBAImage = struct {
    pix: []u8,
    stride: usize,
    rect: Rectangle,
    allocator: ?Allocator = null,

    pub fn init(alloc: Allocator, r: Rectangle) !*RGBAImage {
        const w = @max(0, r.dx());
        const h = @max(0, r.dy());
        const w_u: usize = @intCast(w);
        const h_u: usize = @intCast(h);
        const stride = std.math.mul(usize, w_u, 4) catch return error.OutOfMemory;
        const total_bytes = std.math.mul(usize, stride, h_u) catch return error.OutOfMemory;

        const pix = try alloc.alloc(u8, total_bytes);
        errdefer alloc.free(pix);
        @memset(pix, 0);

        const img = try alloc.create(RGBAImage);
        img.* = .{
            .pix = pix,
            .stride = stride,
            .rect = r,
            .allocator = alloc,
        };
        return img;
    }

    pub fn deinit(self: *RGBAImage) void {
        if (self.allocator) |alloc| {
            alloc.free(self.pix);
            alloc.destroy(self);
        }
    }

    pub fn bounds(self: *const RGBAImage) Rectangle {
        return self.rect;
    }

    pub fn pixOffset(self: *const RGBAImage, x: i32, y: i32) usize {
        const row = @as(usize, @intCast(y - self.rect.min.y));
        const col = @as(usize, @intCast(x - self.rect.min.x));
        return row * self.stride + col * 4;
    }

    pub fn at(self: *const RGBAImage, x: i32, y: i32) color.RGBA {
        if (!pt(x, y).in(self.rect)) {
            return color.RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 };
        }
        const i = self.pixOffset(x, y);
        return color.RGBA{
            .r = self.pix[i],
            .g = self.pix[i + 1],
            .b = self.pix[i + 2],
            .a = self.pix[i + 3],
        };
    }

    pub fn set(self: *RGBAImage, x: i32, y: i32, c: color.RGBA) void {
        if (!pt(x, y).in(self.rect)) return;
        const i = self.pixOffset(x, y);
        self.pix[i] = c.r;
        self.pix[i + 1] = c.g;
        self.pix[i + 2] = c.b;
        self.pix[i + 3] = c.a;
    }

    pub fn setRGBA(self: *RGBAImage, x: i32, y: i32, c: color.RGBA) void {
        self.set(x, y, c);
    }

    /// Returns an image representing the portion of the image visible through `r`.
    /// The returned value shares pixels with the original image.
    pub fn subImage(self: *RGBAImage, r: Rectangle) RGBAImage {
        const inter = self.rect.intersect(r);
        if (inter.empty()) {
            return RGBAImage{
                .pix = &.{},
                .stride = self.stride,
                .rect = Rectangle{},
                .allocator = null,
            };
        }
        const offset = self.pixOffset(inter.min.x, inter.min.y);
        return RGBAImage{
            .pix = self.pix[offset..],
            .stride = self.stride,
            .rect = inter,
            .allocator = null,
        };
    }
};

pub const GrayImage = struct {
    pix: []u8,
    stride: usize,
    rect: Rectangle,
    allocator: ?Allocator = null,

    pub fn init(alloc: Allocator, r: Rectangle) !*GrayImage {
        const w = @max(0, r.dx());
        const h = @max(0, r.dy());
        const stride: usize = @intCast(w);
        const h_u: usize = @intCast(h);
        const total_bytes = std.math.mul(usize, stride, h_u) catch return error.OutOfMemory;

        const pix = try alloc.alloc(u8, total_bytes);
        errdefer alloc.free(pix);
        @memset(pix, 0);

        const img = try alloc.create(GrayImage);
        img.* = .{
            .pix = pix,
            .stride = stride,
            .rect = r,
            .allocator = alloc,
        };
        return img;
    }

    pub fn deinit(self: *GrayImage) void {
        if (self.allocator) |alloc| {
            alloc.free(self.pix);
            alloc.destroy(self);
        }
    }

    pub fn bounds(self: *const GrayImage) Rectangle {
        return self.rect;
    }

    pub fn pixOffset(self: *const GrayImage, x: i32, y: i32) usize {
        const row = @as(usize, @intCast(y - self.rect.min.y));
        const col = @as(usize, @intCast(x - self.rect.min.x));
        return row * self.stride + col;
    }

    pub fn at(self: *const GrayImage, x: i32, y: i32) color.Gray {
        if (!pt(x, y).in(self.rect)) {
            return color.Gray{ .y = 0 };
        }
        const i = self.pixOffset(x, y);
        return color.Gray{ .y = self.pix[i] };
    }

    pub fn set(self: *GrayImage, x: i32, y: i32, c: color.Gray) void {
        if (!pt(x, y).in(self.rect)) return;
        const i = self.pixOffset(x, y);
        self.pix[i] = c.y;
    }

    pub fn setGray(self: *GrayImage, x: i32, y: i32, c: color.Gray) void {
        self.set(x, y, c);
    }
};

test "point and rectangle geometry" {
    const testing = std.testing;

    const p = pt(10, 20);
    const q = pt(5, 5);

    try testing.expect(p.add(q).eq(pt(15, 25)));
    try testing.expect(p.sub(q).eq(pt(5, 15)));
    try testing.expect(p.mul(2).eq(pt(20, 40)));
    try testing.expect(p.div(2).eq(pt(5, 10)));

    const r1 = rect(0, 0, 100, 100);
    try testing.expect(p.in(r1));
    try testing.expect(!pt(100, 100).in(r1)); // boundary is exclusive for max

    const r2 = rect(50, 50, 150, 150);
    const inter = r1.intersect(r2);
    try testing.expect(inter.eq(rect(50, 50, 100, 100)));

    const un = r1.unionRect(r2);
    try testing.expect(un.eq(rect(0, 0, 150, 150)));

    try testing.expect(r1.inset(10).eq(rect(10, 10, 90, 90)));
    try testing.expect(r1.inset(-10).eq(rect(-10, -10, 110, 110)));
    try testing.expect(rect(0, 0, 3, 100).inset(2).eq(rect(1, 2, 1, 98)));
    // Like Go, the midpoint truncates toward zero: (-5 + -2) / 2 == -3.
    try testing.expect(rect(-5, 0, -2, 3).inset(2).eq(rect(-3, 1, -3, 1)));
}

test "RGBAImage and subImage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var img = try RGBAImage.init(alloc, rect(0, 0, 10, 10));
    defer img.deinit();

    try testing.expectEqual(@as(i32, 10), img.bounds().dx());
    try testing.expectEqual(@as(i32, 10), img.bounds().dy());

    const red = color.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 };
    img.set(2, 3, red);

    const got = img.at(2, 3);
    try testing.expectEqual(@as(u8, 255), got.r);
    try testing.expectEqual(@as(u8, 0), got.g);
    try testing.expectEqual(@as(u8, 255), got.a);

    // subImage shares memory
    var sub = img.subImage(rect(0, 0, 5, 5));
    const sub_got = sub.at(2, 3);
    try testing.expectEqual(@as(u8, 255), sub_got.r);

    // modifying subImage reflects in img
    const blue = color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 };
    sub.set(2, 3, blue);
    try testing.expectEqual(@as(u8, 255), img.at(2, 3).b);

    // subImage with non-zero origin slices pix at the right offset
    const green = color.RGBA{ .r = 0, .g = 255, .b = 0, .a = 255 };
    img.set(4, 5, green);
    var offset_sub = img.subImage(rect(3, 4, 8, 8));
    try testing.expectEqual(@as(u8, 255), offset_sub.at(4, 5).g);
    const yellow = color.RGBA{ .r = 255, .g = 255, .b = 0, .a = 255 };
    offset_sub.set(4, 5, yellow);
    try testing.expectEqual(@as(u8, 255), img.at(4, 5).r);
    try testing.expectEqual(@as(u8, 255), img.at(4, 5).g);
}

test "GrayImage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var img = try GrayImage.init(alloc, rect(0, 0, 8, 8));
    defer img.deinit();

    img.set(4, 4, color.Gray{ .y = 128 });
    try testing.expectEqual(@as(u8, 128), img.at(4, 4).y);
    try testing.expectEqual(@as(u8, 0), img.at(0, 0).y);
}

test {
    std.testing.refAllDecls(@This());
    _ = color;
    _ = draw;
    _ = png;
}
