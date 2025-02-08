pub const columns = @import("columns.zig");

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
};
