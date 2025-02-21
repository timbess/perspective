const std = @import("std");
const builtin = @import("builtin");
const columns = @import("columns.zig");
const arrow_mod = @import("arrow.zig");
const Column = columns.Column;

const root = @import("root.zig");
const Dtype = root.Dtype;
const PspError = root.PspError;
const Field = root.Field;
const Window = root.Window;

pub const Schema = root.Schema;
pub const Scalar = root.Scalar;
pub const ScalarValue = root.ScalarValue;

const ScalarArray = std.MultiArrayList(ScalarValue);
pub const ColumnSlice = struct {
    column_name: []const u8,
    data: ScalarArray,
    status: std.ArrayList(columns.DeltaStatus),
};

pub const PrimaryKey = struct {
    column: Column,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !PrimaryKey {
        const pkey_column = try allocator.create(columns.ScalarColumn(Dtype.u32));
        pkey_column.* = try columns.ScalarColumn(Dtype.u32).init(allocator, name);
        return PrimaryKey{
            .column = pkey_column.toColumn(),
        };
    }

    pub fn deinit(self: *PrimaryKey, allocator: std.mem.Allocator) void {
        self.column.deinit(allocator);
    }

    pub fn initExistingColumn(column: Column) PrimaryKey {
        return PrimaryKey{
            .column = column,
        };
    }
};

pub const DEFAULT_PKEY_NAME = "psp_pkey";

pub const Table = struct {
    name: []const u8,
    primary_key: PrimaryKey,
    columns: std.ArrayListUnmanaged(Column),
    name_mapping: std.StringHashMapUnmanaged(Column),
    schema: Schema,
    allocator: std.mem.Allocator,
    size: usize,

    const Self = @This();

    pub fn fromArrow(allocator: std.mem.Allocator, name: []const u8, arrow_bytes: []const u8) !Self {
        var arrow = arrow_mod.ArrowTable.init(arrow_bytes);
        defer arrow.deinit();
        return try arrow.toTable(allocator, name);
    }

    pub fn init(allocator: std.mem.Allocator, name: []const u8, schema: Schema) !Self {
        return initWithIndex(allocator, name, schema, DEFAULT_PKEY_NAME);
    }

    pub fn initWithIndex(allocator: std.mem.Allocator, name: []const u8, schema: Schema, index: []const u8) !Self {
        var cols = try std.ArrayListUnmanaged(Column).initCapacity(allocator, schema.fields.items.len);
        var name_mapping = std.StringHashMapUnmanaged(Column){};
        try name_mapping.ensureTotalCapacity(allocator, @truncate(schema.fields.items.len));
        errdefer name_mapping.deinit(allocator);
        for (schema.fields.items) |field| {
            switch (field.dtype) {
                inline else => |dtype| {
                    const ColType = dtype.coltype();
                    var col: *ColType = try allocator.create(ColType);
                    errdefer allocator.destroy(col);
                    // Bypass local arena to let column's choose how to wrap the top level allocator.
                    col.* = try ColType.init(allocator, field.name);
                    errdefer col.deinit();
                    const erased = col.toColumn();
                    cols.appendAssumeCapacity(erased);
                    try name_mapping.put(allocator, field.name, erased);
                },
            }
        }

        const pkey = blk: {
            if (name_mapping.get(index)) |c| {
                break :blk PrimaryKey.initExistingColumn(c);
            } else {
                const res = try PrimaryKey.init(allocator, DEFAULT_PKEY_NAME);
                // errdefer res.deinit();

                // try name_mapping.put(allocator, index, res.column);
                // errdefer _ = name_mapping.remove(index);

                // try cols.append(res.column);
                break :blk res;
            }
        };

        return Self{
            .name = try allocator.dupe(u8, name),
            .primary_key = pkey,
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
            col.deinit(self.allocator);
        }
        self.primary_key.deinit(self.allocator);
        self.columns.deinit(self.allocator);
        self.name_mapping.deinit(self.allocator);
    }

    pub fn addColumn(self: *Self, col: Column) !void {
        const col_size = col.size();
        if (self.columns.items.len > 0 and self.size != col_size) {
            return PspError.ColumnSizeMismatch;
        }
        try self.columns.append(self.allocator, col);
        errdefer _ = self.columns.pop();
        try self.name_mapping.put(self.allocator, col.name, col);
        errdefer _ = self.name_mapping.remove(col.name);
        try self.schema.addField(Field{ .name = col.name, .dtype = col.dtype });
        errdefer _ = self.schema.removeField(col.name);
        self.size = col_size;
    }

    pub fn hasColumn(self: *Self, name: []const u8) bool {
        return self.name_mapping.contains(name);
    }

    pub fn getColumn(self: *Self, name: []const u8) ?Column {
        return self.name_mapping.get(name) orelse null;
    }

    inline fn appendRowUnchecked(self: *Self, row: []const Scalar) !void {
        const old_size = self.size;
        // Cleanup partial writes.
        errdefer {
            for (self.columns.items) |*col| {
                col.truncateToSize(old_size);
            }
        }
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

    pub fn appendRowsComp(self: *Self, rows: anytype) !void {
        for (rows) |row| {
            try self.appendRow(&row);
        }
        self.assertSizeOfAllColumns();
    }

    pub fn readWindow(self: *Self, allocator: std.mem.Allocator, window: Window) ![]Scalar {
        const rstart = window.start_row;
        const rend = window.end_row;
        const cstart = window.start_col;
        const cend = window.end_col;
        if (rstart > rend or cstart > cend or rend > self.size or cend > self.columns.items.len) {
            return error.InvalidArgument;
        }

        const results: []Scalar = try allocator.alloc(Scalar, (rend - rstart) * (cend - cstart));

        try columns.readColumnsIntoScalars(self.columns.items[cstart..cend], results, rstart, rend);

        return results;
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
                .status = std.ArrayList(columns.DeltaStatus).init(allocator),
            };
            try r.data.ensureTotalCapacity(allocator, row_count);
            std.log.debug("column: {s}, dtype: {s}", .{ field.name, @tagName(field.dtype) });
        }
        for (self.columns.items, result) |*col, *r| {
            const null_count = col.nullCount();
            if (null_count > 0) {
                try r.status.ensureTotalCapacity(row_count);
                r.status.items.len = row_count;
            }
            switch (col.dtype) {
                inline else => |dtype| {
                    const ColType = dtype.coltype();
                    const typed_col: *ColType = try col.reflect(dtype);

                    if (null_count > 0) {
                        for (rstart..rend, 0..) |i, dst_i| {
                            r.status.items[dst_i] = @enumFromInt(@intFromEnum(typed_col.nulls.getStatus(i)));
                        }
                    }

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
        .{ .name = "label", .dtype = Dtype.string },
    };
    var schema = try Schema.init(std.testing.allocator);
    for (fields) |f| {
        try schema.addField(f);
    }

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    const rows_values: []const []const ScalarValue = &[_][]const ScalarValue{
        &[_]ScalarValue{ .{ .u32 = 1 }, .{ .f64 = 1 }, .{ .string = "foo" } },
        &[_]ScalarValue{ .{ .u32 = 2 }, .{ .f64 = 2 }, .{ .string = "bar" } },
        &[_]ScalarValue{ .{ .u32 = 3 }, .{ .f64 = 3 }, .{ .string = "baz" } },
    };
    var rows: [3][3]Scalar = undefined;
    for (rows_values, 0..) |row_values, row| {
        for (row_values, 0..) |value, col| {
            rows[row][col] = Scalar.defined(value);
        }
    }

    try table.appendRowsComp(rows);

    try std.testing.expectEqual(table.size, 3);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slices = try table.sliceRows(arena.allocator(), 0, 3);

    const names = [_][]const u8{ "id", "value", "label" };

    try std.testing.expect(slices.len == schema.fields.items.len);
    for (slices, names, 0..) |col, expected_name, coli| {
        try std.testing.expectEqualStrings(expected_name, col.column_name);
        try std.testing.expect(col.data.len > 0);
        for (0..col.data.len) |rowi| {
            const data = col.data.get(rowi);
            switch (data) {
                .string => {
                    try std.testing.expectEqualStrings(rows[rowi][coli].inner.string, data.string);
                },
                else => {
                    try std.testing.expectEqual(rows[rowi][coli].inner, data);
                },
            }
        }
    }
}

test "table windows" {
    const fields = [_]root.Field{
        .{ .name = "id", .dtype = Dtype.u32 },
        .{ .name = "value", .dtype = Dtype.f64 },
        .{ .name = "label", .dtype = Dtype.string },
    };
    var schema = try Schema.init(std.testing.allocator);
    for (fields) |f| {
        try schema.addField(f);
    }

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    const rows_values: []const []const ScalarValue = &[_][]const ScalarValue{
        &[_]ScalarValue{ .{ .u32 = 1 }, .{ .f64 = 1 }, .{ .string = "foo" } },
        &[_]ScalarValue{ .{ .u32 = 2 }, .{ .f64 = 2 }, .{ .string = "bar" } },
        &[_]ScalarValue{ .{ .u32 = 3 }, .{ .f64 = 3 }, .{ .string = "baz" } },
    };
    var rows: [3][3]Scalar = undefined;
    for (rows_values, 0..) |row_values, row| {
        for (row_values, 0..) |value, col| {
            rows[row][col] = Scalar.defined(value);
        }
    }

    try table.appendRowsComp(rows);

    try std.testing.expectEqual(table.size, 3);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const window = try table.readWindow(arena.allocator(), Window{
        .start_col = 0,
        .end_col = 3,
        .start_row = 0,
        .end_row = 3,
    });

    try std.testing.expectEqual(window.len, 9);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 1 }), window[0]);
    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .f64 = 1 }), window[1]);
    try std.testing.expectEqualStrings("foo", window[2].inner.string);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 2 }), window[3]);
    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .f64 = 2 }), window[4]);
    try std.testing.expectEqualStrings("bar", window[5].inner.string);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 3 }), window[6]);
    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .f64 = 3 }), window[7]);
    try std.testing.expectEqualStrings("baz", window[8].inner.string);
}

test "table creation and destruction" {
    const fields = [_]root.Field{
        .{ .name = "id", .dtype = Dtype.u32 },
        .{ .name = "value", .dtype = Dtype.f64 },
        .{ .name = "label", .dtype = Dtype.string },
    };
    var schema = try Schema.init(std.testing.allocator);
    for (fields) |f| {
        try schema.addField(f);
    }

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    var col = table.getColumn("id").?;
    for (0..col.size()) |i| {
        try col.append(Scalar.defined(.{ .u32 = @truncate(i) }));
    }

    var reflected_col = try col.reflect(Dtype.u32);

    for (0..reflected_col.size()) |i| {
        const value: u32 = @truncate(i);
        try std.testing.expectEqual(value, reflected_col.get(i));
    }
}
