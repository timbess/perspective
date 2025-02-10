const std = @import("std");
const builtin = @import("builtin");
const columns = @import("columns.zig");
const arrow_mod = @import("arrow.zig");
const Column = columns.Column;

const root = @import("root.zig");
const Dtype = root.Dtype;
const PspError = root.PspError;
const Field = root.Field;

pub const Schema = root.Schema;
pub const Scalar = root.Scalar;

const ScalarArray = std.MultiArrayList(Scalar);
pub const ColumnSlice = struct {
    column_name: []const u8,
    data: ScalarArray,
};

pub const Table = struct {
    name: []const u8,
    columns: std.ArrayListUnmanaged(Column),
    name_mapping: std.StringHashMapUnmanaged(Column),
    schema: Schema,
    allocator: std.mem.Allocator,
    size: usize,

    const Self = @This();

    pub fn fromArrow(allocator: std.mem.Allocator, name: []const u8, arrow_bytes: []const u8) !Self {
        var arrow = arrow_mod.ArrowTable.init(arrow_bytes);
        return try arrow.toTable(allocator, name);
    }

    pub fn init(allocator: std.mem.Allocator, name: []const u8, schema: Schema) !Self {
        var cols = try std.ArrayListUnmanaged(Column).initCapacity(allocator, schema.fields.items.len);
        var name_mapping = std.StringHashMapUnmanaged(Column){};
        try name_mapping.ensureTotalCapacity(allocator, @truncate(schema.fields.items.len));
        for (schema.fields.items) |field| {
            switch (field.dtype) {
                inline else => |dtype| {
                    const ColType = dtype.coltype();
                    var col: *ColType = try allocator.create(ColType);
                    // Bypass local arena to let column's choose how to wrap the top level allocator.
                    col.* = try ColType.init(allocator, field.name);
                    const erased = col.toColumn();
                    cols.appendAssumeCapacity(erased);
                    try name_mapping.put(allocator, field.name, erased);
                },
            }
        }

        return Self{
            .name = try allocator.dupe(u8, name),
            .columns = cols,
            .name_mapping = name_mapping,
            .schema = schema,
            .allocator = allocator,
            .size = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.schema.deinit();
        self.allocator.free(self.name);
        for (self.columns.items) |*col| {
            const ptr = col.ptr;
            const dtype = col.dtype;
            col.deinit();
            switch (dtype) {
                inline else => |dt| {
                    const ColType = dt.coltype();
                    const col_ptr: *ColType = @ptrCast(@alignCast(ptr));
                    self.allocator.destroy(col_ptr);
                },
            }
        }
        self.columns.deinit(self.allocator);
        self.name_mapping.deinit(self.allocator);
    }

    pub fn addColumn(self: *Self, col: Column) !void {
        const col_size = col.size();
        if (self.columns.items.len > 0 and self.size != col_size) {
            return PspError.ColumnSizeMismatch;
        }
        try self.columns.append(self.allocator, col);
        try self.name_mapping.put(self.allocator, col.name, col);
        try self.schema.addField(Field{ .name = col.name, .dtype = col.dtype });
        self.size = col_size;
    }

    pub fn getColumn(self: *Self, name: []const u8) ?Column {
        return self.name_mapping.get(name) orelse null;
    }

    inline fn appendRowUnchecked(self: *Self, row: []const Scalar) !void {
        for (self.columns.items, row) |*col, scalar| {
            try col.append(scalar);
        }
        self.size += 1;
    }

    pub fn appendRow(self: *Self, row: []const Scalar) !void {
        if (row.len != self.schema.fields.items.len) {
            return PspError.InvalidColumnCount;
        }
        try self.appendRowUnchecked(row);
    }

    pub fn appendRows(self: *Self, rows: []const []const Scalar) !void {
        for (rows) |row| {
            try self.appendRow(row);
        }
        self.assertSizeOfAllColumns();
    }

    /// Slice rows from the table. Probably smart to use an Arena allocator here.
    pub fn sliceRows(self: *Self, allocator: std.mem.Allocator, rstart: usize, rend: usize) ![]ColumnSlice {
        if (rstart > rend or rend > self.size) {
            return error.InvalidArgument;
        }
        const row_count = rend - rstart;
        const result: []ColumnSlice = try allocator.alloc(ColumnSlice, self.columns.items.len);
        for (result, self.schema.fields.items) |*r, field| {
            r.* = ColumnSlice{
                .column_name = field.name,
                .data = ScalarArray{},
            };
            try r.data.ensureTotalCapacity(allocator, row_count);
        }
        for (self.columns.items, result) |*col, *r| {
            switch (col.dtype) {
                inline else => |dtype| {
                    const ColType = dtype.coltype();
                    const typed_col: *ColType = try col.reflect(dtype);

                    // const col_size = typed_col.size();

                    r.data.len = row_count;
                    var dst = r.data.slice().items(ScalarArray.Field.data);
                    dst.len = row_count;
                    var tag_dst = r.data.slice().items(ScalarArray.Field.tags);
                    tag_dst.len = row_count;

                    const Bare = @typeInfo(@TypeOf(dst)).Pointer.child;

                    // Has to be a loop because the contiguous int columns are smaller than the "Scalar" union
                    for (rstart..rend, 0..) |i, dst_i| {
                        dst[dst_i] = @unionInit(Bare, @tagName(dtype), typed_col.data.items[i]);
                    }

                    @memset(tag_dst.ptr[rstart..rend], dtype);
                },
            }
        }
        return result;
    }

    inline fn assertSizeOfAllColumns(self: *Self) void {
        if (builtin.mode == .Debug) {
            for (self.columns.items) |*col| {
                std.debug.assert(col.size() == self.size);
            }
        }
    }
};

test "table slices" {
    const fields = [_]root.Field{
        .{ .name = "id", .dtype = Dtype.u32 },
        .{ .name = "value", .dtype = Dtype.f64 },
        // .{ .name = "label", .dtype = Dtype.string },
    };
    var schema = try Schema.init(std.testing.allocator);
    for (fields) |f| {
        try schema.addField(f);
    }

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    const rows: []const []const Scalar = &[_][]const Scalar{
        // &[_]Scalar{ .{ .u32 = 1 }, .{ .f64 = 1 }, .{ .string = "foo" } },
        // &[_]Scalar{ .{ .u32 = 2 }, .{ .f64 = 2 }, .{ .string = "bar" } },
        // &[_]Scalar{ .{ .u32 = 3 }, .{ .f64 = 3 }, .{ .string = "baz" } },
        &[_]Scalar{ .{ .u32 = 1 }, .{ .f64 = 1 } },
        &[_]Scalar{ .{ .u32 = 2 }, .{ .f64 = 2 } },
        &[_]Scalar{ .{ .u32 = 3 }, .{ .f64 = 3 } },
    };

    try table.appendRows(rows);

    try std.testing.expectEqual(table.size, 3);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slices = try table.sliceRows(arena.allocator(), 0, 3);

    // const names = [_][]const u8{ "id", "value", "label" };
    const names = [_][]const u8{ "id", "value" };

    try std.testing.expect(slices.len == schema.fields.items.len);
    for (slices, names, 0..) |col, expected_name, coli| {
        try std.testing.expectEqualStrings(expected_name, col.column_name);
        try std.testing.expect(col.data.len > 0);
        for (0..col.data.len) |rowi| {
            const data = col.data.get(rowi);
            switch (data) {
                .string => {
                    try std.testing.expectEqualStrings(rows[rowi][coli].string, data.string);
                },
                else => {
                    try std.testing.expectEqual(rows[rowi][coli], data);
                },
            }
        }
    }
}

test "table creation and destruction" {
    const fields = [_]root.Field{
        .{ .name = "id", .dtype = Dtype.u32 },
        .{ .name = "value", .dtype = Dtype.f64 },
        // .{ .name = "label", .dtype = Dtype.string },
    };
    var schema = try Schema.init(std.testing.allocator);
    for (fields) |f| {
        try schema.addField(f);
    }

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    var col = table.getColumn("id").?;
    for (0..col.size()) |i| {
        try col.append(Scalar{ .u32 = @truncate(i) });
    }

    var reflected_col = try col.reflect(Dtype.u32);

    for (0..reflected_col.size()) |i| {
        const value: u32 = @truncate(i);
        try std.testing.expectEqual(value, reflected_col.get(i));
    }
}
