//! Example demonstrating stdgo encoding package:
//! 1. encoding.csv: RFC 4180 CSV Writer & Reader
//! 2. encoding.binary: BigEndian, LittleEndian, and Protobuf Varint
//! 3. encoding.base64: RFC 4648 standard and URL-safe Base64
//! 4. encoding.hex: Hex dump and encode/decode

const std = @import("std");
const stdgo = @import("stdgo");
const encoding = stdgo.encoding;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: encoding (csv, binary, base64, hex) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. encoding.csv: Writing and Reading CSV records
    // -------------------------------------------------------------
    std.debug.print("1. encoding.csv (RFC 4180 CSV Writer & Reader):\n", .{});

    var csv_buf = bytes.Buffer.init(gpa);
    defer csv_buf.deinit();

    var csv_w = encoding.csv.Writer.init(csv_buf.writer());
    const row1 = [_][]const u8{ "user_id", "name", "notes" };
    const row2 = [_][]const u8{ "101", "Alice Smith", "Engineer, \"Core Systems\"" };
    const row3 = [_][]const u8{ "102", "Bob Jones", "QA Lead\nRemote" };

    try csv_w.write(&row1);
    try csv_w.write(&row2);
    try csv_w.write(&row3);

    std.debug.print("   Generated CSV output:\n---\n{s}---\n", .{csv_buf.string()});

    var csv_r_src = bytes.Reader.init(csv_buf.bytes());
    var csv_r = encoding.csv.Reader.init(csv_r_src.reader());

    std.debug.print("   Parsed CSV records:\n", .{});
    var rec_idx: usize = 0;
    while (try csv_r.read(gpa)) |record| {
        defer encoding.csv.freeRecord(gpa, record);
        rec_idx += 1;
        std.debug.print("   Record {d}: [ ", .{rec_idx});
        for (record, 0..) |col, ci| {
            if (ci > 0) std.debug.print(" | ", .{});
            std.debug.print("\"{s}\"", .{col});
        }
        std.debug.print(" ]\n", .{});
    }

    // -------------------------------------------------------------
    // 2. encoding.binary: Endianness & Leb128 Varint
    // -------------------------------------------------------------
    std.debug.print("\n2. encoding.binary (Endian & Varint):\n", .{});
    var be_buf: [4]u8 = undefined;
    var le_buf: [4]u8 = undefined;
    const test_num: u32 = 0x12345678;

    try encoding.binary.BigEndian.writeU32(&be_buf, test_num);
    try encoding.binary.LittleEndian.writeU32(&le_buf, test_num);

    std.debug.print("   Number: 0x{X}\n", .{test_num});
    std.debug.print("   BigEndian bytes:    {s}\n", .{std.fmt.bytesToHex(be_buf, .lower)});
    std.debug.print("   LittleEndian bytes: {s}\n", .{std.fmt.bytesToHex(le_buf, .lower)});

    // Protobuf Varint
    var varint_buf: [10]u8 = undefined;
    const v_n = try encoding.binary.putVarint(&varint_buf, -4242);
    const decoded_v = try encoding.binary.varint(varint_buf[0..v_n]);
    std.debug.print("   Protobuf Varint(-4242): encoded in {d} bytes, decoded val: {d}\n\n", .{ v_n, decoded_v.val });

    // -------------------------------------------------------------
    // 3. encoding.base64: Standard & URL-Safe Base64
    // -------------------------------------------------------------
    std.debug.print("3. encoding.base64:\n", .{});
    const raw_string = "Hello, Zig 0.17 with stdgo!";
    const b64_std = try encoding.base64.std_encoding.encodeToString(gpa, raw_string);
    defer gpa.free(b64_std);
    std.debug.print("   Encoded: \"{s}\" -> \"{s}\"\n", .{ raw_string, b64_std });

    const decoded_str = try encoding.base64.std_encoding.decodeString(gpa, b64_std);
    defer gpa.free(decoded_str);
    std.debug.print("   Decoded: \"{s}\"\n\n", .{decoded_str});

    // -------------------------------------------------------------
    // 4. encoding.hex: Canonical Hex Dump
    // -------------------------------------------------------------
    std.debug.print("4. encoding.hex:\n", .{});
    const binary_data = "stdgo_binary_data_demo_2026";
    const dump_output = try encoding.hex.dump(gpa, binary_data);
    defer gpa.free(dump_output);
    std.debug.print("   Canonical Hex Dump:\n{s}\n", .{dump_output});

    std.debug.print("=== encoding demo completed successfully! ===\n", .{});
}
