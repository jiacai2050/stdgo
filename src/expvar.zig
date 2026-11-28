//! Package expvar provides a standardized interface to public variables, such as
//! operation counters in servers, conforming to Go's expvar package.
const std = @import("std");
const Mutex = @import("sync/mutex.zig").Mutex;
const Allocator = std.mem.Allocator;

/// Var is an abstract type for all exported variables.
pub const Var = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        string: *const fn (ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8,
        deinit: ?*const fn (ctx: *anyopaque, allocator: Allocator) void = null,
    };

    pub fn string(self: Var, allocator: Allocator) Allocator.Error![]u8 {
        return self.vtable.string(self.ptr, allocator);
    }

    pub fn deinit(self: Var, allocator: Allocator) void {
        if (self.vtable.deinit) |f| f(self.ptr, allocator);
    }
};

/// Int is a 64-bit integer variable that satisfies the Var interface.
pub const Int = struct {
    val: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn value(self: *const Int) i64 {
        return self.val.load(.monotonic);
    }

    pub fn add(self: *Int, delta: i64) void {
        _ = self.val.fetchAdd(delta, .monotonic);
    }

    pub fn set(self: *Int, v: i64) void {
        self.val.store(v, .monotonic);
    }

    pub fn string(self: *const Int, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{self.value()});
    }

    pub fn var_ref(self: *Int) Var {
        return .{
            .ptr = self,
            .vtable = &int_vtable,
        };
    }

    fn stringImpl(ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *Int = @ptrCast(@alignCast(ctx));
        return self.string(allocator);
    }

    const int_vtable: Var.VTable = .{
        .string = stringImpl,
    };
};

/// Float is a 64-bit float variable that satisfies the Var interface.
pub const Float = struct {
    mu: Mutex = .{},
    val: f64 = 0.0,

    pub fn value(self: *Float) f64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.val;
    }

    pub fn add(self: *Float, delta: f64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.val += delta;
    }

    pub fn set(self: *Float, v: f64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.val = v;
    }

    pub fn string(self: *Float, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{self.value()});
    }

    pub fn var_ref(self: *Float) Var {
        return .{
            .ptr = self,
            .vtable = &float_vtable,
        };
    }

    fn stringImpl(ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *Float = @ptrCast(@alignCast(ctx));
        return self.string(allocator);
    }

    const float_vtable: Var.VTable = .{
        .string = stringImpl,
    };
};

/// String is a string variable that satisfies the Var interface.
pub const String = struct {
    allocator: Allocator,
    mu: Mutex = .{},
    val: []u8,

    /// Initializes a new heap-allocated String variable with the given initial value.
    pub fn init(allocator: Allocator, initial: []const u8) !*String {
        const s = try allocator.create(String);
        errdefer allocator.destroy(s);
        s.* = .{
            .allocator = allocator,
            .val = try allocator.dupe(u8, initial),
        };
        return s;
    }

    pub fn deinit(self: *String) void {
        self.allocator.free(self.val);
        self.allocator.destroy(self);
    }

    /// Sets the string variable to a copy of v.
    /// Allocates the new copy before freeing the old value so OOM leaves the previous value intact.
    pub fn set(self: *String, v: []const u8) !void {
        const new_val = try self.allocator.dupe(u8, v);
        self.mu.lock();
        defer self.mu.unlock();
        self.allocator.free(self.val);
        self.val = new_val;
    }

    pub fn value(self: *String, allocator: Allocator) ![]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return allocator.dupe(u8, self.val);
    }

    /// Returns the JSON-encoded string value.
    pub fn string(self: *String, allocator: Allocator) Allocator.Error![]u8 {
        self.mu.lock();
        defer self.mu.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendJsonString(&out, allocator, self.val);
        return out.toOwnedSlice(allocator);
    }

    pub fn var_ref(self: *String) Var {
        return .{
            .ptr = self,
            .vtable = &string_vtable,
        };
    }

    fn stringImpl(ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *String = @ptrCast(@alignCast(ctx));
        return self.string(allocator);
    }

    const string_vtable: Var.VTable = .{
        .string = stringImpl,
    };
};

/// Map is a string-to-Var map variable that satisfies the Var interface.
pub const Map = struct {
    allocator: Allocator,
    mu: Mutex = .{},
    entries: std.StringHashMapUnmanaged(Var) = .empty,
    owned_ints: std.ArrayListUnmanaged(*Int) = .empty,

    pub fn init(allocator: Allocator) !*Map {
        const m = try allocator.create(Map);
        m.* = .{
            .allocator = allocator,
        };
        return m;
    }

    pub fn deinit(self: *Map) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);

        for (self.owned_ints.items) |v| {
            self.allocator.destroy(v);
        }
        self.owned_ints.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn get(self: *Map, key: []const u8) ?Var {
        self.mu.lock();
        defer self.mu.unlock();
        return self.entries.get(key);
    }

    /// Sets key to av in the map.
    pub fn set(self: *Map, key: []const u8, av: Var) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.entries.getPtr(key)) |existing| {
            existing.* = av;
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.entries.put(self.allocator, owned_key, av);
        }
    }

    /// Adds delta to the Int value stored under key, creating one if absent.
    /// Returns error.TypeMismatch if key is already bound to a non-Int Var.
    pub fn add(self: *Map, key: []const u8, delta: i64) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.entries.get(key)) |v| {
            if (v.vtable != &Int.int_vtable) {
                return error.TypeMismatch;
            }
            const int_ptr: *Int = @ptrCast(@alignCast(v.ptr));
            int_ptr.add(delta);
        } else {
            const new_int = try self.allocator.create(Int);
            errdefer self.allocator.destroy(new_int);
            new_int.* = .{};
            new_int.set(delta);

            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);

            try self.owned_ints.ensureUnusedCapacity(self.allocator, 1);
            try self.entries.put(self.allocator, owned_key, new_int.var_ref());
            self.owned_ints.appendAssumeCapacity(new_int);
        }
    }

    pub fn delete(self: *Map, key: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Returns the JSON-encoded representation of the map with properly escaped keys.
    pub fn string(self: *Map, allocator: Allocator) Allocator.Error![]u8 {
        self.mu.lock();
        defer self.mu.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.append(allocator, '{');

        var it = self.entries.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try out.appendSlice(allocator, ", ");
            first = false;

            try appendJsonString(&out, allocator, entry.key_ptr.*);
            try out.appendSlice(allocator, ": ");

            const val_str = try entry.value_ptr.string(allocator);
            defer allocator.free(val_str);
            try out.appendSlice(allocator, val_str);
        }

        try out.append(allocator, '}');
        return out.toOwnedSlice(allocator);
    }

    pub fn var_ref(self: *Map) Var {
        return .{
            .ptr = self,
            .vtable = &map_vtable,
        };
    }

    fn stringImpl(ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *Map = @ptrCast(@alignCast(ctx));
        return self.string(allocator);
    }

    const map_vtable: Var.VTable = .{
        .string = stringImpl,
    };
};

/// Func wraps a function returning a string so that calling its string() method evaluates
/// the function.
pub const Func = struct {
    func: *const fn (allocator: Allocator) Allocator.Error![]u8,

    pub fn init(func: *const fn (allocator: Allocator) Allocator.Error![]u8) Func {
        return .{ .func = func };
    }

    pub fn string(self: *const Func, allocator: Allocator) Allocator.Error![]u8 {
        return self.func(allocator);
    }

    pub fn var_ref(self: *const Func) Var {
        return .{
            .ptr = @constCast(self),
            .vtable = &func_vtable,
        };
    }

    fn stringImpl(ctx: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *const Func = @ptrCast(@alignCast(ctx));
        return self.string(allocator);
    }

    const func_vtable: Var.VTable = .{
        .string = stringImpl,
    };
};

/// Global Registry
pub const Registry = struct {
    allocator: Allocator,
    mu: Mutex = .{},
    vars: std.StringHashMapUnmanaged(Var) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.vars.deinit(self.allocator);
    }

    /// Publishes a named variable in the registry.
    pub fn publish(self: *Registry, name: []const u8, v: Var) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.vars.get(name) != null) {
            return error.VariableAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.vars.put(self.allocator, owned_name, v);
    }

    pub fn get(self: *Registry, name: []const u8) ?Var {
        self.mu.lock();
        defer self.mu.unlock();
        return self.vars.get(name);
    }

    /// Serializes all registered variables into a JSON object with properly escaped keys.
    pub fn toJson(self: *Registry, allocator: Allocator) Allocator.Error![]u8 {
        self.mu.lock();
        defer self.mu.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.append(allocator, '{');

        var it = self.vars.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try out.appendSlice(allocator, ", ");
            first = false;

            try appendJsonString(&out, allocator, entry.key_ptr.*);
            try out.appendSlice(allocator, ": ");

            const val_str = try entry.value_ptr.string(allocator);
            defer allocator.free(val_str);
            try out.appendSlice(allocator, val_str);
        }

        try out.append(allocator, '}');
        return out.toOwnedSlice(allocator);
    }
};

fn appendJsonString(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    s: []const u8,
) Allocator.Error!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var esc: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(allocator, &esc);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

test "expvar: Int, Float, String, Map, and Registry JSON serialization" {
    const testing = std.testing;

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    // 1. Int
    var num_requests = Int{};
    num_requests.set(100);
    num_requests.add(42);
    try reg.publish("requests", num_requests.var_ref());

    // 2. Float
    var load_avg = Float{};
    load_avg.set(1.5);
    load_avg.add(0.25);
    try reg.publish("load", load_avg.var_ref());

    // 3. String
    var version_str = try String.init(testing.allocator, "1.2.3");
    defer version_str.deinit();
    try reg.publish("version", version_str.var_ref());

    // 4. Map
    var counters = try Map.init(testing.allocator);
    defer counters.deinit();
    try counters.add("200_ok", 50);
    try counters.add("404_not_found", 2);
    try reg.publish("status_codes", counters.var_ref());

    // 5. Test Registry.toJson()
    const json = try reg.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"requests\": 142") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\": \"1.2.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"200_ok\": 50") != null);
}

test "expvar: Map.add type safety and JSON escaping" {
    const testing = std.testing;

    var s = try String.init(testing.allocator, "line1\n\x01\"quoted\"");
    defer s.deinit();

    const s_json = try s.string(testing.allocator);
    defer testing.allocator.free(s_json);
    try testing.expectEqualStrings("\"line1\\n\\u0001\\\"quoted\\\"\"", s_json);

    var m = try Map.init(testing.allocator);
    defer m.deinit();
    try m.set("k\"1\x00", s.var_ref());

    // Calling add on a non-Int entry must fail safely instead of casting.
    try testing.expectError(error.TypeMismatch, m.add("k\"1\x00", 1));

    const m_json = try m.string(testing.allocator);
    defer testing.allocator.free(m_json);
    try testing.expect(std.mem.indexOf(u8, m_json, "\"k\\\"1\\u0000\": ") != null);
}
