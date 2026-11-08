//! Example demonstrating stdgo archive packages:
//! 1. archive.tar: creating and reading Tar archives
//! 2. archive.zip: creating and inspecting Zip archives

const std = @import("std");
const stdgo = @import("stdgo");
const archive = stdgo.archive;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: archive (tar & zip) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. archive.tar: create in-memory tar archive and read back
    // -------------------------------------------------------------
    std.debug.print("1. Creating in-memory Tar archive:\n", .{});

    var tar_buf = bytes.Buffer.init(gpa);
    defer tar_buf.deinit();

    var tar_w = archive.tar.Writer.init(tar_buf.writer());

    // File 1: hello.txt
    const f1_content = "Hello, Gopher and Zig enthusiast!\n";
    var hdr1 = archive.tar.Header{
        .name = "hello.txt",
        .size = f1_content.len,
        .mode = 0o644,
    };
    try tar_w.writeHeader(&hdr1);
    _ = try tar_w.write(f1_content);

    // File 2: config/app.json
    const f2_content = "{\"env\": \"production\", \"version\": 1.0}\n";
    var hdr2 = archive.tar.Header{
        .name = "config/app.json",
        .size = f2_content.len,
        .mode = 0o600,
    };
    try tar_w.writeHeader(&hdr2);
    _ = try tar_w.write(f2_content);

    try tar_w.close();
    std.debug.print("   Tar archive written successfully, total size: {d} bytes\n\n", .{tar_buf.len()});

    std.debug.print("   Reading entries from Tar archive:\n", .{});
    var tar_r_buf = bytes.Reader.init(tar_buf.bytes());
    var tar_r = archive.tar.Reader.init(tar_r_buf.reader());

    while (try tar_r.next()) |hdr| {
        var content_buf: [256]u8 = undefined;
        var r_len: usize = 0;
        while (true) {
            const n = tar_r.read(content_buf[r_len..]) catch |err| {
                if (err == stdgo.io.Error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            r_len += n;
        }
        std.debug.print("   -> File: '{s}' (mode: 0o{o}, size: {d} bytes): '{s}'\n", .{
            hdr.name,
            hdr.mode,
            hdr.size,
            stdgo.strings.trimSuffix(content_buf[0..r_len], "\n"),
        });
    }

    // -------------------------------------------------------------
    // 2. archive.zip: create in-memory zip archive and inspect
    // -------------------------------------------------------------
    std.debug.print("\n2. Creating in-memory Zip archive:\n", .{});

    var zip_buf = bytes.Buffer.init(gpa);
    defer zip_buf.deinit();

    var zip_w = archive.zip.Writer.init(gpa, zip_buf.writer());
    defer zip_w.deinit();

    try zip_w.writeFile("README.md", "# stdgo Archive Demo\nZig meets Go standard library.\n", .store);
    try zip_w.writeFile("data/stats.csv", "id,val\n1,100\n2,200\n", .store);
    try zip_w.close();

    std.debug.print("   Zip archive created, total size: {d} bytes\n\n", .{zip_buf.len()});

    std.debug.print("   Inspecting Zip files:\n", .{});
    var zip_r = try archive.zip.Reader.init(gpa, zip_buf.bytes());
    defer zip_r.deinit();

    for (zip_r.files()) |file| {
        std.debug.print("   -> Entry: '{s}' (uncompressed size: {d} bytes, method: {any})\n", .{
            file.header.name,
            file.header.uncompressed_size,
            file.header.method,
        });
    }

    std.debug.print("\n=== archive demo completed successfully! ===\n", .{});
}
