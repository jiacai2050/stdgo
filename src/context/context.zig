const std = @import("std");
const Allocator = std.mem.Allocator;
const time = @import("../time.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;

pub const Error = error{
    Canceled,
    DeadlineExceeded,
};

pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deadline: *const fn (ctx: *anyopaque) ?time.Time,
        done: *const fn (ctx: *anyopaque) bool,
        err: *const fn (ctx: *anyopaque) ?Error,
        value: *const fn (ctx: *anyopaque, key: []const u8) ?*const anyopaque,
    };

    pub fn deadline(self: Context) ?time.Time {
        return self.vtable.deadline(self.ptr);
    }

    pub fn done(self: Context) bool {
        return self.vtable.done(self.ptr);
    }

    pub fn err(self: Context) ?Error {
        return self.vtable.err(self.ptr);
    }

    pub fn value(self: Context, key: []const u8) ?*const anyopaque {
        return self.vtable.value(self.ptr, key);
    }
};

// --- Empty Root Context (Background / TODO) ---
const empty_vtable = Context.VTable{
    .deadline = struct {
        fn f(_: *anyopaque) ?time.Time {
            return null;
        }
    }.f,
    .done = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .err = struct {
        fn f(_: *anyopaque) ?Error {
            return null;
        }
    }.f,
    .value = struct {
        fn f(_: *anyopaque, _: []const u8) ?*const anyopaque {
            return null;
        }
    }.f,
};

var empty_dummy: u8 = 0;

pub fn background() Context {
    return .{
        .ptr = &empty_dummy,
        .vtable = &empty_vtable,
    };
}

pub fn todo() Context {
    return background();
}

// --- CancelContext ---
pub const CancelContext = struct {
    parent: Context,
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_err: ?Error = null,
    mutex: Mutex = .{},

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.parent.deadline();
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.isDone();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.getError();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.parent.value(key);
            }
        }.f,
    };

    pub fn context(self: *CancelContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn cancel(self: *CancelContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.canceled.load(.acquire)) {
            self.cancel_err = Error.Canceled;
            self.canceled.store(true, .release);
        }
    }

    pub fn isDone(self: *CancelContext) bool {
        return self.canceled.load(.acquire) or self.parent.done();
    }

    pub fn getError(self: *CancelContext) ?Error {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancel_err) |e| return e;
        return self.parent.err();
    }
};

pub fn withCancel(allocator: Allocator, parent: Context) Allocator.Error!*CancelContext {
    const ctx = try allocator.create(CancelContext);
    ctx.* = .{
        .parent = parent,
        .canceled = std.atomic.Value(bool).init(false),
        .cancel_err = null,
        .mutex = .{},
    };
    return ctx;
}

// --- ValueContext ---
pub const ValueContext = struct {
    parent: Context,
    key: []const u8,
    val_ptr: *const anyopaque,

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.deadline();
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.done();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.err();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                if (std.mem.eql(u8, self.key, key)) {
                    return self.val_ptr;
                }
                return self.parent.value(key);
            }
        }.f,
    };

    pub fn context(self: *ValueContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

pub fn withValue(
    allocator: Allocator,
    parent: Context,
    key: []const u8,
    val_ptr: anytype,
) Allocator.Error!*ValueContext {
    const ctx = try allocator.create(ValueContext);
    ctx.* = .{
        .parent = parent,
        .key = key,
        .val_ptr = @ptrCast(val_ptr),
    };
    return ctx;
}

// --- DeadlineContext ---
pub const DeadlineContext = struct {
    cancel_ctx: CancelContext,
    deadline_val: time.Time,

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.deadline_val;
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.isDone();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.getError();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.parent.value(key);
            }
        }.f,
    };

    pub fn context(self: *DeadlineContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Checks the current time against the deadline using caller-provided io.
    /// If expired, automatically cancels the context with DeadlineExceeded.
    pub fn check(self: *DeadlineContext, io: std.Io) bool {
        if (self.cancel_ctx.isDone()) return true;
        const now = time.Time.now(io);
        if (now.unixNano() >= self.deadline_val.unixNano()) {
            self.cancel_ctx.mutex.lock();
            defer self.cancel_ctx.mutex.unlock();
            self.cancel_ctx.cancel_err = Error.DeadlineExceeded;
            self.cancel_ctx.canceled.store(true, .release);
            return true;
        }
        return false;
    }
};

pub fn withDeadline(
    allocator: Allocator,
    parent: Context,
    deadline_val: time.Time,
) Allocator.Error!*DeadlineContext {
    const ctx = try allocator.create(DeadlineContext);
    ctx.* = .{
        .cancel_ctx = .{
            .parent = parent,
            .canceled = std.atomic.Value(bool).init(false),
            .cancel_err = null,
            .mutex = .{},
        },
        .deadline_val = deadline_val,
    };
    return ctx;
}

test "context.Background and WithCancel" {
    const testing = std.testing;

    const bg = background();
    try testing.expect(!bg.done());
    try testing.expect(bg.err() == null);
    try testing.expect(bg.deadline() == null);

    var cancel_node = try withCancel(testing.allocator, bg);
    defer testing.allocator.destroy(cancel_node);

    const ctx = cancel_node.context();
    try testing.expect(!ctx.done());

    cancel_node.cancel();
    try testing.expect(ctx.done());
    try testing.expectEqual(Error.Canceled, ctx.err().?);
}

test "context.WithValue chain" {
    const testing = std.testing;

    const bg = background();
    const trace_id: usize = 12345;
    const user_name: []const u8 = "alice";

    var v1 = try withValue(testing.allocator, bg, "trace_id", &trace_id);
    defer testing.allocator.destroy(v1);

    var v2 = try withValue(testing.allocator, v1.context(), "user", &user_name);
    defer testing.allocator.destroy(v2);

    const ctx = v2.context();

    const found_user: ?*const anyopaque = ctx.value("user");
    try testing.expect(found_user != null);
    const user_ptr: *const []const u8 = @ptrCast(@alignCast(found_user.?));
    try testing.expectEqualStrings("alice", user_ptr.*);

    const found_trace: ?*const anyopaque = ctx.value("trace_id");
    try testing.expect(found_trace != null);
    const trace_val: *const usize = @ptrCast(@alignCast(found_trace.?));
    try testing.expectEqual(@as(usize, 12345), trace_val.*);
}

test "context.WithDeadline" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const bg = background();
    const target_time = time.Time.unix(0, 0); // long expired in the past

    var dl_node = try withDeadline(testing.allocator, bg, target_time);
    defer testing.allocator.destroy(dl_node);

    const ctx = dl_node.context();
    try testing.expect(dl_node.check(io));
    try testing.expect(ctx.done());
    try testing.expectEqual(Error.DeadlineExceeded, ctx.err().?);
}
