const std = @import("std");
const text = @import("text.zig");
const types = @import("coding_abi").types;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Result = types.Result;
const Op = types.OperationError;

const lower = "ab" ** 32;
const upper = "AB" ** 32;
const written = "cd" ** 32;
const max = std.math.maxInt(u64);
const Event = enum { read, glob, grep, capture, write };

const Fixture = struct {
    events: std.BoundedArray(Event, 4) = .{},
    capture_paths: std.BoundedArray([]const u8, 2) = .{},
    captured_bytes: u64 = 0,
    read: types.ReadOutput = .{ .content = "", .start_line = 1, .next_line = null, .truncated = false, .version = lower },
    glob: types.GlobOutput = .{ .entries = &.{}, .truncated = false },
    grep: types.GrepOutput = .{ .matches = &.{}, .truncated = false },
    write: types.WriteOutput = .{ .version = written, .bytes = 0 },
    fail_event: ?usize = null,
    failure: Op = .{ .code = .io, .message = "witness" },
    read_request: ?types.ReadRequest = null,
    glob_request: ?types.GlobRequest = null,
    grep_request: ?types.GrepRequest = null,
    write_request: ?types.WriteRequest = null,

    fn note(self: *Fixture, event: Event) ?Op {
        self.events.appendAssumeCapacity(event);
        return if (self.events.len == self.fail_event) self.failure else null;
    }

    fn run(self: *Fixture, scratch: Allocator, name: []const u8, args: []const u8) Result([]const u8, types.ToolFailure) {
        // Run via an injected Host value with the same interface namespaces as
        // abi.host. Only observations on this in-memory fixture are possible.
        return text.invoke(scratch, name, args, .{
            .text_read = Reader{ .fixture = self },
            .text_write = Writer{ .fixture = self },
            .cache_points = Cache{ .fixture = self },
            .glob = Glob{ .fixture = self },
            .grep = Grep{ .fixture = self },
        });
    }
};
const Reader = struct {
    fixture: *Fixture,
    pub fn read(self: @This(), _: Allocator, request: types.ReadRequest) Result(types.ReadOutput, Op) {
        self.fixture.read_request = request;
        if (self.fixture.note(.read)) |err| return .{ .err = err };
        return .{ .ok = self.fixture.read };
    }
};
const Writer = struct {
    fixture: *Fixture,
    pub fn write(self: @This(), scratch: Allocator, request: types.WriteRequest) Result(types.WriteOutput, Op) {
        if (self.fixture.note(.write)) |err| return .{ .err = err };
        // A Host may only borrow invocation inputs during its synchronous call.
        var saved = request;
        saved.content = scratch.dupe(u8, request.content) catch return .{ .err = .{ .code = .io, .message = "fixture allocation failed" } };
        switch (request.precondition) {
            .missing => {},
            .version => |v| saved.precondition = .{ .version = scratch.dupe(u8, v) catch return .{ .err = .{ .code = .io, .message = "fixture allocation failed" } } },
        }
        self.fixture.write_request = saved;
        return .{ .ok = self.fixture.write };
    }
};
const Cache = struct {
    fixture: *Fixture,
    pub fn capture(self: @This(), _: Allocator, path: []const u8, max_bytes: u64) Result(void, Op) {
        self.fixture.capture_paths.appendAssumeCapacity(path);
        self.fixture.captured_bytes = max_bytes;
        if (self.fixture.note(.capture)) |err| return .{ .err = err };
        return .{ .ok = {} };
    }
};
const Glob = struct {
    fixture: *Fixture,
    pub fn glob(self: @This(), _: Allocator, request: types.GlobRequest) Result(types.GlobOutput, Op) {
        self.fixture.glob_request = request;
        if (self.fixture.note(.glob)) |err| return .{ .err = err };
        return .{ .ok = self.fixture.glob };
    }
};
const Grep = struct {
    fixture: *Fixture,
    pub fn grep(self: @This(), _: Allocator, request: types.GrepRequest) Result(types.GrepOutput, Op) {
        self.fixture.grep_request = request;
        if (self.fixture.note(.grep)) |err| return .{ .err = err };
        return .{ .ok = self.fixture.grep };
    }
};

fn expectOk(wanted: []const u8, actual: Result([]const u8, types.ToolFailure)) !void {
    switch (actual) {
        .ok => |value| try testing.expectEqualStrings(wanted, value),
        .err => |err| {
            std.debug.print("unexpected tool failure {s}: {s}\n", .{ err.code, err.message });
            return error.UnexpectedToolFailure;
        },
    }
}

fn expectFailure(code: []const u8, actual: Result([]const u8, types.ToolFailure)) !types.ToolFailure {
    try testing.expect(actual == .err);
    try testing.expectEqualStrings(code, actual.err.code);
    try testing.expect(!actual.err.retryable);
    return actual.err;
}

test "read preserves UTF-8 page, exact LF/CRLF content, version, and saturating one-based numbering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    var host: Fixture = .{};
    host.read = .{ .content = "α\r\n\nlast", .start_line = max - 1, .next_line = max, .truncated = true, .version = upper };
    try expectOk(
        \\{"content":"18446744073709551614\tα\r\n18446744073709551615\t\n18446744073709551615\tlast","start_line":18446744073709551614,"next_line":18446744073709551615,"truncated":true,"version":"
        ++ upper ++ "\"}",
        host.run(s, "read", "{\"path\":\"x\",\"offset_line\":18446744073709551615}"),
    );
    try testing.expectEqualDeep(types.ReadRequest{ .path = "x", .offset_line = max, .max_lines = 200, .max_bytes = 65536 }, host.read_request.?);
    host.read = .{ .content = "", .start_line = 1, .next_line = null, .truncated = false, .version = lower };
    try expectOk("{\"content\":\"\",\"start_line\":1,\"next_line\":null,\"truncated\":false,\"version\":\"" ++ lower ++ "\"}", host.run(s, "read", "{\"path\":\"x\"}"));
    try testing.expectEqual(@as(u64, 1), host.read_request.?.offset_line);
}

test "glob groups Host order by kind; grep includes both view and verbatim match records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    var host: Fixture = .{};
    host.glob = .{ .entries = &.{
        .{ .path = "links/s", .kind = .symlink },
        .{ .path = "foo/z", .kind = .file },
        .{ .path = "dir 2", .kind = .directory },
        .{ .path = "foo/a 以下", .kind = .file },
    }, .truncated = true };
    try expectOk(
        \\{"groups":[{"kind":"file","path":["foo/z","foo/a 以下"]},{"kind":"directory","path":["dir 2"]},{"kind":"symlink","path":["links/s"]}],"truncated":true}
    , host.run(s, "glob", "{\"root\":\".\",\"pattern\":\"**\",\"include_hidden\":true,\"include_directories\":true}"));
    try testing.expectEqualDeep(types.GlobRequest{ .root = ".", .pattern = "**", .include_hidden = true, .include_ignored = false, .include_directories = true, .max_results = 100 }, host.glob_request.?);
    host.glob.entries = &.{};
    try expectOk("{\"groups\":[],\"truncated\":true}", host.run(s, "glob", "{\"root\":\".\",\"pattern\":\"*\"}"));
    host.grep = .{ .matches = &.{ .{ .path = "a:b", .line = 9, .text = "\"x\"" }, .{ .path = "z", .line = 20, .text = "\tγ" } }, .truncated = false };
    try expectOk(
        \\{"content":"a:b:9:\"x\"\nz:20:\tγ","matches":[{"path":"a:b","line":9,"text":"\"x\""},{"path":"z","line":20,"text":"\tγ"}],"truncated":false}
    , host.run(s, "grep", "{\"root\":\"root\",\"pattern\":\"x+\"}"));
    try testing.expectEqualDeep(types.GrepRequest{ .root = "root", .pattern = "x+", .include_glob = null, .case_sensitive = true, .literal = false, .max_matches = 100, .max_bytes = 65536 }, host.grep_request.?);
    _ = try expectFailure("limit", host.run(s, "grep", "{\"root\":\"root\",\"pattern\":\"x+\",\"max_matches\":1}"));
}

test "strict shape, lexical type, bounds, UTF-8 and digest admission occurs before effects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "read", "[]" },
        .{ "read", "{}" },
        .{ "read", "{\"path\":[]}" },
        .{ "read", "{\"path\":[65]}" },
        .{ "read", "{\"path\":null}" },
        .{ "read", "{\"path\":\"\"}" },
        .{ "read", "{\"path\":\"bad\\u0000path\"}" },
        .{ "read", "{\"path\":\"\xFF\"}" },
        .{ "read", "{\"path\":\"\\uD800\"}" },
        .{ "read", "{\"path\":\"a\",\"pa\\u0074h\":\"b\"}" },
        .{ "read", "{\"path\":\"a\",\"secret_field\":\"secret_value\"}" },
        .{ "read", "{\"path\":\"a\"}{}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":\"100\"}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":100.0}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":1e2}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":null}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":true}" },
        .{ "read", "{\"path\":\"a\",\"max_lines\":10001}" },
        .{ "read", "{\"path\":\"a\",\"offset_line\":0}" },
        .{ "read", "{\"path\":\"a\",\"offset_line\":-2}" },
        .{ "read", "{\"path\":\"a\",\"offset_line\":18446744073709551616}" },
        .{ "read", "{\"path\":\"" ++ ("a" ** 4097) ++ "\"}" },
        .{ "glob", "{\"root\":\".\",\"pattern\":\"" ++ ("é" ** 513) ++ "\"}" },
        .{ "glob", "{\"root\":\".\",\"pattern\":\"*\",\"include_hidden\":1}" },
        .{ "glob", "{\"root\":\".\",\"pattern\":\"*\",\"max_results\":4097}" },
        .{ "grep", "{\"root\":\".\",\"pattern\":\"*\",\"include_glob\":null}" },
        .{ "grep", "{\"root\":\".\",\"pattern\":\"*\",\"max_bytes\":1048577}" },
        .{ "write", "{\"path\":\"x\",\"content\":\"\",\"expected_version\":null}" },
        .{ "write", "{\"path\":\"x\",\"content\":\"\",\"expected_version\":\"" ++ ("q" ** 64) ++ "\"}" },
        .{ "edit", "{\"path\":\"x\",\"expected_version\":\"" ++ lower ++ "\",\"old_string\":\"\",\"new_string\":\"a\"}" },
        .{ "patch", "{\"path\":\"x\",\"expected_version\":\"" ++ lower ++ "\",\"replacements\":[]}" },
        .{ "patch", "{\"path\":\"x\",\"expected_version\":\"" ++ lower ++ "\",\"replacements\":[{\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":null}]}" },
        .{ "patch", "{\"path\":\"x\",\"expected_version\":\"" ++ lower ++ "\",\"replacements\":[{\"old_string\":\"a\",\"new_string\":\"b\",\"other\":true}]}" },
        .{ "patch", "{\"path\":\"x\",\"expected_version\":\"" ++ lower ++ "\",\"replacements\":[" ++ ("{\"old_string\":\"a\",\"new_string\":\"b\"}," ** 64) ++ "{\"old_string\":\"a\",\"new_string\":\"b\"}]}" },
    };
    var host: Fixture = .{};
    for (cases) |case| {
        const result = host.run(s, case[0], case[1]);
        if (result == .ok) std.debug.print("unexpectedly accepted {s}: {s}\n", .{ case[0], case[1] });
        const err = try expectFailure("invalid_request", result);
        try testing.expect(std.mem.indexOf(u8, err.message, "secret") == null);
    }
    const huge = try s.alloc(u8, 4_300_001);
    @memset(huge, ' ');
    try testing.expectEqualStrings("argument byte limit exceeded", (try expectFailure("invalid_request", host.run(s, "read", huge))).message);
    try testing.expectEqual(@as(usize, 0), host.events.len);
}

test "write witnesses ordered before/write/after; distinct failure branches never retry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    const args = "{\"path\":\"a\",\"content\":\"\",\"expected_version\":\"" ++ upper ++ "\"}";
    var host: Fixture = .{};
    try expectOk("{\"version\":\"" ++ written ++ "\",\"bytes\":0}", host.run(s, "write", args));
    try testing.expectEqualSlices(Event, &.{ .capture, .write, .capture }, host.events.constSlice());
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "a" }), host.capture_paths.constSlice());
    try testing.expectEqual(@as(u64, 1_048_576), host.captured_bytes);
    try testing.expectEqualDeep(types.WriteRequest{ .path = "a", .content = "", .precondition = .{ .version = lower } }, host.write_request.?);
    host = .{};
    try expectOk("{\"version\":\"" ++ written ++ "\",\"bytes\":0}", host.run(s, "write", "{\"path\":\"a\",\"content\":\"\"}"));
    try testing.expectEqual(types.WritePrecondition.missing, host.write_request.?.precondition);

    const scenarios = [_]struct { code: Op, events: []const Event, after: bool }{
        .{ .code = .{ .code = .denied, .message = "before denied" }, .events = &.{.capture}, .after = false },
        .{ .code = .{ .code = .conflict, .message = "version raced" }, .events = &.{ .capture, .write }, .after = false },
        .{ .code = .{ .code = .timeout, .message = "after timed out" }, .events = &.{ .capture, .write, .capture }, .after = true },
    };
    for (scenarios) |scenario| {
        host = .{ .fail_event = scenario.events.len, .failure = scenario.code };
        const err = try expectFailure(@tagName(scenario.code.code), host.run(s, "write", args));
        try testing.expectEqualSlices(Event, scenario.events, host.events.constSlice());
        if (scenario.after) {
            try testing.expectEqual(.timeout, err.kind);
            try testing.expectEqualStrings("write succeeded; after cache-point capture failed: after timed out", err.message);
        } else {
            try testing.expectEqual(.failed, err.kind);
            try testing.expectEqualStrings(scenario.code.message, err.message);
        }
        try testing.expectEqual(scenario.after, host.write_request != null);
    }
}

test "versioned patch is ordered and atomic; no-op omits line counts and avoids captures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    const start = "{\"path\":\"a\",\"expected_version\":\"" ++ lower ++ "\",\"replacements\":[{\"old_string\":\"one\",\"new_string\":\"two\",\"replace_all\":true},";
    const args = start ++ "{\"old_string\":\"two\\r\\ntwo\",\"new_string\":\"done\\nmore\\n\"}]}";
    var host: Fixture = .{};
    host.read.content = "one\r\none";
    host.read.version = upper;
    host.write.bytes = 10;
    try expectOk("{\"version\":\"" ++ written ++ "\",\"bytes\":10,\"changed\":true,\"replacement_counts\":[2,1],\"lines_added\":4,\"lines_removed\":4}", host.run(s, "patch", args));
    try testing.expectEqualSlices(Event, &.{ .read, .capture, .write, .capture }, host.events.constSlice());
    try testing.expectEqualDeep(types.ReadRequest{ .path = "a", .offset_line = 1, .max_lines = 10000, .max_bytes = 1048576 }, host.read_request.?);
    try testing.expectEqualDeep(types.WriteRequest{ .path = "a", .content = "done\nmore\n", .precondition = .{ .version = upper } }, host.write_request.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "a" }), host.capture_paths.constSlice());
    try testing.expectEqual(@as(u64, 1_048_576), host.captured_bytes);

    host = .{};
    host.read.content = "one\r\none";
    try expectOk("{\"version\":\"" ++ lower ++ "\",\"bytes\":8,\"changed\":false,\"replacement_counts\":[2,2]}", host.run(s, "patch", start ++ "{\"old_string\":\"two\",\"new_string\":\"one\",\"replace_all\":true}]}"));
    try testing.expectEqualSlices(Event, &.{.read}, host.events.constSlice());

    host.events.len = 0;
    const failure = try expectFailure("invalid_request", host.run(s, "patch", start ++ "{\"old_string\":\"one\",\"new_string\":\"x\"}]}"));
    try testing.expectEqualStrings("replacement step 2: old_string was not found (zero literal matches)", failure.message);
    try testing.expectEqualSlices(Event, &.{.read}, host.events.constSlice());
}

test "edit refuses mismatched or incomplete reads and propagates Host errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    const args = "{\"path\":\"a\",\"expected_version\":\"" ++ upper ++ "\",\"old_string\":\"one\",\"new_string\":\"x\"}";
    var host: Fixture = .{};
    host.read.content = "one";
    host.read.version = written;
    _ = try expectFailure("conflict", host.run(s, "edit", args));
    try testing.expectEqualSlices(Event, &.{.read}, host.events.constSlice());
    host.read.version = lower;
    host.read.next_line = 2;
    host.events.len = 0;
    const err = try expectFailure("invalid_request", host.run(s, "edit", args));
    try testing.expect(std.mem.startsWith(u8, err.message, "edit requires a complete bounded read"));
    try testing.expectEqualSlices(Event, &.{.read}, host.events.constSlice());
    host.failure = .{ .code = .cancelled, .message = "Host cancelled" };
    host.fail_event = 1;
    host.events.len = 0;
    const cancelled = try expectFailure("cancelled", host.run(s, "edit", args));
    try testing.expectEqual(.cancelled, cancelled.kind);
    try testing.expectEqualStrings("Host cancelled", cancelled.message);
}

test "literal replacement detects overlaps before ambiguity, including Unicode and long needles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    var ws: text.LiteralWorkspace = .{};
    defer ws.deinit(s);
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(s);
    const cases = [_]struct { content: []const u8, needle: []const u8 }{
        .{ .content = "ababa", .needle = "aba" },
        .{ .content = "ééé", .needle = "éé" },
        .{ .content = "éαéαé", .needle = "éαé" },
        .{ .content = "aaaaaa", .needle = "aaaaa" },
    };
    for (cases) |case| {
        const overlap = try ws.replace(s, case.content, case.needle, "x", false, &output);
        try testing.expectEqualStrings("old_string has overlapping matches; provide larger exact context", overlap.err);
    }
    const ambiguous = try ws.replace(s, "word word", "word", "", false, &output);
    try testing.expectEqualStrings("old_string is ambiguous: 2 matches; provide unique context or set replace_all=true", ambiguous.err);
    const removed = try ws.replace(s, "éé-end-éé", "éé", "", true, &output);
    try testing.expectEqual(@as(usize, 2), removed.ok);
    try testing.expectEqualStrings("-end-", output.items);
    const long = try ws.replace(s, "ABCABCD ABCDABCD", "ABCDABCD", "X", false, &output);
    try testing.expectEqual(@as(usize, 1), long.ok);
    try testing.expectEqualStrings("ABCABCD X", output.items);
}

test "output budgets reject oversized Host replies and replacement expansion before allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = arena.allocator();
    var host: Fixture = .{};
    host.read.content = "oversize";
    _ = try expectFailure("limit", host.run(s, "read", "{\"path\":\"a\",\"max_bytes\":1}"));
    host.glob.entries = &.{ .{ .path = "a", .kind = .file }, .{ .path = "b", .kind = .file } };
    _ = try expectFailure("limit", host.run(s, "glob", "{\"root\":\".\",\"pattern\":\"*\",\"max_results\":1}"));
    host.grep.matches = &.{.{ .path = "abc", .line = 1, .text = "z" }};
    _ = try expectFailure("limit", host.run(s, "grep", "{\"root\":\".\",\"pattern\":\"z\",\"max_bytes\":1}"));
    host.grep.matches = &.{.{ .path = "�", .line = 1, .text = "" }};
    try expectOk("{\"content\":\"�:1:\",\"matches\":[{\"path\":\"�\",\"line\":1,\"text\":\"\"}],\"truncated\":false}", host.run(s, "grep", "{\"root\":\".\",\"pattern\":\"z\",\"max_bytes\":1}"));
    const large = try s.alloc(u8, 1_048_576);
    @memset(large, 'b');
    var ws: text.LiteralWorkspace = .{};
    defer ws.deinit(s);
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(s);
    const expansion = try ws.replace(s, "axa", "a", large, true, &buffer);
    try testing.expectEqualStrings("replacement exceeds the file byte limit", expansion.err);
    try testing.expectEqual(@as(usize, 0), buffer.capacity);
}
