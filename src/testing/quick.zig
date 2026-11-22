//! Package quick implements utility functions to help with black-box property-based testing,
//! conforming to Go's testing/quick package.
const std = @import("std");

pub const CheckError = error{
    CheckFailed,
    CheckEqualFailed,
};

pub const Config = struct {
    max_count: usize = 100,
    seed: u64 = 42,
};

/// ValueGenerator provides automatic pseudo-random generation of arbitrary Zig values
/// for property testing.
pub const Generator = struct {
    rand: std.Random,

    pub fn init(rand: std.Random) Generator {
        return .{ .rand = rand };
    }

    pub fn gen(self: Generator, comptime T: type) T {
        // If type has a custom generate function, delegate to it
        const is_custom = @typeInfo(T) == .@"struct" or
            @typeInfo(T) == .@"union" or
            @typeInfo(T) == .@"enum" or
            @typeInfo(T) == .@"opaque";
        if (is_custom) {
            if (@hasDecl(T, "generate")) {
                return T.generate(self.rand);
            }
        }

        const info = @typeInfo(T);
        switch (info) {
            .int => {
                return self.rand.int(T);
            },
            .float => {
                return self.rand.float(T);
            },
            .bool => {
                return self.rand.boolean();
            },
            .array => |arr| {
                var res: T = undefined;
                for (&res) |*elem| {
                    elem.* = self.gen(arr.child);
                }
                return res;
            },
            .@"struct" => |s| {
                var res: T = undefined;
                inline for (s.field_names, s.field_types) |name, FieldType| {
                    @field(res, name) = self.gen(FieldType);
                }
                return res;
            },
            else => @compileError("Unsupported type for quick.Generator: " ++ @typeName(T)),
        }
    }
};

/// Check looks for an input to f, any property returning bool or !void, that fails.
/// It calls f with random values of each argument type.
pub fn check(comptime F: anytype, config: ?Config) !void {
    const cfg = config orelse Config{};
    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rand = prng.random();
    const gen = Generator.init(rand);

    const fn_info = @typeInfo(@TypeOf(F)).@"fn";
    const param_types = fn_info.param_types;

    var iter: usize = 0;
    while (iter < cfg.max_count) : (iter += 1) {
        var args: std.meta.ArgsTuple(@TypeOf(F)) = undefined;
        inline for (param_types, 0..) |p_type, i| {
            args[i] = gen.gen(p_type.?);
        }

        const res = @call(.auto, F, args);
        const res_info = @typeInfo(@TypeOf(res));

        switch (res_info) {
            .bool => {
                if (!res) return error.CheckFailed;
            },
            .error_union => {
                _ = res catch return error.CheckFailed;
            },
            .void => {},
            else => @compileError("Property function must return bool or error union"),
        }
    }
}

/// CheckEqual looks for an input where f and g return different results.
pub fn checkEqual(comptime F: anytype, comptime G: anytype, config: ?Config) !void {
    const cfg = config orelse Config{};
    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rand = prng.random();
    const gen = Generator.init(rand);

    const fn_info = @typeInfo(@TypeOf(F)).@"fn";
    const param_types = fn_info.param_types;

    var iter: usize = 0;
    while (iter < cfg.max_count) : (iter += 1) {
        var args: std.meta.ArgsTuple(@TypeOf(F)) = undefined;
        inline for (param_types, 0..) |p_type, i| {
            args[i] = gen.gen(p_type.?);
        }

        const res_f = @call(.auto, F, args);
        const res_g = @call(.auto, G, args);

        if (!std.meta.eql(res_f, res_g)) {
            return error.CheckEqualFailed;
        }
    }
}

test "testing/quick: check and checkEqual property verification" {
    // 1. Property: Addition is commutative: a + b == b + a
    const prop_comm = struct {
        fn run(a: i32, b: i32) bool {
            return @addWithOverflow(a, b)[0] == @addWithOverflow(b, a)[0];
        }
    }.run;
    try check(prop_comm, .{ .max_count = 50 });

    // 2. Property: Double negation returns original boolean: !!b == b
    const prop_not = struct {
        fn run(b: bool) bool {
            return !(!b) == b;
        }
    }.run;
    try check(prop_not, .{ .max_count = 50 });

    // 3. checkEqual: Bit shift multiplication: x * 8 == x << 3
    const f_mult = struct {
        fn f(x: u16) u16 {
            return x *% 8;
        }
    }.f;

    const g_shift = struct {
        fn g(x: u16) u16 {
            return x << 3;
        }
    }.g;

    try checkEqual(f_mult, g_shift, .{ .max_count = 100 });
}

test "testing/quick: Generator fills struct fields" {
    const Point = struct {
        x: u8,
        y: bool,
        tag: [2]u4,
    };
    const Custom = struct {
        v: u32,

        pub fn generate(rand: std.Random) @This() {
            _ = rand;
            return .{ .v = 7 };
        }
    };
    const Pair = struct { p: Point, c: Custom };

    var prng = std.Random.DefaultPrng.init(42);
    const gen = Generator.init(prng.random());
    const pair = gen.gen(Pair);
    try std.testing.expectEqual(@as(u32, 7), pair.c.v);

    var same_prng = std.Random.DefaultPrng.init(42);
    const same = Generator.init(same_prng.random()).gen(Pair);
    try std.testing.expect(std.meta.eql(pair, same));
}
