const std = @import("std");
const patch = @import("apply_patch.zig");
const t = @import("coding_abi").types;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const version = "ab" ** 32;
const upper_version = "AB" ** 32;
const file_bytes = 1_048_576;
const ErrorCode = @TypeOf(@as(t.OperationError, undefined).code);

const Input = struct { path: []const u8, expected: Expected };
const Expected = union(enum) {
    missing: void,
    version: []const u8,

    pub fn jsonStringify(self: Expected, json: anytype) !void {
        switch (self) {
            .missing => try json.write("missing"),
            .version => |v| try json.write(.{ .version = v }),
        }
    }
};

const Event = union(enum) {
    read: []const u8,
    preflight: usize,
    capture: []const u8,
    mutate: t.FileMutation,
};
const Mock = struct {
    events: std.BoundedArray(Event, 256) = .{},
    capture_count: usize = 0,
    mutation_count: usize = 0,
    source: t.ReadOutput = .{ .content = "old\n", .start_line = 1, .next_line = null, .truncated = false, .version = version },
    read_error: ?t.OperationError = null,
    preflight_error: ?t.OperationError = null,
    wrong_count: bool = false,
    normalized_first: ?[]const u8 = null,
    fail_capture: ?usize = null,
    fail_mutation: ?struct { index: usize, code: ErrorCode } = null,
    partial_move: bool = false,
    mutation_message: []const u8 = "admitted mutation error",

    pub fn read(self: *Mock, _: Allocator, request: t.ReadRequest) t.Result(t.ReadOutput, t.OperationError) {
        testing.expectEqual(@as(u64, 1), request.offset_line) catch unreachable;
        testing.expectEqual(@as(u64, 10_000), request.max_lines) catch unreachable;
        testing.expectEqual(@as(u64, file_bytes), request.max_bytes) catch unreachable;
        self.events.appendAssumeCapacity(.{ .read = request.path });
        if (self.read_error) |err| return .{ .err = err };
        return .{ .ok = self.source };
    }

    pub fn preflight(self: *Mock, scratch: Allocator, requests: []const t.FileMutation) t.Result([]const t.FileMutation, t.OperationError) {
        self.events.appendAssumeCapacity(.{ .preflight = requests.len });
        if (self.preflight_error) |err| return .{ .err = err };
        if (self.wrong_count) return .{ .ok = &.{} };
        if (self.normalized_first) |path| {
            const normalized = scratch.dupe(t.FileMutation, requests) catch unreachable;
            normalized[0].write.path = path;
            return .{ .ok = normalized };
        }
        return .{ .ok = requests };
    }

    pub fn capture(self: *Mock, _: Allocator, path: []const u8, max_bytes: u64) t.Result(void, t.OperationError) {
        testing.expectEqual(@as(u64, file_bytes), max_bytes) catch unreachable;
        self.events.appendAssumeCapacity(.{ .capture = path });
        self.capture_count += 1;
        if (self.fail_capture == self.capture_count) return .{ .err = .{ .code = .limit, .message = "evidence quota exhausted" } };
        return .{ .ok = {} };
    }

    pub fn mutate(self: *Mock, _: Allocator, request: t.FileMutation) t.Result(t.MutationOutput, t.OperationError) {
        self.events.appendAssumeCapacity(.{ .mutate = request });
        self.mutation_count += 1;
        if (self.fail_mutation) |fault| if (fault.index == self.mutation_count) {
            return .{ .err = .{ .code = fault.code, .message = self.mutation_message } };
        };
        return .{ .ok = switch (request) {
            .write => |write| .{ .version = version, .bytes = write.content.len, .source_removed = false, .destination_written = true, .diagnostic = null },
            .delete => .{ .version = null, .bytes = 0, .source_removed = true, .destination_written = false, .diagnostic = null },
            .move => |move| .{ .version = version, .bytes = move.content.len, .source_removed = !self.partial_move, .destination_written = true, .diagnostic = if (self.partial_move) "could not remove source" else null },
        } };
    }
};

fn invoke(scratch: Allocator, host: *Mock, text: []const u8, conditions: []const Input) !patch.Result {
    const args = try std.json.stringifyAlloc(scratch, .{ .patch = text, .preconditions = conditions }, .{});
    return patch.invokeWith(scratch, args, host);
}

fn failure(result: patch.Result, code: []const u8, contains: []const u8) !t.ToolFailure {
    if (result != .err) {
        std.debug.print("expected error; got {s}\n", .{result.ok});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(code, result.err.code);
    try testing.expect(!result.err.retryable);
    try testing.expect(std.mem.indexOf(u8, result.err.message, contains) != null);
    return result.err;
}

fn success(scratch: Allocator, result: patch.Result) !std.json.Value {
    if (result != .ok) {
        std.debug.print("unexpected {s}: {s}\n", .{ result.err.code, result.err.message });
        return error.TestUnexpectedResult;
    }
    return std.json.parseFromSliceLeaky(std.json.Value, scratch, result.ok, .{});
}

fn field(value: std.json.Value, key: []const u8) std.json.Value {
    return value.object.get(key).?;
}

fn expectStatus(receipts: []const std.json.Value, index: usize, status: []const u8, paths: []const []const u8) !void {
    const item = receipts[index];
    try testing.expectEqual(@as(i64, @intCast(index + 1)), field(item, "operation").integer);
    try testing.expectEqualStrings(status, field(item, "status").string);
    const found_paths = field(item, "paths").array.items;
    try testing.expectEqual(paths.len, found_paths.len);
    for (paths, found_paths) |expected, actual| try testing.expectEqualStrings(expected, actual.string);
}

const add_a = "*** Begin Patch\n*** Add File: a\n+x\n*** End Patch";
const add_conditions = [_]Input{.{ .path = "a", .expected = .missing }};
const update_conditions = [_]Input{.{ .path = "a", .expected = .{ .version = version } }};
const triple = "*** Begin Patch\n*** Add File: a\n+x\n*** Add File: b\n+y\n*** Add File: c\n+z\n*** End Patch\n";
const triple_conditions = [_]Input{
    .{ .path = "a", .expected = .missing }, .{ .path = "b", .expected = .missing }, .{ .path = "c", .expected = .missing },
};

test "JSON patch arguments require exact keys, string types, and expected tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var host: Mock = .{};
    for ([_][]const u8{
        "null",                                                                              "[]",                                                                         "{}",                                                                                     "{\"patch\":\"a\",\"patch\":\"b\",\"preconditions\":[]}",
        "{\"patch\":[],\"preconditions\":[]}",                                               "{\"patch\":\"abc\",\"preconditions\":{}}",                                   "{\"patch\":\"abc\",\"preconditions\":[],\"extra\":1}",                                   "{\"patch\":\"abc\",\"preconditions\":[{\"path\":\"a\",\"expected\":{\"missing\":{}}}]}",
        "{\"patch\":\"abc\",\"preconditions\":[{\"path\":\"a\",\"expected\":\"version\"}]}", "{\"patch\":\"abc\",\"preconditions\":[{\"path\":\"a\",\"expected\":null}]}", "{\"patch\":\"abc\",\"preconditions\":[{\"path\":\"a\",\"expected\":{\"version\":[]}}]}", "{\"patch\":\"abc\",\"preconditions\":[{\"path\":\"a\",\"expected\":{\"version\":\"a\",\"version\":\"b\"}}]}",
    }) |args| _ = try failure(patch.invokeWith(arena.allocator(), args, &host), "invalid_request", "invalid patch arguments");
    try testing.expectEqual(@as(usize, 0), host.events.len);
}

test "strict LF grammar permits CR payload and explicit EOF, rejects malformed patches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = "\\ No newline at end of file\n";
    var host: Mock = .{};
    for ([_][]const u8{
        "*** Begin Patch\r\n*** Add File: a\n+x\n*** End Patch\n",
        "*** Begin Patch\n*** Add File: a\n+x\n*** End Patch\r\n",
        "*** Begin Patch\n*** Add File: a\n+x\n*** End Patch\n\n",
        "*** Begin Patch\n*** Add File: a\n+\x00\n*** End Patch\n",
        "*** Begin Patch\n*** Add File: a\n+x\n" ++ marker ++ marker ++ "*** End Patch\n",
        "*** Begin Patch\n*** Add File: a\nbad\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: a\n@@ -1 +1 @@\n-a\n+b\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: a\n@@\n🦀bad\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: a\n@@\n+only\n*** End Patch\n",
        "*** Begin Patch\n*** Update File: a\n*** End Patch\n",
        "*** Begin Patch\n*** Delete File: a\n+x\n*** End Patch\n",
    }) |bad| _ = try failure(try invoke(a, &host, bad, &add_conditions), "invalid_request", "");
    try testing.expectEqual(@as(usize, 0), host.events.len);

    host.source.content = "old\r\n";
    const text = "*** Begin Patch\n*** Update File: a\n@@\n-old\r\n+new\r\n" ++ marker ++ "*** End Patch";
    const out = try success(a, try invoke(a, &host, text, &update_conditions));
    try testing.expect(field(out, "complete").bool);
    try testing.expect(!field(out, "replay_safe").bool);
    try testing.expectEqualStrings("new\r", host.events.slice()[3].mutate.write.content);
}

test "bounds reject excess arguments, patch, operations, hunks, preconditions and per-file result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{};
    const oversized = try a.alloc(u8, 4_300_001);
    @memset(oversized, ' ');
    _ = try failure(patch.invokeWith(a, oversized, &host), "invalid_request", "argument byte limit");
    _ = try failure(try invoke(a, &host, oversized[0 .. 4 * file_bytes + 1], &add_conditions), "invalid_request", "4194304 bytes");
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n" ++ ("*** Delete File: a\n" ** 33) ++ "*** End Patch\n", &update_conditions), "invalid_request", "32 operations");
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n*** Update File: a\n" ++ ("@@\n-old\n+new\n" ** 65) ++ "*** End Patch\n", &update_conditions), "invalid_request", "64 hunks");
    _ = try failure(try invoke(a, &host, add_a, &([_]Input{add_conditions[0]} ** 65)), "invalid_request", "1..=64");
    const add = try std.fmt.allocPrint(a, "*** Begin Patch\n*** Add File: a\n+{s}\n*** End Patch\n", .{oversized[0..file_bytes]});
    _ = try failure(try invoke(a, &host, add, &add_conditions), "invalid_request", "1048576 bytes");
    try testing.expectEqual(@as(usize, 0), host.events.len);
}

test "aggregate source and result budgets are independent and enforced before preflight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try a.alloc(u8, file_bytes);
    @memset(content, 'x');
    var host: Mock = .{};
    host.source.content = content;
    const deletes = "*** Begin Patch\n*** Delete File: a\n*** Delete File: b\n*** Delete File: c\n*** Delete File: d\n*** Delete File: e\n*** End Patch";
    const delete_conditions = [_]Input{
        update_conditions[0],
        .{ .path = "b", .expected = .{ .version = version } },
        .{ .path = "c", .expected = .{ .version = version } },
        .{ .path = "d", .expected = .{ .version = version } },
        .{ .path = "e", .expected = .{ .version = version } },
    };
    _ = try failure(try invoke(a, &host, deletes, &delete_conditions), "invalid_request", "aggregate source bytes");
    try testing.expectEqual(@as(usize, 5), host.events.len);
    for (host.events.constSlice()) |event| try testing.expect(event == .read);

    const moves = "*** Begin Patch\n*** Update File: a\n*** Move to: A\n*** Update File: b\n*** Move to: B\n*** Update File: c\n*** Move to: C\n*** Update File: d\n*** Move to: D\n";
    const move_conditions = delete_conditions[0..4].* ++ [_]Input{
        .{ .path = "A", .expected = .missing },
        .{ .path = "B", .expected = .missing },
        .{ .path = "C", .expected = .missing },
        .{ .path = "D", .expected = .missing },
    };
    host.events.len = 0;
    _ = try failure(try invoke(a, &host, moves ++ "*** Add File: five\n+new\n*** End Patch", &(move_conditions ++ [_]Input{.{ .path = "five", .expected = .missing }})), "invalid_request", "aggregate result bytes");
    try testing.expectEqual(@as(usize, 4), host.events.len);
    for (host.events.constSlice()) |event| try testing.expect(event == .read);

    host.events.len = 0;
    const out = try success(a, try invoke(a, &host, moves ++ "*** End Patch", &move_conditions));
    try testing.expect(field(out, "complete").bool);
    try testing.expectEqual(@as(usize, 4), host.mutation_count);
}

test "all paths require specific and exactly consumed preconditions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{};
    const add_b: Input = .{ .path = "b", .expected = .missing };
    const update_b: Input = .{ .path = "b", .expected = .{ .version = version } };
    const move = "*** Begin Patch\n*** Update File: a\n*** Move to: b\n*** End Patch";
    _ = try failure(try invoke(a, &host, add_a, &update_conditions), "invalid_request", "require missing");
    _ = try failure(try invoke(a, &host, add_a, &.{add_b}), "invalid_request", "missing precondition for a");
    _ = try failure(try invoke(a, &host, add_a, &.{ add_conditions[0], add_b }), "invalid_request", "unused precondition");
    _ = try failure(try invoke(a, &host, add_a, &.{ add_conditions[0], add_conditions[0] }), "invalid_request", "duplicate precondition");
    _ = try failure(try invoke(a, &host, add_a, &.{.{ .path = "a", .expected = .{ .version = "g" ** 64 } }}), "invalid_request", "SHA-256");
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n*** Delete File: a\n*** End Patch", &add_conditions), "invalid_request", "requires a version");
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n*** Add File: a\n*** Add File: a\n*** End Patch", &add_conditions), "invalid_request", "duplicate patch source");
    try testing.expectEqual(@as(usize, 0), host.events.len);
    _ = try failure(try invoke(a, &host, move, &update_conditions), "invalid_request", "destination requires its own missing");
    _ = try failure(try invoke(a, &host, move, &.{ update_conditions[0], update_b }), "invalid_request", "destination requires its own missing");
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n*** Add File: b\n*** Update File: a\n*** Move to: b\n*** End Patch", &.{ update_conditions[0], add_b }), "invalid_request", "destination collides");
    for (host.events.constSlice()) |event| try testing.expect(event == .read);
}

test "bounded reads, literal uniqueness, and stale versions stop before preflight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{ .source = .{ .content = "old\n", .start_line = 1, .next_line = 2, .truncated = false, .version = version } };
    const text = "*** Begin Patch\n*** Update File: a\n@@\n-old\n+new\n*** End Patch";
    _ = try failure(try invoke(a, &host, text, &update_conditions), "invalid_request", "requires a complete read");
    host.source.next_line = null;
    host.source.version = "ba" ** 32;
    _ = try failure(try invoke(a, &host, text, &update_conditions), "conflict", "stale source version");
    host.source.version = version;
    host.source.content = "absent\n";
    _ = try failure(try invoke(a, &host, text, &update_conditions), "invalid_request", "zero literal matches");
    host.source.content = "old\nold\n";
    _ = try failure(try invoke(a, &host, text, &update_conditions), "invalid_request", "ambiguous: 2 matches");
    host.source.content = "ééé";
    _ = try failure(try invoke(a, &host, "*** Begin Patch\n*** Update File: a\n@@\n-éé\n\\ No newline at end of file\n+x\n*** End Patch", &update_conditions), "invalid_request", "overlapping matches");
    host.read_error = .{ .code = .timeout, .message = "operation deadline" };
    const result = try failure(try invoke(a, &host, text, &update_conditions), "timeout", "operation deadline");
    try testing.expect(result.kind == .timeout);
    for (host.events.constSlice()) |event| try testing.expect(event == .read);
}

test "late hunk failure, asymmetric Host preflight and capture rejection cannot mutate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{};
    const text = "*** Begin Patch\n*** Add File: b\n+x\n*** Update File: a\n@@\n-not present\n+new\n*** End Patch";
    _ = try failure(try invoke(a, &host, text, &.{ .{ .path = "b", .expected = .missing }, update_conditions[0] }), "invalid_request", "operation 2, hunk 1");
    try testing.expectEqual(@as(usize, 1), host.events.len);
    try testing.expect(host.events.slice()[0] == .read);

    host = .{ .preflight_error = .{ .code = .conflict, .message = "alias collision" } };
    const collision = "*** Begin Patch\n*** Add File: a\n+x\n*** Add File: ./a\n+y\n*** End Patch";
    _ = try failure(try invoke(a, &host, collision, &.{ add_conditions[0], .{ .path = "./a", .expected = .missing } }), "conflict", "alias collision");
    try testing.expectEqual(@as(usize, 1), host.events.len);
    try testing.expectEqual(@as(usize, 2), host.events.slice()[0].preflight);

    host = .{ .wrong_count = true };
    _ = try failure(try invoke(a, &host, add_a, &add_conditions), "invalid_request", "changed operation count");
    try testing.expectEqual(@as(usize, 0), host.capture_count);
    host = .{ .fail_capture = 3 };
    _ = try failure(try invoke(a, &host, triple, &triple_conditions), "limit", "evidence quota exhausted");
    try testing.expectEqual(@as(usize, 3), host.capture_count);
    try testing.expectEqual(@as(usize, 0), host.mutation_count);
}

test "ordered mixed patch uses Host-normalized paths, lowercase versions and exact receipts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{ .normalized_first = "/norm/added" };
    const text = "*** Begin Patch\n*** Add File: added\n+new\n*** Update File: updated\n@@\n-old\n+step\n@@\n-step\n+updated\n+extra\n*** Delete File: deleted\n*** Update File: moved\n*** Move to: destination\n@@\n-old\n+moved\n*** End Patch\n";
    const args = [_]Input{
        .{ .path = "added", .expected = .missing },                        .{ .path = "updated", .expected = .{ .version = upper_version } },
        .{ .path = "deleted", .expected = .{ .version = upper_version } }, .{ .path = "moved", .expected = .{ .version = upper_version } },
        .{ .path = "destination", .expected = .missing },
    };
    const out = try success(a, try invoke(a, &host, text, &args));
    try testing.expect(field(out, "complete").bool);
    try testing.expect(!field(out, "replay_safe").bool);
    const receipts = field(out, "receipts").array.items;
    try expectStatus(receipts, 0, "committed", &.{"/norm/added"});
    try expectStatus(receipts, 1, "committed", &.{"updated"});
    try expectStatus(receipts, 2, "committed", &.{"deleted"});
    try expectStatus(receipts, 3, "committed", &.{ "moved", "destination" });
    try testing.expectEqual(@as(i64, 1), field(field(receipts[1], "line_counts"), "before_lines").integer);
    try testing.expectEqual(@as(i64, 2), field(field(receipts[1], "line_counts"), "after_lines").integer);
    try testing.expect(field(field(receipts[2], "outcome"), "version") == .null);
    try testing.expect(field(field(receipts[2], "outcome"), "diagnostic") == .null);
    try testing.expectEqual(@as(usize, 0), field(receipts[3], "evidence_errors").array.items.len);
    const events = host.events.constSlice();
    try testing.expectEqual(@as(usize, 4), events[3].preflight);
    for ([_][]const u8{ "/norm/added", "updated", "deleted", "moved", "destination" }, events[4..9]) |path, event| try testing.expectEqualStrings(path, event.capture);
    try testing.expectEqualStrings("/norm/added", events[9].mutate.write.path);
    try testing.expectEqualStrings("updated\nextra\n", events[11].mutate.write.content);
    try testing.expectEqualStrings(version, events[11].mutate.write.precondition.version);
    try testing.expectEqualStrings(version, events[13].mutate.delete.expected_version);
    try testing.expectEqualStrings(version, events[15].mutate.move.expected_version);
    try testing.expectEqualStrings("moved\n", events[15].mutate.move.content);
    try testing.expectEqualStrings("moved", events[16].capture);
    try testing.expectEqualStrings("destination", events[17].capture);
}

test "unchanged write still preflights but neither captures nor mutates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{ .normalized_first = "/norm/a" };
    const text = "*** Begin Patch\n*** Update File: a\n@@\n old\n*** End Patch";
    const out = try success(a, try invoke(a, &host, text, &update_conditions));
    const receipts = field(out, "receipts").array.items;
    try expectStatus(receipts, 0, "unchanged", &.{"/norm/a"});
    try testing.expect(field(out, "complete").bool);
    try testing.expectEqual(@as(usize, 3), receipts[0].object.count());
    try testing.expectEqual(@as(usize, 2), host.events.len);
    try testing.expectEqual(@as(usize, 1), host.events.slice()[1].preflight);
}

test "commit prefix retains exact typed failure or uncertainty, without replay" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (std.enums.values(ErrorCode)) |code| {
        const message = "🦀" ** 513;
        var host: Mock = .{ .fail_mutation = .{ .index = 2, .code = code }, .mutation_message = message };
        const out = try success(a, try invoke(a, &host, triple, &triple_conditions));
        try testing.expect(!field(out, "complete").bool);
        try testing.expect(!field(out, "replay_safe").bool);
        const receipts = field(out, "receipts").array.items;
        try expectStatus(receipts, 0, "committed", &.{"a"});
        const status = switch (code) {
            .denied, .invalid_request, .unsupported, .conflict, .limit => "failed",
            .io, .timeout, .cancelled => "uncertain",
        };
        try expectStatus(receipts, 1, status, &.{"b"});
        try expectStatus(receipts, 2, "not_started", &.{"c"});
        const err = field(receipts[1], "error");
        try testing.expectEqualStrings(@tagName(code), field(err, "code").string);
        try testing.expectEqualStrings("🦀" ** 512, field(err, "message").string);
        try testing.expectEqual(@as(usize, 2), host.mutation_count);
        try testing.expectEqual(@as(usize, 4), host.capture_count);
    }
}

test "post-commit capture error and partial move retain receipt and stop suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: Mock = .{ .fail_capture = 4 };
    const out = try success(a, try invoke(a, &host, triple, &triple_conditions));
    const receipts = field(out, "receipts").array.items;
    try expectStatus(receipts, 0, "committed", &.{"a"});
    try expectStatus(receipts, 1, "not_started", &.{"b"});
    try testing.expectEqualStrings("limit", field(field(receipts[0], "evidence_errors").array.items[0], "code").string);
    try testing.expectEqual(@as(usize, 1), host.mutation_count);

    host = .{ .partial_move = true, .fail_capture = 4 };
    const text = "*** Begin Patch\n*** Update File: a\n*** Move to: target\n*** Delete File: later\n*** End Patch\n";
    const args = [_]Input{ update_conditions[0], .{ .path = "target", .expected = .missing }, .{ .path = "later", .expected = .{ .version = version } } };
    const moved = try success(a, try invoke(a, &host, text, &args));
    const move_receipts = field(moved, "receipts").array.items;
    try expectStatus(move_receipts, 0, "committed", &.{ "a", "target" });
    try expectStatus(move_receipts, 1, "not_started", &.{"later"});
    const move = field(move_receipts[0], "outcome");
    try testing.expect(field(move, "destination_written").bool);
    try testing.expect(!field(move, "source_removed").bool);
    try testing.expectEqualStrings("could not remove source", field(move, "diagnostic").string);
    try testing.expectEqual(@as(usize, 1), host.mutation_count);
    try testing.expectEqual(@as(usize, 5), host.capture_count);
    try testing.expect(!field(moved, "complete").bool);
}
