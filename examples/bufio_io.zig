//! Example demonstrating stdgo bufio & io streaming packages:
//! 1. bufio.Scanner: line-by-line and word-by-word tokenization
//! 2. bufio.Reader & Writer: buffered streaming operations
//! 3. io.copy, io.LimitReader, io.TeeReader

const std = @import("std");
const stdgo = @import("stdgo");
const io = stdgo.io;
const bufio = stdgo.bufio;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: bufio & io Streaming Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. bufio.Scanner: Word and Line Scanning
    // -------------------------------------------------------------
    const sample_text =
        \\Zig 0.17 provides safe high-performance systems programming.
        \\stdgo delivers Go standard library ergonomics.
        \\Together they make systems programming productive and reliable.
    ;

    std.debug.print("1. bufio.Scanner (Line scanning):\n", .{});
    var line_reader = bytes.Reader.init(sample_text);
    var line_scanner = try bufio.Scanner.init(gpa, line_reader.reader());
    defer line_scanner.deinit();

    var line_no: usize = 1;
    while (line_scanner.scan()) {
        std.debug.print("   Line {d}: \"{s}\"\n", .{ line_no, line_scanner.bytes() });
        line_no += 1;
    }

    std.debug.print("\n2. bufio.Scanner (Word tokenization):\n", .{});
    const quote = "The quick brown fox jumps";
    var word_reader = bytes.Reader.init(quote);
    var word_scanner = try bufio.Scanner.init(gpa, word_reader.reader());
    defer word_scanner.deinit();
    word_scanner.setSplit(bufio.scanWords);

    var word_count: usize = 0;
    while (word_scanner.scan()) {
        word_count += 1;
        std.debug.print("   Word {d}: [{s}]\n", .{ word_count, word_scanner.bytes() });
    }

    // -------------------------------------------------------------
    // 2. io.LimitReader and io.copy
    // -------------------------------------------------------------
    std.debug.print("\n3. io.LimitReader:\n", .{});
    const stream_payload = "ABCDEFGHIJ0123456789";
    var stream_src = bytes.Reader.init(stream_payload);
    var limited = io.LimitReader.init(stream_src.reader(), 7);

    var limit_buf = bytes.Buffer.init(gpa);
    defer limit_buf.deinit();

    var copy_scratch: [16]u8 = undefined;
    const copied = try io.copy(limit_buf.writer(), limited.reader(), &copy_scratch);
    std.debug.print("   Copied exactly {d} bytes: \"{s}\"\n", .{ copied, limit_buf.string() });

    // -------------------------------------------------------------
    // 3. io.TeeReader: Stream duplication
    // -------------------------------------------------------------
    std.debug.print("\n4. io.TeeReader (reading while mirroring to a buffer):\n", .{});
    var orig_reader = bytes.Reader.init("DirectPayloadToConsumer");
    var mirror_buf = bytes.Buffer.init(gpa);
    defer mirror_buf.deinit();

    var tee = io.TeeReader.init(orig_reader.reader(), mirror_buf.writer());
    var consumer_buf: [13]u8 = undefined;
    const read_bytes = try tee.reader().read(&consumer_buf);

    std.debug.print("   Consumer read: \"{s}\" ({d} bytes)\n", .{ consumer_buf[0..read_bytes], read_bytes });
    std.debug.print("   Mirror buffer captured: \"{s}\"\n", .{mirror_buf.string()});

    std.debug.print("\n=== bufio & io demo completed successfully! ===\n", .{});
}
