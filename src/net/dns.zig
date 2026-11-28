//! RFC 1035 Domain Name System (DNS) wire protocol implementation and Resolver.
const std = @import("std");
const ip_mod = @import("ip.zig");
const udp_mod = @import("udp.zig");
const hostport = @import("hostport.zig");
const IP = ip_mod.IP;
const Allocator = std.mem.Allocator;
const time_mod = @import("../time.zig");
const Duration = time_mod.Duration;
const Deadline = @import("../io/deadline.zig").Deadline;

pub const RecordType = enum(u16) {
    A = 1,
    NS = 2,
    CNAME = 5,
    SOA = 6,
    PTR = 12,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    ANY = 255,
    _,
};

pub const MX = struct {
    host: []const u8,
    pref: u16,
};

pub const DnsError = error{
    InvalidDomainName,
    DnsFormatError,
    DnsServerFailure,
    DnsNameError, // NXDOMAIN
    DnsNotImplemented,
    DnsRefused,
    DnsTruncated,
    DnsPacketTooShort,
    InvalidDnsPointer,
    NoRecordsFound,
};

/// Encodes a domain name like "api.example.com" into DNS wire label format:
/// "\x03api\x07example\x03com\x00".
pub fn encodeDomainName(name: []const u8, buf: []u8) !usize {
    if (name.len == 0 or name.len > 253) return error.InvalidDomainName;

    var out_idx: usize = 0;
    var start: usize = 0;

    for (name, 0..) |c, i| {
        if (c == '.') {
            const label_len = i - start;
            if (label_len == 0 or label_len > 63) return error.InvalidDomainName;
            if (out_idx + 1 + label_len >= buf.len) return error.DnsPacketTooShort;

            buf[out_idx] = @intCast(label_len);
            out_idx += 1;
            @memcpy(buf[out_idx .. out_idx + label_len], name[start..i]);
            out_idx += label_len;
            start = i + 1;
        }
    }

    if (start < name.len) {
        const label_len = name.len - start;
        if (label_len == 0 or label_len > 63) return error.InvalidDomainName;
        if (out_idx + 1 + label_len >= buf.len) return error.DnsPacketTooShort;

        buf[out_idx] = @intCast(label_len);
        out_idx += 1;
        @memcpy(buf[out_idx .. out_idx + label_len], name[start..]);
        out_idx += label_len;
    }

    if (out_idx >= buf.len) return error.DnsPacketTooShort;
    buf[out_idx] = 0;
    out_idx += 1;

    return out_idx;
}

/// Decodes a DNS domain name from the wire packet at `offset`,
/// handling RFC 1035 pointer compression.
pub fn decodeDomainName(
    allocator: Allocator,
    packet: []const u8,
    start_offset: usize,
    next_offset_out: ?*usize,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var cur = start_offset;
    var jumped = false;
    var steps: usize = 0;
    var final_next = start_offset;

    while (cur < packet.len) {
        steps += 1;
        if (steps > 128) return error.InvalidDnsPointer; // Loop detection

        const len_byte = packet[cur];
        if (len_byte == 0) {
            if (!jumped) final_next = cur + 1;
            break;
        }

        // Pointer (RFC 1035 §4.1.4): two high bits set (0b11xxxxxx)
        if ((len_byte & 0xC0) == 0xC0) {
            if (cur + 1 >= packet.len) return error.DnsPacketTooShort;
            const ptr_offset: usize = ((@as(usize, len_byte & 0x3F)) << 8) | packet[cur + 1];
            if (ptr_offset >= packet.len) return error.InvalidDnsPointer;

            if (!jumped) {
                final_next = cur + 2;
                jumped = true;
            }
            cur = ptr_offset;
            continue;
        }

        // Reject reserved DNS label lengths (64..191, i.e., high bits 01 or 10).
        if ((len_byte & 0xC0) != 0) return error.DnsFormatError;

        // Regular label
        const label_len: usize = len_byte;
        cur += 1;
        if (cur + label_len > packet.len) return error.DnsPacketTooShort;

        if (result.items.len > 0) {
            try result.append(allocator, '.');
        }
        try result.appendSlice(allocator, packet[cur .. cur + label_len]);
        cur += label_len;

        if (!jumped) {
            final_next = cur;
        }
    }

    if (next_offset_out) |p| p.* = final_next;
    return result.toOwnedSlice(allocator);
}

/// Builds a DNS query packet for `name` and `qtype`.
pub fn buildQuery(id: u16, name: []const u8, qtype: RecordType, buf: []u8) !usize {
    if (name.len == 0) return error.InvalidDomainName;
    if (buf.len < 12) return error.DnsPacketTooShort;

    // Header (12 bytes)
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // Standard query with Recursion Desired (RD)
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT = 1
    std.mem.writeInt(u16, buf[6..8], 0, .big); // ANCOUNT = 0
    std.mem.writeInt(u16, buf[8..10], 0, .big); // NSCOUNT = 0
    std.mem.writeInt(u16, buf[10..12], 0, .big); // ARCOUNT = 0

    // Question Section
    const name_len = try encodeDomainName(name, buf[12..]);
    var pos = 12 + name_len;

    if (pos + 4 > buf.len) return error.DnsPacketTooShort;
    std.mem.writeInt(u16, buf[pos..][0..2], @backingInt(qtype), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], 1, .big); // QCLASS: IN (1)
    pos += 4;

    return pos;
}

pub const Resolver = struct {
    nameserver: []const u8 = "8.8.8.8:53",
    timeout: ?Duration = null,

    /// Look up host IPv4 and IPv6 addresses as string slices.
    pub fn lookupHost(
        self: Resolver,
        allocator: Allocator,
        io: std.Io,
        host: []const u8,
    ) ![][]const u8 {
        if (host.len == 0) return error.InvalidDomainName;
        const ips = try self.lookupIP(allocator, io, host);
        defer allocator.free(ips);

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }

        for (ips) |ip| {
            var buf: [46]u8 = undefined;
            const s = ip.stringBuf(&buf);
            const dup = try allocator.dupe(u8, s);
            errdefer allocator.free(dup);
            try list.append(allocator, dup);
        }

        return list.toOwnedSlice(allocator);
    }

    /// Look up host addresses returning IP structs.
    pub fn lookupIP(self: Resolver, allocator: Allocator, io: std.Io, host: []const u8) ![]IP {
        if (host.len == 0) return error.InvalidDomainName;
        const deadline_value = self.deadline(io);
        var list: std.ArrayListUnmanaged(IP) = .empty;
        errdefer list.deinit(allocator);

        var last_err: ?anyerror = null;

        // First query IPv4 (A)
        const a_query = self.queryRaw(allocator, io, host, .A, deadline_value);
        const a_records = a_query catch |err| switch (err) {
            error.Timeout, error.Canceled => |e| return e,
            error.DnsNameError => null,
            else => |e| blk: {
                last_err = e;
                break :blk null;
            },
        };
        if (a_records) |records| {
            defer {
                for (records) |r| allocator.free(r.data);
                allocator.free(records);
            }
            for (records) |r| {
                if (r.data.len == 4) {
                    try list.append(allocator, .{ .v4 = r.data[0..4].* });
                }
            }
        }

        // Then query IPv6 (AAAA)
        const aaaa_query = self.queryRaw(allocator, io, host, .AAAA, deadline_value);
        const aaaa_records = aaaa_query catch |err| switch (err) {
            error.Timeout, error.Canceled => |e| return e,
            error.DnsNameError => null,
            else => |e| blk: {
                last_err = e;
                break :blk null;
            },
        };
        if (aaaa_records) |records| {
            defer {
                for (records) |r| allocator.free(r.data);
                allocator.free(records);
            }
            for (records) |r| {
                if (r.data.len == 16) {
                    try list.append(allocator, .{ .v6 = r.data[0..16].* });
                }
            }
        }

        if (list.items.len > 0) return list.toOwnedSlice(allocator);
        if (last_err) |err| return err;
        return error.NoRecordsFound;
    }

    /// Look up CNAME record.
    pub fn lookupCNAME(
        self: Resolver,
        allocator: Allocator,
        io: std.Io,
        host: []const u8,
    ) ![]const u8 {
        if (host.len == 0) return error.InvalidDomainName;
        const records = try self.queryRaw(allocator, io, host, .CNAME, self.deadline(io));
        defer {
            for (records) |r| allocator.free(r.data);
            allocator.free(records);
        }

        for (records) |r| {
            if (r.rtype == .CNAME and r.data.len > 0) {
                return try allocator.dupe(u8, r.data);
            }
        }

        return error.NoRecordsFound;
    }

    /// Look up TXT records.
    pub fn lookupTXT(
        self: Resolver,
        allocator: Allocator,
        io: std.Io,
        host: []const u8,
    ) ![][]const u8 {
        if (host.len == 0) return error.InvalidDomainName;
        const records = try self.queryRaw(allocator, io, host, .TXT, self.deadline(io));
        defer {
            for (records) |r| allocator.free(r.data);
            allocator.free(records);
        }

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }

        for (records) |r| {
            if (r.rtype == .TXT) {
                const dup = try allocator.dupe(u8, r.data);
                errdefer allocator.free(dup);
                try list.append(allocator, dup);
            }
        }

        if (list.items.len == 0) return error.NoRecordsFound;
        return list.toOwnedSlice(allocator);
    }

    /// Look up MX records sorted by preference.
    pub fn lookupMX(self: Resolver, allocator: Allocator, io: std.Io, host: []const u8) ![]MX {
        if (host.len == 0) return error.InvalidDomainName;
        const records = try self.queryRaw(allocator, io, host, .MX, self.deadline(io));
        defer {
            for (records) |r| allocator.free(r.data);
            allocator.free(records);
        }

        var list: std.ArrayListUnmanaged(MX) = .empty;
        errdefer {
            for (list.items) |m| allocator.free(m.host);
            list.deinit(allocator);
        }

        for (records) |r| {
            if (r.rtype == .MX and r.data.len >= 2) {
                const pref = std.mem.readInt(u16, r.data[0..][0..2], .big);
                const mx_host = try allocator.dupe(u8, r.data[2..]);
                errdefer allocator.free(mx_host);
                try list.append(allocator, .{ .host = mx_host, .pref = pref });
            }
        }

        if (list.items.len == 0) return error.NoRecordsFound;

        // Sort by preference (ascending)
        std.mem.sort(MX, list.items, {}, struct {
            fn less(_: void, a: MX, b: MX) bool {
                return a.pref < b.pref;
            }
        }.less);

        return list.toOwnedSlice(allocator);
    }

    const RawRecord = struct {
        rtype: RecordType,
        ttl: u32,
        data: []u8,
    };

    fn deadline(self: Resolver, io: std.Io) Deadline {
        const duration = self.timeout orelse return .none;
        const ns = duration.nanoseconds();
        if (ns <= 0) return .none;
        return Deadline.after(io, .{ .nanoseconds = ns });
    }

    fn queryRaw(
        self: Resolver,
        allocator: Allocator,
        io: std.Io,
        host: []const u8,
        qtype: RecordType,
        deadline_value: Deadline,
    ) ![]RawRecord {
        if (host.len == 0) return error.InvalidDomainName;
        const uc = try udp_mod.dialUDP(allocator, io, "udp", null, self.nameserver);
        defer uc.close();

        var query_buf: [512]u8 = undefined;
        var rand_bytes: [2]u8 = undefined;
        io.random(&rand_bytes);
        const query_id: u16 = std.mem.readInt(u16, &rand_bytes, .big);
        const q_len = try buildQuery(query_id, host, qtype, &query_buf);

        const sent = try uc.writeDeadline(query_buf[0..q_len], deadline_value);
        std.debug.assert(sent == q_len);

        var resp_buf: [1500]u8 = undefined;
        const rn = try uc.readDeadline(&resp_buf, deadline_value);
        if (rn < 12) return error.DnsPacketTooShort;

        const packet = resp_buf[0..rn];
        const resp_id = std.mem.readInt(u16, packet[0..2], .big);
        if (resp_id != query_id) return error.DnsTransactionMismatch;

        const flags = std.mem.readInt(u16, packet[2..4], .big);
        if ((flags & 0x8000) == 0) return error.DnsNotResponse;
        const rcode = flags & 0x0F;

        switch (rcode) {
            0 => {},
            1 => return error.DnsFormatError,
            2 => return error.DnsServerFailure,
            3 => return error.DnsNameError, // NXDOMAIN
            4 => return error.DnsNotImplemented,
            5 => return error.DnsRefused,
            else => return error.DnsServerFailure,
        }

        const qdcount = std.mem.readInt(u16, packet[4..6], .big);
        const ancount = std.mem.readInt(u16, packet[6..8], .big);

        // Skip Question Section
        var offset: usize = 12;
        var q_idx: usize = 0;
        while (q_idx < qdcount and offset < packet.len) : (q_idx += 1) {
            const dec_name = try decodeDomainName(allocator, packet, offset, &offset);
            allocator.free(dec_name);
            if (offset + 4 > packet.len) return error.DnsPacketTooShort;
            offset += 4; // QTYPE (2) + QCLASS (2)
        }

        var results: std.ArrayListUnmanaged(RawRecord) = .empty;
        errdefer {
            for (results.items) |r| allocator.free(r.data);
            results.deinit(allocator);
        }

        var a_idx: usize = 0;
        while (a_idx < ancount and offset < packet.len) : (a_idx += 1) {
            const dec_name = try decodeDomainName(allocator, packet, offset, &offset);
            allocator.free(dec_name);

            if (offset + 10 > packet.len) return error.DnsPacketTooShort;
            const rtype_val = std.mem.readInt(u16, packet[offset..][0..2], .big);
            const rtype: RecordType = @fromBackingInt(@intCast(rtype_val));
            const ttl = std.mem.readInt(u32, packet[offset + 4 ..][0..4], .big);
            const rdlength = std.mem.readInt(u16, packet[offset + 8 ..][0..2], .big);
            offset += 10;

            if (offset + rdlength > packet.len) return error.DnsPacketTooShort;
            const rdata = packet[offset .. offset + rdlength];

            switch (rtype) {
                .A, .AAAA => {
                    const data_copy = try allocator.dupe(u8, rdata);
                    errdefer allocator.free(data_copy);
                    try results.append(allocator, .{
                        .rtype = rtype,
                        .ttl = ttl,
                        .data = data_copy,
                    });
                },
                .CNAME => {
                    const cname_host = try decodeDomainName(allocator, packet, offset, null);
                    errdefer allocator.free(cname_host);
                    try results.append(allocator, .{
                        .rtype = rtype,
                        .ttl = ttl,
                        .data = cname_host,
                    });
                },
                .MX => {
                    if (rdata.len >= 2) {
                        const pref = std.mem.readInt(u16, rdata[0..][0..2], .big);
                        const mx_host = try decodeDomainName(allocator, packet, offset + 2, null);
                        defer allocator.free(mx_host);

                        const mx_buf = try allocator.alloc(u8, 2 + mx_host.len);
                        errdefer allocator.free(mx_buf);
                        std.mem.writeInt(u16, mx_buf[0..][0..2], pref, .big);
                        @memcpy(mx_buf[2..], mx_host);
                        try results.append(allocator, .{
                            .rtype = rtype,
                            .ttl = ttl,
                            .data = mx_buf,
                        });
                    }
                },
                .TXT => {
                    // TXT RDATA consists of one or more <len><text> character strings
                    var txt_res: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer txt_res.deinit(allocator);
                    var t_pos: usize = 0;
                    while (t_pos < rdata.len) {
                        const t_len = rdata[t_pos];
                        t_pos += 1;
                        if (t_pos + t_len <= rdata.len) {
                            try txt_res.appendSlice(allocator, rdata[t_pos .. t_pos + t_len]);
                            t_pos += t_len;
                        } else break;
                    }
                    const txt_data = try txt_res.toOwnedSlice(allocator);
                    errdefer allocator.free(txt_data);
                    try results.append(allocator, .{
                        .rtype = rtype,
                        .ttl = ttl,
                        .data = txt_data,
                    });
                },
                else => {},
            }

            offset += rdlength;
        }

        return results.toOwnedSlice(allocator);
    }
};

// Convenience top-level functions using default public DNS
pub fn lookupHost(allocator: Allocator, io: std.Io, host: []const u8) ![][]const u8 {
    const r = Resolver{};
    return r.lookupHost(allocator, io, host);
}

pub fn lookupIP(allocator: Allocator, io: std.Io, host: []const u8) ![]IP {
    const r = Resolver{};
    return r.lookupIP(allocator, io, host);
}

pub fn lookupCNAME(allocator: Allocator, io: std.Io, host: []const u8) ![]const u8 {
    const r = Resolver{};
    return r.lookupCNAME(allocator, io, host);
}

pub fn lookupTXT(allocator: Allocator, io: std.Io, host: []const u8) ![][]const u8 {
    const r = Resolver{};
    return r.lookupTXT(allocator, io, host);
}

pub fn lookupMX(allocator: Allocator, io: std.Io, host: []const u8) ![]MX {
    const r = Resolver{};
    return r.lookupMX(allocator, io, host);
}

test "net.dns: lookupIP propagates network errors instead of swallowing into NoRecordsFound" {
    const testing = std.testing;
    const io = testing.io;

    const r = Resolver{
        .nameserver = "invalid_addr_format",
    };

    const res = r.lookupIP(testing.allocator, io, "example.com");
    // Must propagate the underlying parsing/network error, NEVER swallow into NoRecordsFound!
    try testing.expect(res != error.NoRecordsFound);
}

test "net.dns: resolver timeout bounds an unresponsive nameserver" {
    const testing = std.testing;
    const io = testing.io;
    const server = try udp_mod.listenUDP(testing.allocator, io, "udp", "127.0.0.1:0");
    defer server.close();
    const address = try testing.allocator.print("127.0.0.1:{d}", .{server.port()});
    defer testing.allocator.free(address);
    const resolver: Resolver = .{
        .nameserver = address,
        .timeout = @fromBackingInt(50 * std.time.ns_per_ms),
    };
    const res = resolver.lookupIP(testing.allocator, io, "example.test");
    try testing.expectError(error.Timeout, res);
}

test "net.dns: empty host returns InvalidDomainName and reserved label lengths rejected" {
    const testing = std.testing;
    const io = testing.io;
    const resolver = Resolver{};

    var buf: [64]u8 = undefined;
    try testing.expectError(error.InvalidDomainName, buildQuery(1, "", .A, &buf));
    try testing.expectError(error.InvalidDomainName, resolver.lookupIP(testing.allocator, io, ""));
    try testing.expectError(error.InvalidDomainName, resolver.lookupHost(testing.allocator, io, ""));

    // Reserved label length 0x40 (64) and 0x80 (128) must be rejected.
    const bad_label_64 = [_]u8{ 0x40, 'a', 0x00 };
    try testing.expectError(
        error.DnsFormatError,
        decodeDomainName(testing.allocator, &bad_label_64, 0, null),
    );
    const bad_label_128 = [_]u8{ 0x80, 'a', 0x00 };
    try testing.expectError(
        error.DnsFormatError,
        decodeDomainName(testing.allocator, &bad_label_128, 0, null),
    );
}
