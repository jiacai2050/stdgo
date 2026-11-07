const std = @import("std");

pub const Mutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *Mutex) void {
        while (self.locked.swap(true, .acquire)) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.locked.store(false, .release);
    }

    pub fn tryLock(self: *Mutex) bool {
        return !self.locked.swap(true, .acquire);
    }
};
