//! Package smtp implements the Simple Mail Transfer Protocol as specified in RFC 5321.
//! It also implements the PLAIN (RFC 4616) and CRAM-MD5 (RFC 2195) authentication mechanisms.
const std = @import("std");
pub const auth = @import("smtp/auth.zig");
pub const client = @import("smtp/client.zig");
const conn_mod = @import("conn.zig");
const hostport = @import("hostport.zig");
const Allocator = std.mem.Allocator;

pub const Auth = auth.Auth;
pub const ServerInfo = auth.ServerInfo;
pub const plainAuth = auth.plainAuth;
pub const cramMD5Auth = auth.cramMD5Auth;

pub const Client = client.Client;
pub const SmtpError = client.SmtpError;

/// Connects to the SMTP server at `addr` over plain TCP (TLS/STARTTLS is not yet
/// supported), authenticates with the optional mechanism `a` if provided, and sends
/// an email from `from` to `to` with message body `msg`.
/// The `addr` must include a port, as in `"mail.example.com:25"`.
pub fn sendMail(
    allocator: Allocator,
    io: std.Io,
    addr: []const u8,
    a: ?Auth,
    from: []const u8,
    to: []const []const u8,
    msg: []const u8,
) !void {
    const hp = try hostport.splitHostPort(addr);
    const host = hp.host;

    const c = try conn_mod.dial(allocator, io, "tcp", addr, .none);
    const cl = Client.init(allocator, c, host) catch |err| {
        c.close();
        return err;
    };
    defer cl.close();

    // 1. Greet with EHLO
    try cl.ehlo("localhost");

    // 2. Authenticate if auth mechanism provided
    if (a) |authenticator| {
        try cl.auth(authenticator);
    }

    // 3. Set sender
    try cl.mail(from);

    // 4. Set recipients
    for (to) |rcpt| {
        try cl.rcpt(rcpt);
    }

    // 5. Transmit message data with dot-stuffing
    try cl.sendData(msg);

    // 6. Graceful QUIT
    try cl.quit();
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = auth;
    _ = client;
}

test "smtp client and mock server workflow with PLAIN auth" {
    const testing = std.testing;
    const net = @import("../net.zig");

    const io = testing.io;

    var listener = try net.listen(testing.allocator, io, "tcp", "127.0.0.1:0");
    defer listener.close();
    const port = listener.port().?;

    const MockSmtpServer = struct {
        fn run(l: net.Listener) void {
            const sc = l.accept() catch return;
            defer sc.close();

            // 1. Initial 220 banner
            _ = sc.write("220 mock.smtp.internal ESMTP Ready\r\n") catch return;

            var buf: [512]u8 = undefined;

            // 2. Expect EHLO
            var n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write(
                "250-mock.smtp.internal\r\n250-AUTH PLAIN CRAM-MD5\r\n250 8BITMIME\r\n",
            ) catch return;

            // 3. Expect AUTH PLAIN
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("235 2.7.0 Authentication successful\r\n") catch return;

            // 4. Expect MAIL FROM
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250 2.1.0 Sender OK\r\n") catch return;

            // 5. Expect RCPT TO
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250 2.1.5 Recipient OK\r\n") catch return;

            // 6. Expect DATA
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("354 Start mail input; end with <CRLF>.<CRLF>\r\n") catch return;

            // 7. Expect Mail body and trailing .\r\n
            while (true) {
                n = sc.read(&buf) catch return;
                if (n == 0) return;
                if (std.mem.endsWith(u8, buf[0..n], ".\r\n")) break;
            }
            _ = sc.write("250 2.0.0 Queued mail\r\n") catch return;

            // 8. Expect QUIT
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("221 2.0.0 Service closing transmission channel\r\n") catch return;
        }
    };

    const th = try std.Thread.spawn(.{}, MockSmtpServer.run, .{listener});
    defer th.join();

    var addr_buf: [32]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});

    const plain_a = try plainAuth(
        testing.allocator,
        "",
        "alice@example.com",
        "secret123",
        "127.0.0.1",
    );
    defer plain_a.deinit();

    const recipients = [_][]const u8{"bob@example.com"};
    const email_body = "Subject: Test\r\n\r\nHello SMTP from Zig 0.17 stdgo!\r\n";

    try sendMail(
        testing.allocator,
        io,
        addr_str,
        plain_a,
        "alice@example.com",
        &recipients,
        email_body,
    );
}

test "smtp rejects CRLF command injection in arguments" {
    const testing = std.testing;
    const pair = try conn_mod.pipe(testing.allocator, testing.io);
    defer pair.conn2.close();

    _ = try pair.conn2.write("220 mock.smtp Ready\r\n");
    const cl = try Client.init(testing.allocator, pair.conn1, "mock.smtp");
    defer cl.close();

    try testing.expectError(error.InvalidSmtpArgument, cl.ehlo("host\r\nRSET"));
    try testing.expectError(error.InvalidSmtpArgument, cl.hello("host\nRSET"));
    try testing.expectError(error.InvalidSmtpArgument, cl.mail("a@b.com>\r\nDATA"));
    try testing.expectError(error.InvalidSmtpArgument, cl.rcpt("b@c.com\nQUIT"));
}
