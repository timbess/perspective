const std = @import("std");
const builtin = @import("builtin");
const column = @import("columns.zig");
const root = @import("root.zig");
const Schema = root.Schema;
const Dtype = root.Dtype;
const Scalar = root.Scalar;
const Table = @import("table.zig").Table;

const pb = @import("generated_protos/perspective/proto.pb.zig");
const protobuf = @import("protobuf");

pub fn generate_proto_features(filter_ops: *std.ArrayList(pb.GetFeaturesResp.FilterOpsEntry)) !void {
    filter_ops.ensureTotalCapacity(6);

    for (0..filter_ops.capacity) |i| {
        try filter_ops.append(pb.GetFeaturesResp.FilterOpsEntry.init(filter_ops.allocator));
        filter_ops.items[i].value = pb.GetFeaturesResp.ColumnTypeOptions.init(filter_ops.allocator);
    }

    const s = protobuf.ManagedString.static;

    filter_ops.items[0].key = pb.ColumnType.STRING;
    filter_ops.items[0].value.?.options.appendSlice(&[_]protobuf.ManagedString{
        s("=="),
        s("!="),
        s(">"),
        s("<"),
        s(">="),
        s("<="),
        s("begins with"),
        s("contains"),
        s("ends with"),
        s("in"),
        s("not in"),
        s("is not null"),
        s("is null"),
    });
    filter_ops.items[1].key = pb.ColumnType.INTEGER;
    const numeric_ops: []protobuf.ManagedString = &[_]protobuf.ManagedString{
        s("=="),
        s("!="),
        s(">"),
        s("<"),
        s(">="),
        s("<="),
        s("is not null"),
        s("is null"),
    };
    filter_ops.items[1].value.?.options.appendSlice(numeric_ops);
    filter_ops.items[2].key = pb.ColumnType.FLOAT;
    filter_ops.items[2].value.?.options.appendSlice(numeric_ops);
    filter_ops.items[3].key = pb.ColumnType.DATE;
    filter_ops.items[3].value.?.options.appendSlice(numeric_ops);
    filter_ops.items[4].key = pb.ColumnType.DATETIME;
    filter_ops.items[4].value.?.options.appendSlice(numeric_ops);
    filter_ops.items[5].key = pb.ColumnType.BOOLEAN;
    filter_ops.items[5].value.?.options.appendSlice(numeric_ops);
}

const Server = struct {
    allocator: std.mem.Allocator,
    tables: std.StringArrayHashMapUnmanaged(Table),

    const Self = @This();

    pub fn handleRequest(self: *Self, response_allocator: std.mem.Allocator, request: pb.Request) ![]pb.Response {
        if (request.client_req == null) {
            return error.InvalidRequest;
        }
        const responses = try std.ArrayList(pb.Response).initCapacity(response_allocator, 2);
        const lambdas = struct {
            fn pushResp(resp: pb.Response.client_resp_union) !void {
                try responses.append(.{
                    .msg_id = request.msg_id,
                    .entity_id = request.entity_id,
                    .client_resp = resp,
                });
            }
        };

        switch (request.client_req.?) {
            .get_features_req => {
                const feature_resp = pb.GetFeaturesResp.init(response_allocator);
                feature_resp.expressions = true;
                feature_resp.group_by = true;
                feature_resp.expressions = true;
                feature_resp.filter_ops.appendSlice(&[_]pb.GetFeaturesResp.FilterOpsEntry{});
                lambdas.pushResp(.{ .get_features_resp = feature_resp });
            },
            .get_hosted_tables_req => {
                const table_resp = pb.GetHostedTablesResp.init(response_allocator);
                table_resp.table_infos.ensureTotalCapacity(self.tables.count());
                for (self.tables.keys()) |entity_id| {
                    table_resp.table_infos.append(pb.HostedTable{
                        .entity_id = protobuf.ManagedString.managed(entity_id),
                        // TODO: Unmock these
                        // .index = protobuf.ManagedString.static("index"),
                        .limit = std.math.maxInt(u32),
                    });
                }
                lambdas.pushResp(.{ .get_hosted_tables_resp = table_resp });
            },
            .table_make_port_req => |_| {},
            .table_make_view_req => |_| {},
            .table_schema_req => |_| {},
            .table_size_req => |_| {},
            .table_validate_expr_req => |_| {},
            .view_column_paths_req => |_| {},
            .view_delete_req => |_| {},
            .view_dimensions_req => |_| {},
            .view_expression_schema_req => |_| {},
            .view_get_config_req => |_| {},
            .view_schema_req => |_| {},
            .view_to_arrow_req => |_| {},
            .server_system_info_req => |_| {},
            .view_collapse_req => |_| {},
            .view_expand_req => |_| {},
            .view_get_min_max_req => |_| {},
            .view_on_update_req => |_| {},
            .view_remove_on_update_req => |_| {},
            .view_set_depth_req => |_| {},
            .view_to_columns_string_req => |_| {},
            .view_to_csv_req => |_| {},
            .view_to_rows_string_req => |_| {},
            .view_to_ndjson_string_req => |_| {},
            .make_table_req => |_| {},
            .table_delete_req => |_| {},
            .table_on_delete_req => |_| {},
            .table_remove_delete_req => |_| {},
            .table_remove_req => |_| {},
            .table_replace_req => |_| {},
            .table_update_req => |_| {},
            .view_on_delete_req => |_| {},
            .view_remove_delete_req => |_| {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
    var allocator: std.mem.Allocator = undefined;

    if (builtin.mode == .Debug) {
        gpa = std.heap.GeneralPurposeAllocator(.{}){};
        allocator = gpa.allocator();
    } else {
        allocator = std.heap.c_allocator;
    }

    defer {
        if (builtin.mode == .Debug) {
            std.debug.assert(!gpa.detectLeaks());
            _ = gpa.deinit();
        }
    }

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
    const columns = try table.sliceRows(arena.allocator(), 0, 3);

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
