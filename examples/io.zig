//! Example demonstrating stdgo io streaming utilities:
//! 1. Native buffered reading (takeDelimiterExclusive, takeByte)
//! 2. io.copy stream transfer
//! 3. io.LimitReader: bounded streams
//! 4. io.TeeReader: stream mirroring

const std = @import("std");
const stdgo = @import("stdgo");
const io = stdgo.io;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: io Streaming Utilities Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Native Buffered Reading with std.Io.Reader
    // -------------------------------------------------------------
    const sample_text =
        "Zig 0.17 provides native high-performance buffered streams.\n" ++
        "stdgo delivers Go standard library ergonomics.\n" ++
        "Together they make systems programming productive and reliable.\n";

    std.debug.print("1. Native Line-by-Line Streaming (takeDelimiterExclusive):\n", .{});
    var line_reader = bytes.Reader.init(sample_text);
    const r = line_reader.reader();

    var line_no: usize = 1;
    while (true) {
        const line = r.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        _ = r.takeByte() catch {}; // consume delimiter
        std.debug.print("   Line {d}: \"{s}\"\n", .{ line_no, line });
        line_no += 1;
    }

    // -------------------------------------------------------------
    // 2. io.LimitReader and io.copy
    // -------------------------------------------------------------
    std.debug.print("\n2. io.LimitReader & io.copy:\n", .{});
    const stream_payload = "ABCDEFGHIJ0123456789";
    var stream_src = bytes.Reader.init(stream_payload);
    var limited = io.LimitReader.init(stream_src.reader(), 7);

    var limit_buf = bytes.Buffer.init(gpa);
    defer limit_buf.deinit();

    const copied = try io.copy(limit_buf.writer(), limited.reader());
    std.debug.print("   Copied exactly {d} bytes: \"{s}\"\n", .{ copied, limit_buf.string() });

    // -------------------------------------------------------------
    // 3. io.TeeReader: Stream duplication
    // -------------------------------------------------------------
    std.debug.print("\n3. io.TeeReader (reading while mirroring to a buffer):\n", .{});
    var orig_reader = bytes.Reader.init("DirectPayloadToConsumer");
    var mirror_buf = bytes.Buffer.init(gpa);
    defer mirror_buf.deinit();

    var tee = io.TeeReader.init(orig_reader.reader(), mirror_buf.writer());
    var consumer_buf: [13]u8 = undefined;
    const read_bytes = try tee.reader().readSliceShort(&consumer_buf);

    std.debug.print("   Consumer read: \"{s}\" ({d} bytes)\n", .{ consumer_buf[0..read_bytes], read_bytes });
    std.debug.print("   Mirror buffer captured: \"{s}\"\n", .{mirror_buf.string()});

    std.debug.print("\n=== io streaming demo completed successfully! ===\n", .{});
}
