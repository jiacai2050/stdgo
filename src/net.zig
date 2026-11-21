pub const url = @import("net/url.zig");
pub const http = @import("net/http.zig");
pub const ip = @import("net/ip.zig");
pub const hostport = @import("net/hostport.zig");
pub const textproto = @import("net/textproto.zig");
pub const mail = @import("net/mail.zig");
pub const conn = @import("net/conn.zig");
pub const netip = @import("net/netip.zig");
pub const addr = @import("net/addr.zig");
pub const udp = @import("net/udp.zig");
pub const dns = @import("net/dns.zig");
pub const smtp = @import("net/smtp.zig");

// Direct aliases matching Go net package
pub const IP = ip.IP;
pub const IPMask = ip.IPMask;
pub const IPNet = ip.IPNet;
pub const parseIp = ip.parseIp;
pub const parseCidr = ip.parseCidr;
pub const cidrMask = ip.cidrMask;
pub const ipv4Mask = ip.ipv4Mask;

pub const splitHostPort = hostport.splitHostPort;
pub const joinHostPort = hostport.joinHostPort;
pub const HostPort = hostport.HostPort;

pub const Conn = conn.Conn;
pub const StreamConn = conn.StreamConn;
pub const Listener = conn.Listener;
pub const TCPListener = conn.TCPListener;
pub const Dialer = conn.Dialer;
pub const dial = conn.dial;
pub const listen = conn.listen;
pub const pipe = conn.pipe;
pub const PipePair = conn.PipePair;

pub const PacketConn = udp.PacketConn;
pub const UDPConn = udp.UDPConn;
pub const listenUDP = udp.listenUDP;
pub const dialUDP = udp.dialUDP;

pub const Resolver = dns.Resolver;
pub const lookupHost = dns.lookupHost;
pub const lookupIP = dns.lookupIP;
pub const lookupCNAME = dns.lookupCNAME;
pub const lookupTXT = dns.lookupTXT;
pub const lookupMX = dns.lookupMX;
pub const MX = dns.MX;

pub const Addr = addr.Addr;
pub const TCPAddr = addr.TCPAddr;
pub const UDPAddr = addr.UDPAddr;
pub const lookupPort = addr.lookupPort;

test {
    @import("std").testing.refAllDecls(@This());
    _ = url;
    _ = http;
    _ = ip;
    _ = hostport;
    _ = textproto;
    _ = mail;
    _ = conn;
    _ = netip;
    _ = addr;
    _ = udp;
    _ = dns;
    _ = smtp;
}

test "net.listen and net.Dialer loopback integration" {
    const testing = @import("std").testing;
    const std = @import("std");
    const time = @import("time.zig");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener_inst = try listen(testing.allocator, io, "tcp", "127.0.0.1:0");
    defer listener_inst.close();

    const port_num = listener_inst.port().?;
    try testing.expect(port_num > 0);

    const ServerWorker = struct {
        fn run(l: Listener) void {
            const server_conn = l.accept() catch return;
            defer server_conn.close();

            var req_buf: [16]u8 = undefined;
            const n = server_conn.read(&req_buf) catch return;
            _ = server_conn.write(req_buf[0..n]) catch return;
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerWorker.run, .{listener_inst});
    defer server_thread.join();

    var addr_buf: [32]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port_num});

    const d = Dialer{
        .timeout = @fromBackingInt(@intCast(5 * @backingInt(time.Duration.second))),
    };
    const client_conn = try d.dial(testing.allocator, io, "tcp", addr_str, .none);
    defer client_conn.close();

    _ = try client_conn.write("PING_STDGO");

    var reply: [10]u8 = undefined;
    const rn = try client_conn.read(&reply);
    try testing.expectEqual(@as(usize, 10), rn);
    try testing.expectEqualStrings("PING_STDGO", reply[0..rn]);
}

test "net.Dialer rejects expired configured and call deadlines before connecting" {
    const std = @import("std");
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Deadline = @import("io/deadline.zig").Deadline;
    const deadline = Deadline.after(io, .zero);
    const configured: Dialer = .{ .deadline = deadline };
    try testing.expectError(
        error.Timeout,
        configured.dial(testing.allocator, io, "tcp", "127.0.0.1:1", .none),
    );
    try testing.expectError(
        error.Timeout,
        (Dialer{}).dial(testing.allocator, io, "tcp", "127.0.0.1:1", deadline),
    );
}

test "net.pipe in-memory bidirectional communication" {
    const testing = @import("std").testing;
    const std = @import("std");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const pair = try pipe(testing.allocator, threaded.io());
    const c1 = pair.conn1;
    const c2 = pair.conn2;

    const ClientWorker = struct {
        fn run(c: Conn) void {
            defer c.close();
            _ = c.write("HELLO_FROM_C2") catch return;

            var buf: [16]u8 = undefined;
            const n = c.read(&buf) catch return;
            if (n > 0) {
                _ = c.write(buf[0..n]) catch return;
            }
        }
    };

    const th = try std.Thread.spawn(.{}, ClientWorker.run, .{c2});
    defer th.join();
    defer c1.close();

    var r1: [16]u8 = undefined;
    const n1 = try c1.read(&r1);
    try testing.expectEqual(@as(usize, 13), n1);
    try testing.expectEqualStrings("HELLO_FROM_C2", r1[0..n1]);

    _ = try c1.write("ECHO_TEST");

    var r2: [16]u8 = undefined;
    const n2 = try c1.read(&r2);
    try testing.expectEqual(@as(usize, 9), n2);
    try testing.expectEqualStrings("ECHO_TEST", r2[0..n2]);
}

test "net.listenUDP and dialUDP loopback test" {
    const testing = @import("std").testing;
    const std = @import("std");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server_uc = try listenUDP(testing.allocator, io, "udp", "127.0.0.1:0");
    defer server_uc.close();
    const s_port = server_uc.port();

    var addr_buf: [32]u8 = undefined;
    const s_addr_str = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{s_port});

    const client_uc = try dialUDP(testing.allocator, io, "udp", null, s_addr_str);
    defer client_uc.close();

    _ = try client_uc.write("PING_UDP");

    var recv_buf: [64]u8 = undefined;
    const from_res = try server_uc.readFrom(&recv_buf);
    try testing.expectEqualStrings("PING_UDP", recv_buf[0..from_res.n]);

    // 1. Send packet from an unrelated/unconnected UDP socket to client_uc
    const unrelated_uc = try listenUDP(testing.allocator, io, "udp", "127.0.0.1:0");
    defer unrelated_uc.close();

    var client_addr_buf: [32]u8 = undefined;
    const client_addr_str = try std.fmt.bufPrint(&client_addr_buf, "127.0.0.1:{d}", .{client_uc.port()});
    const client_udp_addr = UDPAddr{
        .ip = .{ .v4 = .{ 127, 0, 0, 1 } },
        .port = client_uc.port(),
    };
    _ = client_addr_str;
    _ = try unrelated_uc.writeTo("SPOOFED_PACKET", client_udp_addr);

    // 2. Server sends legitimate reply
    _ = try server_uc.writeTo("PONG_UDP", from_res.addr);

    // 3. Client read() must filter out the packet from unrelated_uc and return only PONG_UDP
    var client_recv: [64]u8 = undefined;
    const cn = try client_uc.read(&client_recv);
    try testing.expectEqualStrings("PONG_UDP", client_recv[0..cn]);
}

test "net.dns wire encoding and mock DNS server" {
    const testing = @import("std").testing;
    const std = @import("std");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Test domain encoding and decoding
    var wire_buf: [128]u8 = undefined;
    const enc_len = try dns.encodeDomainName("api.example.com", &wire_buf);
    try testing.expectEqual(@as(usize, 17), enc_len);

    const decoded = try dns.decodeDomainName(testing.allocator, wire_buf[0..enc_len], 0, null);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("api.example.com", decoded);

    // 2. Mock UDP DNS Server answering A query for "example.com" -> 93.184.216.34
    const dns_server = try listenUDP(testing.allocator, io, "udp", "127.0.0.1:0");
    defer dns_server.close();
    const dns_port = dns_server.port();

    const MockDnsWorker = struct {
        fn run(s: *UDPConn) void {
            var q_count: usize = 0;
            while (q_count < 2) : (q_count += 1) {
                var q_buf: [512]u8 = undefined;
                const res = s.readFrom(&q_buf) catch return;
                const q_pkt = q_buf[0..res.n];
                if (q_pkt.len < 12) return;

                const q_id = std.mem.readInt(u16, q_pkt[0..2], .big);

                // Construct DNS response
                var r_buf: [512]u8 = undefined;
                std.mem.writeInt(u16, r_buf[0..2], q_id, .big);
                std.mem.writeInt(u16, r_buf[2..4], 0x8180, .big); // QR=1, RA=1, RCODE=0
                std.mem.writeInt(u16, r_buf[4..6], 1, .big); // QDCOUNT = 1
                std.mem.writeInt(u16, r_buf[6..8], 1, .big); // ANCOUNT = 1
                std.mem.writeInt(u16, r_buf[8..10], 0, .big);
                std.mem.writeInt(u16, r_buf[10..12], 0, .big);

                // Copy Question section
                const q_section = q_pkt[12..];
                @memcpy(r_buf[12 .. 12 + q_section.len], q_section);
                var pos = 12 + q_section.len;

                // Answer section: Pointer to QNAME at offset 12 (0xC00C)
                std.mem.writeInt(u16, r_buf[pos..][0..2], 0xC00C, .big);
                pos += 2;
                std.mem.writeInt(u16, r_buf[pos..][0..2], 1, .big); // TYPE A
                pos += 2;
                std.mem.writeInt(u16, r_buf[pos..][0..2], 1, .big); // CLASS IN
                pos += 2;
                std.mem.writeInt(u32, r_buf[pos..][0..4], 300, .big); // TTL
                pos += 4;
                std.mem.writeInt(u16, r_buf[pos..][0..2], 4, .big); // RDLENGTH 4
                pos += 2;
                @memcpy(r_buf[pos..][0..4], &[_]u8{ 93, 184, 216, 34 });
                pos += 4;

                _ = s.writeTo(r_buf[0..pos], res.addr) catch return;
            }
        }
    };

    const th = try std.Thread.spawn(.{}, MockDnsWorker.run, .{dns_server});
    defer th.join();

    var ns_buf: [32]u8 = undefined;
    const ns_str = try std.fmt.bufPrint(&ns_buf, "127.0.0.1:{d}", .{dns_port});

    const resolver = Resolver{
        .nameserver = ns_str,
    };

    const ips = try resolver.lookupHost(testing.allocator, io, "example.com");
    defer {
        for (ips) |ip_s| testing.allocator.free(ip_s);
        testing.allocator.free(ips);
    }

    try testing.expectEqual(@as(usize, 1), ips.len);
    try testing.expectEqualStrings("93.184.216.34", ips[0]);
}
