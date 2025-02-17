const std = @import("std");
pub const columns = @import("columns.zig");
const arrow = @import("arrow.zig");
const Table = @import("table.zig").Table;
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .logFn = if (builtin.target.os.tag == .emscripten) log else std.log.defaultLog,
    // .logFn = foo,
};

pub fn customLog(
    comptime message_level: std.log.Level,
    comptime _: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    // const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Choose a CSS style based on the log level.
    const style = switch (message_level) {
        .err => "background: #FF0000; color: #FFFFFF; padding: 2px 4px; border-radius: 3px;",
        .warn => "background: #FFA500; color: #000000; padding: 2px 4px; border-radius: 3px;",
        .info => "background: #1E90FF; color: #FFFFFF; padding: 2px 4px; border-radius: 3px;",
        .debug => "background: #808080; color: #FFFFFF; padding: 2px 4px; border-radius: 3px;",
    };

    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    nosuspend {
        // The format string here:
        //   %c -> applies the given CSS style (for the [LEVEL] label)
        //   %s -> the log level text
        //   %c -> resets styling (empty string)
        //   %s -> the prefix (e.g. scope information)
        //   %s -> the user-provided message (with its own format specifiers)
        //   \n -> new line at the end.
        writer.print("{s}%c[%s{s}]%c", .{ style, level_txt }) catch return;
        writer.print(format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

extern fn emscripten_console_error([*c]const u8) void;
extern fn emscripten_console_warn([*c]const u8) void;
extern fn emscripten_console_log([*c]const u8) void;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const prefix = level_txt ++ prefix2;

    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintZ(buf[0 .. buf.len - 1], prefix ++ format, args) catch |err| {
        switch (err) {
            error.NoSpaceLeft => {
                emscripten_console_error("log message too long, skipped.");
                return;
            },
        }
    };
    switch (level) {
        .err => emscripten_console_error(@ptrCast(msg.ptr)),
        .warn => emscripten_console_warn(@ptrCast(msg.ptr)),
        else => emscripten_console_log(@ptrCast(msg.ptr)),
    }
}

pub export fn table_from_arrow(data: [*]const u8, data_size: usize) callconv(.C) *anyopaque {
    var arrow_table = arrow.ArrowTable.init(data[0..data_size]);
    defer arrow_table.deinit();
    const table = std.heap.c_allocator.create(Table) catch unreachable;
    table.* = arrow_table.toTable(std.heap.c_allocator, "TEST") catch unreachable;
    return table;
}

pub export fn print_rows(table: ?*anyopaque, num_rows: usize) callconv(.C) void {
    if (table == null) {
        std.log.err("Got null table", .{});
        return;
    }

    const t: *Table = @alignCast(@ptrCast(table.?));

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const cols = t.sliceRows(arena.allocator(), 0, num_rows) catch unreachable;

    for (cols) |*c| {
        // try stdout.print("Col: {s}\n", .{c.column_name});
        std.log.info("Col: {s}", .{c.column_name});
        for (0..c.data.len) |i| {
            const scalar = c.data.get(i);
            switch (scalar) {
                .string => |s| std.log.info("{s}", .{s}),
                inline else => |s| std.log.info("{any}", .{s}),
            }
        }
    }
}

pub const Schema = struct {
    fields: std.ArrayList(Field),

    pub fn init(allocator: std.mem.Allocator) !Schema {
        return .{
            .fields = std.ArrayList(Field).init(allocator),
        };
    }

    pub fn deinit(self: *Schema) void {
        for (self.fields.items) |f| {
            self.fields.allocator.free(f.name);
        }
        self.fields.deinit();
    }

    pub fn removeField(self: *Schema, name: []const u8) ?void {
        for (self.fields.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) {
                self.fields.allocator.free(f.name);
                _ = self.fields.orderedRemove(i);
                return;
            } else {}
        }
        return null;
    }

    pub fn addField(self: *Schema, field: Field) !void {
        try self.fields.append(Field{
            .name = try self.fields.allocator.dupe(u8, field.name),
            .dtype = field.dtype,
        });
    }
};

pub const Field = struct {
    name: []const u8,
    dtype: Dtype,
};

pub const Dtype = enum {
    u32,
    u64,
    i32,
    i64,
    f64,
    date32,
    date64,
    string,

    pub fn maxAlignment() comptime_int {
        var max = std.math.maxInt(comptime_int);
        for (std.meta.fields(@This())) |f| {
            max = @max(@alignOf(f.field_type.underlying()), max);
        }
        return max;
    }

    pub fn underlying(self: Dtype) type {
        return switch (self) {
            .u32 => u32,
            .u64 => u64,
            .i32 => i32,
            .i64 => i64,
            .f64 => f64,
            .date32 => u32,
            .date64 => u64,
            .string => []const u8,
        };
    }

    pub fn coltype(self: Dtype) type {
        return switch (self) {
            .u32 => columns.ScalarColumn(self),
            .u64 => columns.ScalarColumn(self),
            .i32 => columns.ScalarColumn(self),
            .i64 => columns.ScalarColumn(self),
            .f64 => columns.ScalarColumn(self),
            .date32 => columns.ScalarColumn(self),
            .date64 => columns.ScalarColumn(self),
            .string => columns.StringColumn,
        };
    }

    pub fn isScalar(self: Dtype) bool {
        return switch (self) {
            .u32, .u64, .i32, .i64, .f64, .date32, .date64 => true,
            else => false,
        };
    }

    pub fn alignment(self: Dtype) comptime_int {
        return switch (self) {
            inline else => |d| @alignOf(d.underlying()),
        };
    }

    pub fn size(self: Dtype) comptime_int {
        return switch (self) {
            inline else => |d| @sizeOf(d.underlying()),
        };
    }
};

pub const ScalarValue = union(Dtype) {
    u32: u32,
    u64: u64,
    i32: i32,
    i64: i64,
    f64: f64,
    date32: u32, // Days since UNIX epoch
    date64: u64, // Milliseconds ^
    string: []const u8,
};

pub const Scalar = struct {
    status: columns.DeltaStatus,
    inner: ScalarValue,

    pub fn defined(value: ScalarValue) Scalar {
        return Scalar{
            .inner = value,
            .status = .defined,
        };
    }
};

pub const PspError = error{
    InvalidDtype,
    InvalidStatus,
    InvalidColumnCount,
    ColumnSizeMismatch,
};

test {
    _ = @import("columns.zig");
    _ = @import("table.zig");
    _ = @import("arrow.zig");
    _ = @import("bitvector.zig");
}
