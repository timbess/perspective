const std = @import("std");
const columns = @import("columns.zig");
const arrow_ffi = @cImport({
    @cInclude("ffi/bridge.h");
});

test "Read Arrow" {
    const file: []const u8 = @embedFile("./test.arrow");

    const arrow = arrow_ffi.InitArrow(file.ptr, file.len);
    defer arrow_ffi.FreeArrow(arrow);

    var column_data: [3]u32 = undefined;
    arrow_ffi.ReadInto(arrow, "x", &column_data, @sizeOf(@TypeOf(column_data)));

    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3 }, column_data[0..3]);
}
