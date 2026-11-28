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

    pub const max_inline_insts = 64;

    const Thread = struct {
        pc: u32,
        start_pos: usize,
    };

    const ThreadList = struct {
        slice: []Thread,
        len: usize = 0,
        allocator: ?Allocator = null,

        fn initSlice(buf: []Thread) ThreadList {
            return .{
                .slice = buf,
                .len = 0,
                .allocator = null,
            };
        }

        fn initAlloc(allocator: Allocator, capacity: usize) Allocator.Error!ThreadList {
            const buf = try allocator.alloc(Thread, capacity);
            return .{
                .slice = buf,
                .len = 0,
                .allocator = allocator,
            };
        }

        fn deinit(self: *ThreadList) void {
            if (self.allocator) |alloc| {
                alloc.free(self.slice);
                self.slice = &.{};
            }
        }

        fn clearRetainingCapacity(self: *ThreadList) void {
            self.len = 0;
        }

        fn items(self: *const ThreadList) []const Thread {
            return self.slice[0..self.len];
        }

        fn append(self: *ThreadList, allocator: Allocator, thread: Thread) Allocator.Error!void {
            if (self.len < self.slice.len) {
                self.slice[self.len] = thread;
                self.len += 1;
                return;
            }
            if (self.allocator) |alloc| {
                const new_cap = @max(self.slice.len * 2, 8);
                self.slice = try alloc.realloc(self.slice, new_cap);
                self.slice[self.len] = thread;
                self.len += 1;
                return;
            }
            const new_cap = @max(self.slice.len * 2, 8);
            const new_slice = try allocator.alloc(Thread, new_cap);
            @memcpy(new_slice[0..self.len], self.slice[0..self.len]);
            self.slice = new_slice;
            self.allocator = allocator;
            self.slice[self.len] = thread;
            self.len += 1;
        }
    };

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

    /// Find searches for the leftmost match of the compiled program in text.
    pub fn find(self: *const VM, text: []const u8) anyerror!?MatchResult {
        return self.findAt(text, 0);
    }

    /// FindAt searches for the leftmost match of the compiled program in text
    /// starting at byte index start_offset, preserving start-of-text (^) anchor semantics.
    pub fn findAt(self: *const VM, text: []const u8, start_offset: usize) anyerror!?MatchResult {
        const num_insts = self.prog.insts.items.len;
        if (num_insts == 0 or start_offset > text.len) return null;

        var visited_buf: [max_inline_insts]bool = undefined;
        const visited = if (num_insts <= max_inline_insts)
            visited_buf[0..num_insts]
        else
            try self.allocator.alloc(bool, num_insts);
        defer if (num_insts > max_inline_insts) self.allocator.free(visited);

        var cur_buf: [max_inline_insts]Thread = undefined;
        var next_buf: [max_inline_insts]Thread = undefined;

        var cur_threads = if (num_insts <= max_inline_insts)
            ThreadList.initSlice(&cur_buf)
        else
            try ThreadList.initAlloc(self.allocator, num_insts);
        defer cur_threads.deinit();

        var next_threads = if (num_insts <= max_inline_insts)
            ThreadList.initSlice(&next_buf)
        else
            try ThreadList.initAlloc(self.allocator, num_insts);
        defer next_threads.deinit();

        var best_match: ?MatchResult = null;

        // Try matching starting at each position in text from start_offset
        var start_pos: usize = start_offset;
        while (start_pos <= text.len) : (start_pos += 1) {
            cur_threads.clearRetainingCapacity();
            @memset(visited, false);
            try self.addThread(&cur_threads, self.prog.start, start_pos, text, visited, start_pos);

            var pos = start_pos;
            while (cur_threads.items().len > 0) {
                // Check if any thread is at match
                for (cur_threads.items()) |t| {
                    if (self.prog.insts.items[t.pc].op == .match) {
                        const len = pos - t.start_pos;
                        const is_better = best_match == null or
                            (len > best_match.?.end - best_match.?.start);
                        if (is_better) {
                            best_match = .{ .start = t.start_pos, .end = pos };
                        }
                    }
                }

                if (pos >= text.len) break;
                const ch = text[pos];

                @memset(visited, false);
                next_threads.clearRetainingCapacity();

                for (cur_threads.items()) |t| {
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
                        try self.addThread(
                            &next_threads,
                            inst.out,
                            pos + 1,
                            text,
                            visited,
                            t.start_pos,
                        );
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

    fn addThread(
        self: *const VM,
        list: *ThreadList,
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

test "VM stack scratch execution" {
    const testing = std.testing;
    var prog = Prog.init(testing.allocator);
    defer prog.deinit();

    // inst 0: char 'a', out: 1
    // inst 1: match
    try prog.insts.append(testing.allocator, .{ .op = .char, .c = 'a', .out = 1 });
    try prog.insts.append(testing.allocator, .{ .op = .match });

    const vm = VM.init(testing.allocator, &prog);
    try testing.expect(try vm.match("a"));
    try testing.expect(try vm.match("bac"));
    try testing.expect(!(try vm.match("xyz")));
}

test "VM fallback to heap when insts > max_inline_insts" {
    const testing = std.testing;
    var prog = Prog.init(testing.allocator);
    defer prog.deinit();

    // Create 70 instructions: 69 jumps chaining together, ending in char 'z' then match
    var i: u32 = 0;
    while (i < 68) : (i += 1) {
        try prog.insts.append(testing.allocator, .{ .op = .jump, .out = i + 1 });
    }
    try prog.insts.append(testing.allocator, .{ .op = .char, .c = 'z', .out = 69 });
    try prog.insts.append(testing.allocator, .{ .op = .match });

    const vm = VM.init(testing.allocator, &prog);
    try testing.expect(try vm.match("z"));
    try testing.expect(!(try vm.match("a")));
}
