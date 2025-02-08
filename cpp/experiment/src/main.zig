const std = @import("std");
const column = @import("columns.zig");
const root = @import("root.zig");

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        std.debug.assert(!allocator.detectLeaks());
        _ = allocator.deinit();
    }
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var col = try column.ScalarColumn(root.Dtype.u32).init(allocator.allocator(), "u32_column");
    defer col.deinit();

    for (0..10) |i| {
        const value: u32 = @intCast(i);
        try col.append(value);
    }

    try stdout.print("Column size: {d}\n", .{col.size()});
    try stdout.print("Column dtype: {s}\n", .{@tagName(col.dtype)});

    for (0..col.size()) |i| {
        const value = col.get(i);
        try stdout.print("Value at index {d}: {?}\n", .{ i, value });
    }

    // Test out strings
    var arena = std.heap.ArenaAllocator.init(allocator.allocator());
    defer arena.deinit();

    var strCol = try column.StringColumn().init(allocator.allocator(), "test_column");
    defer strCol.deinit();

    try strCol.append("hello");
    try strCol.append("world");
    try strCol.append("hello");
    try strCol.append("zig");

    for (0..strCol.size()) |i| {
        const value = strCol.get(i);
        try stdout.print("String at index {d}: {s}\n", .{ i, value.? });
    }

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
