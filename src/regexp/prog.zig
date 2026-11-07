const std = @import("std");
const Allocator = std.mem.Allocator;

pub const InstOp = enum {
    char,
    any,
    class,
    split,
    jump,
    assert_start,
    assert_end,
    match,
};

pub const Range = struct {
    lo: u8,
    hi: u8,
};

pub const Inst = struct {
    op: InstOp,
    c: u8 = 0,
    out: u32 = 0,
    out1: u32 = 0,
    ranges: []const Range = &[_]Range{},
    negated: bool = false,
};

pub const Prog = struct {
    allocator: Allocator,
    insts: std.ArrayList(Inst),
    start: u32 = 0,

    pub fn init(allocator: Allocator) Prog {
        return .{
            .allocator = allocator,
            .insts = std.ArrayList(Inst).empty,
            .start = 0,
        };
    }

    pub fn deinit(self: *Prog) void {
        for (self.insts.items) |inst| {
            if (inst.ranges.len > 0) {
                self.allocator.free(inst.ranges);
            }
        }
        self.insts.deinit(self.allocator);
    }
};
