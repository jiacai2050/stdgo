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

pub const request = @import("http/request.zig");
pub const Request = request.Request;
pub const newRequest = request.newRequest;
pub const parseUrlTarget = request.parseUrlTarget;

pub const response = @import("http/response.zig");
pub const Response = response.Response;
pub const ResponseBodyReader = response.ResponseBodyReader;

pub const transport = @import("http/transport.zig");
pub const Transport = transport.Transport;
pub const TransportOptions = transport.TransportOptions;

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
    const raw = "session=xyz123; Path=/; Domain=example.com; Secure; HttpOnly; SameSite=Lax; Max-Age=3600";
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
    const req = try newRequest(allocator, .POST, "http://127.0.0.1:8080/submit", "test payload data");
    return req;
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
    try testing.expectEqualStrings("Basic YWxhZGRpbjpvcGVuc2VzYW1l", req.header.get("Authorization").?);

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
