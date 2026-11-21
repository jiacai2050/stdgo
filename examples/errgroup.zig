//! Example demonstrating bounded, structured task execution.

const std = @import("std");
const stdgo = @import("stdgo");
const errgroup = stdgo.sync.errgroup;

pub fn main(init: std.process.Init) !void {
    const Worker = struct {
        fn run(io: std.Io, id: usize) !void {
            try io.checkCancel();
            std.debug.print("Processed item {d}\n", .{id});
        }
    };
    const Args = std.meta.ArgsTuple(@TypeOf(Worker.run));
    const tasks = [_]Args{
        .{ init.io, 1 },
        .{ init.io, 2 },
        .{ init.io, 3 },
        .{ init.io, 4 },
    };
    try errgroup.Group.run(init.gpa, init.io, Worker.run, &tasks, 2);
}
