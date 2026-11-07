//! HTTP Response representation conforming to Go's net/http Response.
const std = @import("std");
const Header = @import("header.zig").Header;
const Status = @import("status.zig").Status;
const HttpConn = @import("conn.zig").HttpConn;
const ConnPool = @import("pool.zig").ConnPool;

pub const BodyMode = enum {
    fixed,
    chunked,
    close_eof,
};

pub const ResponseBodyReader = struct {
    io: std.Io,
    conn: *HttpConn,
    mode: BodyMode,
    remaining_bytes: u64 = 0,
    chunk_remaining: usize = 0,
    eof_reached: bool = false,
    leftover: []const u8,
    leftover_pos: usize = 0,

    pub fn init(
        io: std.Io,
        conn: *HttpConn,
        mode: BodyMode,
        content_length: u64,
        leftover: []const u8,
    ) ResponseBodyReader {
        return .{
            .io = io,
            .conn = conn,
            .mode = mode,
            .remaining_bytes = content_length,
            .leftover = leftover,
            .leftover_pos = 0,
        };
    }

    pub fn read(self: *ResponseBodyReader, buf: []u8) !usize {
        if (self.eof_reached or buf.len == 0) return 0;

        switch (self.mode) {
            .fixed => {
                if (self.remaining_bytes == 0) {
                    self.eof_reached = true;
                    return 0;
                }
                const to_read = @min(buf.len, self.remaining_bytes);
                const n = try self.readDirect(buf[0..to_read]);
                if (n == 0) {
                    self.eof_reached = true;
                    return 0;
                }
                self.remaining_bytes -= n;
                if (self.remaining_bytes == 0) {
                    self.eof_reached = true;
                }
                return n;
            },
            .close_eof => {
                const n = try self.readDirect(buf);
                if (n == 0) {
                    self.eof_reached = true;
                }
                return n;
            },
            .chunked => {
                while (self.chunk_remaining == 0) {
                    const chunk_size = try self.readChunkHeader();
                    if (chunk_size == 0) {
                        self.eof_reached = true;
                        try self.consumeCrlf();
                        return 0;
                    }
                    self.chunk_remaining = chunk_size;
                }

                const to_read = @min(buf.len, self.chunk_remaining);
                const n = try self.readDirect(buf[0..to_read]);
                if (n == 0) {
                    self.eof_reached = true;
                    return 0;
                }
                self.chunk_remaining -= n;
                if (self.chunk_remaining == 0) {
                    try self.consumeCrlf();
                }
                return n;
            },
        }
    }

    fn readDirect(self: *ResponseBodyReader, buf: []u8) !usize {
        if (self.leftover_pos < self.leftover.len) {
            const avail = self.leftover.len - self.leftover_pos;
            const n = @min(avail, buf.len);
            @memcpy(buf[0..n], self.leftover[self.leftover_pos .. self.leftover_pos + n]);
            self.leftover_pos += n;
            return n;
        }

        return self.conn.read(self.io, buf, null);
    }

    fn readByte(self: *ResponseBodyReader) !u8 {
        var b: [1]u8 = undefined;
        const n = try self.readDirect(&b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }

    fn consumeCrlf(self: *ResponseBodyReader) !void {
        const c1 = try self.readByte();
        const c2 = try self.readByte();
        if (c1 != '\r' or c2 != '\n') return error.MalformedChunk;
    }

    fn readChunkHeader(self: *ResponseBodyReader) !usize {
        var hex_buf: [16]u8 = undefined;
        var hex_len: usize = 0;

        while (true) {
            const b = try self.readByte();
            if (b == '\r') {
                const lf = try self.readByte();
                if (lf != '\n') return error.MalformedChunkHeader;
                break;
            }
            if (b == ';') {
                while (true) {
                    const ext_b = try self.readByte();
                    if (ext_b == '\r') {
                        const lf = try self.readByte();
                        if (lf != '\n') return error.MalformedChunkHeader;
                        break;
                    }
                }
                break;
            }
            if (hex_len < hex_buf.len) {
                hex_buf[hex_len] = b;
                hex_len += 1;
            } else {
                return error.ChunkHeaderTooLarge;
            }
        }

        const trimmed = std.mem.trim(u8, hex_buf[0..hex_len], " \t");
        return std.fmt.parseInt(usize, trimmed, 16) catch error.MalformedChunkSize;
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: Status,
    status_code: u16,
    proto: []const u8,
    header: Header,
    body: ResponseBodyReader,
    conn: *HttpConn,
    pool: ?*ConnPool = null,
    pool_host: ?[]const u8 = null,
    pool_port: u16 = 0,
    can_keep_alive: bool = false,
    closed: bool = false,
    raw_head: []const u8,

    pub fn close(self: *Response) void {
        if (self.closed) return;
        self.closed = true;

        if (self.pool) |pool| {
            if (self.can_keep_alive and self.pool_host != null) {
                // If EOF not yet reached, drain remaining small fixed-size body so connection can be reused
                if (!self.body.eof_reached and self.body.mode == .fixed and self.body.remaining_bytes <= 16 * 1024) {
                    var drain_buf: [1024]u8 = undefined;
                    while (!self.body.eof_reached) {
                        const n = self.body.read(&drain_buf) catch break;
                        if (n == 0) break;
                    }
                }

                if (self.body.eof_reached) {
                    pool.release(self.body.io, self.pool_host.?, self.pool_port, self.conn.is_tls, self.conn);
                    if (self.pool_host) |h| {
                        self.allocator.free(h);
                    }
                    self.header.deinit();
                    self.allocator.free(self.raw_head);
                    return;
                }
            }
        }

        self.conn.close(self.body.io);
        self.allocator.destroy(self.conn);

        if (self.pool_host) |h| {
            self.allocator.free(h);
        }
        self.header.deinit();
        self.allocator.free(self.raw_head);
    }

    pub fn readAllAlloc(self: *Response, max_size: usize) ![]u8 {
        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.body.read(&buf);
            if (n == 0) break;
            if (list.items.len + n > max_size) return error.ResponseTooLarge;
            try list.appendSlice(self.allocator, buf[0..n]);
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn cookies(self: *const Response, allocator: std.mem.Allocator) ![]@import("cookie.zig").Cookie {
        var list = std.ArrayListUnmanaged(@import("cookie.zig").Cookie).empty;
        errdefer list.deinit(allocator);

        for (self.header.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "Set-Cookie")) {
                if (@import("cookie.zig").parseSetCookie(entry.value)) |c| {
                    try list.append(allocator, c);
                }
            }
        }
        return list.toOwnedSlice(allocator);
    }
};
