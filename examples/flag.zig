//! Example demonstrating stdgo flag package:
//! 1. flag.FlagSet: Defining flags (string, int, bool, float)
//! 2. Parsing command line flags and positional arguments
//! 3. Default values and usage generation

const std = @import("std");
const stdgo = @import("stdgo");
const flag = stdgo.flag;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: flag CLI Argument Parsing Example ===\n\n", .{});

    var fs = flag.FlagSet.init(gpa, "server");
    defer fs.deinit();

    var host: []const u8 = undefined;
    var port: i64 = undefined;
    var verbose: bool = undefined;
    var timeout_sec: f64 = undefined;

    try fs.stringVar(&host, "host", "127.0.0.1", "Bind address for the server");
    try fs.intVar(&port, "port", 8080, "Port to listen on");
    try fs.boolVar(&verbose, "verbose", false, "Enable verbose logging");
    try fs.floatVar(&timeout_sec, "timeout", 30.0, "Connection timeout in seconds");

    std.debug.print("1. Default configuration:\n", .{});
    std.debug.print("   host: {s}, port: {d}, verbose: {any}, timeout: {d:.1}s\n\n", .{
        host, port, verbose, timeout_sec,
    });

    // Simulate CLI arguments: -host 0.0.0.0 -port=9090 -verbose extra_file1 extra_file2
    const mock_args = [_][]const u8{
        "-host",    "0.0.0.0",
        "-port=9090",
        "-verbose",
        "service.conf",
        "deploy.json",
    };

    std.debug.print("2. Parsing arguments:\n   ", .{});
    for (mock_args) |arg| {
        std.debug.print("{s} ", .{arg});
    }
    std.debug.print("\n\n", .{});

    try fs.parse(&mock_args);

    std.debug.print("3. Parsed configuration:\n", .{});
    std.debug.print("   host:    \"{s}\"\n", .{host});
    std.debug.print("   port:    {d}\n", .{port});
    std.debug.print("   verbose: {any}\n", .{verbose});
    std.debug.print("   timeout: {d:.1}s\n\n", .{timeout_sec});

    std.debug.print("4. Remaining positional arguments (fs.args()):\n", .{});
    for (fs.args(), 0..) |pos_arg, idx| {
        std.debug.print("   [{d}] \"{s}\"\n", .{ idx, pos_arg });
    }

    std.debug.print("\n=== flag demo completed successfully! ===\n", .{});
}
