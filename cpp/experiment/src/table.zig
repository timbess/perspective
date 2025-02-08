const std = @import("std");
const columns = @import("columns.zig");
const Column = columns.Column;

const root = @import("root.zig");
const Dtype = root.Dtype;

pub const Schema = root.Schema;
pub const Scalar = root.Scalar;

pub const Table = struct {
    name: []const u8,
    columns: std.ArrayListUnmanaged(Column),
    name_mapping: std.StringHashMapUnmanaged(Column),
    schema: Schema,
    arena: std.heap.ArenaAllocator,

    fn init(parent_allocator: std.mem.Allocator, name: []const u8, schema: Schema) !Table {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        var local_allocator = arena.allocator();
        var cols = try std.ArrayListUnmanaged(Column).initCapacity(local_allocator, schema.fields.len);
        var name_mapping = std.StringHashMapUnmanaged(Column){};
        try name_mapping.ensureTotalCapacity(local_allocator, @truncate(schema.fields.len));
        for (schema.fields) |field| {
            switch (field.dtype) {
                inline else => |dtype| {
                    const ColType = dtype.coltype();
                    var col: *ColType = try local_allocator.create(ColType);
                    // Bypass local arena to let column's choose how to wrap the top level allocator.
                    col.* = try ColType.init(parent_allocator, field.name);
                    const erased = col.toColumn();
                    cols.appendAssumeCapacity(erased);
                    try name_mapping.put(local_allocator, field.name, erased);
                },
            }
        }

        return .{
            .name = name,
            .columns = cols,
            .name_mapping = name_mapping,
            .arena = arena,
            .schema = schema,
        };
    }

    fn deinit(self: *Table) void {
        for (self.columns.items) |*col| {
            col.deinit();
        }
        self.arena.deinit();
    }

    fn getColumn(self: *Table, name: []const u8) ?Column {
        return self.name_mapping.get(name) orelse null;
    }
};

test "table creation and destruction" {
    const schema = Schema{
        .fields = &[_]root.Field{
            .{ .name = "id", .dtype = Dtype.u32 },
            .{ .name = "value", .dtype = Dtype.f64 },
            .{ .name = "label", .dtype = Dtype.string },
        },
    };

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
