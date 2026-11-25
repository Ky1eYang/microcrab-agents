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

// The witness is historical; remove exactly the retired tool, its media
// budget, and its permission in each mode before comparing with the guest.
fn removeImage(agent: *Value) !void {
    const name = "read_image";
    const tools = &agent.object.getPtr("tools").?.array;
    for (tools.items, 0..) |tool, i| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, name)) continue;
        _ = tools.orderedRemove(i);
        const media = agent.object.get("tool_media_output_bytes").?.object;
        try std.testing.expectEqual(@as(usize, 1), media.count());
        try std.testing.expectEqual(@as(i64, 20 * 1024 * 1024), media.get(name).?.integer);
        try std.testing.expect(agent.object.orderedRemove("tool_media_output_bytes"));
        for (agent.object.getPtr("modes").?.array.items) |*mode| {
            const permissions = &mode.object.getPtr("permissions").?.array;
            for (permissions.items, 0..) |rule, j| {
                const matcher = rule.object.get("tool").?.object;
                if (!std.mem.eql(u8, matcher.get("value").?.string, name)) continue;
                try std.testing.expectEqualStrings("exact", matcher.get("kind").?.string);
                try std.testing.expectEqualStrings("allow", rule.object.get("action").?.string);
                _ = permissions.orderedRemove(j);
                break;
            } else return error.MissingHistoricalPermission;
        }
        return;
    }
    try std.testing.expect(agent.object.get("tool_media_output_bytes") == null);
}

test "Rust catalog parity with explicit Coding tool and policy changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { name: []const u8, host: catalog.HostInfo, catalog: Value };
    const cases = try std.json.parseFromSliceLeaky([]Case, a, @embedFile("fixtures/rust-v0_1_20.json"), .{ .max_value_len = 4096 });
    for (cases) |case| {
        const agent = &case.catalog.array.items[0];
        try removeImage(agent);
        for (agent.object.getPtr("tools").?.array.items) |*tool| {
            const name = tool.object.get("name").?.string;
            if (std.mem.eql(u8, name, "grep")) {
                const properties = tool.object.getPtr("parameters").?.object.getPtr("properties").?;
                try tool.object.put("description", .{ .string = "Search file contents recursively. Returns structured matches, a path:line:text rendering, and a truncated flag." });
                try properties.object.getPtr("pattern").?.object.put("description", .{ .string = "Line-matching regular expression (for example, SessionState|visibility). Set literal: true to search for exact text instead. Nonempty, at most 1024 UTF-8 bytes, no NUL; null is invalid." });
                try properties.object.getPtr("include_glob").?.object.put("description", .{ .string = "Filter files by path relative to root. * does not cross /: *.md selects only direct children, while **/*.{md,wit} selects Markdown and WIT files at any depth. Omit to apply no path filter. Nonempty, at most 1024 UTF-8 bytes, no NUL; null is invalid." });
                continue;
            }
            if (!std.mem.eql(u8, name, "glob")) continue;
            const properties = tool.object.getPtr("parameters").?.object.getPtr("properties").?;
            try properties.object.getPtr("pattern").?.object.put("description", .{ .string = "Match paths relative to root. * does not cross /: *.md matches direct children only; **/*.md matches at any depth. Nonempty, <=1024 UTF-8 bytes, no NUL; null is invalid." });
            _ = properties.object.orderedRemove("include_ignored");
            const schema = try std.json.parseFromSliceLeaky(Value, a,
                \\{"type":"array","items":{"type":"string","minLength":1},"maxItems":4096,"default":"{{var:glob_ignored}}","description":"Concrete workspace-relative paths, not glob rules. A trailing slash excludes a directory subtree; other paths exclude exactly the named node. Omission uses the current visible glob_ignored State; an explicit list replaces it and [] disables filtering. If the default is unavailable or incomplete, supply an explicit list. Null is invalid. Host path restrictions still apply."}
            , .{});
            try properties.object.put("ignored_list", schema);
            try tool.object.put("description", .{ .string = "Find Host entries with a glob. Returns groups of kind (file, directory, symlink), each with a path array. Paths are workspace-relative inside the workspace and absolute outside it when explicit Host filesystem policy permits external access. Empty kinds are omitted. Links are listed without reading or traversing targets. truncated means matching output was omitted; scan_incomplete means a scan limit left part of the search unexamined. An empty incomplete result is not proof of absence." });
        }
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
        var supported = case.host;
        const capabilities = try a.alloc([]const u8, supported.capabilities.len + 1);
        @memcpy(capabilities[0..supported.capabilities.len], supported.capabilities);
        capabilities[supported.capabilities.len] = "file_versions_v1";
        supported.capabilities = capabilities;
        const actual = try catalog.describe(a, supported);
        const decoded = try std.json.parseFromSliceLeaky(Value, a, actual, .{ .max_value_len = 4096 });
        // Compare all unchanged tool definitions and the complete policies. File
        // reference definitions are separately checked against the new grammar.
        const current = decoded.array.items[0].object.get("tools").?.array.items;
        const historical = agent.object.getPtr("tools").?.array.items;
        try std.testing.expectEqual(current.len, historical.len);
        for (historical, current) |*old, new| {
            const name = old.object.get("name").?.string;
            try std.testing.expectEqualStrings(name, new.object.get("name").?.string);
            if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "patch")) {
                const properties = new.object.get("parameters").?.object.get("properties").?;
                const replacement = if (std.mem.eql(u8, name, "patch"))
                    properties.object.get("replacements").?.object.get("items").?.object.get("properties").?
                else
                    properties;
                try std.testing.expectEqualStrings(
                    "UTF-8 text to match literally, not a regular expression. Nonempty, <=1048576 bytes, no NUL; null is invalid.",
                    replacement.object.get("old_string").?.object.get("description").?.string,
                );
            }
            if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "patch") or std.mem.eql(u8, name, "apply_patch")) {
                old.* = new;
            }
        }
        for (agent.object.getPtr("modes").?.array.items, decoded.array.items[0].object.get("modes").?.array.items) |*old, new| {
            try old.object.put("prompt", new.object.get("prompt").?);
        }
        for (vars.object.getPtr("rules").?.array.items, decoded.array.items[0].object.get("variables").?.object.get("rules").?.array.items) |*old, new| {
            if (std.mem.eql(u8, old.object.get("name").?.string, "safe_edits")) try old.object.put("description", new.object.get("description").?);
        }
        if (!equal(case.catalog, decoded)) std.debug.print("catalog differs for {s}\n", .{case.name});
        try std.testing.expect(equal(case.catalog, decoded));
    }
}

test "scoped file reference catalog needs explicit linkage and describes full CAS compatibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = catalog.HostInfo{
        .os_family = .unix,
        .os = "linux",
        .arch = "x86",
        .shell = "bash",
        .path_separator = "/",
        .newline = "\n",
        .capabilities = &.{ "read", "write", "file_mutation" },
    };
    for ([_][]const u8{ "read", "write", "edit", "patch", "apply_patch" }) |tool| try std.testing.expect(!host.offers(tool));
    host.capabilities = &.{ "read", "write", "file_mutation", "file_versions_v1" };
    const wire = try catalog.describe(a, host);
    const rendered = try std.json.parseFromSliceLeaky(Value, a, wire, .{});
    const tools = rendered.array.items[0].object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), tools.len);
    try std.testing.expect(std.mem.startsWith(u8, tools[0].object.get("description").?.string, "Read text with scoped file version references (fv_)."));
    const grammar = "^(fv_([a-f0-9]{16}|[a-f0-9]{20}|[a-f0-9]{24})|[a-fA-F0-9]{64})$";
    try std.testing.expectEqualStrings(grammar, tools[1].object.get("parameters").?.object.get("properties").?.object.get("expected_version").?.object.get("pattern").?.string);
}

test "retired read_image name cannot be advertised as a Host shell" {
    const host = catalog.HostInfo{
        .os_family = .other,
        .os = "other",
        .arch = "x86",
        .shell = "read_image",
        .path_separator = "/",
        .newline = "\n",
        .capabilities = &.{ "shell", "process", "filesystem.stat", "filesystem.open", "filesystem.read", "filesystem.close" },
    };
    try std.testing.expect(host.shellName() == null);
    try std.testing.expect(!host.offers("read_image"));
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
