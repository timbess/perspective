const std = @import("std");
const builtin = @import("builtin");
const column = @import("columns.zig");
const root = @import("root.zig");
const Schema = root.Schema;
const Dtype = root.Dtype;
const Scalar = root.Scalar;
const Table = @import("table.zig").Table;

pub fn main() !void {
    var allocator: std.mem.Allocator = undefined;

    switch (builtin.mode) {
        .Debug => {
            allocator = std.heap.c_allocator;
        },
        else => {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            allocator = gpa.allocator();
            defer {
                std.debug.assert(!gpa.detectLeaks());
                _ = gpa.deinit();
            }
        },
    }
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const schema = Schema{
        .fields = &[_]root.Field{
            .{ .name = "x", .dtype = Dtype.u32 },
            .{ .name = "y", .dtype = Dtype.f64 },
            .{ .name = "label", .dtype = Dtype.string },
        },
    };

    var table = try Table.init(allocator, "test_table", schema);
    defer table.deinit();

    try table.appendRow(&[_]Scalar{
        Scalar{ .u32 = 42 },
        Scalar{ .f64 = 10.5 },
        Scalar{ .string = "hello" },
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const columns = try table.sliceRows(arena.allocator(), 0, 1);

    for (columns) |*c| {
        try stdout.print("Col: {s}\n", .{c.column_name});
        for (0..c.data.len) |i| {
            const scalar = c.data.get(i);
            switch (scalar) {
                .string => |s| try stdout.print("{s}", .{s}),
                inline else => |s| try stdout.print("{any}\n", .{s}),
            }
        }
    }

    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
