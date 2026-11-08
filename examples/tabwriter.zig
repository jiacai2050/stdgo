//! Example demonstrating stdgo text.tabwriter package:
//! 1. tabwriter.Writer: Elastic tabstops for formatted, aligned terminal tables
//! 2. Column alignment, padding, and formatting

const std = @import("std");
const stdgo = @import("stdgo");
const tabwriter = stdgo.text.tabwriter;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: text.tabwriter Table Formatting Example ===\n\n", .{});

    var out_buf = bytes.Buffer.init(gpa);
    defer out_buf.deinit();

    // minwidth=0, tabwidth=8, padding=4, padchar=' ', flags=0
    var tw = tabwriter.Writer.init(gpa, out_buf.writer(), 0, 8, 4, ' ', 0);
    defer tw.deinit();

    // Write table with tab '\t' separators
    _ = try tw.write("NAME\tSTATUS\tCPU\tMEMORY\tRESTARTS\n");
    _ = try tw.write("auth-service\tRunning\t120m\t256Mi\t0\n");
    _ = try tw.write("payment-gateway-v2\tCrashLoopBackOff\t850m\t1024Mi\t14\n");
    _ = try tw.write("redis-cache\tRunning\t45m\t512Mi\t1\n");
    _ = try tw.write("worker-node-pool\tRunning\t2200m\t4096Mi\t0\n");

    try tw.flush();

    std.debug.print("Formatted Service Status Table:\n\n{s}\n", .{out_buf.string()});
    std.debug.print("=== tabwriter demo completed successfully! ===\n", .{});
}
