//! Example demonstrating stdgo's net.http Client capabilities:
//! 1. Client initialization and proxy configuration
//! 2. HTTP request deadlines
//! 3. Streaming uploads via io.Reader (Transfer-Encoding: chunked)
//! 4. Transparent Gzip response decompression

const std = @import("std");
const stdgo = @import("stdgo");
const http = stdgo.net.http;

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
        0xe4, 0x02, 0x00, 0x23, 0x9f, 0x54, 0x50, 0x29, 0x00, 0x00,
        0x00,
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
        .timeout_ns = 5 * std.time.ns_per_s,
        .max_redirects = 5,
        .proxy_from_env = false, // disable env proxy for loopback demo
    });
    defer client.deinit();

    std.debug.print("1. Client initialized with a 5s request and response-body budget\n", .{});

    // -------------------------------------------------------------
    // 3. Streaming Chunked Upload via stdgo.io.Reader
    // -------------------------------------------------------------
    var stream_src = stdgo.bytes.Reader.init("Streaming dynamic log payload line by line without buffering everything!");
    const upload_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/upload", .{server_port});
    defer gpa.free(upload_url);

    // Pass reader with null content_length -> triggers Chunked Transfer-Encoding
    var upload_req = try http.newRequestWithReader(gpa, .POST, upload_url, stream_src.reader(), null);
    defer upload_req.deinit();

    var upload_resp = try client.do(&upload_req, .none);
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
    // 5. Deadline capability
    // -------------------------------------------------------------
    var req_ctx = try http.newRequest(gpa, .GET, "http://127.0.0.1:1/cancelled", null);
    defer req_ctx.deinit();
    const deadline = stdgo.io.Deadline.after(io, .fromNanoseconds(0));
    if (client.do(&req_ctx, deadline)) |res_val| {
        var res = res_val;
        res.close();
        std.debug.print("\n4. Expired deadline request unexpectedly succeeded\n", .{});
    } else |err| {
        std.debug.print("\n4. Deadline request result: {s} (Expected: Timeout)\n", .{@errorName(err)});
    }

    // -------------------------------------------------------------
    // 6. Close idle connections & Custom RoundTripper Middleware Demo
    // -------------------------------------------------------------
    client.closeIdleConnections();
    std.debug.print("5. client.closeIdleConnections() executed successfully.\n", .{});

    // Demonstrate BasicAuth & Cookie generation
    var auth_req = try http.newRequest(gpa, .GET, "https://api.example.com/user", null);
    defer auth_req.deinit();
    try auth_req.setBasicAuth("developer", "token-secret-xyz");
    try auth_req.addCookie(.{ .name = "session_id", .value = "s_12345" });

    var decoded_auth = (try auth_req.basicAuth(gpa)).?;
    defer decoded_auth.deinit(gpa);
    std.debug.print("6. Request BasicAuth decoded: username='{s}', password='{s}'\n", .{ decoded_auth.username, decoded_auth.password });

    const req_cookies = try auth_req.cookies(gpa);
    defer gpa.free(req_cookies);
    std.debug.print("   Request parsed {d} cookie(s): {s}={s}\n", .{ req_cookies.len, req_cookies[0].name, req_cookies[0].value });

    // -------------------------------------------------------------
    // 7. SOCKS5 Proxy Demonstration (RFC 1928 / RFC 1929)
    // -------------------------------------------------------------
    std.debug.print("7. SOCKS5 Proxy Support:\n", .{});
    const socks_proxy_url = "socks5://user:pass@127.0.0.1:1080";
    var proxy_details = try http.proxy.parseProxyDetails(gpa, socks_proxy_url);
    defer proxy_details.deinit(gpa);
    std.debug.print("   - Configured SOCKS5 URL: '{s}' (is_socks5={})\n", .{ proxy_details.clean_proxy_url, proxy_details.is_socks5 });
    std.debug.print("   - SOCKS5 Auth: user='{?s}', pass='{?s}'\n", .{ proxy_details.socks_user, proxy_details.socks_pass });

    std.debug.print("\n=== HTTP Client demo completed successfully! ===\n", .{});
}
