const std = @import("std");
const catalog = @import("catalog.zig");
const Value = std.json.Value;

fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |value| blk: {
            if (value.items.len != b.array.items.len) break :blk false;
            for (value.items, b.array.items) |left, right| if (!equal(left, right)) break :blk false;
            break :blk true;
        },
        .object => |value| blk: {
            if (value.count() != b.object.count()) break :blk false;
            var it = value.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equal(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "Rust catalog parity except the approved plan shell Ask" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { name: []const u8, host: catalog.HostInfo, catalog: Value };
    const cases = try std.json.parseFromSliceLeaky([]Case, a, @embedFile("fixtures/rust-v0_1_20.json"), .{ .max_value_len = 4096 });
    for (cases) |case| {
        if (case.host.shellName()) |name| {
            const modes = case.catalog.array.items[0].object.get("modes").?.array.items;
            const plan = modes[0].object.get("permissions").?.array.items;
            for (plan) |*rule| {
                const tool = rule.object.get("tool").?.object.get("value").?.string;
                if (std.mem.eql(u8, name, tool)) {
                    try std.testing.expectEqualStrings("deny", rule.object.get("action").?.string);
                    try rule.object.put("action", .{ .string = "ask" });
                }
            }
        }
        const actual = try catalog.describe(a, case.host);
        const decoded = try std.json.parseFromSliceLeaky(Value, a, actual, .{ .max_value_len = 4096 });
        if (!equal(case.catalog, decoded)) std.debug.print("catalog differs for {s}\n", .{case.name});
        try std.testing.expect(equal(case.catalog, decoded));
    }
}

test "supplied Host facts are compared structurally with authoritative import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = "{\"os_family\":\"unix\",\"os\":\"linux\",\"arch\":\"x86\",\"shell\":\"x\",\"path_separator\":\"/\",\"newline\":\"\\n\",\"capabilities\":[]}";
    const right = "{\"capabilities\":[],\"newline\":\"\\n\",\"path_separator\":\"/\",\"shell\":\"x\",\"arch\":\"x86\",\"os\":\"linux\",\"os_family\":\"unix\",\"description\":null}";
    _ = try catalog.checkedHost(a, left, right);
    const changed = try std.mem.replaceOwned(u8, a, right, "linux", "other");
    try std.testing.expectError(error.HostInfoMismatch, catalog.checkedHost(a, left, changed));
}
