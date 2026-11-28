const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Managed = std.math.big.int.Managed;
const Const = std.math.big.int.Const;

pub const Int = struct {
    managed: Managed,

    pub fn init(alloc: Allocator) !Int {
        return .{
            .managed = try Managed.init(alloc),
        };
    }

    pub fn initSet(alloc: Allocator, val: anytype) !Int {
        var res = try Int.init(alloc);
        errdefer res.deinit();
        _ = try res.set(val);
        return res;
    }

    pub fn deinit(self: *Int) void {
        self.managed.deinit();
    }

    pub fn clone(self: *const Int) !Int {
        return .{
            .managed = try self.managed.clone(),
        };
    }

    pub fn getAllocator(self: *const Int) Allocator {
        return self.managed.allocator;
    }

    /// Set self = x, returns self
    pub fn set(self: *Int, x: anytype) !*Int {
        const T = @TypeOf(x);
        if (T == *Int or T == *const Int or T == Int) {
            try self.managed.copy(x.managed.toConst());
        } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            try self.managed.set(x);
        } else {
            @compileError("Unsupported type for Int.set: " ++ @typeName(T));
        }
        return self;
    }

    pub fn setInt64(self: *Int, x: i64) !*Int {
        return try self.set(x);
    }

    pub fn setUint64(self: *Int, x: u64) !*Int {
        return try self.set(x);
    }

    /// Parse string in given base (0 = auto-detect prefix, or 2..36).
    pub fn setString(self: *Int, s: []const u8, base: u8) !*Int {
        if (s.len == 0) return error.InvalidSyntax;

        var str = s;
        var negative = false;
        if (str[0] == '+') {
            str = str[1..];
        } else if (str[0] == '-') {
            negative = true;
            str = str[1..];
        }
        if (str.len == 0) return error.InvalidSyntax;

        var actual_base = base;
        if (actual_base == 0) {
            if (str.len >= 2 and str[0] == '0') {
                switch (str[1]) {
                    'x', 'X' => {
                        actual_base = 16;
                        str = str[2..];
                    },
                    'b', 'B' => {
                        actual_base = 2;
                        str = str[2..];
                    },
                    'o', 'O' => {
                        actual_base = 8;
                        str = str[2..];
                    },
                    else => {
                        actual_base = 10;
                    },
                }
            } else {
                actual_base = 10;
            }
        }

        if (str.len == 0) return error.InvalidSyntax;
        try self.managed.setString(actual_base, str);
        if (negative and !self.isZero()) {
            self.managed.setSign(false);
        }
        return self;
    }

    pub fn isZero(self: *const Int) bool {
        return self.managed.len() == 1 and self.managed.limbs[0] == 0;
    }

    pub fn sign(self: *const Int) i8 {
        if (self.isZero()) return 0;
        return if (self.managed.isPositive()) 1 else -1;
    }

    /// Returns -1 if self < y, 0 if self == y, 1 if self > y
    pub fn cmp(self: *const Int, y: *const Int) i8 {
        const order = self.managed.toConst().order(y.managed.toConst());
        return switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// Returns -1 if |self| < |y|, 0 if |self| == |y|, 1 if |self| > |y|
    pub fn cmpAbs(self: *const Int, y: *const Int) i8 {
        const order = self.managed.toConst().orderAbs(y.managed.toConst());
        return switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// self = -x
    pub fn neg(self: *Int, x: *const Int) !*Int {
        _ = try self.set(x);
        if (!self.isZero()) {
            self.managed.setSign(!self.managed.isPositive());
        }
        return self;
    }

    /// self = |x|
    pub fn abs(self: *Int, x: *const Int) !*Int {
        _ = try self.set(x);
        self.managed.setSign(true);
        return self;
    }

    /// self = x + y
    pub fn add(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.add(&x.managed, &y.managed);
        return self;
    }

    /// self = x - y
    pub fn sub(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.sub(&x.managed, &y.managed);
        return self;
    }

    /// self = x * y
    pub fn mul(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.mul(&x.managed, &y.managed);
        return self;
    }

    /// self = x / y (Euclidean quotient: remainder is non-negative)
    pub fn div(self: *Int, x: *const Int, y: *const Int) !*Int {
        var rem = try Int.init(self.getAllocator());
        defer rem.deinit();
        try self.divMod(x, y, &rem);
        return self;
    }

    /// self = x % y (Euclidean remainder: 0 <= self < |y|)
    pub fn mod(self: *Int, x: *const Int, y: *const Int) !*Int {
        var quo = try Int.init(self.getAllocator());
        defer quo.deinit();
        try quo.divMod(x, y, self);
        return self;
    }

    /// self = x / y, m = x % y (Truncated/Euclidean division)
    pub fn divMod(self: *Int, x: *const Int, y: *const Int, m: *Int) !void {
        if (y.isZero()) return error.DivisionByZero;
        try Managed.divFloor(&self.managed, &m.managed, &x.managed, &y.managed);
    }

    /// self = x & y
    pub fn bitAnd(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.bitAnd(&x.managed, &y.managed);
        return self;
    }

    /// self = x | y
    pub fn bitOr(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.bitOr(&x.managed, &y.managed);
        return self;
    }

    /// self = x ^ y
    pub fn bitXor(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.bitXor(&x.managed, &y.managed);
        return self;
    }

    /// self = x << n
    pub fn lsh(self: *Int, x: *const Int, n: usize) !*Int {
        try self.managed.shiftLeft(&x.managed, n);
        return self;
    }

    /// self = x >> n
    pub fn rsh(self: *Int, x: *const Int, n: usize) !*Int {
        try self.managed.shiftRight(&x.managed, n);
        return self;
    }

    /// Returns bit at index i (0 or 1)
    pub fn bit(self: *const Int, i: usize) u1 {
        const limb_bits = @typeInfo(std.math.big.Limb).int.bits;
        const limb_index = i / limb_bits;
        if (limb_index >= self.managed.len()) return 0;
        const bit_offset: std.math.Log2Int(std.math.big.Limb) = @intCast(i % limb_bits);
        return @truncate((self.managed.limbs[limb_index] >> bit_offset) & 1);
    }

    /// self = x with bit i set to b (0 or 1)
    pub fn setBit(self: *Int, x: *const Int, i: usize, b: u1) !*Int {
        _ = try self.set(x);
        const limb_bits = @typeInfo(std.math.big.Limb).int.bits;
        const limb_index = i / limb_bits;
        const bit_offset: std.math.Log2Int(std.math.big.Limb) = @intCast(i % limb_bits);

        if (limb_index >= self.managed.len()) {
            if (b == 0) return self;
            try self.managed.ensureCapacity(limb_index + 1);
            while (self.managed.len() <= limb_index) {
                const current_len = self.managed.len();
                self.managed.limbs[current_len] = 0;
                self.managed.setLen(current_len + 1);
            }
        }

        const mask: std.math.big.Limb = @as(std.math.big.Limb, 1) << bit_offset;
        if (b == 1) {
            self.managed.limbs[limb_index] |= mask;
        } else {
            self.managed.limbs[limb_index] &= ~mask;
            // re-normalize length
            var l = self.managed.len();
            while (l > 1 and self.managed.limbs[l - 1] == 0) : (l -= 1) {}
            self.managed.setLen(l);
        }
        return self;
    }

    /// Bit length of absolute value
    pub fn bitLen(self: *const Int) usize {
        return self.managed.toConst().bitCountAbs();
    }

    /// Trailing zero bits
    pub fn trailingZeroBits(self: *const Int) usize {
        if (self.isZero()) return 0;
        var count: usize = 0;
        const c = self.managed.toConst();
        for (c.limbs) |limb| {
            if (limb == 0) {
                count += @typeInfo(std.math.big.Limb).int.bits;
            } else {
                count += @ctz(limb);
                break;
            }
        }
        return count;
    }

    /// self = gcd(x, y)
    pub fn gcd(self: *Int, x: *const Int, y: *const Int) !*Int {
        try self.managed.gcd(&x.managed, &y.managed);
        return self;
    }

    /// Modular exponentiation: self = (x^y) % m (if m != null and m > 0)
    /// or self = x^y (if m == null)
    pub fn exp(self: *Int, x: *const Int, y: *const Int, m: ?*const Int) !*Int {
        if (y.sign() < 0) return error.NegativeExponent;

        if (m) |mod_val| {
            if (mod_val.isZero()) return error.DivisionByZero;
            if (y.isZero()) {
                var one = try Int.initSet(self.getAllocator(), @as(u32, 1));
                defer one.deinit();
                _ = try self.mod(&one, mod_val);
                return self;
            }

            // Binary modular exponentiation
            var base = try Int.init(self.getAllocator());
            defer base.deinit();
            _ = try base.mod(x, mod_val);

            var exp_copy = try y.clone();
            defer exp_copy.deinit();

            var result = try Int.initSet(self.getAllocator(), @as(u32, 1));
            defer result.deinit();

            var temp = try Int.init(self.getAllocator());
            defer temp.deinit();

            while (!exp_copy.isZero()) {
                if (exp_copy.bit(0) == 1) {
                    _ = try temp.mul(&result, &base);
                    _ = try result.mod(&temp, mod_val);
                }
                _ = try temp.mul(&base, &base);
                _ = try base.mod(&temp, mod_val);
                _ = try exp_copy.rsh(&exp_copy, 1);
            }

            _ = try self.set(&result);
            return self;
        } else {
            // Normal pow: y must fit in u32
            if (y.bitLen() > 32) return error.ExponentTooLarge;
            const exp_u32: u32 = @intCast(y.managed.limbs[0]);
            try self.managed.pow(&x.managed, exp_u32);
            return self;
        }
    }

    /// Returns string in requested base (2..36). Caller owns returned memory.
    pub fn text(self: *const Int, alloc: Allocator, base: u8) ![]u8 {
        if (base < 2 or base > 36) return error.InvalidBase;
        return self.managed.toString(alloc, base, .lower);
    }

    /// String representation in base 10. Caller owns returned memory.
    pub fn string(self: *const Int, alloc: Allocator) ![]u8 {
        return self.text(alloc, 10);
    }

    /// Formats Int for std.fmt
    pub fn format(self: Int, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.managed.format(w);
    }

    /// Returns the i64 representation of self, or null if it does not fit in an i64.
    pub fn int64(self: *const Int) ?i64 {
        return self.managed.toConst().toInt(i64) catch null;
    }

    /// Returns the u64 representation of self, or null if it does not fit in a u64.
    pub fn uint64(self: *const Int) ?u64 {
        return self.managed.toConst().toInt(u64) catch null;
    }
};

test "Int basic arithmetic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try Int.initSet(alloc, @as(i64, 100));
    defer a.deinit();

    var b = try Int.initSet(alloc, @as(i64, 42));
    defer b.deinit();

    var c = try Int.init(alloc);
    defer c.deinit();

    _ = try c.add(&a, &b);
    try testing.expectEqual(@as(i64, 142), c.int64().?);

    _ = try c.sub(&a, &b);
    try testing.expectEqual(@as(i64, 58), c.int64().?);

    _ = try c.mul(&a, &b);
    try testing.expectEqual(@as(i64, 4200), c.int64().?);

    _ = try c.div(&a, &b);
    try testing.expectEqual(@as(i64, 2), c.int64().?);

    _ = try c.mod(&a, &b);
    try testing.expectEqual(@as(i64, 16), c.int64().?);
}

test "Int string parsing and formatting" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var x = try Int.init(alloc);
    defer x.deinit();

    _ = try x.setString("123456789012345678901234567890", 10);
    const s1 = try x.string(alloc);
    defer alloc.free(s1);
    try testing.expectEqualStrings("123456789012345678901234567890", s1);

    // Auto-detect hex prefix
    _ = try x.setString("0xff", 0);
    try testing.expectEqual(@as(u64, 255), x.uint64().?);

    // Auto-detect binary prefix
    _ = try x.setString("0b101010", 0);
    try testing.expectEqual(@as(u64, 42), x.uint64().?);

    // Negative parsing
    _ = try x.setString("-999", 10);
    try testing.expectEqual(@as(i64, -999), x.int64().?);
    try testing.expectEqual(@as(i8, -1), x.sign());

    // minInt(i64) and maxInt(u64)
    _ = try x.setInt64(std.math.minInt(i64));
    try testing.expectEqual(std.math.minInt(i64), x.int64().?);
    try testing.expectEqual(@as(?u64, null), x.uint64());

    _ = try x.setUint64(std.math.maxInt(u64));
    try testing.expectEqual(std.math.maxInt(u64), x.uint64().?);
    try testing.expectEqual(@as(?i64, null), x.int64());
}

test "Int modular exponentiation and bit ops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var base = try Int.initSet(alloc, @as(u32, 4));
    defer base.deinit();

    var exp_val = try Int.initSet(alloc, @as(u32, 13));
    defer exp_val.deinit();

    var mod_val = try Int.initSet(alloc, @as(u32, 497));
    defer mod_val.deinit();

    var res = try Int.init(alloc);
    defer res.deinit();

    // 4^13 mod 497 = 445
    _ = try res.exp(&base, &exp_val, &mod_val);
    try testing.expectEqual(@as(u64, 445), res.uint64().?);

    // Bits
    _ = try res.setBit(&base, 10, 1);
    try testing.expectEqual(@as(u1, 1), res.bit(10));
    try testing.expectEqual(@as(u1, 1), res.bit(2)); // 4 is 1 << 2
    try testing.expectEqual(@as(u1, 0), res.bit(0));
}

test "Int comparisons and bitwise ops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try Int.initSet(alloc, @as(i64, 48));
    defer a.deinit();

    var b = try Int.initSet(alloc, @as(i64, 18));
    defer b.deinit();

    var g = try Int.init(alloc);
    defer g.deinit();

    _ = try g.gcd(&a, &b);
    try testing.expectEqual(@as(i64, 6), g.int64().?);

    // Comparisons
    try testing.expectEqual(@as(i8, 1), a.cmp(&b));
    try testing.expectEqual(@as(i8, -1), b.cmp(&a));
    try testing.expectEqual(@as(i8, 0), a.cmp(&a));

    // Shifts
    var sh = try Int.init(alloc);
    defer sh.deinit();
    _ = try sh.lsh(&b, 2); // 18 << 2 = 72
    try testing.expectEqual(@as(i64, 72), sh.int64().?);

    _ = try sh.rsh(&sh, 1); // 72 >> 1 = 36
    try testing.expectEqual(@as(i64, 36), sh.int64().?);

    // Bitwise and / or / xor
    var bit_res = try Int.init(alloc);
    defer bit_res.deinit();
    _ = try bit_res.bitAnd(&a, &b); // 48 & 18 = 0b110000 & 0b010010 = 0b010000 = 16
    try testing.expectEqual(@as(i64, 16), bit_res.int64().?);

    _ = try bit_res.bitOr(&a, &b); // 48 | 18 = 0b110000 | 0b010010 = 0b110010 = 50
    try testing.expectEqual(@as(i64, 50), bit_res.int64().?);

    _ = try bit_res.bitXor(&a, &b); // 48 ^ 18 = 0b110000 ^ 0b010010 = 0b100010 = 34
    try testing.expectEqual(@as(i64, 34), bit_res.int64().?);

    // Trailing zero bits: 48 = 0b110000 -> 4 trailing zeros
    try testing.expectEqual(@as(usize, 4), a.trailingZeroBits());
}
