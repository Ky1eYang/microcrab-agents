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

fn rewriteAction(rule: *Value, from: []const u8, to: []const u8) !void {
    try std.testing.expectEqualStrings(from, rule.object.get("action").?.string);
    try rule.object.put("action", .{ .string = to });
}

fn argRule(a: std.mem.Allocator, original: Value, action: []const u8, pointer: []const u8, pattern: []const u8) !Value {
    const source = try std.json.stringifyAlloc(a, .{ .action = action, .args = .{.{ .pointer = pointer, .matcher = .{ .kind = "regex", .value = pattern } }} }, .{});
    var rule = try std.json.parseFromSliceLeaky(Value, a, source, .{});
    for ([_][]const u8{ "agent", "mode", "tool" }) |key| try rule.object.put(key, original.object.get(key).?);
    return rule;
}

test "Rust catalog parity except the approved PLAN specialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { name: []const u8, host: catalog.HostInfo, catalog: Value };
    const cases = try std.json.parseFromSliceLeaky([]Case, a, @embedFile("fixtures/rust-v0_1_20.json"), .{ .max_value_len = 4096 });
    for (cases) |case| {
        const agent = &case.catalog.array.items[0];
        const plan = &agent.object.getPtr("modes").?.array.items[0];
        try std.testing.expectEqualStrings("plan", plan.object.get("name").?.string);
        try plan.object.put("prompt", .{ .string = "Inspect relevant files, identify constraints and explain a concrete plan. Use read and search tools. To save a plan, write a new .md file with Markdown body only and omit expected_version; Coding adds the plan metadata. To revise a plan from this Session, read its version and edit only its Markdown body. Request a mode switch before implementing changes; Runtime remains the permission authority." });
        const vars = agent.object.getPtr("variables").?;
        for (vars.object.getPtr("rules").?.array.items) |*rule| {
            if (std.mem.eql(u8, "plan_first", rule.object.get("name").?.string)) {
                try rule.object.put("description", .{ .string = "Inspect relevant code and form a concrete plan before implementation. In plan mode, use read/search and save or revise plans as Markdown. Runtime is the sole permission authority; never treat a tool schema or mode recommendation as approval." });
            }
        }
        const original = plan.object.get("permissions").?.array.items;
        var expected = std.json.Array.init(a);
        for (original) |original_rule| {
            var rule = original_rule;
            const tool = rule.object.get("tool").?.object.get("value").?.string;
            const actual_shell = if (case.host.shellName()) |name| std.mem.eql(u8, name, tool) else false;
            if (actual_shell or std.mem.eql(u8, "patch", tool)) try rewriteAction(&rule, "deny", "ask");
            try expected.append(rule);
            const write = std.mem.eql(u8, "write", tool);
            if (write or std.mem.eql(u8, "edit", tool)) {
                try std.testing.expectEqualStrings("deny", rule.object.get("action").?.string);
                try expected.append(try argRule(a, rule, "allow", "/path", "(?s:.*)\\.md"));
                if (write) try expected.append(try argRule(a, rule, "deny", "/expected_version", "(?s:.*)"));
            }
        }
        try plan.object.put("permissions", .{ .array = expected });
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
