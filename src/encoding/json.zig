//! Port of Go's `encoding/json` package to Zig 0.17.
//!
//! Provides streaming `Decoder`, `Encoder`, `Token`, `Delim`,
//! as well as convenient `marshal`, `marshalIndent`, `unmarshal`, and `valid` functions.
//! Designed for zero-overhead streaming on native `*stdgo.io.Reader` and `*stdgo.io.Writer`.

const std = @import("std");
const io = @import("../io.zig");
const bytes_mod = @import("../bytes.zig");
const Allocator = std.mem.Allocator;

pub const Delim = enum(u8) {
    object_begin = '{',
    object_end = '}',
    array_begin = '[',
    array_end = ']',

    pub fn string(self: Delim) []const u8 {
        return switch (self) {
            .object_begin => "{",
            .object_end => "}",
            .array_begin => "[",
            .array_end => "]",
        };
    }
};

pub const Token = union(enum) {
    delim: Delim,
    bool: bool,
    number: []const u8,
    string: []const u8,
    null,
};

pub const Whitespace = @TypeOf(@as(std.json.Stringify.Options, undefined).whitespace);

/// Decoder reads and decodes JSON values from an input stream.
pub const Decoder = struct {
    allocator: Allocator,
    json_reader: std.json.Reader,

    pub fn init(allocator: Allocator, r: *io.Reader) Decoder {
        return .{
            .allocator = allocator,
            .json_reader = std.json.Reader.init(allocator, r),
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.json_reader.deinit();
    }

    /// Token returns the next JSON token in the input stream.
    /// At the end of the input stream, Token returns null.
    pub fn token(self: *Decoder) !?Token {
        const raw_tok = self.json_reader.nextAlloc(
            self.allocator,
            .alloc_if_needed,
        ) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };

        return switch (raw_tok) {
            .object_begin => Token{ .delim = .object_begin },
            .object_end => Token{ .delim = .object_end },
            .array_begin => Token{ .delim = .array_begin },
            .array_end => Token{ .delim = .array_end },
            .true => Token{ .bool = true },
            .false => Token{ .bool = false },
            .null => Token.null,
            .number => |n| Token{ .number = n },
            .allocated_number => |n| Token{ .number = n },
            .string => |s| Token{ .string = s },
            .allocated_string => |s| Token{ .string = s },
            .end_of_document => null,
            else => return error.UnexpectedToken,
        };
    }

    /// More reports whether there is another element in the current array or object being parsed.
    pub fn more(self: *Decoder) bool {
        const next_type = self.json_reader.peekNextTokenType() catch return false;
        return next_type != .array_end and
            next_type != .object_end and
            next_type != .end_of_document;
    }

    /// Decode reads the next JSON-encoded value from its input and stores it in the
    /// value pointed to by T.
    pub fn decode(self: *Decoder, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromTokenSource(T, self.allocator, &self.json_reader, .{
            .ignore_unknown_fields = true,
        });
    }

    /// DecodeLeaky parses without retaining individual allocations. Best used with
    /// an arena allocator.
    pub fn decodeLeaky(self: *Decoder, comptime T: type) !T {
        return std.json.parseFromTokenSourceLeaky(T, self.allocator, &self.json_reader, .{
            .ignore_unknown_fields = true,
        });
    }
};

/// Encoder writes JSON values to an output stream.
pub const Encoder = struct {
    allocator: Allocator,
    writer: *io.Writer,
    indent_whitespace: ?Whitespace = null,
    prefix: []const u8 = "",

    pub fn init(allocator: Allocator, w: *io.Writer) Encoder {
        return .{
            .allocator = allocator,
            .writer = w,
        };
    }

    /// SetIndent instructs the encoder to format each subsequent encoded value as indented JSON.
    pub fn setIndent(self: *Encoder, prefix: []const u8, indent: []const u8) void {
        self.prefix = prefix;
        if (std.mem.eql(u8, indent, "\t")) {
            self.indent_whitespace = .indent_tab;
        } else if (indent.len == 2) {
            self.indent_whitespace = .indent_2;
        } else if (indent.len == 4) {
            self.indent_whitespace = .indent_4;
        } else if (indent.len > 0) {
            self.indent_whitespace = .indent_1;
        } else {
            self.indent_whitespace = .minified;
        }
    }

    /// Encode writes the JSON encoding of v to the stream, followed by a newline character.
    pub fn encode(self: *Encoder, value: anytype) !void {
        var stringify: std.json.Stringify = .{
            .writer = self.writer,
            .options = .{
                .whitespace = self.indent_whitespace orelse .minified,
            },
        };
        try stringify.write(value);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    /// EncodeToken writes a single JSON token to the stream.
    pub fn encodeToken(self: *Encoder, tok: Token) !void {
        switch (tok) {
            .delim => |d| try self.writer.writeByte(@backingInt(d)),
            .bool => |b| try self.writer.writeAll(if (b) "true" else "false"),
            .number => |n| try self.writer.writeAll(n),
            .string => |s| {
                var stringify: std.json.Stringify = .{
                    .writer = self.writer,
                    .options = .{},
                };
                try stringify.write(s);
            },
            .null => try self.writer.writeAll("null"),
        }
    }
};

/// Marshal returns the JSON encoding of v.
pub fn marshal(allocator: Allocator, value: anytype) ![]u8 {
    var buf = bytes_mod.Buffer.init(allocator);
    errdefer buf.deinit();

    var enc = Encoder.init(allocator, buf.writer());
    var stringify: std.json.Stringify = .{
        .writer = enc.writer,
        .options = .{ .whitespace = .minified },
    };
    try stringify.write(value);
    try enc.writer.flush();

    return try buf.toOwnedSlice();
}

/// MarshalBuf formats the JSON encoding of value directly into buf using a fixed buffer writer.
/// Returns the slice of buf containing the serialized JSON without any heap allocations.
pub fn marshalBuf(buf: []u8, value: anytype) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    var stringify: std.json.Stringify = .{
        .writer = &w,
        .options = .{ .whitespace = .minified },
    };
    try stringify.write(value);
    try w.flush();
    return buf[0..w.buffered().len];
}

/// MarshalIndent is like Marshal but applies Indent to format the output.
pub fn marshalIndent(
    allocator: Allocator,
    value: anytype,
    prefix: []const u8,
    indent: []const u8,
) ![]u8 {
    var buf = bytes_mod.Buffer.init(allocator);
    errdefer buf.deinit();

    var enc = Encoder.init(allocator, buf.writer());
    enc.setIndent(prefix, indent);

    var stringify: std.json.Stringify = .{
        .writer = enc.writer,
        .options = .{
            .whitespace = enc.indent_whitespace orelse .indent_2,
        },
    };
    try stringify.write(value);
    try enc.writer.flush();

    return try buf.toOwnedSlice();
}

/// Unmarshal parses the JSON-encoded data and stores the result in the value pointed to by T.
pub fn unmarshal(allocator: Allocator, comptime T: type, data: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, data, .{
        .ignore_unknown_fields = true,
    });
}

/// UnmarshalLeaky parses the JSON-encoded data using the provided allocator
/// without tracking individual frees.
pub fn unmarshalLeaky(allocator: Allocator, comptime T: type, data: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, data, .{
        .ignore_unknown_fields = true,
    });
}

/// Valid reports whether data is a valid JSON encoding.
pub fn valid(allocator: Allocator, data: []const u8) bool {
    return std.json.validate(allocator, data) catch false;
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "encoding.json: marshal and unmarshal round-trip" {
    const testing = std.testing;

    const User = struct {
        id: u64,
        name: []const u8,
        active: bool,
    };

    const user = User{
        .id = 1001,
        .name = "Alice",
        .active = true,
    };

    const json_bytes = try marshal(testing.allocator, user);
    defer testing.allocator.free(json_bytes);

    try testing.expect(valid(testing.allocator, json_bytes));
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"name\":\"Alice\"") != null);

    const parsed = try unmarshal(testing.allocator, User, json_bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(u64, 1001), parsed.value.id);
    try testing.expectEqualStrings("Alice", parsed.value.name);
    try testing.expect(parsed.value.active);
}

test "encoding.json: marshalIndent" {
    const testing = std.testing;

    const Config = struct {
        host: []const u8,
        port: u16,
    };

    const cfg = Config{ .host = "localhost", .port = 8080 };
    const indented = try marshalIndent(testing.allocator, cfg, "", "  ");
    defer testing.allocator.free(indented);

    try testing.expect(valid(testing.allocator, indented));
    try testing.expect(std.mem.indexOf(u8, indented, "\n") != null);
    try testing.expect(std.mem.indexOf(u8, indented, "  \"port\": 8080") != null);
}

test "encoding.json: streaming Token and more()" {
    const testing = std.testing;

    const input = "[10, \"hello\", true, null]";
    var r = bytes_mod.Reader.init(input);
    var dec = Decoder.init(testing.allocator, r.reader());
    defer dec.deinit();

    // Read array begin '['
    const tok1 = (try dec.token()).?;
    try testing.expectEqual(Delim.array_begin, tok1.delim);

    try testing.expect(dec.more());
    const tok2 = (try dec.token()).?;
    try testing.expectEqualStrings("10", tok2.number);

    try testing.expect(dec.more());
    const tok3 = (try dec.token()).?;
    try testing.expectEqualStrings("hello", tok3.string);

    try testing.expect(dec.more());
    const tok4 = (try dec.token()).?;
    try testing.expectEqual(true, tok4.bool);

    try testing.expect(dec.more());
    const tok5 = (try dec.token()).?;
    try testing.expectEqual(Token.null, tok5);

    try testing.expect(!dec.more());
    const tok6 = (try dec.token()).?;
    try testing.expectEqual(Delim.array_end, tok6.delim);

    const eof = try dec.token();
    try testing.expectEqual(@as(?Token, null), eof);
}

test "encoding.json: streaming Encoder" {
    const testing = std.testing;

    var buf = bytes_mod.Buffer.init(testing.allocator);
    defer buf.deinit();

    var enc = Encoder.init(testing.allocator, buf.writer());
    const data = [_]i32{ 1, 2, 3 };
    try enc.encode(data);

    try testing.expectEqualStrings("[1,2,3]\n", buf.string());
}

test "encoding.json: valid validator" {
    const testing = std.testing;

    try testing.expect(valid(testing.allocator, "{\"a\": 123}"));
    try testing.expect(valid(testing.allocator, "[1, 2, 3]"));
    try testing.expect(valid(testing.allocator, "\"string\""));
    try testing.expect(!valid(testing.allocator, "{unquoted: 123}"));
    try testing.expect(!valid(testing.allocator, "[1, 2, "));
}

test "encoding.json: marshalBuf zero allocation" {
    const testing = std.testing;

    const Item = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };
    const item = Item{
        .id = 42,
        .name = "gadget",
        .active = true,
    };

    var buf: [128]u8 = undefined;
    const res = try marshalBuf(&buf, item);
    try testing.expectEqualStrings("{\"id\":42,\"name\":\"gadget\",\"active\":true}", res);
    try testing.expect(valid(testing.allocator, res));

    var small_buf: [4]u8 = undefined;
    try testing.expectError(error.WriteFailed, marshalBuf(&small_buf, item));
}
