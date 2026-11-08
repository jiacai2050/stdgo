//! stdgo: Go standard library equivalents for Zig
const std = @import("std");

pub const io = @import("io.zig");
pub const bytes = @import("bytes.zig");
pub const strings = @import("strings.zig");
pub const bufio = @import("bufio.zig");
pub const encoding = @import("encoding.zig");
pub const path = @import("path.zig");
pub const net = @import("net.zig");
pub const archive = @import("archive.zig");
pub const compress = @import("compress.zig");
pub const regexp = @import("regexp.zig");
pub const flag = @import("flag.zig");
pub const text = @import("text.zig");
pub const sync = @import("sync.zig");
pub const time = @import("time.zig");
pub const container = @import("container.zig");
pub const slices = @import("slices.zig");
pub const hash = @import("hash.zig");
pub const crypto = @import("crypto.zig");
pub const context = @import("context.zig");
pub const math = @import("math.zig");
pub const mime = @import("mime.zig");
pub const log = @import("log.zig");

test "stdgo integration: bytes.Buffer + io.copy + bytes.Reader" {
    const testing = std.testing;

    const source_text = "The quick brown fox jumps over the lazy dog";
    var r = bytes.Reader.init(source_text);

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    var temp_buf: [16]u8 = undefined;
    const copied = try io.copy(buf.writer(), r.reader(), &temp_buf);

    try testing.expectEqual(@as(u64, source_text.len), copied);
    try testing.expectEqualStrings(source_text, buf.string());
}

test "stdgo integration: bufio.Scanner + encoding.binary" {
    const testing = std.testing;

    var buf = bytes.Buffer.init(testing.allocator);
    defer buf.deinit();

    var varint_scratch: [10]u8 = undefined;
    const numbers = [_]i64{ 42, -999, 12345678, -1 };
    for (numbers) |num| {
        const n = try encoding.binary.putVarint(&varint_scratch, num);
        _ = try buf.write(varint_scratch[0..n]);
    }

    var r = bytes.Reader.init(buf.bytes());
    var decoded: [4]i64 = undefined;
    var idx: usize = 0;
    while (r.len() > 0) {
        const res = try encoding.binary.varint(r.s[@intCast(r.i)..]);
        _ = try r.seek(@intCast(res.bytes_read), .current);
        decoded[idx] = res.val;
        idx += 1;
    }

    try testing.expectEqual(numbers.len, idx);
    for (numbers, 0..) |expected, i| {
        try testing.expectEqual(expected, decoded[i]);
    }
}

test "stdgo integration: csv + zip + regexp pipeline" {
    const testing = std.testing;

    var csv_buf = bytes.Buffer.init(testing.allocator);
    defer csv_buf.deinit();

    var csv_w = encoding.csv.Writer.init(csv_buf.writer());
    const r1 = [_][]const u8{ "user_id", "email", "status" };
    const r2 = [_][]const u8{ "1001", "alice@example.com", "active" };
    const r3 = [_][]const u8{ "1002", "bob@example.org", "pending" };
    try csv_w.write(&r1);
    try csv_w.write(&r2);
    try csv_w.write(&r3);

    var zip_buf = bytes.Buffer.init(testing.allocator);
    defer zip_buf.deinit();

    var zw = archive.zip.Writer.init(testing.allocator, zip_buf.writer());
    defer zw.deinit();
    try zw.writeFile("users.csv", csv_buf.bytes(), .store);
    try zw.close();

    var zr = try archive.zip.Reader.init(testing.allocator, zip_buf.bytes());
    defer zr.deinit();

    const files = zr.files();
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("users.csv", files[0].header.name);

    const extracted = try files[0].open(testing.allocator);
    defer testing.allocator.free(extracted);

    var re = try regexp.compile(testing.allocator, "[a-z]+@example\\.[a-z]+");
    defer re.deinit();

    try testing.expect(re.matchString(extracted));
    try testing.expectEqualStrings("alice@example.com", re.findString(extracted).?);
}

test "stdgo integration: flag + tabwriter CLI formatting" {
    const testing = std.testing;

    var fs = flag.FlagSet.init(testing.allocator, "server");
    defer fs.deinit();

    var port: i64 = 8080;
    var host: []const u8 = "127.0.0.1";
    var debug: bool = false;

    try fs.intVar(&port, "port", 8080, "listen port");
    try fs.stringVar(&host, "host", "127.0.0.1", "listen host");
    try fs.boolVar(&debug, "debug", false, "enable debug logging");

    const argv = [_][]const u8{ "--port=9000", "--debug" };
    try fs.parse(&argv);

    try testing.expectEqual(@as(i64, 9000), port);
    try testing.expect(debug);

    var table_buf = bytes.Buffer.init(testing.allocator);
    defer table_buf.deinit();

    var tw = text.tabwriter.Writer.init(testing.allocator, table_buf.writer(), 0, 8, 2, ' ', 0);
    defer tw.deinit();

    _ = try tw.write("OPTION\tVALUE\tDESCRIPTION\n");
    _ = try tw.write("port\t9000\tlisten port\n");
    _ = try tw.write("debug\ttrue\tenable debug logging\n");
    try tw.flush();

    const expected =
        "OPTION  VALUE  DESCRIPTION\n" ++
        "port    9000   listen port\n" ++
        "debug   true   enable debug logging\n";

    try testing.expectEqualStrings(expected, table_buf.string());
}

test "stdgo integration: tar + crypto.sha256 streaming hash" {
    const testing = std.testing;

    var tar_buf = bytes.Buffer.init(testing.allocator);
    defer tar_buf.deinit();

    var tw = archive.tar.Writer.init(tar_buf.writer());
    const payload = "Antigravity standard Go library replica in Zig";
    const hdr = archive.tar.Header{
        .name = "payload.bin",
        .size = payload.len,
    };
    try tw.writeHeader(&hdr);
    _ = try tw.write(payload);
    try tw.close();

    var br = bytes.Reader.init(tar_buf.bytes());
    var tr = archive.tar.Reader.init(br.reader());
    const ent = (try tr.next()).?;
    try testing.expectEqualStrings("payload.bin", ent.name);

    var sha_digest = crypto.sha256.New();
    var temp_chunk: [16]u8 = undefined;
    const copied = try io.copy(sha_digest.writer(), tr.reader(), &temp_chunk);
    try testing.expectEqual(@as(u64, payload.len), copied);

    var final_hash: [32]u8 = undefined;
    sha_digest.sum(&final_hash);

    const expected_hash = crypto.sha256.Sum256(payload);
    try testing.expectEqualStrings(&expected_hash, &final_hash);
}

test "stdgo integration: strings.Builder + time.parseDuration + slices.sort" {
    const testing = std.testing;

    // 1. Build a log line
    var sb = strings.Builder.init(testing.allocator);
    defer sb.deinit();

    _ = try sb.writeString("task_timeout=");
    _ = try sb.writeString("2m30s");
    _ = try sb.writeString(";retry_interval=500ms");

    // 2. Parse out durations
    const kv_pairs = try strings.split(testing.allocator, sb.string(), ";");
    defer strings.freeSplit(testing.allocator, kv_pairs);
    try testing.expectEqual(@as(usize, 2), kv_pairs.len);

    const d1 = try time.parseDuration(strings.trimPrefix(kv_pairs[0], "task_timeout="));
    try testing.expectEqual(@as(i64, 150), @divTrunc(d1.milliseconds(), 1000));

    const d2 = try time.parseDuration(strings.trimPrefix(kv_pairs[1], "retry_interval="));
    try testing.expectEqual(@as(i64, 500), d2.milliseconds());

    // 3. Sort slice
    var dur_array = [_]i64{ d1.milliseconds(), d2.milliseconds(), 100 };
    slices.sort(i64, &dur_array, struct {
        fn less(a: i64, b: i64) bool {
            return a < b;
        }
    }.less);
    try testing.expectEqualSlices(i64, &[_]i64{ 100, 500, 150000 }, &dur_array);
}

test "stdgo integration: base64 + hex encoding" {
    const testing = std.testing;

    const data = "Go standard library features in Zig 0.17!";
    const b64 = try encoding.base64.std_encoding.encodeToString(testing.allocator, data);
    defer testing.allocator.free(b64);

    const hex_encoded = try encoding.hex.encodeToString(testing.allocator, b64);
    defer testing.allocator.free(hex_encoded);

    const hex_decoded = try encoding.hex.decodeString(testing.allocator, hex_encoded);
    defer testing.allocator.free(hex_decoded);

    const original = try encoding.base64.std_encoding.decodeString(testing.allocator, hex_decoded);
    defer testing.allocator.free(original);

    try testing.expectEqualStrings(data, original);
}

test "stdgo integration: context cancellation + value chain" {
    const testing = std.testing;

    const root_ctx = context.background();
    const req_id: []const u8 = "req-9876";

    var val_node = try context.withValue(testing.allocator, root_ctx, "req_id", &req_id);
    defer testing.allocator.destroy(val_node);

    var cancel_node = try context.withCancel(testing.allocator, val_node.context());
    defer testing.allocator.destroy(cancel_node);

    const ctx = cancel_node.context();
    try testing.expect(!ctx.done());

    const found: ?*const anyopaque = ctx.value("req_id");
    const val_ptr: *const []const u8 = @ptrCast(@alignCast(found.?));
    try testing.expectEqualStrings("req-9876", val_ptr.*);

    cancel_node.cancel();
    try testing.expect(ctx.done());
    try testing.expectEqual(context.Error.Canceled, ctx.err().?);
}

test "stdgo integration: sync.Pool + math.rand" {
    const testing = std.testing;

    const BufferHelper = struct {
        fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*bytes.Buffer {
            const buf = try allocator.create(bytes.Buffer);
            buf.* = bytes.Buffer.init(allocator);
            return buf;
        }

        fn destroy(allocator: std.mem.Allocator, buf: *bytes.Buffer) void {
            buf.deinit();
            allocator.destroy(buf);
        }
    };

    var pool = sync.Pool(bytes.Buffer).init(testing.allocator, BufferHelper.create);
    defer pool.deinit(BufferHelper.destroy);

    var r = math.rand.Rand.init(999);

    const b = (try pool.get()).?;
    _ = try b.write("random number: ");
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{r.intn(1000)}) catch unreachable;
    _ = try b.write(num_str);

    try testing.expect(b.len() > 15);
    b.reset();
    try pool.put(b);
}

test "stdgo integration: net.http Request and Header" {
    const testing = std.testing;

    var req = try net.http.newRequest(testing.allocator, .POST, "http://127.0.0.1:8080/api/login", "{\"user\":\"admin\"}");
    defer req.deinit();

    try req.setHeader("Content-Type", "application/json");
    try req.setHeader("Authorization", "Bearer token123");

    try testing.expectEqualStrings("application/json", req.header.get("content-type").?);
    try testing.expectEqualStrings("Bearer token123", req.header.get("authorization").?);
    try testing.expectEqualStrings("16", req.header.get("content-length").?);
    try testing.expectEqual(net.http.StatusOK, .ok);
}

fn mockHttpServerThread(std_io: std.Io, server: *std.Io.net.Server) void {
    var stream = server.accept(std_io) catch return;
    defer stream.close(std_io);

    var buf: [1024]u8 = undefined;
    var data = [1][]u8{&buf};
    const op = std.Io.Operation{
        .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        },
    };
    _ = std_io.operate(op) catch return;

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "Hello, stdgo!";

    var resp_slice = [1][]const u8{resp};
    const write_op = std.Io.Operation{
        .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &resp_slice,
        },
    };
    _ = std_io.operate(write_op) catch return;
}

test "stdgo integration: net.http real TCP loopback round-trip" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init_single_threaded;
    const std_io = threaded.io();

    const bind_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try bind_addr.listen(std_io, .{ .reuse_address = true });
    defer server.deinit(std_io);

    const actual_port = server.socket.address.ip4.port;

    var thread = try std.Thread.spawn(.{}, mockHttpServerThread, .{ std_io, &server });
    defer thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{actual_port});

    var resp = try net.http.get(testing.allocator, std_io, url);
    defer resp.close();

    try testing.expectEqual(net.http.StatusOK, resp.status);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expectEqualStrings("text/plain", resp.header.get("content-type").?);

    const body = try resp.readAllAlloc(1024);
    defer testing.allocator.free(body);

    try testing.expectEqualStrings("Hello, stdgo!", body);
}

test {
    std.testing.refAllDecls(@This());
    _ = io;
    _ = bytes;
    _ = strings;
    _ = bufio;
    _ = encoding;
    _ = path;
    _ = net;
    _ = archive;
    _ = compress;
    _ = regexp;
    _ = flag;
    _ = text;
    _ = sync;
    _ = time;
    _ = container;
    _ = slices;
    _ = hash;
    _ = crypto;
    _ = context;
    _ = math;
    _ = mime;
    _ = log;
}
