//! Example demonstrating stdgo's net.http Client capabilities:
//! 1. Client initialization with timeout & proxy configuration
//! 2. Context-bound cancellation
//! 3. Streaming uploads via io.Reader (Transfer-Encoding: chunked)
//! 4. Transparent Gzip response decompression

const std = @import("std");
const stdgo = @import("stdgo");
const http = stdgo.net.http;
const context = stdgo.context;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: net.http Client Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Setup a local mock HTTP server on 127.0.0.1 to showcase
    //    client-server streaming, chunked upload, and gzip response.
    // -------------------------------------------------------------
    const bind_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try bind_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const server_port = server.socket.address.ip4.port;

    // Gzip compressed payload of "Hello from stdgo transparent gzip server!\n"
    const gzip_payload = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0x2b, 0xca, 0xcf,
        0x55, 0x28, 0x2e, 0x49, 0x49, 0xcf, 0x57, 0x28, 0x29, 0x4a,
        0xcc, 0x2b, 0x2e, 0x48, 0x2d, 0x4a, 0xcd, 0x53, 0x48, 0xaf,
        0xca, 0x2c, 0x50, 0x28, 0x4e, 0x2d, 0x2a, 0x4b, 0x2d, 0x52,
        0xe4, 0x02, 0x00, 0x23, 0x9f, 0x54, 0x50, 0x29, 0x00, 0x00, 0x00,
    };

    const ServerThread = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, payload: []const u8) !void {
            // Handle 2 requests
            var req_count: usize = 0;
            while (req_count < 2) : (req_count += 1) {
                var conn = try s.accept(s_io);
                defer conn.close(s_io);

                var r_buf: [1024]u8 = undefined;
                var sr = conn.reader(s_io, &r_buf);
                while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n\r\n") == null) {
                    try sr.interface.fillMore();
                }

                const head = sr.interface.buffered();
                var w_buf: [512]u8 = undefined;
                var sw = conn.writer(s_io, &w_buf);

                if (std.mem.indexOf(u8, head, "POST /upload") != null) {
                    // 1. Read chunked upload from client
                    const crlf_idx = std.mem.indexOf(u8, head, "\r\n\r\n").?;
                    sr.interface.toss(crlf_idx + 4);

                    var upload_len: usize = 0;
                    while (true) {
                        while (std.mem.indexOf(u8, sr.interface.buffered(), "\r\n") == null) {
                            try sr.interface.fillMore();
                        }
                        const sz_end = std.mem.indexOf(u8, sr.interface.buffered(), "\r\n").?;
                        const chunk_sz = try std.fmt.parseInt(usize, sr.interface.buffered()[0..sz_end], 16);
                        sr.interface.toss(sz_end + 2);
                        if (chunk_sz == 0) {
                            while (sr.interface.buffered().len < 2) try sr.interface.fillMore();
                            sr.interface.toss(2);
                            break;
                        }
                        while (sr.interface.buffered().len < chunk_sz + 2) try sr.interface.fillMore();
                        upload_len += chunk_sz;
                        sr.interface.toss(chunk_sz + 2);
                    }

                    var resp_buf: [128]u8 = undefined;
                    const r_str = try std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Length: 17\r\n\r\nReceived {d} bytes", .{upload_len});
                    try sw.interface.writeAll(r_str);
                    try sw.interface.flush();
                } else {
                    // 2. Gzip response
                    var resp_buf: [128]u8 = undefined;
                    const r_str = try std.fmt.bufPrint(
                        &resp_buf,
                        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
                        .{payload.len},
                    );
                    try sw.interface.writeAll(r_str);
                    try sw.interface.writeAll(payload);
                    try sw.interface.flush();
                }
            }
        }
    };

    var server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, io, &gzip_payload });

    // -------------------------------------------------------------
    // 2. Configure HTTP Client with Options
    // -------------------------------------------------------------
    var client = http.Client.init(gpa, io, .{
        .timeout_ns = 5 * std.time.ns_per_s, // 5 second end-to-end deadline
        .max_redirects = 5,
        .proxy_from_env = false, // disable env proxy for loopback demo
    });
    defer client.deinit();

    std.debug.print("1. Client initialized with 5s timeout\n", .{});

    // -------------------------------------------------------------
    // 3. Streaming Chunked Upload via stdgo.io.Reader
    // -------------------------------------------------------------
    const StreamBuffer = struct {
        data: []const u8,
        cursor: usize = 0,

        fn read(ctx_ptr: *anyopaque, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (self.cursor >= self.data.len) return 0;
            const avail = self.data.len - self.cursor;
            const n = @min(avail, @min(buf.len, 10)); // send in 10-byte chunks
            @memcpy(buf[0..n], self.data[self.cursor .. self.cursor + n]);
            self.cursor += n;
            return n;
        }

        fn reader(self: *@This()) stdgo.io.Reader {
            return .{
                .ptr = self,
                .vtable = &.{ .read = read },
            };
        }
    };

    var stream_src = StreamBuffer{ .data = "Streaming dynamic log payload line by line without buffering everything!" };
    const upload_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/upload", .{server_port});
    defer gpa.free(upload_url);

    // Pass reader with null content_length -> triggers Chunked Transfer-Encoding
    var upload_req = try http.newRequestWithReader(gpa, .POST, upload_url, stream_src.reader(), null);
    defer upload_req.deinit();

    var upload_resp = try client.do(&upload_req);
    defer upload_resp.close();

    const upload_body = try upload_resp.readAllAlloc(1024);
    defer gpa.free(upload_body);
    std.debug.print("2. Chunked Upload Status: {d}, Server reply: '{s}'\n", .{ upload_resp.status_code, upload_body });

    // -------------------------------------------------------------
    // 4. Transparent Gzip Response Decompression
    // -------------------------------------------------------------
    const gzip_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/compressed", .{server_port});
    defer gpa.free(gzip_url);

    var gzip_resp = try client.get(gzip_url);
    defer gzip_resp.close();

    std.debug.print("3. Gzip Request complete:\n", .{});
    std.debug.print("   - Uncompressed flag: {any}\n", .{gzip_resp.uncompressed});
    std.debug.print("   - Content-Encoding header: {?s}\n", .{gzip_resp.header.get("Content-Encoding")});

    const decompressed_body = try gzip_resp.readAllAlloc(1024);
    defer gpa.free(decompressed_body);
    std.debug.print("   - Automatically decompressed body: '{s}'\n", .{std.mem.trim(u8, decompressed_body, "\r\n")});

    server_thread.join();

    // -------------------------------------------------------------
    // 5. Context Cancellation Demo
    // -------------------------------------------------------------
    var cancel_ctx = try context.withCancel(gpa, context.background());
    defer gpa.destroy(cancel_ctx);

    var req_ctx = try http.newRequest(gpa, .GET, "http://127.0.0.1:1/cancelled", null);
    defer req_ctx.deinit();
    req_ctx.withContext(cancel_ctx.context());

    // Cancel before or during request
    cancel_ctx.cancel();
    if (client.do(&req_ctx)) |res_val| {
        var res = res_val;
        res.close();
        std.debug.print("\n4. Context-cancelled request unexpected success\n", .{});
    } else |err| {
        std.debug.print("\n4. Context-cancelled request result: {s} (Expected: Canceled)\n", .{@errorName(err)});
    }

    std.debug.print("\n=== HTTP Client demo completed successfully! ===\n", .{});
}
