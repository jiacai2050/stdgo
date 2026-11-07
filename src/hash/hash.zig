const std = @import("std");
const io = @import("../io.zig");

pub const Hash = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        sum: *const fn (ctx: *anyopaque, out: []u8) []const u8,
        reset: *const fn (ctx: *anyopaque) void,
        size: *const fn (ctx: *anyopaque) usize,
        blockSize: *const fn (ctx: *anyopaque) usize,
    };

    pub fn write(self: Hash, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn sum(self: Hash, out: []u8) []const u8 {
        return self.vtable.sum(self.ptr, out);
    }

    pub fn reset(self: Hash) void {
        self.vtable.reset(self.ptr);
    }

    pub fn size(self: Hash) usize {
        return self.vtable.size(self.ptr);
    }

    pub fn blockSize(self: Hash) usize {
        return self.vtable.blockSize(self.ptr);
    }

    pub fn writer(self: Hash) io.Writer {
        return .{
            .ptr = self.ptr,
            .vtable = &.{
                .write = self.vtable.write,
            },
        };
    }
};
