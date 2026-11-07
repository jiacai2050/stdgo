const std = @import("std");
const stdgo = @import("stdgo");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: Go standard library equivalents for Zig ===\n\n", .{});

    // 1. RegExp & URL parsing
    var re = try stdgo.regexp.compile(gpa, "[a-zA-Z]+://[^\\s]+");
    defer re.deinit();

    const sample = "Visit our project at https://github.com/jiacai/stdgo today!";
    if (re.findString(sample)) |url_str| {
        std.debug.print("1. Found URL: {s}\n", .{url_str});

        const parsed_url = try stdgo.net.url.parse(url_str);
        std.debug.print("   Scheme: {s}\n", .{parsed_url.scheme});
        std.debug.print("   Host:   {s}\n", .{parsed_url.host});
        std.debug.print("   Path:   {s}\n\n", .{parsed_url.path});
    }

    // 2. Glob match
    const matched = try stdgo.path.match("*.zig", "main.zig");
    std.debug.print("2. Path glob '*.zig' matches 'main.zig': {any}\n\n", .{matched});

    // 3. Tabwriter table output
    std.debug.print("3. Tabwriter Aligned Output:\n", .{});
    var tw_buf = stdgo.bytes.Buffer.init(gpa);
    defer tw_buf.deinit();

    var tw = stdgo.text.tabwriter.Writer.init(gpa, tw_buf.writer(), 0, 8, 4, ' ', 0);
    defer tw.deinit();

    _ = try tw.write("FLAG\tDEFAULT\tCURRENT\tDESCRIPTION\n");
    _ = try tw.write("port\t8080\t8080\tserver port\n");
    _ = try tw.write("host\t127.0.0.1\t127.0.0.1\tserver bind address\n");
    _ = try tw.write("verbose\ttrue\ttrue\tenable detailed logs\n");
    try tw.flush();

    std.debug.print("{s}\n", .{tw_buf.string()});

    // 4. Crypto SHA-256 + Hash
    const message = "stdgo brings Go standard library ergonomics to Zig!";
    const digest = stdgo.crypto.sha256.Sum256(message);
    const hex = std.fmt.bytesToHex(digest, .lower);
    std.debug.print("4. SHA-256: {s}\n\n", .{hex});

    // 5. Time ParseDuration, Now, Sleep & Slices Sort
    const t_now = stdgo.time.Time.now(init.io);
    try stdgo.time.sleep(init.io, @enumFromInt(100)); // sleep 100ns via user-passed init.io

    const d1 = try stdgo.time.parseDuration("1h30m");
    const d2 = try stdgo.time.parseDuration("45s");
    std.debug.print("5. Time Now (Unix Sec): {d}, Duration: '1h30m' = {d}s, '45s' = {d}s\n", .{
        t_now.wall_sec,
        @as(i64, @intFromFloat(d1.seconds())),
        @as(i64, @intFromFloat(d2.seconds())),
    });

    var numbers = [_]i32{ 42, 10, 88, 3, 17 };
    stdgo.slices.sort(i32, &numbers, struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less);
    std.debug.print("   Sorted Slices: {any}\n\n", .{numbers});

    // 6. Sync WaitGroup demo
    std.debug.print("6. Sync WaitGroup:\n", .{});
    var wg = stdgo.sync.WaitGroup.init();
    const Worker = struct {
        fn run(group: *stdgo.sync.WaitGroup, id: usize) void {
            defer group.done();
            std.debug.print("   Worker {d} done\n", .{id});
        }
    };

    wg.add(3);
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ &wg, 1 });
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ &wg, 2 });
    var t3 = try std.Thread.spawn(.{}, Worker.run, .{ &wg, 3 });
    wg.wait();
    t1.join();
    t2.join();
    t3.join();
    std.debug.print("   All workers finished successfully!\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
