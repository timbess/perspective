const std = @import("std");
const builtin = @import("builtin");
const column = @import("columns.zig");
const root = @import("root.zig");
const Schema = root.Schema;
const Dtype = root.Dtype;
const Scalar = root.Scalar;
const Table = @import("table.zig").Table;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
    var allocator: std.mem.Allocator = undefined;

    if (builtin.mode == .Debug) {
        gpa = std.heap.GeneralPurposeAllocator(.{}){};
        allocator = gpa.allocator();
    } else {
        allocator = std.heap.c_allocator;
    }

    // defer {
    //     if (builtin.mode == .Debug) {
    //         std.debug.assert(!gpa.detectLeaks());
    //         _ = gpa.deinit();
    //     }
    // }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fs.realpath("./src/superstore.lz4.arrow", &path_buffer);

    const f = try std.fs.openFileAbsolute(path, .{});

    const bytes = try f.readToEndAlloc(allocator, std.math.maxInt(u64));
    defer allocator.free(bytes);
    var table = try Table.fromArrow(allocator, "test", bytes);
    defer table.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const columns = try table.sliceRows(arena.allocator(), 0, 10);

    for (columns) |*c| {
        try stdout.print("Col: {s}\n", .{c.column_name});
        for (0..c.data.len) |i| {
            const scalar = c.data.get(i);
            switch (scalar) {
                .string => |s| try stdout.print("{s}\n", .{s}),
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
