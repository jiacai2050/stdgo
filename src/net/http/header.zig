//! HTTP Header representation conforming to Go's net/http Header map.
const std = @import("std");

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub fn isValidTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn isCaseInsensitiveEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const Header = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(HeaderEntry),

    pub fn init(allocator: std.mem.Allocator) Header {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Header) void {
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *const Header, name: []const u8) ?[]const u8 {
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (isCaseInsensitiveEqual(self.entries.items[i].name, name)) {
                return self.entries.items[i].value;
            }
        }
        return null;
    }

    pub fn set(self: *Header, name: []const u8, value: []const u8) !void {
        var i: usize = 0;
        var replaced = false;
        while (i < self.entries.items.len) {
            if (isCaseInsensitiveEqual(self.entries.items[i].name, name)) {
                if (!replaced) {
                    self.entries.items[i].name = name;
                    self.entries.items[i].value = value;
                    replaced = true;
                    i += 1;
                } else {
                    _ = self.entries.swapRemove(i);
                }
            } else {
                i += 1;
            }
        }
        if (!replaced) {
            try self.entries.append(self.allocator, .{ .name = name, .value = value });
        }
    }

    pub fn add(self: *Header, name: []const u8, value: []const u8) !void {
        try self.entries.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn del(self: *Header, name: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (isCaseInsensitiveEqual(self.entries.items[i].name, name)) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clone(self: *const Header, allocator: std.mem.Allocator) !Header {
        var new_h = Header.init(allocator);
        try new_h.entries.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            try new_h.entries.append(allocator, entry);
        }
        return new_h;
    }

    /// has reports whether Header contains the specified key.
    pub fn has(self: *const Header, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// values returns all values associated with the given key.
    pub fn values(
        self: *const Header,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![][]const u8 {
        var list = std.ArrayListUnmanaged([]const u8).empty;
        errdefer list.deinit(allocator);

        for (self.entries.items) |entry| {
            if (isCaseInsensitiveEqual(entry.name, name)) {
                try list.append(allocator, entry.value);
            }
        }
        return list.toOwnedSlice(allocator);
    }
};
