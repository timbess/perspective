const std = @import("std");
const columns = @import("columns.zig");
const root = @import("root.zig");
const Dtype = root.Dtype;
const PspError = root.PspError;
const arrow_ffi = @cImport({
    @cInclude("ffi/bridge.h");
});

pub fn cpp_dtype_to_zig(a: arrow_ffi.enum_dtype) Dtype {
    return @enumFromInt(a);
}

pub fn zig_dtype_to_cpp(a: Dtype) arrow_ffi.enum_dtype {
    return @enumFromInt(@intFromEnum(a));
}

pub const ArrowTable = struct {
    table: *arrow_ffi.OpaqueArrow,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        const arrow = arrow_ffi.InitArrow(data.ptr, data.len).?;
        return Self{ .table = arrow };
    }

    pub fn deinit(self: *Self) void {
        arrow_ffi.FreeArrow(self.table);
    }

    pub fn numColumns(self: *Self) usize {
        return arrow_ffi.TableColumns(self.table);
    }

    pub fn numRows(self: *Self) usize {
        return arrow_ffi.TableSize(self.table);
    }

    pub fn readFields(self: *Self, out: []arrow_ffi.Field) PspError!void {
        if (out.len != self.numColumns()) {
            return PspError.InvalidColumnCount;
        }
        arrow_ffi.ReadColumns(self.table, out.ptr);
    }

    pub fn readInto(self: *Self, column: []const u8, out: anytype) void {
        const T = @TypeOf(out);
        const typeInfo = @typeInfo(T);
        switch (typeInfo) {
            .Pointer => |p| {
                switch (@typeInfo(p.child)) {
                    .Array => {
                        return arrow_ffi.ReadInto(self.table, column.ptr, out.ptr, @sizeOf(p.child));
                    },
                    else => {
                        if (p.size == .Slice) {
                            return arrow_ffi.ReadInto(self.table, column.ptr, out.ptr, out.len * @sizeOf(p.child));
                        }
                        @compileError("Only slices or pointers to arrays are accepted. Got: " ++ @typeName(T));
                    },
                }
            },
            else => {
                @compileError("Only slices or pointers to arrays are accepted. Got: " ++ @typeName(T));
            },
        }
    }
};

test "Basic Arrow Functionality" {
    const file: []const u8 = @embedFile("./test.arrow");

    var arrow = ArrowTable.init(file);
    defer arrow.deinit();

    try std.testing.expectEqual(1, arrow.numColumns());

    var fields: [1]arrow_ffi.Field = undefined;
    try arrow.readFields(&fields);

    var too_many_fields: [100]arrow_ffi.Field = undefined;
    try std.testing.expectError(PspError.InvalidColumnCount, arrow.readFields(&too_many_fields));

    const i32_dtype: arrow_ffi.enum_dtype = @intCast(arrow_ffi.i32);
    try std.testing.expectEqual(i32_dtype, fields[0].dtype);

    const dtype = cpp_dtype_to_zig(fields[0].dtype);
    try std.testing.expectEqual(Dtype.i32, dtype);

    // This function works with pointers to comptime known sized arrays
    // and slices with runtime known length.
    var column_data: [3]i32 = undefined;
    const nm: []const u8 = std.mem.span(fields[0].name);
    arrow.readInto(nm, &column_data);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, &column_data);

    var column_data_buffer: [3]i32 = undefined;
    const column_data_slice: []i32 = &column_data_buffer;
    arrow.readInto(nm, column_data_slice);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, &column_data_buffer);
}
