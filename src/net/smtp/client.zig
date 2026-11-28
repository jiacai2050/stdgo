//! RFC 5321 Simple Mail Transfer Protocol (SMTP) client.
const std = @import("std");
const conn_mod = @import("../conn.zig");
const textproto = @import("../textproto.zig");
const auth_mod = @import("auth.zig");
const base64 = @import("../../encoding/base64.zig");
const Conn = conn_mod.Conn;
const Auth = auth_mod.Auth;
const ServerInfo = auth_mod.ServerInfo;
const Allocator = std.mem.Allocator;

pub const SmtpError = error{
    SmtpCommandFailed,
    SmtpAuthNotSupported,
    SmtpAuthFailed,
    SmtpBadResponse,
    SmtpNotConnected,
    InvalidSmtpArgument,
};

fn containsCrLf(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") != null;
}

fn freeResponseAlloc(allocator: Allocator, resp: Response) void {
    for (resp.lines) |l| allocator.free(l);
    allocator.free(resp.lines);
}

pub const Response = struct {
    code: u16,
    lines: [][]const u8,
};

pub const Client = struct {
    allocator: Allocator,
    conn: Conn,
    host: []const u8,
    ext: std.StringHashMapUnmanaged([]const u8) = .empty,
    auth_mechanisms: std.ArrayListUnmanaged([]const u8) = .empty,
    read_buf: [4096]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    /// Initializes an SMTP client over an existing connection and reads the
    /// server's initial `220` greeting. On error, `conn` is not closed by `init`;
    /// the caller retains ownership of `conn`.
    pub fn init(allocator: Allocator, conn: Conn, host: []const u8) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .host = host,
        };

        // Read the initial 220 greeting from server
        const resp = try self.readResponse();
        defer freeResponseAlloc(allocator, resp);
        if (resp.code != 220) {
            return error.SmtpCommandFailed;
        }

        return self;
    }

    pub fn deinit(self: *Client) void {
        var it = self.ext.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.ext.deinit(self.allocator);

        for (self.auth_mechanisms.items) |m| {
            self.allocator.free(m);
        }
        self.auth_mechanisms.deinit(self.allocator);

        self.conn.close();
        self.allocator.destroy(self);
    }

    pub fn close(self: *Client) void {
        self.deinit();
    }

    /// Read a line ending with \r\n from connection.
    fn readLine(self: *Client) ![]const u8 {
        var line_list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer line_list.deinit(self.allocator);

        const line_bytes_max: usize = 8192;
        while (line_list.items.len < line_bytes_max) {
            if (self.read_pos >= self.read_len) {
                const n = try self.conn.read(&self.read_buf);
                if (n == 0) return error.EndOfStream;
                self.read_pos = 0;
                self.read_len = n;
            }

            const b = self.read_buf[self.read_pos];
            self.read_pos += 1;

            if (b == '\n') {
                if (line_list.items.len > 0 and line_list.items[line_list.items.len - 1] == '\r') {
                    _ = line_list.pop();
                }
                return line_list.toOwnedSlice(self.allocator);
            }
            try line_list.append(self.allocator, b);
        } else {
            return error.SmtpLineTooLong;
        }
    }

    /// Reads a multi-line SMTP response (e.g., "250-first\r\n250 last\r\n").
    pub fn readResponse(self: *Client) !Response {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (lines.items) |l| self.allocator.free(l);
            lines.deinit(self.allocator);
        }

        var code: u16 = 0;
        const response_lines_max: usize = 128;
        var line_count: usize = 0;

        while (line_count < response_lines_max) : (line_count += 1) {
            const raw_line = try self.readLine();
            if (raw_line.len < 3) {
                self.allocator.free(raw_line);
                return error.SmtpBadResponse;
            }

            const line_code = std.fmt.parseInt(u16, raw_line[0..3], 10) catch {
                self.allocator.free(raw_line);
                return error.SmtpBadResponse;
            };

            if (code == 0) code = line_code;

            const is_continuation = (raw_line.len > 3 and raw_line[3] == '-');
            const msg_part = if (raw_line.len > 4) raw_line[4..] else "";

            try lines.append(self.allocator, try self.allocator.dupe(u8, msg_part));
            self.allocator.free(raw_line);

            if (!is_continuation) break;
        } else {
            return error.SmtpResponseTooManyLines;
        }

        return .{
            .code = code,
            .lines = try lines.toOwnedSlice(self.allocator),
        };
    }

    pub fn freeResponse(self: *Client, resp: Response) void {
        for (resp.lines) |l| self.allocator.free(l);
        self.allocator.free(resp.lines);
    }

    /// Sends a formatted command string and returns the response.
    pub fn cmd(self: *Client, comptime fmt: []const u8, args: anytype) !Response {
        var cmd_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&cmd_buf, fmt ++ "\r\n", args) catch {
            return error.SmtpCommandFailed;
        };
        const sent = try self.conn.write(msg);
        std.debug.assert(sent == msg.len);
        return self.readResponse();
    }

    /// Sends EHLO and parses supported extensions.
    /// Rejects empty names or values containing CR/LF to prevent SMTP command injection.
    pub fn ehlo(self: *Client, local_name: []const u8) !void {
        if (local_name.len == 0 or containsCrLf(local_name)) return error.InvalidSmtpArgument;
        const resp = try self.cmd("EHLO {s}", .{local_name});
        defer self.freeResponse(resp);

        if (resp.code != 250) {
            return error.SmtpCommandFailed;
        }

        // Parse extensions
        for (resp.lines) |line| {
            var parts = std.mem.splitScalar(u8, line, ' ');
            const ext_name = parts.next() orelse continue;

            const upper_ext = try self.allocator.alloc(u8, ext_name.len);
            var owns_key = true;
            errdefer if (owns_key) self.allocator.free(upper_ext);
            for (ext_name, 0..) |c, i| upper_ext[i] = std.ascii.toUpper(c);

            const rest = std.mem.trim(u8, line[ext_name.len..], " \t");
            const val_copy = try self.allocator.dupe(u8, rest);
            var owns_val = true;
            errdefer if (owns_val) self.allocator.free(val_copy);

            if (try self.ext.fetchPut(self.allocator, upper_ext, val_copy)) |prev| {
                self.allocator.free(prev.key);
                self.allocator.free(prev.value);
            }
            owns_key = false;
            owns_val = false;

            if (std.ascii.eqlIgnoreCase(ext_name, "AUTH")) {
                var auth_it = std.mem.splitScalar(u8, rest, ' ');
                while (auth_it.next()) |mech| {
                    if (mech.len > 0) {
                        const m = try self.allocator.dupe(u8, mech);
                        errdefer self.allocator.free(m);
                        try self.auth_mechanisms.append(self.allocator, m);
                    }
                }
            }
        }
    }

    /// Sends HELO (basic SMTP).
    /// Rejects empty names or values containing CR/LF to prevent SMTP command injection.
    pub fn hello(self: *Client, local_name: []const u8) !void {
        if (local_name.len == 0 or containsCrLf(local_name)) return error.InvalidSmtpArgument;
        const resp = try self.cmd("HELO {s}", .{local_name});
        defer self.freeResponse(resp);
        if (resp.code != 250) return error.SmtpCommandFailed;
    }

    /// Authenticates using the given Auth mechanism.
    pub fn auth(self: *Client, a: Auth) !void {
        const s_info = ServerInfo{
            .name = self.host,
            .tls = false,
            .auth = self.auth_mechanisms.items,
        };

        const start_res = try a.start(s_info);

        if (std.mem.eql(u8, start_res.proto, "PLAIN")) {
            if (start_res.to_server) |raw_resp| {
                defer self.allocator.free(raw_resp);
                const b64_len = base64.std_encoding.encodedLen(raw_resp.len);
                const b64_buf = try self.allocator.alloc(u8, b64_len);
                defer self.allocator.free(b64_buf);
                _ = base64.std_encoding.encode(b64_buf, raw_resp);

                const resp = try self.cmd("AUTH PLAIN {s}", .{b64_buf});
                defer self.freeResponse(resp);
                if (resp.code != 235) return error.SmtpAuthFailed;
            } else {
                const resp = try self.cmd("AUTH PLAIN", .{});
                defer self.freeResponse(resp);
                if (resp.code != 235) return error.SmtpAuthFailed;
            }
        } else if (std.mem.eql(u8, start_res.proto, "CRAM-MD5")) {
            const chal_resp = try self.cmd("AUTH CRAM-MD5", .{});
            defer self.freeResponse(chal_resp);
            if (chal_resp.code != 334 or chal_resp.lines.len == 0) return error.SmtpAuthFailed;

            // Decode base64 challenge
            const raw_chal = chal_resp.lines[0];
            const max_dec_len = base64.std_encoding.decodedLen(raw_chal.len);
            const dec_buf = try self.allocator.alloc(u8, max_dec_len);
            defer self.allocator.free(dec_buf);
            const dec_len = try base64.std_encoding.decode(dec_buf, raw_chal);

            // Compute response
            const auth_reply = (try a.next(dec_buf[0..dec_len], true)) orelse {
                return error.SmtpAuthFailed;
            };
            defer self.allocator.free(auth_reply);

            // Base64 encode reply
            const b64_len = base64.std_encoding.encodedLen(auth_reply.len);
            const b64_buf = try self.allocator.alloc(u8, b64_len);
            defer self.allocator.free(b64_buf);
            _ = base64.std_encoding.encode(b64_buf, auth_reply);

            const resp = try self.cmd("{s}", .{b64_buf});
            defer self.freeResponse(resp);
            if (resp.code != 235) return error.SmtpAuthFailed;
        } else {
            return error.SmtpAuthNotSupported;
        }
    }

    /// Sends `MAIL FROM:<from>`.
    /// Rejects empty addresses or values containing CR/LF to prevent SMTP command injection.
    pub fn mail(self: *Client, from: []const u8) !void {
        if (from.len == 0 or containsCrLf(from)) return error.InvalidSmtpArgument;
        const resp = try self.cmd("MAIL FROM:<{s}>", .{from});
        defer self.freeResponse(resp);
        if (resp.code != 250) return error.SmtpCommandFailed;
    }

    /// Sends `RCPT TO:<to>`.
    /// Rejects empty addresses or values containing CR/LF to prevent SMTP command injection.
    pub fn rcpt(self: *Client, to: []const u8) !void {
        if (to.len == 0 or containsCrLf(to)) return error.InvalidSmtpArgument;
        const resp = try self.cmd("RCPT TO:<{s}>", .{to});
        defer self.freeResponse(resp);
        if (resp.code != 250 and resp.code != 251) return error.SmtpCommandFailed;
    }

    /// Sends DATA and transmits msg with RFC 5321 dot-stuffing.
    pub fn sendData(self: *Client, msg: []const u8) !void {
        const resp = try self.cmd("DATA", .{});
        defer self.freeResponse(resp);
        if (resp.code != 354) return error.SmtpCommandFailed;

        // Build dot-stuffed payload buffer
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        var at_start = true;
        for (msg) |c| {
            if (at_start and c == '.') {
                try out.append(self.allocator, '.');
            }
            try out.append(self.allocator, c);
            at_start = (c == '\n');
        }

        if (!at_start) {
            try out.appendSlice(self.allocator, "\r\n");
        }
        try out.appendSlice(self.allocator, ".\r\n");

        const sent = try self.conn.write(out.items);
        std.debug.assert(sent == out.items.len);

        const data_resp = try self.readResponse();
        defer self.freeResponse(data_resp);
        if (data_resp.code != 250) return error.SmtpCommandFailed;
    }

    /// Sends QUIT and closes session.
    pub fn quit(self: *Client) !void {
        const resp = try self.cmd("QUIT", .{});
        defer self.freeResponse(resp);
        if (resp.code != 221) return error.SmtpCommandFailed;
    }

    /// Sends RSET to cancel current mail transaction.
    pub fn reset(self: *Client) !void {
        const resp = try self.cmd("RSET", .{});
        defer self.freeResponse(resp);
        if (resp.code != 250) return error.SmtpCommandFailed;
    }

    /// Checks if a given extension was announced by server.
    pub fn extension(self: *Client, ext_name: []const u8) ?[]const u8 {
        var upper: [32]u8 = undefined;
        if (ext_name.len > upper.len) return null;
        for (ext_name, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        return self.ext.get(upper[0..ext_name.len]);
    }
};
