const std = @import("std");
const Allocator = std.mem.Allocator;
const textproto = @import("textproto.zig");

pub const Address = struct {
    name: []const u8,
    address: []const u8,

    pub fn deinit(self: *Address, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.address);
    }

    /// String formats the address for use in RFC 5322 headers.
    pub fn string(self: Address, allocator: Allocator) Allocator.Error![]u8 {
        if (self.name.len == 0) {
            return try allocator.dupe(u8, self.address);
        }

        var needs_quote = false;
        for (self.name) |c| {
            if (c == '"' or c == '\\' or c == '(' or c == ')' or
                c == '<' or c == '>' or c == '[' or c == ']' or
                c == ':' or c == ';' or c == '@' or c == ',' or c == '.')
            {
                needs_quote = true;
                break;
            }
        }

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        if (needs_quote) {
            try list.append(allocator, '"');
            for (self.name) |c| {
                if (c == '"' or c == '\\') {
                    try list.append(allocator, '\\');
                }
                try list.append(allocator, c);
            }
            try list.append(allocator, '"');
        } else {
            try list.appendSlice(allocator, self.name);
        }

        try list.appendSlice(allocator, " <");
        try list.appendSlice(allocator, self.address);
        try list.append(allocator, '>');

        return list.toOwnedSlice(allocator);
    }
};

pub const ParseError = error{
    InvalidAddress,
    EmptyAddress,
} || Allocator.Error;

/// ParseAddress parses a single RFC 5322 address, e.g. "Barry Gibbs <bg@example.com>"
pub fn parseAddress(allocator: Allocator, s_in: []const u8) ParseError!Address {
    const s = std.mem.trim(u8, s_in, " \t\r\n");
    if (s.len == 0) return ParseError.EmptyAddress;

    // Check for angle bracket form: Name <addr>
    if (std.mem.indexOfScalar(u8, s, '<')) |start_idx| {
        const end_idx = std.mem.lastIndexOfScalar(u8, s, '>') orelse {
            return ParseError.InvalidAddress;
        };
        if (end_idx <= start_idx) return ParseError.InvalidAddress;

        const raw_addr = std.mem.trim(u8, s[start_idx + 1 .. end_idx], " \t\r\n");
        if (raw_addr.len == 0 or !isValidEmail(raw_addr)) return ParseError.InvalidAddress;

        var raw_name = std.mem.trim(u8, s[0..start_idx], " \t\r\n");

        // Strip quotes if quoted string
        var clean_name: []u8 = undefined;
        if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"') {
            raw_name = raw_name[1 .. raw_name.len - 1];
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(allocator);
            var i: usize = 0;
            while (i < raw_name.len) {
                if (raw_name[i] == '\\' and i + 1 < raw_name.len) {
                    try list.append(allocator, raw_name[i + 1]);
                    i += 2;
                } else {
                    try list.append(allocator, raw_name[i]);
                    i += 1;
                }
            }
            clean_name = try list.toOwnedSlice(allocator);
        } else {
            clean_name = try allocator.dupe(u8, raw_name);
        }
        errdefer allocator.free(clean_name);

        const clean_addr = try allocator.dupe(u8, raw_addr);

        return .{
            .name = clean_name,
            .address = clean_addr,
        };
    }

    // Check for RFC 822 comment syntax: addr (Name)
    if (std.mem.indexOfScalar(u8, s, '(')) |start_idx| {
        const end_idx = std.mem.lastIndexOfScalar(u8, s, ')') orelse {
            return ParseError.InvalidAddress;
        };
        if (end_idx <= start_idx) return ParseError.InvalidAddress;

        const raw_addr = std.mem.trim(u8, s[0..start_idx], " \t\r\n");
        if (raw_addr.len == 0 or !isValidEmail(raw_addr)) return ParseError.InvalidAddress;

        const raw_name = std.mem.trim(u8, s[start_idx + 1 .. end_idx], " \t\r\n");

        return .{
            .name = try allocator.dupe(u8, raw_name),
            .address = try allocator.dupe(u8, raw_addr),
        };
    }

    // Bare address: addr
    if (!isValidEmail(s)) return ParseError.InvalidAddress;
    return .{
        .name = try allocator.dupe(u8, ""),
        .address = try allocator.dupe(u8, s),
    };
}

fn isValidEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    // ensure only one @
    if (std.mem.indexOfScalar(u8, s[at + 1 ..], '@') != null) return false;
    return true;
}

/// ParseAddressList parses the given string as a list of comma-separated RFC 5322 addresses.
pub fn parseAddressList(allocator: Allocator, list_in: []const u8) ParseError![]Address {
    var list: std.ArrayList(Address) = .empty;
    defer list.deinit(allocator);
    errdefer {
        for (list.items) |*addr| {
            addr.deinit(allocator);
        }
    }

    var start: usize = 0;
    var in_quotes = false;
    var in_angles = false;
    var i: usize = 0;

    while (i < list_in.len) : (i += 1) {
        const c = list_in[i];
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == '<' and !in_quotes) {
            in_angles = true;
        } else if (c == '>' and !in_quotes) {
            in_angles = false;
        } else if (c == ',' and !in_quotes and !in_angles) {
            const piece = std.mem.trim(u8, list_in[start..i], " \t\r\n");
            if (piece.len > 0) {
                const addr = try parseAddress(allocator, piece);
                try list.append(allocator, addr);
            }
            start = i + 1;
        }
    }

    const last = std.mem.trim(u8, list_in[start..], " \t\r\n");
    if (last.len > 0) {
        const addr = try parseAddress(allocator, last);
        try list.append(allocator, addr);
    }

    return list.toOwnedSlice(allocator);
}

pub const Message = struct {
    header: textproto.MIMEHeader,
    body: *std.Io.Reader,

    pub fn deinit(self: *Message) void {
        self.header.deinit();
    }
};

/// ReadMessage reads a message from r. The headers are parsed into message.header,
/// and the remaining stream is preserved as message.body.
pub fn readMessage(allocator: Allocator, r: *std.Io.Reader) !Message {
    var tp_reader = textproto.Reader.init(allocator, r);
    const hdr = try tp_reader.readMIMEHeader();
    return .{
        .header = hdr,
        .body = r,
    };
}

test "parseAddress variations" {
    const testing = std.testing;

    // 1. Plain address
    var a1 = try parseAddress(testing.allocator, "alice@example.com");
    defer a1.deinit(testing.allocator);
    try testing.expectEqualStrings("", a1.name);
    try testing.expectEqualStrings("alice@example.com", a1.address);

    // 2. Name with angle brackets
    var a2 = try parseAddress(testing.allocator, "Alice Smith <alice@example.com>");
    defer a2.deinit(testing.allocator);
    try testing.expectEqualStrings("Alice Smith", a2.name);
    try testing.expectEqualStrings("alice@example.com", a2.address);

    // 3. Quoted name with comma
    var a3 = try parseAddress(testing.allocator, "\"Smith, Alice\" <alice@example.com>");
    defer a3.deinit(testing.allocator);
    try testing.expectEqualStrings("Smith, Alice", a3.name);
    try testing.expectEqualStrings("alice@example.com", a3.address);

    // 4. RFC 822 comment syntax
    var a4 = try parseAddress(testing.allocator, "alice@example.com (Alice Smith)");
    defer a4.deinit(testing.allocator);
    try testing.expectEqualStrings("Alice Smith", a4.name);
    try testing.expectEqualStrings("alice@example.com", a4.address);

    // 5. String formatting
    const s = try a3.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"Smith, Alice\" <alice@example.com>", s);
}

test "parseAddressList" {
    const testing = std.testing;

    const raw = "\"Smith, Alice\" <alice@example.com>, Bob <bob@example.com>, carol@example.com";
    const addrs = try parseAddressList(testing.allocator, raw);
    defer {
        for (addrs) |*addr| {
            addr.deinit(testing.allocator);
        }
        testing.allocator.free(addrs);
    }

    try testing.expectEqual(@as(usize, 3), addrs.len);
    try testing.expectEqualStrings("Smith, Alice", addrs[0].name);
    try testing.expectEqualStrings("alice@example.com", addrs[0].address);
    try testing.expectEqualStrings("Bob", addrs[1].name);
    try testing.expectEqualStrings("bob@example.com", addrs[1].address);
    try testing.expectEqualStrings("", addrs[2].name);
    try testing.expectEqualStrings("carol@example.com", addrs[2].address);
}

test "readMessage" {
    const testing = std.testing;

    const email_data =
        "From: Alice <alice@example.com>\r\n" ++
        "To: Bob <bob@example.com>\r\n" ++
        "Subject: Weekly Status Report\r\n" ++
        "\r\n" ++
        "Hello Bob,\r\nAll systems operational.\r\n";

    var r = @import("../bytes/reader.zig").Reader.init(email_data);
    var msg = try readMessage(testing.allocator, r.reader());
    defer msg.deinit();

    try testing.expectEqualStrings("Alice <alice@example.com>", msg.header.get("From").?);
    try testing.expectEqualStrings("Weekly Status Report", msg.header.get("Subject").?);

    var body_buf: [128]u8 = undefined;
    const n = try msg.body.readSliceShort(&body_buf);
    try testing.expectEqualStrings("Hello Bob,\r\nAll systems operational.\r\n", body_buf[0..n]);
}
