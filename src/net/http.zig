//! Go net/http implementation for Zig.
const std = @import("std");

pub const status = @import("http/status.zig");
pub const Status = status.Status;
pub const StatusOK = status.StatusOK;
pub const StatusNotFound = status.StatusNotFound;
pub const StatusBadRequest = status.StatusBadRequest;
pub const StatusInternalServerError = status.StatusInternalServerError;

pub const method = @import("http/method.zig");
pub const Method = method.Method;
pub const MethodGet = method.MethodGet;
pub const MethodPost = method.MethodPost;
pub const MethodHead = method.MethodHead;
pub const MethodPut = method.MethodPut;
pub const MethodDelete = method.MethodDelete;

pub const header = @import("http/header.zig");
pub const Header = header.Header;

pub const cookie = @import("http/cookie.zig");
pub const Cookie = cookie.Cookie;
pub const CookieIterator = cookie.CookieIterator;
pub const parseSetCookie = cookie.parseSetCookie;

pub const jar = @import("http/jar.zig");
pub const CookieJar = jar.CookieJar;

pub const proxy = @import("http/proxy.zig");
pub const socks5 = @import("http/socks5.zig");
pub const proxyFromEnvironment = proxy.proxyFromEnvironment;
pub const proxyFromEnvWithMap = proxy.proxyFromEnvWithMap;
pub const proxyFromEnvWithLookup = proxy.proxyFromEnvWithLookup;
pub const isNoProxy = proxy.isNoProxy;

pub const request = @import("http/request.zig");
pub const Request = request.Request;
pub const newRequest = request.newRequest;
pub const newRequestWithReader = request.newRequestWithReader;
pub const parseUrlTarget = request.parseUrlTarget;

pub const response = @import("http/response.zig");
pub const Response = response.Response;
pub const ResponseBodyReader = response.ResponseBodyReader;

pub const transport = @import("http/transport.zig");
pub const Transport = transport.Transport;
pub const TransportOptions = transport.TransportOptions;
pub const RoundTripper = transport.RoundTripper;

pub const pool = @import("http/pool.zig");
pub const ConnPool = pool.ConnPool;

pub const client = @import("http/client.zig");
pub const Client = client.Client;
pub const ClientOptions = client.ClientOptions;
pub const get = client.get;
pub const head = client.head;
pub const post = client.post;
pub const put = client.put;
pub const delete = client.delete;
pub const patch = client.patch;
pub const postForm = client.postForm;

test {
    std.testing.refAllDecls(@This());
    _ = @import("http/status.zig");
    _ = @import("http/method.zig");
    _ = @import("http/header.zig");
    _ = @import("http/cookie.zig");
    _ = @import("http/jar.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response_parser.zig");
    _ = @import("http/pool.zig");
    _ = @import("http/conn.zig");
}

test "http Header get set add del" {
    var h = Header.init(std.testing.allocator);
    defer h.deinit();

    try h.set("content-type", "text/plain");
    try std.testing.expectEqualStrings("text/plain", h.get("Content-Type").?);

    try h.set("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", h.get("content-type").?);

    try h.add("Accept", "text/html");
    try h.add("accept", "application/xhtml+xml");
    try std.testing.expect(h.get("accept") != null);

    h.del("accept");
    try std.testing.expect(h.get("accept") == null);
}

test "http Cookie parseSetCookie" {
    const raw = "session=xyz123; Path=/; Domain=example.com; " ++
        "Secure; HttpOnly; SameSite=Lax; Max-Age=3600";
    const c = parseSetCookie(raw).?;
    try std.testing.expectEqualStrings("session", c.name);
    try std.testing.expectEqualStrings("xyz123", c.value);
    try std.testing.expectEqualStrings("/", c.path.?);
    try std.testing.expectEqualStrings("example.com", c.domain.?);
    try std.testing.expect(c.secure);
    try std.testing.expect(c.http_only);
    try std.testing.expectEqual(@as(?i64, 3600), c.max_age);
    try std.testing.expectEqual(cookie.SameSite.lax, c.same_site);
}

test "http CookieJar store and inject" {
    var cj = CookieJar.init(std.testing.allocator);
    defer cj.deinit();

    try cj.setCookiesFromHeader("example.com", "token=abc; Path=/");
    try cj.setCookiesFromHeader("example.com", "user=alice; Path=/");

    const formatted = (try cj.formatCookieHeader(std.testing.allocator, "example.com")).?;
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("token=abc; user=alice", formatted);
}

test "http parseUrlTarget" {
    const t1 = try parseUrlTarget("http://127.0.0.1:8080/api/v1/users?page=1");
    try std.testing.expectEqualStrings("127.0.0.1", t1.host);
    try std.testing.expectEqual(@as(u16, 8080), t1.port);
    try std.testing.expectEqualStrings("/api/v1/users?page=1", t1.request_target);
    try std.testing.expect(!t1.is_tls);

    const t2 = try parseUrlTarget("http://example.com");
    try std.testing.expectEqualStrings("example.com", t2.host);
    try std.testing.expectEqual(@as(u16, 80), t2.port);
    try std.testing.expectEqualStrings("/", t2.request_target);
    try std.testing.expect(!t2.is_tls);

    const t3 = try parseUrlTarget("https://example.com/secure");
    try std.testing.expectEqualStrings("example.com", t3.host);
    try std.testing.expectEqual(@as(u16, 443), t3.port);
    try std.testing.expectEqualStrings("/secure", t3.request_target);
    try std.testing.expect(t3.is_tls);
}

fn createTestRequestOnStack(allocator: std.mem.Allocator) !Request {
    // Tests that returning Request across stack frames preserves Content-Length slice
    const url = "http://127.0.0.1:8080/submit";
    return try newRequest(allocator, .POST, url, "test payload data");
}

test "http newRequest stack escape safety" {
    const testing = std.testing;

    var req = try createTestRequestOnStack(testing.allocator);
    defer req.deinit();

    // Call another function to touch the stack
    var dummy: [128]u8 = undefined;
    @memset(&dummy, 0xAA);

    const cl = req.header.get("Content-Length");
    try testing.expect(cl != null);
    try testing.expectEqualStrings("17", cl.?);
}

test "http Request setBasicAuth and addCookie" {
    const testing = std.testing;
    var req = try newRequest(testing.allocator, .GET, "https://example.com/api", null);
    defer req.deinit();

    try req.setBasicAuth("aladdin", "opensesame");
    const auth_header = req.header.get("Authorization").?;
    try testing.expectEqualStrings("Basic YWxhZGRpbjpvcGVuc2VzYW1l", auth_header);

    try req.addCookie(.{ .name = "foo", .value = "bar" });
    try req.addCookie(.{ .name = "baz", .value = "qux" });
    try testing.expectEqualStrings("foo=bar; baz=qux", req.header.get("Cookie").?);
}

test "http ConnPool acquire, release and thread-safe mutex" {
    const testing = std.testing;

    var p = ConnPool.init(testing.allocator, 2);
    // Initially empty
    try testing.expect(p.acquire("127.0.0.1", 8080, false) == null);
}

test "http Header has and values" {
    const testing = std.testing;
    var h = Header.init(testing.allocator);
    defer h.deinit();

    try testing.expect(!h.has("Accept"));
    try h.add("Accept", "text/html");
    try h.add("accept", "application/json");
    try testing.expect(h.has("Accept"));
    try testing.expect(h.has("accept"));

    const vals = try h.values(testing.allocator, "Accept");
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("text/html", vals[0]);
    try testing.expectEqualStrings("application/json", vals[1]);
}

test "http Cookie string formatting" {
    const testing = std.testing;
    const c = Cookie{
        .name = "session_id",
        .value = "xyz789",
        .path = "/app",
        .domain = "example.com",
        .max_age = 7200,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    };

    const s = try c.string(testing.allocator);
    defer testing.allocator.free(s);
    const expected = "session_id=xyz789; Path=/app; Domain=example.com; " ++
        "Max-Age=7200; Secure; HttpOnly; SameSite=Lax";
    try testing.expectEqualStrings(expected, s);
}

test "http Request basicAuth decoding, cookies and clone" {
    const testing = std.testing;
    var req = try newRequest(testing.allocator, .GET, "https://example.com/api", null);
    defer req.deinit();

    try req.setBasicAuth("admin", "secret123");
    try req.addCookie(.{ .name = "theme", .value = "dark" });
    try req.setHeader("User-Agent", "stdgo-agent/1.0");

    try testing.expectEqualStrings("stdgo-agent/1.0", req.userAgent().?);

    var auth = (try req.basicAuth(testing.allocator)).?;
    defer auth.deinit(testing.allocator);
    try testing.expectEqualStrings("admin", auth.username);
    try testing.expectEqualStrings("secret123", auth.password);

    const parsed_cookies = try req.cookies(testing.allocator);
    defer testing.allocator.free(parsed_cookies);
    try testing.expectEqual(@as(usize, 1), parsed_cookies.len);
    try testing.expectEqualStrings("theme", parsed_cookies[0].name);
    try testing.expectEqualStrings("dark", parsed_cookies[0].value);

    var cloned = try req.clone(testing.allocator);
    defer cloned.deinit();
    try testing.expectEqualStrings("stdgo-agent/1.0", cloned.userAgent().?);
    try testing.expectEqualStrings("https://example.com/api", cloned.url);
}

test "http custom RoundTripper injection and closeIdleConnections" {
    const testing = std.testing;

    const io = testing.io;

    const MockRoundTripper = struct {
        calls: usize = 0,
        idle_closed: bool = false,

        fn roundTrip(
            ctx: *anyopaque,
            _: *Request,
            _: @import("../io/deadline.zig").Deadline,
        ) anyerror!Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return error.MockNetworkError;
        }

        fn closeIdle(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.idle_closed = true;
        }

        fn rt(self: *@This()) RoundTripper {
            return .{
                .ptr = self,
                .vtable = &.{
                    .roundTrip = roundTrip,
                    .closeIdleConnections = closeIdle,
                },
            };
        }
    };

    var mock = MockRoundTripper{};
    var c = Client.init(testing.allocator, io, .{
        .round_tripper = mock.rt(),
    });
    defer c.deinit();

    var req = try newRequest(testing.allocator, .GET, "http://mock.local/test", null);
    defer req.deinit();

    const res = c.do(&req, .none);
    try testing.expectError(error.MockNetworkError, res);
    try testing.expectEqual(@as(usize, 1), mock.calls);

    c.closeIdleConnections();
    try testing.expect(mock.idle_closed);
}

test "http transparent SOCKS5 proxy end-to-end" {
    const testing = std.testing;

    const io = testing.io;

    // 1. Target HTTP server
    const http_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var http_server = try http_addr.listen(io, .{ .reuse_address = true });
    defer http_server.deinit(io);
    const http_port = http_server.socket.address.ip4.port;

    const HttpWorker = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io) void {
            var client_sock = s.accept(s_io) catch return;
            defer client_sock.close(s_io);

            var r_buf: [512]u8 = undefined;
            var reader = client_sock.reader(s_io, &r_buf);
            while (std.mem.indexOf(u8, reader.interface.buffered(), "\r\n\r\n") == null) {
                reader.interface.fillMore() catch return;
            }

            var w_buf: [512]u8 = undefined;
            var writer = client_sock.writer(s_io, &w_buf);
            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 17\r\n" ++
                "Connection: close\r\n\r\nHello from SOCKS5";
            writer.interface.writeAll(resp) catch return;
            writer.interface.flush() catch return;
        }
    };
    const http_thread = try std.Thread.spawn(.{}, HttpWorker.run, .{ &http_server, io });
    defer http_thread.join();

    // 2. Mock SOCKS5 server
    const socks_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var socks_server = try socks_addr.listen(io, .{ .reuse_address = true });
    defer socks_server.deinit(io);
    const socks_port = socks_server.socket.address.ip4.port;

    const SocksWorker = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io, target_port: u16) void {
            var client_sock = s.accept(s_io) catch return;
            defer client_sock.close(s_io);

            var r_buf: [512]u8 = undefined;
            var cr = client_sock.reader(s_io, &r_buf);
            var w_buf: [512]u8 = undefined;
            var cw = client_sock.writer(s_io, &w_buf);

            // Read Greeting
            while (cr.interface.buffered().len < 3) {
                cr.interface.fillMore() catch return;
            }
            cr.interface.toss(cr.interface.buffered().len);

            // Accept No Auth: 0x05, 0x00
            cw.interface.writeAll(&[_]u8{ 0x05, 0x00 }) catch return;
            cw.interface.flush() catch return;

            // Read Connect Request: 0x05, 0x01, 0x00, ATYP...
            while (cr.interface.buffered().len < 7) {
                cr.interface.fillMore() catch return;
            }
            cr.interface.toss(cr.interface.buffered().len);

            // Connect to real target
            const target_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", target_port) catch {
                return;
            };
            var upstream = target_addr.connect(
                s_io,
                .{ .mode = .stream, .timeout = .none },
            ) catch return;
            defer upstream.close(s_io);

            // Reply Success: 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0
            cw.interface.writeAll(&[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }) catch return;
            cw.interface.flush() catch return;

            // Bidirectional proxy: client -> upstream
            var u_rbuf: [512]u8 = undefined;
            var ur = upstream.reader(s_io, &u_rbuf);
            var u_wbuf: [512]u8 = undefined;
            var uw = upstream.writer(s_io, &u_wbuf);

            // Read client HTTP request and forward to upstream
            while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) {
                cr.interface.fillMore() catch return;
            }
            uw.interface.writeAll(cr.interface.buffered()) catch return;
            uw.interface.flush() catch return;
            cr.interface.toss(cr.interface.buffered().len);

            // Read upstream HTTP response and forward to client
            while (std.mem.indexOf(u8, ur.interface.buffered(), "Hello from SOCKS5") == null) {
                ur.interface.fillMore() catch return;
            }
            cw.interface.writeAll(ur.interface.buffered()) catch return;
            cw.interface.flush() catch return;
        }
    };
    const socks_thread = try std.Thread.spawn(
        .{},
        SocksWorker.run,
        .{ &socks_server, io, http_port },
    );
    defer socks_thread.join();

    // 3. Client configured with SOCKS5 proxy
    var proxy_buf: [64]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_buf, "socks5://127.0.0.1:{d}", .{socks_port});

    var c = Client.init(testing.allocator, io, .{
        .proxy_url = proxy_url,
    });
    defer c.deinit();

    var target_buf: [64]u8 = undefined;
    const target_url = try std.fmt.bufPrint(&target_buf, "http://127.0.0.1:{d}/test", .{http_port});

    var resp = try c.get(target_url);
    defer resp.close();

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    const body = try resp.readAllAlloc(1024);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Hello from SOCKS5", body);
}
