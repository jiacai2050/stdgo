const std = @import("std");

pub const Error = error{ InvalidDeadline, Timeout };

/// An optional absolute deadline on the awake clock.
pub const Deadline = struct {
    timestamp: ?std.Io.Clock.Timestamp,

    pub const none: Deadline = .{ .timestamp = null };

    pub fn after(io: std.Io, duration: std.Io.Duration) Deadline {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        return .{ .timestamp = .{
            .clock = .awake,
            .raw = .{ .nanoseconds = now.raw.nanoseconds +| duration.nanoseconds },
        } };
    }

    pub fn at(timestamp: std.Io.Clock.Timestamp) error{InvalidDeadline}!Deadline {
        const deadline: Deadline = .{ .timestamp = timestamp };
        try deadline.validate();
        return deadline;
    }

    pub fn isNone(self: Deadline) bool {
        return self.timestamp == null;
    }

    pub fn earlier(self: Deadline, other: Deadline) Deadline {
        const first = self.timestamp orelse return other;
        const second = other.timestamp orelse return self;
        return if (first.raw.nanoseconds <= second.raw.nanoseconds) self else other;
    }

    pub fn validate(self: Deadline) error{InvalidDeadline}!void {
        if (self.timestamp) |value| {
            if (value.clock != .awake) return error.InvalidDeadline;
        }
    }

    pub fn isExpired(self: Deadline, io: std.Io) error{InvalidDeadline}!bool {
        try self.validate();
        if (self.timestamp) |value| {
            return value.raw.nanoseconds <= std.Io.Clock.awake.now(io).nanoseconds;
        }
        return false;
    }

    pub fn check(self: Deadline, io: std.Io) Error!void {
        if (try self.isExpired(io)) return error.Timeout;
    }

    /// The deadline must have already passed validate.
    pub fn timeout(self: Deadline) std.Io.Timeout {
        if (self.timestamp) |value| {
            std.debug.assert(value.clock == .awake);
            return .{ .deadline = value };
        }
        return .none;
    }
};

test "deadline validates clocks and elapsed budgets" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try Deadline.none.check(io);
    try std.testing.expect(!try Deadline.none.isExpired(io));
    try Deadline.after(io, .fromSeconds(60)).check(io);
    try std.testing.expect(try Deadline.after(io, .zero).isExpired(io));
    try std.testing.expectError(error.Timeout, Deadline.after(io, .zero).check(io));
    try std.testing.expectError(error.Timeout, Deadline.after(io, .fromSeconds(-1)).check(io));
    try std.testing.expectError(error.InvalidDeadline, Deadline.at(.now(io, .real)));
    const invalid: Deadline = .{ .timestamp = .now(io, .real) };
    try std.testing.expectError(error.InvalidDeadline, invalid.check(io));
    try std.testing.expect(Deadline.none.timeout() == .none);
    try std.testing.expect(Deadline.after(io, .fromSeconds(1)).timeout() == .deadline);
    const timestamp = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectEqual(timestamp, (try Deadline.at(timestamp)).timestamp.?);
}
