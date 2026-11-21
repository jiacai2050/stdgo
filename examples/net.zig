//! Example demonstrating stdgo net package:
//! 1. IP address parsing, private / loopback checks
//! 2. CIDR subnet mask calculation & IPNet.contains
//! 3. splitHostPort & joinHostPort
//! 4. Go 1.18+ net/netip zero-allocation IP stack
//! 5. net.listen & net.Dialer with TCP stream
//! 6. net.pipe in-memory bidirectional communication
//! 7. net.lookupPort & net.TCPAddr / net.UDPAddr

const std = @import("std");
const stdgo = @import("stdgo");
const net = stdgo.net;
const time = stdgo.time;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: net (IP, CIDR, HostPort, Dialer, Pipe) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. IP Parsing and Classifications
    // -------------------------------------------------------------
    std.debug.print("1. net.parseIp:\n", .{});

    const ip_list = [_][]const u8{
        "127.0.0.1",
        "192.168.1.100",
        "10.0.4.1",
        "8.8.8.8",
        "::1",
        "2001:db8::1",
    };

    for (ip_list) |s| {
        if (net.parseIp(s)) |addr| {
            std.debug.print("   IP: {s: <16} -> loopback: {}, private: {}\n", .{
                s,
                addr.isLoopback(),
                addr.isPrivate(),
            });
        }
    }

    // -------------------------------------------------------------
    // 2. CIDR Subnet and Membership
    // -------------------------------------------------------------
    std.debug.print("\n2. net.parseCidr and IPNet.contains:\n", .{});

    const subnet_cidr = "10.244.0.0/16";
    const cidr_res = try net.parseCidr(subnet_cidr);
    std.debug.print("   Subnet: {s}, Network base: {}\n", .{ subnet_cidr, cidr_res.ipnet.network() });

    const test_ips = [_][]const u8{
        "10.244.15.99",
        "10.244.254.1",
        "10.245.0.1",
        "192.168.1.1",
    };

    for (test_ips) |tip| {
        if (net.parseIp(tip)) |addr| {
            const inside = cidr_res.ipnet.contains(addr);
            std.debug.print("   Contains {s: <14}? {}\n", .{ tip, inside });
        }
    }

    // -------------------------------------------------------------
    // 3. splitHostPort & joinHostPort
    // -------------------------------------------------------------
    std.debug.print("\n3. net.splitHostPort & net.joinHostPort:\n", .{});

    const addresses = [_][]const u8{
        "127.0.0.1:8080",
        "[::1]:9090",
        "api.example.com:443",
    };

    for (addresses) |addr_str| {
        const hp = try net.splitHostPort(addr_str);
        std.debug.print("   split('{s}') -> host: '{s}', port: '{s}'\n", .{ addr_str, hp.host, hp.port });

        const rejoined = try net.joinHostPort(gpa, hp.host, hp.port);
        defer gpa.free(rejoined);
        std.debug.print("   rejoined: '{s}'\n", .{rejoined});
    }

    // -------------------------------------------------------------
    // 4. Go 1.18+ net/netip Zero-allocation Stack
    // -------------------------------------------------------------
    std.debug.print("\n4. net.netip (Go 1.18+ Zero-Allocation IP & Prefix):\n", .{});
    const nip = try net.netip.parseAddr("192.168.1.1");
    std.debug.print("   netip.Addr: is4={}, isPrivate={}, isLoopback={}\n", .{ nip.is4(), nip.isPrivate(), nip.isLoopback() });

    const np = try net.netip.parsePrefix("192.168.1.0/24");
    std.debug.print("   netip.Prefix: '192.168.1.0/24' contains 192.168.1.1? {}\n", .{np.contains(nip)});

    const nap = try net.netip.parseAddrPort("127.0.0.1:9090");
    std.debug.print("   netip.AddrPort: port={d}, isLoopback={}\n", .{ nap.port, nap.addr.isLoopback() });

    // -------------------------------------------------------------
    // 5. net.listen & net.Dialer
    // -------------------------------------------------------------
    std.debug.print("\n5. net.listen & net.Dialer:\n", .{});

    var listener = try net.listen(gpa, io, "tcp", "127.0.0.1:0");
    defer listener.close();
    const port = listener.port().?;

    const ServerWorker = struct {
        fn run(l: net.Listener) void {
            const server_conn = l.accept() catch return;
            defer server_conn.close();

            var r_buf: [64]u8 = undefined;
            const n = server_conn.read(&r_buf) catch return;
            _ = server_conn.write(r_buf[0..n]) catch return;
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerWorker.run, .{listener});
    defer server_thread.join();

    var dial_buf: [32]u8 = undefined;
    const dial_str = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});

    const dialer = net.Dialer{
        .timeout = @fromBackingInt(@intCast(5 * @backingInt(time.Duration.second))),
    };
    const client_conn = try dialer.dial(gpa, io, "tcp", dial_str, .none);
    defer client_conn.close();

    _ = try client_conn.write("PING_STDGO_DIALER");
    var reply_buf: [32]u8 = undefined;
    const n = try client_conn.read(&reply_buf);
    std.debug.print("   Dialer connected to {s}, received echo: '{s}'\n", .{ dial_str, reply_buf[0..n] });

    // -------------------------------------------------------------
    // 6. net.pipe In-Memory Full-Duplex Connection (net.Pipe())
    // -------------------------------------------------------------
    std.debug.print("\n6. net.pipe (In-Memory Duplex Pipe):\n", .{});
    const pair = try net.pipe(gpa, io);
    const c1 = pair.conn1;
    const c2 = pair.conn2;

    const PipeEchoWorker = struct {
        fn run(c: net.Conn) void {
            defer c.close();
            var b: [32]u8 = undefined;
            const bytes_read = c.read(&b) catch return;
            _ = c.write(b[0..bytes_read]) catch return;
        }
    };

    const pipe_thread = try std.Thread.spawn(.{}, PipeEchoWorker.run, .{c2});
    defer pipe_thread.join();
    defer c1.close();

    _ = try c1.write("HELLO_PIPE");
    var pipe_reply: [32]u8 = undefined;
    const pipe_n = try c1.read(&pipe_reply);
    std.debug.print("   Pipe exchange: sent 'HELLO_PIPE', received: '{s}'\n", .{pipe_reply[0..pipe_n]});

    // -------------------------------------------------------------
    // 7. net.lookupPort & Addr Types
    // -------------------------------------------------------------
    std.debug.print("\n7. net.lookupPort & Addr Types:\n", .{});
    std.debug.print("   lookupPort('tcp', 'http'):   {d}\n", .{try net.lookupPort("tcp", "http")});
    std.debug.print("   lookupPort('tcp', 'https'):  {d}\n", .{try net.lookupPort("tcp", "https")});
    std.debug.print("   lookupPort('tcp', 'socks5'): {d}\n", .{try net.lookupPort("tcp", "socks5")});

    const tcp_addr = try net.TCPAddr.parse("192.168.1.1:8080");
    const formatted_addr = try tcp_addr.string(gpa);
    defer gpa.free(formatted_addr);
    std.debug.print("   TCPAddr: network='{s}', addr='{s}', loopback={}\n", .{ tcp_addr.addr().network(), formatted_addr, tcp_addr.ip.isLoopback() });

    std.debug.print("\nnet example finished successfully.\n", .{});
}
