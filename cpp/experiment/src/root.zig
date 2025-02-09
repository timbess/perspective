const std = @import("std");
pub const columns = @import("columns.zig");
const arrow = @import("arrow.zig");

pub const Schema = struct {
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    dtype: Dtype,
};

pub const Dtype = enum {
    u32,
    u64,
    i32,
    f64,
    string,

    pub fn maxAlignment() comptime_int {
        var max = std.math.maxInt(comptime_int);
        for (std.meta.fields(@This())) |f| {
            max = @max(@alignOf(f.field_type.underlying()), max);
        }
        return max;
    }

    pub fn underlying(self: Dtype) type {
        return switch (self) {
            .u32 => u32,
            .u64 => u64,
            .i32 => i32,
            .f64 => f64,
            .string => []const u8,
        };
    }

    pub fn coltype(self: Dtype) type {
        return switch (self) {
            .u32 => columns.ScalarColumn(self),
            .u64 => columns.ScalarColumn(self),
            .i32 => columns.ScalarColumn(self),
            .f64 => columns.ScalarColumn(self),
            .string => columns.StringColumn,
        };
    }

    pub fn isScalar(self: Dtype) bool {
        return switch (self) {
            .u32, .u64, .i32, .f64 => true,
            else => false,
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

pub const Scalar = union(Dtype) {
    u32: u32,
    u64: u64,
    i32: i32,
    f64: f64,
    string: []const u8,
};

pub const PspError = error{
    InvalidDtype,
    InvalidColumnCount,
};

test {
    _ = @import("columns.zig");
    _ = @import("table.zig");
    _ = @import("arrow.zig");
}
