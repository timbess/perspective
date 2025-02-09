const std = @import("std");
const column = @import("columns.zig");
const root = @import("root.zig");
const Schema = root.Schema;
const Dtype = root.Dtype;
const Scalar = root.Scalar;
const Table = @import("table.zig").Table;

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        std.debug.assert(!allocator.detectLeaks());
        _ = allocator.deinit();
    }
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    stdout.print("Test");

    const schema = Schema{
        .fields = &[_]root.Field{
            .{ .name = "x", .dtype = Dtype.u32 },
            .{ .name = "y", .dtype = Dtype.f64 },
            .{ .name = "label", .dtype = Dtype.string },
        },
    };

    var table = try Table.init(std.testing.allocator, "test_table", schema);
    defer table.deinit();

    table.appendRows([_]Scalar{
        .{ .u32 = 42 },
        .{ .f64 = 10.5 },
        .{ .string = "hello" },
    });

    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
