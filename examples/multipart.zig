//! Example demonstrating stdgo's mime.multipart:
//! 1. Constructing RFC 2046 multipart/form-data bodies with Writer
//! 2. Creating text form fields and attached files
//! 3. Streaming and parsing multipart parts with Reader
//! 4. Extracting field names, filenames, headers, and part contents

const std = @import("std");
const stdgo = @import("stdgo");
const multipart = stdgo.mime.multipart;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: mime.multipart Form Data Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Construct Multipart Form with Writer
    // -------------------------------------------------------------
    var body_buf = bytes.Buffer.init(gpa);
    defer body_buf.deinit();

    var writer = multipart.Writer.init(gpa, body_buf.writer());

    // Add standard text field
    try writer.writeField("username", "gopher2026");
    try writer.writeField("description", "Zig 0.17 + stdgo high performance runtime");

    // Add file upload field
    const file_writer = try writer.createFormFile("avatar", "gopher.png");
    try file_writer.writeAll("FAKE_PNG_BINARY_BYTES_1234567890");

    // Finish writing trailing boundary
    try writer.close();

    var ct_buf: [128]u8 = undefined;
    const content_type = try writer.formDataContentType(&ct_buf);

    std.debug.print("1. Constructed Multipart Form-Data:\n", .{});
    std.debug.print("   Content-Type: {s}\n", .{content_type});
    std.debug.print("   Payload Size: {d} bytes\n\n", .{body_buf.len()});

    // -------------------------------------------------------------
    // 2. Parse Multipart Stream with Reader
    // -------------------------------------------------------------
    std.debug.print("2. Parsing stream with multipart.Reader:\n", .{});

    var stream_reader = bytes.Reader.init(body_buf.bytes());
    var reader = multipart.Reader.init(gpa, stream_reader.reader(), writer.boundary());

    var part_idx: usize = 1;
    while (try reader.nextPart()) |part_val| {
        var part = part_val;
        defer part.deinit();

        std.debug.print("   [Part {d}]\n", .{part_idx});
        std.debug.print("     Field Name: {?s}\n", .{part.formName()});
        std.debug.print("     File Name:  {?s}\n", .{part.fileName()});
        std.debug.print("     Headers:    Content-Disposition={?s}\n", .{part.header.get("Content-Disposition")});

        var content_buf: [256]u8 = undefined;
        const n = try part.read(&content_buf);
        std.debug.print("     Body Content: '{s}' ({d} bytes)\n\n", .{ content_buf[0..n], n });

        part_idx += 1;
    }

    std.debug.print("=== Multipart demo completed successfully! ===\n", .{});
}
