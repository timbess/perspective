const std = @import("std");
const columns = @import("columns.zig");
const root = @import("root.zig");
const Scalar = root.Scalar;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const Schema = table_mod.Schema;
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

    pub fn numChunks(self: *Self, column: []const u8) usize {
        return @intCast(arrow_ffi.NumChunks(self.table, column.ptr));
    }

    pub fn toTable(self: *Self, allocator: std.mem.Allocator, name: []const u8) !Table {
        const fields = try allocator.alloc(arrow_ffi.Field, self.numColumns());
        defer allocator.free(fields);
        try self.readFields(fields);

        for (fields) |f| {
            std.log.debug("Field name: {s}, dtype: {s}", .{ std.mem.span(f.name), @tagName(cpp_dtype_to_zig(f.dtype)) });
        }

        var table = try Table.init(allocator, name, try Schema.init(allocator));

        for (fields) |field| {
            const dt = cpp_dtype_to_zig(field.dtype);
            const field_name: []const u8 = std.mem.span(field.name);
            switch (dt) {
                .string => {
                    const ColType = columns.StringColumn;

                    var col_data: *ColType = try allocator.create(ColType);
                    col_data.* = try ColType.init(allocator, field_name);
                    try col_data.ensureSize(self.numRows());

                    col_data.data.items.len = self.numRows();
                    const num_chunks = self.numChunks(field_name);
                    const dicts: []arrow_ffi.DictColumnChunk = try allocator.alloc(arrow_ffi.DictColumnChunk, num_chunks);
                    defer allocator.free(dicts);

                    arrow_ffi.GetDictColumn(self.table, field_name.ptr, dicts.ptr);
                    var offset: usize = 0;
                    for (dicts) |d| {
                        // try col_data.vocab.loadDict(d.dict_values[0..d.dict_size], d.offsets[0 .. d.dict_size + 1]);
                        switch (cpp_dtype_to_zig(d.index_type)) {
                            .f64 => return error.UnsupportedType,
                            .string => return error.UnsupportedType,
                            inline else => |dtype| {
                                const IndexColType = dtype.underlying();

                                const src_ptr: [*]IndexColType = @alignCast(@ptrCast(d.indices.?));
                                for (src_ptr[0..d.indices_size], offset..offset + d.indices_size) |idx, dest_idx| {
                                    const idx_usize: usize = @intCast(idx);
                                    const start: usize = @intCast(d.offsets[idx_usize]);
                                    const end: usize = @intCast(d.offsets[idx_usize + 1]);
                                    const data = try col_data.vocab.intern(d.dict_values[start..end]);
                                    col_data.data.items[dest_idx] = data;
                                }
                                offset += d.indices_size;
                            },
                        }
                    }

                    try table.addColumn(col_data.toColumn());
                },
                inline else => |dtype| {
                    const ColType = dtype.coltype();

                    var col_data: *ColType = try allocator.create(ColType);
                    col_data.* = try ColType.init(allocator, field_name);
                    try col_data.ensureSize(self.numRows());

                    col_data.data.items.len = self.numRows();
                    self.readInto(field_name, col_data.data.items);

                    try table.addColumn(col_data.toColumn());
                },
            }
        }

        return table;
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

    var table = try arrow.toTable(std.testing.allocator, "TEST");
    defer table.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const local = arena.allocator();
    const data = try table.sliceRows(local, 0, 3);

    for (data) |d| {
        try std.testing.expectEqualStrings("x", d.column_name);
        for (1..4) |i| {
            try std.testing.expectEqual(Scalar{ .i32 = @intCast(i) }, d.data.get(i - 1));
        }
    }
}
