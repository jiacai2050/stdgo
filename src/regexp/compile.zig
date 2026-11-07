const std = @import("std");
const prog_mod = @import("prog.zig");
const Prog = prog_mod.Prog;
const Inst = prog_mod.Inst;
const Range = prog_mod.Range;
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadPattern,
    UnmatchedParen,
    UnmatchedBracket,
    TrailingBackslash,
};

const Frag = struct {
    start: u32,
    out: std.ArrayList(u32),
};

pub const Compiler = struct {
    allocator: Allocator,
    pattern: []const u8,
    pos: usize = 0,
    prog: Prog,

    pub fn compile(allocator: Allocator, pattern: []const u8) anyerror!Prog {
        var c = Compiler{
            .allocator = allocator,
            .pattern = pattern,
            .pos = 0,
            .prog = Prog.init(allocator),
        };
        errdefer c.prog.deinit();

        var frag = try c.parseAlt();
        defer frag.out.deinit(c.allocator);
        if (c.pos < c.pattern.len) {
            return Error.BadPattern;
        }

        const match_inst = try c.emit(.{ .op = .match });
        c.patch(frag.out, match_inst);
        c.prog.start = frag.start;
        return c.prog;
    }

    fn emit(self: *Compiler, inst: Inst) Allocator.Error!u32 {
        const id: u32 = @intCast(self.prog.insts.items.len);
        try self.prog.insts.append(self.allocator, inst);
        return id;
    }

    fn patch(self: *Compiler, outs: std.ArrayList(u32), target: u32) void {
        for (outs.items) |idx| {
            var inst = &self.prog.insts.items[idx];
            if (inst.out == 0) {
                inst.out = target;
            } else if (inst.out1 == 0 and (inst.op == .split)) {
                inst.out1 = target;
            }
        }
    }

    fn makeFrag(self: *Compiler, start: u32) Allocator.Error!Frag {
        var out = std.ArrayList(u32).empty;
        try out.append(self.allocator, start);
        return .{ .start = start, .out = out };
    }

    fn parseAlt(self: *Compiler) anyerror!Frag {
        var left = try self.parseConcat();

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            var right = try self.parseConcat();
            const split_idx = try self.emit(.{
                .op = .split,
                .out = left.start,
                .out1 = right.start,
            });

            var merged_out = std.ArrayList(u32).empty;
            for (left.out.items) |o| try merged_out.append(self.allocator, o);
            for (right.out.items) |o| try merged_out.append(self.allocator, o);
            left.out.deinit(self.allocator);
            right.out.deinit(self.allocator);

            left = .{ .start = split_idx, .out = merged_out };
        }

        return left;
    }

    fn parseConcat(self: *Compiler) anyerror!Frag {
        var left: ?Frag = null;

        while (self.pos < self.pattern.len) {
            const ch = self.pattern[self.pos];
            if (ch == '|' or ch == ')') {
                break;
            }
            const piece = try self.parsePiece();
            if (left) |*cur| {
                self.patch(cur.out, piece.start);
                cur.out.deinit(self.allocator);
                cur.out = piece.out;
            } else {
                left = piece;
            }
        }

        if (left) |l| {
            return l;
        }

        // Empty string matches
        const nop = try self.emit(.{ .op = .split, .out = 0, .out1 = 0 });
        return self.makeFrag(nop);
    }

    fn parsePiece(self: *Compiler) anyerror!Frag {
        var atom = try self.parseAtom();

        if (self.pos < self.pattern.len) {
            const op_char = self.pattern[self.pos];
            if (op_char == '*') {
                self.pos += 1;
                const split_idx = try self.emit(.{
                    .op = .split,
                    .out = atom.start,
                    .out1 = 0,
                });
                self.patch(atom.out, split_idx);
                atom.out.deinit(self.allocator);

                var out = std.ArrayList(u32).empty;
                try out.append(self.allocator, split_idx);
                return .{ .start = split_idx, .out = out };
            } else if (op_char == '+') {
                self.pos += 1;
                const split_idx = try self.emit(.{
                    .op = .split,
                    .out = atom.start,
                    .out1 = 0,
                });
                self.patch(atom.out, split_idx);
                atom.out.deinit(self.allocator);

                var out = std.ArrayList(u32).empty;
                try out.append(self.allocator, split_idx);
                return .{ .start = atom.start, .out = out };
            } else if (op_char == '?') {
                self.pos += 1;
                const split_idx = try self.emit(.{
                    .op = .split,
                    .out = atom.start,
                    .out1 = 0,
                });
                var out = std.ArrayList(u32).empty;
                for (atom.out.items) |o| try out.append(self.allocator, o);
                try out.append(self.allocator, split_idx);
                atom.out.deinit(self.allocator);

                return .{ .start = split_idx, .out = out };
            }
        }

        return atom;
    }

    fn parseAtom(self: *Compiler) anyerror!Frag {
        if (self.pos >= self.pattern.len) return Error.BadPattern;
        const ch = self.pattern[self.pos];

        if (ch == '(') {
            self.pos += 1;
            const frag = try self.parseAlt();
            if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                return Error.UnmatchedParen;
            }
            self.pos += 1;
            return frag;
        }

        if (ch == '.') {
            self.pos += 1;
            const idx = try self.emit(.{ .op = .any });
            return self.makeFrag(idx);
        }

        if (ch == '^') {
            self.pos += 1;
            const idx = try self.emit(.{ .op = .assert_start });
            return self.makeFrag(idx);
        }

        if (ch == '$') {
            self.pos += 1;
            const idx = try self.emit(.{ .op = .assert_end });
            return self.makeFrag(idx);
        }

        if (ch == '[') {
            return self.parseClass();
        }

        if (ch == '\\') {
            self.pos += 1;
            if (self.pos >= self.pattern.len) return Error.TrailingBackslash;
            const esc = self.pattern[self.pos];
            self.pos += 1;
            switch (esc) {
                'd' => return self.makeClassRanges(&[_]Range{.{ .lo = '0', .hi = '9' }}, false),
                'w' => return self.makeClassRanges(&[_]Range{
                    .{ .lo = 'a', .hi = 'z' },
                    .{ .lo = 'A', .hi = 'Z' },
                    .{ .lo = '0', .hi = '9' },
                    .{ .lo = '_', .hi = '_' },
                }, false),
                's' => return self.makeClassRanges(&[_]Range{
                    .{ .lo = ' ', .hi = ' ' },
                    .{ .lo = '\t', .hi = '\t' },
                    .{ .lo = '\n', .hi = '\n' },
                    .{ .lo = '\r', .hi = '\r' },
                }, false),
                else => {
                    const idx = try self.emit(.{ .op = .char, .c = esc });
                    return self.makeFrag(idx);
                },
            }
        }

        self.pos += 1;
        const idx = try self.emit(.{ .op = .char, .c = ch });
        return self.makeFrag(idx);
    }

    fn parseClass(self: *Compiler) anyerror!Frag {
        self.pos += 1; // skip '['
        var negated = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges = std.ArrayList(Range).empty;
        defer ranges.deinit(self.allocator);

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const lo = self.pattern[self.pos];
            self.pos += 1;
            var hi = lo;
            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // skip '-'
                hi = self.pattern[self.pos];
                self.pos += 1;
            }
            try ranges.append(self.allocator, .{ .lo = lo, .hi = hi });
        }

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ']') {
            return Error.UnmatchedBracket;
        }
        self.pos += 1; // skip ']'

        return self.makeClassRanges(ranges.items, negated);
    }

    fn makeClassRanges(self: *Compiler, in_ranges: []const Range, negated: bool) Allocator.Error!Frag {
        const ranges_copy = try self.allocator.dupe(Range, in_ranges);
        const idx = try self.emit(.{
            .op = .class,
            .ranges = ranges_copy,
            .negated = negated,
        });
        return self.makeFrag(idx);
    }
};
