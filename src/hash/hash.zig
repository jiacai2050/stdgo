const std = @import("std");
const io = @import("../io.zig");

pub const Hash = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    writer_inst: std.Io.Writer = undefined,

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

    pub fn writer(self: *Hash) *io.Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drainImpl,
                .flush = flushImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Hash = @alignCast(@fieldParentPtr("writer_inst", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            _ = self.vtable.write(self.ptr, slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            _ = self.vtable.write(self.ptr, pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }

    fn flushImpl(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};

pub const Hash32 = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    writer_inst: std.Io.Writer = undefined,

    pub const VTable = struct {
        hash: Hash.VTable,
        sum32: *const fn (ctx: *anyopaque) u32,
    };

    pub fn hash(self: Hash32) Hash {
        return .{
            .ptr = self.ptr,
            .vtable = &self.vtable.hash,
        };
    }

    pub fn write(self: Hash32, bytes: []const u8) anyerror!usize {
        return self.vtable.hash.write(self.ptr, bytes);
    }

    pub fn sum(self: Hash32, out: []u8) []const u8 {
        return self.vtable.hash.sum(self.ptr, out);
    }

    pub fn reset(self: Hash32) void {
        self.vtable.hash.reset(self.ptr);
    }

    pub fn size(self: Hash32) usize {
        return self.vtable.hash.size(self.ptr);
    }

    pub fn blockSize(self: Hash32) usize {
        return self.vtable.hash.blockSize(self.ptr);
    }

    pub fn sum32(self: Hash32) u32 {
        return self.vtable.sum32(self.ptr);
    }

    pub fn writer(self: *Hash32) *io.Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drainImpl,
                .flush = flushImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Hash32 = @alignCast(@fieldParentPtr("writer_inst", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            _ = self.vtable.hash.write(self.ptr, slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            _ = self.vtable.hash.write(self.ptr, pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }

    fn flushImpl(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};

pub const Hash64 = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    writer_inst: std.Io.Writer = undefined,

    pub const VTable = struct {
        hash: Hash.VTable,
        sum64: *const fn (ctx: *anyopaque) u64,
    };

    pub fn hash(self: Hash64) Hash {
        return .{
            .ptr = self.ptr,
            .vtable = &self.vtable.hash,
        };
    }

    pub fn write(self: Hash64, bytes: []const u8) anyerror!usize {
        return self.vtable.hash.write(self.ptr, bytes);
    }

    pub fn sum(self: Hash64, out: []u8) []const u8 {
        return self.vtable.hash.sum(self.ptr, out);
    }

    pub fn reset(self: Hash64) void {
        self.vtable.hash.reset(self.ptr);
    }

    pub fn size(self: Hash64) usize {
        return self.vtable.hash.size(self.ptr);
    }

    pub fn blockSize(self: Hash64) usize {
        return self.vtable.hash.blockSize(self.ptr);
    }

    pub fn sum64(self: Hash64) u64 {
        return self.vtable.sum64(self.ptr);
    }

    pub fn writer(self: *Hash64) *io.Writer {
        self.writer_inst = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drainImpl,
                .flush = flushImpl,
            },
        };
        return &self.writer_inst;
    }

    fn drainImpl(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Hash64 = @alignCast(@fieldParentPtr("writer_inst", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            _ = self.vtable.hash.write(self.ptr, slice) catch return error.WriteFailed;
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            _ = self.vtable.hash.write(self.ptr, pattern) catch return error.WriteFailed;
            total += pattern.len;
        }
        return total;
    }

    fn flushImpl(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};
