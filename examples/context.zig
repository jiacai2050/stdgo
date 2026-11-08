//! Example demonstrating stdgo context package:
//! 1. context.background(): Root context
//! 2. withCancel(): Manual cancellation propagation across workers
//! 3. withValue(): Request-scoped key-value propagation
//! 4. withDeadline(): Deadline expiration checking

const std = @import("std");
const stdgo = @import("stdgo");
const context = stdgo.context;
const time = stdgo.time;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: context Lifecycle & Propagation Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. context.withValue: Request metadata propagation
    // -------------------------------------------------------------
    std.debug.print("1. context.withValue (Metadata Propagation):\n", .{});
    const root_ctx = context.background();

    const trace_id: []const u8 = "trace-uuid-9876-xyz";
    const user_role: []const u8 = "admin-role";

    const ctx_with_trace = try context.withValue(gpa, root_ctx, "trace_id", &trace_id);
    const ctx_with_auth = try context.withValue(gpa, ctx_with_trace.context(), "role", &user_role);

    const val_trace = ctx_with_auth.context().value("trace_id");
    if (val_trace) |ptr| {
        const tid: *const []const u8 = @ptrCast(@alignCast(ptr));
        std.debug.print("   Retrieved trace_id from deep context: \"{s}\"\n", .{tid.*});
    }

    const val_role = ctx_with_auth.context().value("role");
    if (val_role) |ptr| {
        const r: *const []const u8 = @ptrCast(@alignCast(ptr));
        std.debug.print("   Retrieved role from deep context:     \"{s}\"\n\n", .{r.*});
    }

    // -------------------------------------------------------------
    // 2. context.withCancel: Cancellation coordination
    // -------------------------------------------------------------
    std.debug.print("2. context.withCancel (Coordinated Cancellation):\n", .{});
    var cancel_ctx = try context.withCancel(gpa, ctx_with_auth.context());
    const c_ctx = cancel_ctx.context();

    std.debug.print("   Initial state -> done: {any}, err: {any}\n", .{ c_ctx.done(), c_ctx.err() });

    std.debug.print("   Simulating worker triggering cancellation...\n", .{});
    cancel_ctx.cancel();

    std.debug.print("   After cancel  -> done: {any}, err: {any}\n\n", .{ c_ctx.done(), c_ctx.err() });

    // -------------------------------------------------------------
    // 3. context.withDeadline: Deadline expiration
    // -------------------------------------------------------------
    std.debug.print("3. context.withDeadline:\n", .{});
    const now = time.Time.now(io);
    const short_dur: time.Duration = @enumFromInt(50 * 1_000_000); // 50ms
    const short_deadline = now.add(short_dur);

    var dl_ctx = try context.withDeadline(gpa, root_ctx, short_deadline);
    const d_ctx = dl_ctx.context();

    std.debug.print("   Checking deadline before expiration: done={any}\n", .{dl_ctx.check(io)});

    // Sleep 60ms to exceed 50ms deadline
    try time.sleep(io, @enumFromInt(60 * 1_000_000));

    std.debug.print("   Checking deadline after 60ms sleep:  done={any}, err={any}\n", .{ dl_ctx.check(io), d_ctx.err() });

    std.debug.print("\n=== context demo completed successfully! ===\n", .{});
}
