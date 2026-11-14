const std = @import("std");
const io = @import("../io.zig");
const bytes = @import("../bytes.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = error{
    UnknownFlag,
    MissingValue,
    InvalidSyntax,
    HelpRequested,
};

pub const ValueType = union(enum) {
    bool_val: *bool,
    int_val: *i64,
    str_val: *[]const u8,
    float_val: *f64,
};

pub const Flag = struct {
    name: []const u8,
    usage: []const u8,
    val: ValueType,
    def_val: []const u8,
};

pub const FlagSet = struct {
    allocator: Allocator,
    name: []const u8,
    flags: std.ArrayList(Flag),
    actual_args: std.ArrayList([]const u8),
    parsed: bool = false,

    pub fn init(allocator: Allocator, name: []const u8) FlagSet {
        return .{
            .allocator = allocator,
            .name = name,
            .flags = std.ArrayList(Flag).empty,
            .actual_args = std.ArrayList([]const u8).empty,
            .parsed = false,
        };
    }

    pub fn deinit(self: *FlagSet) void {
        for (self.flags.items) |f| {
            self.allocator.free(f.def_val);
        }
        self.flags.deinit(self.allocator);
        self.actual_args.deinit(self.allocator);
    }

    pub fn boolVar(self: *FlagSet, ptr: *bool, name: []const u8, def_val: bool, usage: []const u8) Allocator.Error!void {
        ptr.* = def_val;
        const def_str = if (def_val) "true" else "false";
        try self.flags.append(self.allocator, .{
            .name = name,
            .usage = usage,
            .val = .{ .bool_val = ptr },
            .def_val = try self.allocator.dupe(u8, def_str),
        });
    }

    pub fn intVar(self: *FlagSet, ptr: *i64, name: []const u8, def_val: i64, usage: []const u8) Allocator.Error!void {
        ptr.* = def_val;
        var buf: [32]u8 = undefined;
        const def_str = std.fmt.bufPrint(&buf, "{d}", .{def_val}) catch "0";
        try self.flags.append(self.allocator, .{
            .name = name,
            .usage = usage,
            .val = .{ .int_val = ptr },
            .def_val = try self.allocator.dupe(u8, def_str),
        });
    }

    pub fn stringVar(self: *FlagSet, ptr: *[]const u8, name: []const u8, def_val: []const u8, usage: []const u8) Allocator.Error!void {
        ptr.* = def_val;
        try self.flags.append(self.allocator, .{
            .name = name,
            .usage = usage,
            .val = .{ .str_val = ptr },
            .def_val = try self.allocator.dupe(u8, def_val),
        });
    }

    pub fn floatVar(self: *FlagSet, ptr: *f64, name: []const u8, def_val: f64, usage: []const u8) Allocator.Error!void {
        ptr.* = def_val;
        var buf: [32]u8 = undefined;
        const def_str = std.fmt.bufPrint(&buf, "{d}", .{def_val}) catch "0.0";
        try self.flags.append(self.allocator, .{
            .name = name,
            .usage = usage,
            .val = .{ .float_val = ptr },
            .def_val = try self.allocator.dupe(u8, def_str),
        });
    }

    pub fn parse(self: *FlagSet, arguments: []const []const u8) anyerror!void {
        self.parsed = true;
        var i: usize = 0;
        while (i < arguments.len) {
            const argument = arguments[i];
            if (argument.len == 0 or argument[0] != '-' or std.mem.eql(u8, argument, "-")) {
                // First non-flag argument, remaining are positional
                while (i < arguments.len) : (i += 1) {
                    try self.actual_args.append(self.allocator, arguments[i]);
                }
                break;
            }

            if (std.mem.eql(u8, argument, "--")) {
                i += 1;
                while (i < arguments.len) : (i += 1) {
                    try self.actual_args.append(self.allocator, arguments[i]);
                }
                break;
            }

            // Strip leading - or --
            var flag_slice = argument[1..];
            if (flag_slice.len > 0 and flag_slice[0] == '-') {
                flag_slice = flag_slice[1..];
            }

            // Check for help flag
            if (std.mem.eql(u8, flag_slice, "h") or std.mem.eql(u8, flag_slice, "help")) {
                return Error.HelpRequested;
            }

            // Check for -flag=value syntax
            var name = flag_slice;
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, flag_slice, '=')) |eq| {
                name = flag_slice[0..eq];
                inline_val = flag_slice[eq + 1 ..];
            }

            const flag_ptr = self.lookup(name) orelse return Error.UnknownFlag;

            switch (flag_ptr.val) {
                .bool_val => |b_ptr| {
                    if (inline_val) |val_str| {
                        b_ptr.* = try parseBool(val_str);
                    } else {
                        b_ptr.* = true;
                    }
                },
                .int_val => |i_ptr| {
                    const val_str = inline_val orelse blk: {
                        i += 1;
                        if (i >= arguments.len) return Error.MissingValue;
                        break :blk arguments[i];
                    };
                    i_ptr.* = std.fmt.parseInt(i64, val_str, 0) catch return Error.InvalidSyntax;
                },
                .str_val => |s_ptr| {
                    const val_str = inline_val orelse blk: {
                        i += 1;
                        if (i >= arguments.len) return Error.MissingValue;
                        break :blk arguments[i];
                    };
                    s_ptr.* = val_str;
                },
                .float_val => |f_ptr| {
                    const val_str = inline_val orelse blk: {
                        i += 1;
                        if (i >= arguments.len) return Error.MissingValue;
                        break :blk arguments[i];
                    };
                    f_ptr.* = std.fmt.parseFloat(f64, val_str) catch return Error.InvalidSyntax;
                },
            }

            i += 1;
        }
    }

    pub fn args(self: *const FlagSet) []const []const u8 {
        return self.actual_args.items;
    }

    pub fn nArg(self: *const FlagSet) usize {
        return self.actual_args.items.len;
    }

    pub fn arg(self: *const FlagSet, index: usize) ?[]const u8 {
        if (index < self.actual_args.items.len) {
            return self.actual_args.items[index];
        }
        return null;
    }

    pub fn lookup(self: *FlagSet, name: []const u8) ?*Flag {
        for (self.flags.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f;
            }
        }
        return null;
    }

    /// PrintDefaults prints usage of all defined flags to writer.
    pub fn printDefaults(self: *const FlagSet, w: *io.Writer) anyerror!void {
        for (self.flags.items) |f| {
            try w.writeAll("  -");
            try w.writeAll(f.name);
            switch (f.val) {
                .bool_val => {},
                .int_val => try w.writeAll(" int"),
                .str_val => try w.writeAll(" string"),
                .float_val => try w.writeAll(" float"),
            }
            try w.writeAll("\n    \t");
            try w.writeAll(f.usage);
            if (f.def_val.len > 0) {
                try w.writeAll(" (default ");
                try w.writeAll(f.def_val);
                try w.writeAll(")");
            }
            try w.writeAll("\n");
        }
        try w.flush();
    }
};

fn parseBool(s: []const u8) Error!bool {
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "T") or
        std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "True"))
    {
        return true;
    }
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "f") or std.mem.eql(u8, s, "F") or
        std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "False"))
    {
        return false;
    }
    return Error.InvalidSyntax;
}

test "flag.FlagSet basic parsing and args" {
    const testing = std.testing;

    var fs = FlagSet.init(testing.allocator, "my-tool");
    defer fs.deinit();

    var verbose: bool = false;
    var port: i64 = 80;
    var host: []const u8 = "localhost";

    try fs.boolVar(&verbose, "v", false, "verbose output");
    try fs.intVar(&port, "port", 80, "server listening port");
    try fs.stringVar(&host, "host", "localhost", "server hostname");

    const argv = [_][]const u8{
        "-v",
        "--port=8080",
        "-host",
        "example.com",
        "file1.txt",
        "file2.txt",
    };

    try fs.parse(&argv);

    try testing.expect(verbose);
    try testing.expectEqual(@as(i64, 8080), port);
    try testing.expectEqualStrings("example.com", host);

    // Positional arguments
    try testing.expectEqual(@as(usize, 2), fs.nArg());
    try testing.expectEqualStrings("file1.txt", fs.arg(0).?);
    try testing.expectEqualStrings("file2.txt", fs.arg(1).?);
    try testing.expectEqual(@as(?[]const u8, null), fs.arg(2));
}

test "flag.FlagSet help request" {
    const testing = std.testing;

    var fs = FlagSet.init(testing.allocator, "test");
    defer fs.deinit();

    const argv = [_][]const u8{"--help"};
    try testing.expectError(Error.HelpRequested, fs.parse(&argv));
}
