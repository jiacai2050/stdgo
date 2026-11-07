const std = @import("std");
const prog_mod = @import("prog.zig");
const Prog = prog_mod.Prog;
const Allocator = std.mem.Allocator;

pub const MatchResult = struct {
    start: usize,
    end: usize,
};

pub const VM = struct {
    prog: *const Prog,
    allocator: Allocator,

    pub fn init(allocator: Allocator, prog: *const Prog) VM {
        return .{
            .prog = prog,
            .allocator = allocator,
        };
    }

    pub fn match(self: *const VM, text: []const u8) anyerror!bool {
        const res = try self.find(text);
        return res != null;
    }

    pub fn find(self: *const VM, text: []const u8) anyerror!?MatchResult {
        const num_insts = self.prog.insts.items.len;
        if (num_insts == 0) return null;

        const visited = try self.allocator.alloc(bool, num_insts);
        defer self.allocator.free(visited);

        var cur_threads = std.ArrayList(Thread).empty;
        defer cur_threads.deinit(self.allocator);

        var next_threads = std.ArrayList(Thread).empty;
        defer next_threads.deinit(self.allocator);

        var best_match: ?MatchResult = null;

        // Try matching starting at each position in text
        var start_pos: usize = 0;
        while (start_pos <= text.len) : (start_pos += 1) {
            @memset(visited, false);
            try self.addThread(&cur_threads, self.prog.start, start_pos, text, visited, start_pos);

            var pos = start_pos;
            while (cur_threads.items.len > 0) {
                // Check if any thread is at match
                for (cur_threads.items) |t| {
                    if (self.prog.insts.items[t.pc].op == .match) {
                        if (best_match == null or (pos - t.start_pos > best_match.?.end - best_match.?.start)) {
                            best_match = .{ .start = t.start_pos, .end = pos };
                        }
                    }
                }

                if (pos >= text.len) break;
                const ch = text[pos];

                @memset(visited, false);
                next_threads.clearRetainingCapacity();

                for (cur_threads.items) |t| {
                    const inst = self.prog.insts.items[t.pc];
                    var matched = false;
                    switch (inst.op) {
                        .char => {
                            matched = (inst.c == ch);
                        },
                        .any => {
                            matched = (ch != '\n');
                        },
                        .class => {
                            var in_range = false;
                            for (inst.ranges) |r| {
                                if (ch >= r.lo and ch <= r.hi) {
                                    in_range = true;
                                    break;
                                }
                            }
                            matched = (in_range != inst.negated);
                        },
                        else => {},
                    }

                    if (matched) {
                        try self.addThread(&next_threads, inst.out, pos + 1, text, visited, t.start_pos);
                    }
                }

                // Swap cur and next
                const tmp = cur_threads;
                cur_threads = next_threads;
                next_threads = tmp;
                pos += 1;
            }

            if (best_match != null) {
                return best_match;
            }
        }

        return null;
    }

    const Thread = struct {
        pc: u32,
        start_pos: usize,
    };

    fn addThread(
        self: *const VM,
        list: *std.ArrayList(Thread),
        pc: u32,
        pos: usize,
        text: []const u8,
        visited: []bool,
        start_pos: usize,
    ) anyerror!void {
        if (pc >= self.prog.insts.items.len) return;
        if (visited[pc]) return;
        visited[pc] = true;

        const inst = self.prog.insts.items[pc];
        switch (inst.op) {
            .split => {
                try self.addThread(list, inst.out, pos, text, visited, start_pos);
                try self.addThread(list, inst.out1, pos, text, visited, start_pos);
            },
            .jump => {
                try self.addThread(list, inst.out, pos, text, visited, start_pos);
            },
            .assert_start => {
                if (pos == 0) {
                    try self.addThread(list, inst.out, pos, text, visited, start_pos);
                }
            },
            .assert_end => {
                if (pos == text.len) {
                    try self.addThread(list, inst.out, pos, text, visited, start_pos);
                }
            },
            else => {
                try list.append(self.allocator, .{ .pc = pc, .start_pos = start_pos });
            },
        }
    }
};
