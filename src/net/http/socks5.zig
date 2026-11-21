//! RFC 1928 (SOCKS Protocol Version 5) and RFC 1929 (Username/Password Authentication) implementation.
//!
//! ### socks5:// vs socks5h:// URL Schemes
//! - `socks5://`: The client resolves hostnames using local DNS before connecting, sending the raw
//!   resolved IP (IPv4 `0x01` or IPv6 `0x04`) to the SOCKS5 proxy server.
//!   *Warning*: This can cause DNS leaks to the local ISP and may fail if the local DNS is poisoned.
//! - `socks5h://`: The `h` suffix indicates remote **Host** name resolution. The client bypasses local
//!   DNS entirely and transmits the target hostname directly (ATYP `0x03` Domain Name) to the remote
//!   SOCKS5 proxy server, which performs DNS resolution on behalf of the client.
//!   *Benefits*: Prevents DNS leaks, bypasses local DNS censorship/poisoning, and enables reaching
//!   internal domains hosted behind the remote proxy network.
//!
//! In stdgo's implementation, `establishSocks5Tunnel` natively supports sending domain names directly
//! via ATYP `0x03`, preserving full privacy and remote resolution compatibility.
const std = @import("std");

pub const Socks5Error = error{
    Socks5InvalidVersion,
    Socks5NoAcceptableAuthMethod,
    Socks5AuthRequired,
    Socks5AuthFailed,
    Socks5GeneralFailure,
    Socks5ConnectionNotAllowed,
    Socks5NetworkUnreachable,
    Socks5HostUnreachable,
    Socks5ConnectionRefused,
    Socks5TtlExpired,
    Socks5CommandNotSupported,
    Socks5AddressTypeNotSupported,
    Socks5MalformedResponse,
};

pub const Auth = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// establishSocks5Tunnel executes the SOCKS5 handshake over an open TCP stream,
/// optionally authenticates via RFC 1929, and issues a CONNECT command to the target host and port.
pub fn establishSocks5Tunnel(
    io: std.Io,
    stream: std.Io.net.Stream,
    target_host: []const u8,
    target_port: u16,
    auth: ?Auth,
) !void {
    var write_buf: [512]u8 = undefined;
    var stream_w = stream.writer(io, &write_buf);
    const w = &stream_w.interface;

    var read_buf: [512]u8 = undefined;
    var stream_r = stream.reader(io, &read_buf);
    const r = &stream_r.interface;

    try establishWithReaderWriter(r, w, target_host, target_port, auth);
}

pub fn establishWithReaderWriter(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    target_host: []const u8,
    target_port: u16,
    auth: ?Auth,
) !void {
    const has_auth = auth != null and auth.?.username != null;

    // 1. Initial Greeting: Version 5 + Authentication Methods
    if (has_auth) {
        // Support 0x00 (No Auth) and 0x02 (Username/Password)
        const greeting = [_]u8{ 0x05, 0x02, 0x00, 0x02 };
        try w.writeAll(&greeting);
    } else {
        // Support 0x00 (No Auth) only
        const greeting = [_]u8{ 0x05, 0x01, 0x00 };
        try w.writeAll(&greeting);
    }
    try w.flush();

    // 2. Read Server Choice (2 bytes)
    var method_resp: [2]u8 = undefined;
    try readExact(r, &method_resp);

    if (method_resp[0] != 0x05) return error.Socks5InvalidVersion;
    const selected_method = method_resp[1];

    if (selected_method == 0xff) {
        return error.Socks5NoAcceptableAuthMethod;
    } else if (selected_method == 0x02) {
        // RFC 1929 Username/Password Subnegotiation
        if (!has_auth) return error.Socks5AuthRequired;
        const u = auth.?.username.?;
        const p = auth.?.password orelse "";

        if (u.len > 255 or p.len > 255) return error.Socks5AuthFailed;

        // Subnegotiation version 1
        try w.writeByte(0x01);
        try w.writeByte(@intCast(u.len));
        try w.writeAll(u);
        try w.writeByte(@intCast(p.len));
        try w.writeAll(p);
        try w.flush();

        var auth_resp: [2]u8 = undefined;
        try readExact(r, &auth_resp);
        if (auth_resp[0] != 0x01 or auth_resp[1] != 0x00) {
            return error.Socks5AuthFailed;
        }
    } else if (selected_method != 0x00) {
        return error.Socks5NoAcceptableAuthMethod;
    }

    // 3. Connect Command
    // CMD = 0x01 (CONNECT), RSV = 0x00
    try w.writeByte(0x05);
    try w.writeByte(0x01);
    try w.writeByte(0x00);

    // ATYP and Address
    if (std.Io.net.IpAddress.parse(target_host, target_port)) |ip| {
        switch (ip) {
            .ip4 => |v4| {
                try w.writeByte(0x01); // ATYP = IPv4
                try w.writeAll(&v4.bytes);
            },
            .ip6 => |v6| {
                try w.writeByte(0x04); // ATYP = IPv6
                try w.writeAll(&v6.bytes);
            },
        }
    } else |_| {
        // ATYP = Domain Name (proxy resolves DNS remotely)
        if (target_host.len > 255) return error.Socks5AddressTypeNotSupported;
        try w.writeByte(0x03);
        try w.writeByte(@intCast(target_host.len));
        try w.writeAll(target_host);
    }

    // Port (2 bytes big-endian)
    var port_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_buf, target_port, .big);
    try w.writeAll(&port_buf);
    try w.flush();

    // 4. Read Connection Response
    var header_resp: [4]u8 = undefined;
    try readExact(r, &header_resp);

    if (header_resp[0] != 0x05) return error.Socks5InvalidVersion;
    const rep = header_resp[1];
    switch (rep) {
        0x00 => {}, // Success
        0x01 => return error.Socks5GeneralFailure,
        0x02 => return error.Socks5ConnectionNotAllowed,
        0x03 => return error.Socks5NetworkUnreachable,
        0x04 => return error.Socks5HostUnreachable,
        0x05 => return error.Socks5ConnectionRefused,
        0x06 => return error.Socks5TtlExpired,
        0x07 => return error.Socks5CommandNotSupported,
        0x08 => return error.Socks5AddressTypeNotSupported,
        else => return error.Socks5GeneralFailure,
    }

    // Drain bound address and port returned by SOCKS5 server
    const bnd_atyp = header_resp[3];
    switch (bnd_atyp) {
        0x01 => {
            // IPv4: 4 bytes addr + 2 bytes port
            var bnd: [6]u8 = undefined;
            try readExact(r, &bnd);
        },
        0x04 => {
            // IPv6: 16 bytes addr + 2 bytes port
            var bnd: [18]u8 = undefined;
            try readExact(r, &bnd);
        },
        0x03 => {
            // Domain: 1 byte len + domain + 2 bytes port
            var len_buf: [1]u8 = undefined;
            try readExact(r, &len_buf);
            var domain_discard: [256]u8 = undefined;
            const domain_len = len_buf[0];
            try readExact(r, domain_discard[0..domain_len]);
            var port_discard: [2]u8 = undefined;
            try readExact(r, &port_discard);
        },
        else => return error.Socks5MalformedResponse,
    }
}

fn readExact(r: anytype, out: []u8) !void {
    var total: usize = 0;
    while (total < out.len) {
        if (r.buffered().len == 0) {
            try r.fillMore();
        }
        const avail = r.buffered();
        if (avail.len == 0) return error.EndOfStream;
        const n = @min(avail.len, out.len - total);
        @memcpy(out[total .. total + n], avail[0..n]);
        r.toss(n);
        total += n;
    }
}

test "socks5: username/password auth verification" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const socks_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var socks_server = try socks_addr.listen(io, .{ .reuse_address = true });
    defer socks_server.deinit(io);
    const socks_port = socks_server.socket.address.ip4.port;

    const AuthWorker = struct {
        fn run(s: *std.Io.net.Server, s_io: std.Io) void {
            var client_sock = s.accept(s_io) catch return;
            defer client_sock.close(s_io);

            var r_buf: [512]u8 = undefined;
            var cr = client_sock.reader(s_io, &r_buf);
            var w_buf: [512]u8 = undefined;
            var cw = client_sock.writer(s_io, &w_buf);

            // Read Greeting: expect method 0x02
            while (cr.interface.buffered().len < 4) {
                cr.interface.fillMore() catch return;
            }
            cr.interface.toss(cr.interface.buffered().len);

            // Select 0x02 (Username/Password)
            cw.interface.writeAll(&[_]u8{ 0x05, 0x02 }) catch return;
            cw.interface.flush() catch return;

            // Read Subnegotiation: [0x01, ulen, u..., plen, p...]
            while (cr.interface.buffered().len < 2) {
                cr.interface.fillMore() catch return;
            }
            const buf = cr.interface.buffered();
            if (buf[0] != 0x01) return;
            const ulen = buf[1];
            while (cr.interface.buffered().len < 2 + ulen + 1) {
                cr.interface.fillMore() catch return;
            }
            const u = cr.interface.buffered()[2 .. 2 + ulen];
            const plen = cr.interface.buffered()[2 + ulen];
            while (cr.interface.buffered().len < 2 + ulen + 1 + plen) {
                cr.interface.fillMore() catch return;
            }
            const p = cr.interface.buffered()[2 + ulen + 1 .. 2 + ulen + 1 + plen];

            if (std.mem.eql(u8, u, "admin") and std.mem.eql(u8, p, "secret123")) {
                // Success: 0x01, 0x00
                cw.interface.writeAll(&[_]u8{ 0x01, 0x00 }) catch return;
            } else {
                // Failure: 0x01, 0x01
                cw.interface.writeAll(&[_]u8{ 0x01, 0x01 }) catch return;
            }
            cw.interface.flush() catch return;
            cr.interface.toss(cr.interface.buffered().len);

            // Read Connect Request
            while (cr.interface.buffered().len < 7) {
                cr.interface.fillMore() catch return;
            }
            cr.interface.toss(cr.interface.buffered().len);

            // Reply Success: 0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0
            cw.interface.writeAll(&[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }) catch return;
            cw.interface.flush() catch return;
        }
    };

    const auth_thread = try std.Thread.spawn(.{}, AuthWorker.run, .{ &socks_server, io });
    defer auth_thread.join();

    const target_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", socks_port);
    var stream = try target_addr.connect(io, .{ .mode = .stream, .timeout = .none });
    defer stream.close(io);

    try establishSocks5Tunnel(io, stream, "example.com", 80, .{
        .username = "admin",
        .password = "secret123",
    });
}
