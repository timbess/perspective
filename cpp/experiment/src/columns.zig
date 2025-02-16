const std = @import("std");
const root = @import("root.zig");
const BitVector = @import("bitvector.zig").BitVector;

const Dtype = root.Dtype;
const Scalar = root.Scalar;
const PspError = root.PspError;

/// Type erased column, useful for cases where we have heterogeneous sets of columns.
/// It only exposes scalar unions types, but for more effecient access, we can reflect to the
/// underlying concrete type when needed.
pub const Column = struct {
    ptr: *anyopaque,
    name: []const u8,
    appendScalarFn: *const fn (*anyopaque, Scalar) anyerror!void,
    getScalarFn: *const fn (*anyopaque, usize) ?Scalar,
    sizeFn: *const fn (*anyopaque) usize,
    deinitFn: *const fn (*anyopaque) void,
    dtype: Dtype,

    const Self = @This();

    fn init(ptr_: *anyopaque, name: []const u8, dtype: Dtype, comptime vtable: type) Self {
        return .{
            .ptr = ptr_,
            .name = name,
            .appendScalarFn = vtable.appendScalar,
            .getScalarFn = vtable.getScalar,
            .sizeFn = vtable.size,
            .deinitFn = vtable.deinit,
            .dtype = dtype,
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinitFn(self.ptr);
    }

    pub fn append(self: *Self, scalar: Scalar) !void {
        try self.appendScalarFn(self.ptr, scalar);
    }

    pub fn getScalar(self: *Self, index: usize) ?Scalar {
        return self.getScalarFn(self.ptr, index);
    }

    pub fn size(self: *const Self) usize {
        return self.sizeFn(self.ptr);
    }

    pub fn reflect(self: *Self, comptime dtype: Dtype) PspError!*dtype.coltype() {
        if (dtype != self.dtype) {
            return PspError.InvalidDtype;
        }

        return @ptrCast(@alignCast(self.ptr));
    }
};

/// Set of virtual functions for a Column implementation.
pub fn ColumnVtable(comptime dtype: Dtype) type {
    const ColType = dtype.coltype();
    return struct {
        fn appendScalar(self: *anyopaque, value: Scalar) !void {
            const column: *ColType = @ptrCast(@alignCast(self));
            try column.appendScalar(value);
        }

        fn getScalar(self: *anyopaque, index: usize) ?Scalar {
            const column: *ColType = @ptrCast(@alignCast(self));
            return column.getScalar(index);
        }

        fn size(self: *anyopaque) usize {
            const column: *ColType = @ptrCast(@alignCast(self));
            return column.size();
        }

        fn deinit(self: *anyopaque) void {
            const column: *ColType = @ptrCast(@alignCast(self));
            column.deinit();
        }
    };
}

pub const ValueStatus = enum(u1) { defined, null };
pub const DeltaStatus = enum(u2) {
    defined,
    null,
    undefined,
};

test {
    try std.testing.expectEqual(1, @typeInfo(@typeInfo(ValueStatus).Enum.tag_type).Int.bits);
    try std.testing.expectEqual(2, @typeInfo(@typeInfo(DeltaStatus).Enum.tag_type).Int.bits);

    inline for (std.meta.fields(ValueStatus)) |v| {
        const delta_field = std.meta.stringToEnum(DeltaStatus, v.name).?;
        try std.testing.expectEqual(v.value, @intFromEnum(delta_field));
    }
}

/// A generic column type for scalar values. This is a template that should be instantiated with a specific Dtype.
pub fn ScalarColumn(comptime dtype: Dtype) type {
    if (!dtype.isScalar()) {
        @compileError("Cannot create a ScalarColumn for non-scalar type " ++ @typeName(dtype));
    }

    return struct {
        name: []const u8,
        dtype: Dtype,
        data: std.ArrayListUnmanaged(dtype.underlying()),
        nulls: Nulls,
        allocator: std.mem.Allocator,

        const Self = @This();
        const vtable = ColumnVtable(dtype);

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
            return Self{
                .name = try allocator.dupe(u8, name),
                .dtype = dtype,
                .data = std.ArrayListUnmanaged(dtype.underlying()){},
                .nulls = Nulls.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.name);
            self.data.deinit(self.allocator);
            self.nulls.deinit();
        }

        pub fn ensureSize(self: *Self, capacity: usize) !void {
            try self.data.ensureTotalCapacity(self.allocator, capacity);
        }

        pub fn append(self: *Self, value: dtype.underlying()) !void {
            try self.data.append(self.allocator, value);
        }

        pub fn get(self: *Self, index: usize) ?dtype.underlying() {
            if (index >= self.data.items.len) return null;
            return self.data.items[index];
        }

        pub fn appendScalar(self: *Self, value: Scalar) !void {
            if (@intFromEnum(dtype) == @intFromEnum(value)) {
                try self.data.append(self.allocator, @field(value, @tagName(dtype)));
            } else {
                return PspError.InvalidDtype;
            }
        }

        pub fn getScalar(self: *Self, index: usize) ?Scalar {
            if (index >= self.data.items.len) return null;
            return @unionInit(Scalar, @tagName(dtype), self.data.items[index]);
        }

        pub fn size(self: *Self) usize {
            return self.data.items.len;
        }

        pub fn toColumn(self: *Self) Column {
            return Column.init(self, self.name, dtype, vtable);
        }
    };
}

/// A vocabulary for interning strings. By using an Arena Allocator, we effectively store
/// strings in a contiguous block of memory, which can be more efficient when accessing repeated small
/// string values (such as when a string column is iterated over). This also means we can free them all
/// in one go at the end of the Column's lifetime.
pub const Vocab = struct {
    allocator: std.heap.ArenaAllocator,
    interned: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Vocab {
        return Vocab{
            .allocator = std.heap.ArenaAllocator.init(allocator),
            .interned = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Vocab) void {
        self.interned.deinit();
        self.allocator.deinit();
    }

    pub fn loadDict(self: *Vocab, dict_values: []const u8, offsets: []const i32) !void {
        std.debug.assert(dict_values.len == offsets.len - 1);
        for (0..dict_values.len) |i| {
            const start: usize = @intCast(offsets[i]);
            const end: usize = @intCast(offsets[i + 1]);
            const str_slice: []const u8 = dict_values[start..end];
            _ = try self.intern(str_slice);
        }
    }

    pub fn intern(self: *Vocab, str: []const u8) ![]const u8 {
        return self.interned.get(str) orelse {
            const interned_str: []const u8 = try self.allocator.allocator().dupe(u8, str);
            try self.interned.put(interned_str, interned_str);
            return interned_str;
        };
    }
};

test "Vocab must deduplicate strings" {
    var vocab = Vocab.init(std.testing.allocator);
    defer vocab.deinit();

    // Dynamically allocate string so that Zig doesn't intern them.
    const str1 = try std.testing.allocator.dupe(u8, "hello");
    const str2 = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(str1);
    defer std.testing.allocator.free(str2);

    try std.testing.expect(str1.ptr != str2.ptr);

    const index1 = try vocab.intern(str1);
    const index2 = try vocab.intern(str2);

    // Both should point to the same interned string.
    try std.testing.expectEqual(index1.ptr, index2.ptr);

    // Both strings should equal the original strings.
    try std.testing.expectEqualStrings("hello", index1);
    try std.testing.expectEqualStrings("hello", index2);
}

const Nulls = struct {
    const BitVectorType = BitVector(@typeInfo(ValueStatus).Enum.tag_type);
    nulls: BitVectorType,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .nulls = try BitVectorType.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.nulls.deinit();
    }

    pub fn deleteLastN(self: *Self, num: usize) void {
        self.nulls.deleteLastN(num);
    }

    pub fn backFillDefined(self: *Self, cap: usize) std.mem.Allocator.Error!void {
        try self.nulls.appendNTimes(@intFromEnum(ValueStatus.defined), cap);
    }

    pub fn append(self: *Self, status: ValueStatus) std.mem.Allocator.Error!void {
        try self.nulls.append(@intFromEnum(status));
    }

    pub fn appendAt(self: *Self, idx: usize, status: ValueStatus) std.mem.Allocator.Error!void {
        if (idx > self.nulls.elementCount) {
            try self.backFillDefined(idx - self.nulls.elementCount);
        }
        try self.append(status);
    }

    pub inline fn setStatus(self: *Self, idx: usize, status: ValueStatus) void {
        self.nulls.set(idx, @intFromEnum(status));
    }

    pub inline fn getStatus(self: *Self, idx: usize) ValueStatus {
        return @enumFromInt(self.nulls.get(idx));
    }

    pub inline fn size(self: *Self) usize {
        return self.nulls.elementCount;
    }
};

test "Nulls backfills defined values when appended mid-list" {
    var nulls = Nulls.init(std.testing.allocator);
    defer nulls.deinit();

    try nulls.appendAt(100, .null);

    try std.testing.expectEqual(101, nulls.size());
    try std.testing.expectEqual(.null, nulls.getStatus(100));
    // for (nulls.nulls.items[0..100]) |s| {
    for (0..100) |i| {
        try std.testing.expectEqual(.defined, nulls.getStatus(i));
    }
}

test "Nulls at index 0 work" {
    var nulls = Nulls.init(std.testing.allocator);
    defer nulls.deinit();

    try std.testing.expectEqual(0, nulls.size());

    try nulls.appendAt(0, .null);

    try std.testing.expectEqual(1, nulls.size());
    try std.testing.expectEqual(.null, nulls.getStatus(0));
}

/// A column that stores string values as a Vocab of unique strings combined with a list of
/// fat pointers into the Vocab. This is especially efficient for datasets with many repeated strings.
pub const StringColumn = struct {
    name: []const u8,
    data: std.ArrayList([]const u8),
    nulls: Nulls,
    vocab: Vocab,

    const Self = @This();
    const vtable = ColumnVtable(Dtype.string);

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
        var data = std.ArrayList([]const u8).init(allocator);
        errdefer data.deinit();
        var vocab = Vocab.init(allocator);
        errdefer vocab.deinit();
        return Self{
            .name = try allocator.dupe(u8, name),
            .data = data,
            .nulls = Nulls.init(allocator),
            .vocab = vocab,
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.allocator.free(self.name);
        self.data.deinit();
        self.vocab.deinit();
    }

    pub fn append(self: *Self, str: ?[]const u8) !void {
        if (str != null) {
            const interned_str = try self.vocab.intern(str.?);
            try self.data.append(interned_str);
        } else {
            // Only deal with nulls on the first occurence.
            if (self.nulls.size() > 0) {
                try self.nulls.append(.null);
                errdefer self.nulls.deleteLastN(1);
                try self.data.append("");
            } else {
                try self.nulls.backFillDefined(self.data.items.len);
                errdefer self.nulls.deleteLastN(self.data.items.len);
                try self.nulls.append(.null);
                errdefer self.nulls.deleteLastN(1);
                try self.data.append("");
            }
        }
    }

    pub fn appendScalar(self: *Self, scalar: Scalar) !void {
        switch (scalar) {
            .string => |str| try self.append(str),
            else => return PspError.InvalidDtype,
        }
    }

    pub fn get(self: *Self, index: usize) ?[]const u8 {
        if (index >= self.data.items.len) return null;
        return self.data.items[index];
    }

    pub fn getScalar(self: *Self, index: usize) ?Scalar {
        if (self.get(index)) |str| {
            return Scalar{ .string = str };
        }
        return null;
    }

    pub fn ensureSize(self: *Self, capacity: usize) !void {
        try self.data.ensureTotalCapacity(capacity);
    }

    pub fn size(self: *Self) usize {
        return self.data.items.len;
    }

    pub fn toColumn(self: *Self) Column {
        return Column.init(self, self.name, Dtype.string, vtable);
    }
};

test "StringColumn functionality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var column = try StringColumn.init(allocator, "test_column");
    defer column.deinit();

    try column.append("hello");
    try column.append("world");
    try column.append("hello");
    try column.append("zig");

    try std.testing.expectEqualStrings("hello", column.get(0).?);
    try std.testing.expectEqualStrings("world", column.get(1).?);
    try std.testing.expectEqualStrings("hello", column.get(2).?);
    try std.testing.expectEqualStrings("zig", column.get(3).?);
}

test "ScalarColumn scalar methods" {
    var column = try ScalarColumn(Dtype.i32).init(std.testing.allocator, "test_column");
    defer column.deinit();

    for (0..100) |i| {
        try column.appendScalar(Scalar{ .i32 = @intCast(i) });
    }

    for (0..100) |i| {
        try std.testing.expectEqual(Scalar{ .i32 = @intCast(i) }, column.getScalar(i));
    }

    try std.testing.expectEqual(100, column.size());

    try std.testing.expectError(PspError.InvalidDtype, column.appendScalar(Scalar{ .f64 = 123.45 }));
}

test "ScalarColumn comptime methods" {
    var column = try ScalarColumn(Dtype.i32).init(std.testing.allocator, "test_column");
    defer column.deinit();

    for (0..100) |i| {
        const value: i32 = @intCast(i);
        try column.append(value);
    }

    for (0..100) |i| {
        const value: i32 = @intCast(i);
        try std.testing.expectEqual(value, column.get(i));
    }
}

test "ScalarColumn erasure/reflection" {
    var column = try ScalarColumn(Dtype.i32).init(std.testing.allocator, "test_column");
    defer column.deinit();

    for (0..100) |i| {
        const value: i32 = @intCast(i);
        try column.append(value);
    }
    var erased_column: Column = column.toColumn();

    for (0..100) |i| {
        const value: Scalar = .{ .i32 = @intCast(i) };
        try std.testing.expectEqual(value, erased_column.getScalar(i));
    }

    var reflected = try erased_column.reflect(Dtype.i32);

    for (0..100) |i| {
        const value: i32 = @intCast(i);
        try std.testing.expectEqual(value, reflected.get(i));
    }
}

test "ScalarColumn erasure/reflection with strings" {
    var column = try StringColumn.init(std.testing.allocator, "test_column");
    defer column.deinit();

    for (0..10) |i| {
        const value: []const u8 = std.fmt.allocPrint(std.testing.allocator, "{}", .{i}) catch unreachable;
        defer std.testing.allocator.free(value);
        try column.append(value);
    }
    var erased_column = column.toColumn();

    for (0..10) |i| {
        const value: []const u8 = std.fmt.allocPrint(std.testing.allocator, "{}", .{i}) catch unreachable;
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(value, erased_column.getScalar(i).?.string);
    }

    var reflected_column: *StringColumn = try erased_column.reflect(Dtype.string);

    for (0..10) |i| {
        const value: []const u8 = std.fmt.allocPrint(std.testing.allocator, "{}", .{i}) catch unreachable;
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(value, reflected_column.getScalar(i).?.string);
    }
}
