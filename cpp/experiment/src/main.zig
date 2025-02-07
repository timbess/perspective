const std = @import("std");

const Dtype = enum {
    i32,
    f64,

    pub fn underlying(self: Dtype) type {
        return switch (self) {
            .i32 => i32,
            .f64 => f64,
        };
    }

    pub fn alignment(self: Dtype) comptime_int {
        return switch (self) {
            inline else => |d| @alignOf(d.underlying()),
        };
    }

    pub fn size(self: Dtype) comptime_int {
        return switch (self) {
            inline else => |d| @sizeOf(d.underlying()),
        };
    }
};

const Scalar = union(Dtype) {
    i32: i32,
    f64: f64,
};

const PspError = error{
    InvalidDtype,
};

pub fn ScalarColumn(comptime dtype: Dtype) type {
    return struct {
        name: []const u8,
        dtype: Dtype,
        data: std.ArrayList(dtype.underlying()),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
            return Self{
                .name = name,
                .dtype = dtype,
                .data = std.ArrayList(dtype.underlying()).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
        }

        pub fn append(self: *Self, value: dtype.underlying()) !void {
            try self.data.append(value);
        }

        pub fn get(self: *Self, index: usize) ?dtype.underlying() {
            if (index >= self.data.items.len) return null;
            return self.data.items[index];
        }

        pub fn appendScalar(self: *Self, value: Scalar) !void {
            if (@intFromEnum(dtype) == @intFromEnum(value)) {
                try self.data.append(@field(value, @tagName(dtype)));
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

        pub fn typeErase(self: *Self) !ErasedColumn() {
            return ErasedColumn().init(dtype, self);
        }
    };
}

pub fn ErasedColumn() type {
    return struct {
        dtype: Dtype,
        data: *anyopaque,

        const Self = @This();

        pub fn init(comptime dtype: Dtype, column: *ScalarColumn(dtype)) !Self {
            return Self{
                .dtype = dtype,
                .data = @constCast(@ptrCast(@alignCast(column))),
            };
        }

        pub fn reflect(self: *Self, comptime T: Dtype) PspError!*ScalarColumn(T) {
            if (@intFromEnum(self.dtype) != @intFromEnum(T)) {
                return PspError.InvalidDtype;
            }
            return @ptrCast(@alignCast(self.data));
        }

        pub fn getScalar(self: *Self, index: usize) ?Scalar {
            switch (self.dtype) {
                inline else => |T| {
                    const col: *ScalarColumn(T) = @ptrCast(@alignCast(self.data));
                    return col.getScalar(index);
                },
            }
        }
    };
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
    var erased_column: ErasedColumn() = try column.typeErase();

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

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
