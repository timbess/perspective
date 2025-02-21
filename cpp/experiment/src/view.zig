const std = @import("std");
const Table = @import("table.zig").Table;
const root_mod = @import("root.zig");
const Dtype = root_mod.Dtype;
const Field = root_mod.Field;
const Schema = root_mod.Schema;
const PspError = root_mod.PspError;
const Scalar = root_mod.Scalar;
const ScalarValue = root_mod.ScalarValue;
const Window = root_mod.Window;
const columns = @import("columns.zig");
const Column = columns.Column;

pub const AggType = enum {
    sum,
    avg,
    min,
    max,
    count,
};

pub const ViewConfig = struct {
    columns: std.ArrayListUnmanaged([]const u8) = .{},
    group_by: std.ArrayListUnmanaged([]const u8) = .{},
    sort_by: std.ArrayListUnmanaged([]const u8) = .{},
    aggregations: std.StringHashMapUnmanaged(AggType) = .{},

    pub fn addColumn(self: *ViewConfig, allocator: std.mem.Allocator, column: []const u8) !void {
        try self.columns.append(allocator, column);
    }

    pub fn addGroupBy(self: *ViewConfig, allocator: std.mem.Allocator, group_by: []const u8) !void {
        try self.group_by.append(allocator, group_by);
    }

    pub fn addSortBy(self: *ViewConfig, allocator: std.mem.Allocator, sort_by: []const u8) !void {
        try self.sort_by.append(allocator, sort_by);
    }

    pub fn addAggregation(self: *ViewConfig, allocator: std.mem.Allocator, column: []const u8, agg_func: AggType) !void {
        try self.aggregations.put(allocator, column, agg_func);
    }

    pub fn deinit(self: *ViewConfig, allocator: std.mem.Allocator) void {
        self.columns.deinit(allocator);
        self.group_by.deinit(allocator);
        self.sort_by.deinit(allocator);
    }
};

pub const View = struct {
    allocator: std.mem.Allocator,
    table: *Table,
    config: ViewConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, table: *Table, config: ViewConfig) !Self {
        return Self{
            .allocator = allocator,
            .table = table,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.config.deinit(self.allocator);
    }

    inline fn isTrivial(self: *Self) bool {
        return self.config.group_by.items.len == 0 and
            self.config.aggregations.count() == 0;
    }

    pub fn readWindow(self: *Self, allocator: std.mem.Allocator, window: Window) ![]Scalar {
        const rstart = window.start_row;
        const rend = window.end_row;
        const cstart = window.start_col;
        const cend = window.end_col;
        if (self.isTrivial()) {
            const out = try allocator.alloc(Scalar, (rend - rstart) * (cend - cstart));
            errdefer allocator.free(out);
            const cols = try allocator.alloc(Column, cend - cstart);
            defer allocator.free(cols);
            for (self.config.columns.items[cstart..cend], 0..) |col_name, i| {
                cols[i] = self.table.getColumn(col_name).?;
            }
            try columns.readColumnsIntoScalars(cols, out, rstart, rend);
            return out;
        } else {
            // TODO: handle non-trivial case
            return error.Unimplemented;
        }
    }
};

test "Test trivial View" {
    const fields = [_]Field{
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

    var config = ViewConfig{};
    try config.addColumn(std.testing.allocator, "id");
    try config.addColumn(std.testing.allocator, "label");
    var view = try View.init(std.testing.allocator, &table, config);
    defer view.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const window = try view.readWindow(arena.allocator(), Window{
        .start_col = 0,
        .end_col = 2,
        .start_row = 0,
        .end_row = 3,
    });

    try std.testing.expectEqual(window.len, 6);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 1 }), window[0]);
    try std.testing.expectEqualStrings("foo", window[1].inner.string);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 2 }), window[2]);
    try std.testing.expectEqualStrings("bar", window[3].inner.string);

    try std.testing.expectEqual(Scalar.defined(ScalarValue{ .u32 = 3 }), window[4]);
    try std.testing.expectEqualStrings("baz", window[5].inner.string);
}

const GroupByTree = struct {
    underlying: *Table,
    grouped_table: Table,

    const Layer = struct {
        children: std.StringHashMap(*Node),
        rollup_idx: usize,
    };
    const Leaf = struct {
        row_idx: usize,
    };
    const Node = union(enum) {
        layer: Layer,
        leaf: Leaf,
    };

    pub fn init(allocator: std.mem.Allocator, table: *Table, group_by_columns: []const []const u8) !GroupByTree {
        for (group_by_columns) |column| {
            if (!table.hasColumn(column)) return PspError.ColumnNotFound;
        }

        return GroupByTree{
            .underlying = table,
            .grouped_table = try Table.init(allocator, table.name ++ "_grouped", table.schema),
        };
    }
};
