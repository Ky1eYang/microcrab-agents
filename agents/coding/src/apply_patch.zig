//! Bounded multi-file patch planning and ordered receipts. Only the Host can
//! resolve path aliases, reserve evidence, or perform a file mutation.
const std = @import("std");
const abi = @import("coding_abi");
const t = abi.types;
const Allocator = std.mem.Allocator;
const eq = std.mem.eql;
const starts = std.mem.startsWith;

const file_bytes = 1_048_576;
const total_bytes = 4 * file_bytes;
const argument_bytes = 4_300_000;
const max_lines = 10_000;
const operations = 32;
const max_hunks = 64;
const max_preconditions = 2 * operations;

pub const Result = t.Result([]const u8, t.ToolFailure);

const ImportedHost = struct {
    fn read(_: @This(), scratch: Allocator, request: t.ReadRequest) t.Result(t.ReadOutput, t.OperationError) {
        return switch (abi.host.file_versions.read(scratch, request)) {
            .ok => |observed| .{ .ok = observed.page },
            .err => |err| .{ .err = err },
        };
    }
    fn preflight(_: @This(), scratch: Allocator, requests: []const t.FileMutation) t.Result([]const t.FileMutation, t.OperationError) {
        return abi.host.file_versions.preflight(scratch, requests);
    }
    fn capture(_: @This(), scratch: Allocator, path: []const u8, max_bytes: u64) t.Result(void, t.OperationError) {
        return abi.host.cache_points.capture(scratch, path, max_bytes);
    }
    fn mutate(_: @This(), scratch: Allocator, request: t.FileMutation) t.Result(t.MutationOutput, t.OperationError) {
        return abi.host.file_versions.mutate(scratch, request);
    }
};

pub fn invoke(scratch: Allocator, arguments: []const u8) Result {
    return invokeWith(scratch, arguments, ImportedHost{});
}

/// The adapter uses the same requests and tagged replies as `abi.host`. Use an
/// allocator scoped to this call for parser data, Host results, and the reply.
pub fn invokeWith(scratch: Allocator, arguments: []const u8, host: anytype) Result {
    var failure: t.OperationError = undefined;
    const content = run(scratch, arguments, host, &failure) catch |err| return .{ .err = switch (err) {
        error.Rejected => .{
            .kind = switch (failure.code) {
                .cancelled => .cancelled,
                .timeout => .timeout,
                else => .failed,
            },
            .code = @tagName(failure.code),
            .message = failure.message,
            .retryable = false,
        },
        error.OutOfMemory => .{
            .kind = .failed,
            .code = "failed",
            .message = "out of memory while processing patch",
            .retryable = false,
        },
    } };
    return .{ .ok = content };
}

// Zig's default []const u8 parser also accepts arrays of numbers. Require
// actual JSON strings, including for fields inside the external-tag enum.
const JsonString = struct {
    value: []const u8,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !JsonString {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

const Expected = union(enum) {
    missing: void,
    version: JsonString,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Expected {
        if (try source.peekNextTokenType() == .string) {
            const tag = try std.json.innerParse(JsonString, allocator, source, options);
            if (!eq(u8, tag.value, "missing")) return error.UnexpectedToken;
            return .missing;
        }
        const Version = struct { version: JsonString };
        return .{ .version = (try std.json.innerParse(Version, allocator, source, options)).version };
    }
};
const Precondition = struct { path: JsonString, expected: Expected };
const Preconditions = struct {
    items: std.BoundedArray(Precondition, max_preconditions) = .{},

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Preconditions {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var list: Preconditions = .{};
        while (try source.peekNextTokenType() != .array_end) {
            if (list.items.len == max_preconditions) return error.Overflow;
            list.items.appendAssumeCapacity(try std.json.innerParse(Precondition, allocator, source, options));
        }
        _ = try source.next();
        return list;
    }
};
const Arguments = struct { patch: JsonString, preconditions: Preconditions };

const Hunk = struct { old: []const u8, new: []const u8 };
const Change = union(enum) {
    add: []const u8,
    update: struct { destination: ?[]const u8, hunks: []const Hunk },
    delete: void,
};
const Entry = struct { path: []const u8, change: Change };
const Entries = std.BoundedArray(Entry, operations);
const Error = Allocator.Error || error{Rejected};

const Planner = struct {
    scratch: Allocator,
    failure: *t.OperationError,

    fn reject(self: Planner, err: t.OperationError) error{Rejected} {
        self.failure.* = err;
        return error.Rejected;
    }

    fn invalid(self: Planner, message: []const u8) error{Rejected} {
        return self.reject(.{ .code = .invalid_request, .message = message });
    }

    fn invalidFmt(self: Planner, comptime format: []const u8, args: anytype) Error {
        return self.invalid(try std.fmt.allocPrint(self.scratch, format, args));
    }

    fn unwrap(self: Planner, comptime T: type, result: t.Result(T, t.OperationError)) error{Rejected}!T {
        return switch (result) {
            .ok => |value| value,
            .err => |err| self.reject(err),
        };
    }

    fn text(self: Planner, value: []const u8, comptime max: usize, nonempty: bool) error{Rejected}!void {
        if (value.len > max) return self.invalid(std.fmt.comptimePrint("string exceeds maximum {d} bytes", .{max}));
        if (std.mem.indexOfScalar(u8, value, 0) != null) return self.invalid("string contains NUL");
        if (nonempty and value.len == 0) return self.invalid("string must not be empty");
    }

    fn grammar(self: Planner, patch: []const u8) Error!Entries {
        try self.text(patch, total_bytes, true);
        var lines: Lines = .{ .rest = patch };
        if (!eq(u8, header(lines.take()), "*** Begin Patch")) {
            return self.invalid("patch must start with *** Begin Patch on its own LF-delimited line");
        }
        var entries: Entries = .{};
        while (lines.rest.len != 0 and !eq(u8, header(lines.peek()), "*** End Patch")) {
            if (entries.len == operations) return self.invalid("patch exceeds 32 operations");
            const line = header(lines.take());
            const entry = if (stripPrefix(line, "*** Add File: ")) |path| blk: {
                try self.text(path, 4096, true);
                break :blk Entry{ .path = path, .change = .{ .add = try self.addPayload(&lines) } };
            } else if (stripPrefix(line, "*** Update File: ")) |path| blk: {
                try self.text(path, 4096, true);
                break :blk Entry{ .path = path, .change = try self.updatePayload(&lines) };
            } else if (stripPrefix(line, "*** Delete File: ")) |path| blk: {
                try self.text(path, 4096, true);
                break :blk Entry{ .path = path, .change = .delete };
            } else return self.invalidFmt("unsupported patch header at line {d}", .{lines.consumed});
            entries.appendAssumeCapacity(entry);
        }
        if (entries.len == 0 or !eq(u8, header(lines.take()), "*** End Patch") or lines.rest.len != 0) {
            return self.invalid("patch requires 1..=32 operations and one final *** End Patch line without trailing material");
        }
        return entries;
    }

    fn addPayload(self: Planner, lines: *Lines) Error![]const u8 {
        var content = std.ArrayList(u8).init(self.scratch);
        var previous = false;
        while (lines.isPayload()) {
            const line = lines.take();
            if (eq(u8, header(line), no_newline)) {
                if (!previous or !removeLf(&content)) return self.invalid(marker_requires_payload);
                previous = false;
            } else {
                const payload = stripPrefix(line, "+") orelse return self.invalid("add file payload lines must start with +");
                try content.appendSlice(payload);
                previous = true;
            }
        }
        return content.items;
    }

    fn updatePayload(self: Planner, lines: *Lines) Error!Change {
        const destination = stripPrefix(header(lines.peek()), "*** Move to: ");
        if (destination) |path| {
            try self.text(path, 4096, true);
            _ = lines.take();
        }
        var hunks = std.ArrayList(Hunk).init(self.scratch);
        while (lines.isPayload()) {
            if (!eq(u8, header(lines.take()), "@@")) {
                return self.invalid("update hunks must begin with an exact @@ line; numbered/fuzzy hunks are unsupported");
            }
            try hunks.append(try self.hunk(lines));
            if (hunks.items.len > max_hunks) return self.invalid("update exceeds 64 hunks");
        }
        if (hunks.items.len == 0 and destination == null) return self.invalid("update requires hunks or Move to");
        return .{ .update = .{ .destination = destination, .hunks = hunks.items } };
    }

    fn hunk(self: Planner, lines: *Lines) Error!Hunk {
        var old = std.ArrayList(u8).init(self.scratch);
        var new = std.ArrayList(u8).init(self.scratch);
        var previous: ?u8 = null;
        while (lines.isPayload() and !eq(u8, header(lines.peek()), "@@")) {
            const line = lines.take();
            if (eq(u8, header(line), no_newline)) {
                switch (previous orelse return self.invalid(marker_requires_payload)) {
                    ' ' => if (!removeLf(&old) or !removeLf(&new)) return self.invalid("invalid no-newline context marker"),
                    '-' => if (!removeLf(&old)) return self.invalid("invalid no-newline deletion marker"),
                    '+' => if (!removeLf(&new)) return self.invalid("invalid no-newline addition marker"),
                    else => unreachable, // Payload prefixes are checked before assignment.
                }
                previous = null;
            } else {
                switch (line[0]) {
                    ' ' => {
                        try old.appendSlice(line[1..]);
                        try new.appendSlice(line[1..]);
                    },
                    '-' => try old.appendSlice(line[1..]),
                    '+' => try new.appendSlice(line[1..]),
                    else => return self.invalid("hunk payload requires an ASCII space, - or + prefix"),
                }
                previous = line[0];
            }
        }
        if (old.items.len == 0) return self.invalid("update hunks require nonempty exact source context");
        return .{ .old = old.items, .new = new.items };
    }

    fn existing(self: Planner, host: anytype, path: []const u8, expected: Expected, total: *usize) Error!struct { content: []const u8, version: []const u8 } {
        const version = switch (expected) {
            .version => |s| s.value,
            .missing => return self.invalidFmt("existing source {s} requires a version precondition", .{path}),
        };
        const read = try self.unwrap(t.ReadOutput, host.read(self.scratch, .{
            .path = path,
            .offset_line = 1,
            .max_lines = max_lines,
            .max_bytes = file_bytes,
        }));
        if (read.truncated or read.next_line != null or read.start_line != 1 or
            read.content.len > file_bytes or lineCount(read.content) > max_lines)
        {
            return self.invalidFmt("{s}: source requires a complete read within 10000 lines / 1048576 bytes", .{path});
        }
        if (!std.ascii.eqlIgnoreCase(read.version, version)) return self.reject(.{
            .code = .conflict,
            .message = try std.fmt.allocPrint(self.scratch, "{s}: stale source version; reread before applying patch", .{path}),
        });
        total.* += read.content.len;
        if (total.* > total_bytes) return self.invalid("aggregate source bytes exceed 4194304");
        return .{ .content = read.content, .version = try std.ascii.allocLowerString(self.scratch, version) };
    }
};

const no_newline = "\\ No newline at end of file";
const marker_requires_payload = "no-newline marker requires a preceding payload line";

// Split inclusively at LF, never at CR or a Unicode line separator. A final LF
// does not create an empty line; EOF without LF is allowed for the End header.
const Lines = struct {
    rest: []const u8,
    consumed: usize = 0,

    fn peek(self: Lines) []const u8 {
        return if (std.mem.indexOfScalar(u8, self.rest, '\n')) |at| self.rest[0 .. at + 1] else self.rest;
    }

    fn take(self: *Lines) []const u8 {
        const line = self.peek();
        self.rest = self.rest[line.len..];
        self.consumed += 1;
        return line;
    }

    fn isPayload(self: Lines) bool {
        return self.rest.len != 0 and !starts(u8, self.rest, "*** ");
    }
};

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    return if (starts(u8, s, prefix)) s[prefix.len..] else null;
}

fn header(line: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, line, "\n")) line[0 .. line.len - 1] else line;
}

fn removeLf(content: *std.ArrayList(u8)) bool {
    if (!std.mem.endsWith(u8, content.items, "\n")) return false;
    _ = content.pop();
    return true;
}

fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + @intFromBool(content[content.len - 1] != '\n');
}

// KMP finds overlapping and non-overlapping occurrences in one linear scan.
// Use a reusable prefix table and edit a reusable buffer within each file;
// retaining all intermediate files in the call arena can cost 64x per file.
const Matcher = struct {
    prefix: std.ArrayList(u32),

    fn replace(self: *Matcher, content: *std.ArrayList(u8), h: Hunk) Allocator.Error!?[]const u8 {
        const bytes = content.items;
        const old = h.old; // Nonempty by grammar.
        if (old.len > bytes.len) return "old_string was not found (zero literal matches)";
        try self.prefix.resize(old.len);
        const prefix = self.prefix.items;
        prefix[0] = 0;
        var matched: u32 = 0;
        for (old[1..], 1..) |byte, i| {
            while (matched > 0 and byte != old[matched]) matched = prefix[matched - 1];
            if (byte == old[matched]) matched += 1;
            prefix[i] = matched;
        }
        matched = 0;
        var first: usize = undefined;
        var last_end: usize = 0;
        var count: usize = 0;
        for (bytes, 1..) |byte, end| {
            while (matched > 0 and byte != old[matched]) matched = prefix[matched - 1];
            if (byte == old[matched]) matched += 1;
            if (matched == old.len) {
                const at = end - old.len;
                if (at < last_end) return "old_string has overlapping matches; provide larger exact context";
                if (count == 0) first = at;
                count += 1;
                last_end = end;
                matched = prefix[matched - 1];
            }
        }
        if (count == 0) return "old_string was not found (zero literal matches)";
        if (count != 1) return try std.fmt.allocPrint(content.allocator, "old_string is ambiguous: {d} matches; provide unique context or set replace_all=true", .{count});
        if (bytes.len - old.len + h.new.len > file_bytes) return "replacement exceeds the file byte limit";
        try content.replaceRange(first, old.len, h.new);
        return null;
    }
};

const PreconditionEntry = struct { expected: Expected, used: bool = false };
const LineCounts = struct { before_lines: usize = 0, after_lines: usize = 0 };

fn run(scratch: Allocator, arguments: []const u8, host: anytype, failure: *t.OperationError) Error![]const u8 {
    const p: Planner = .{ .scratch = scratch, .failure = failure };
    if (arguments.len > argument_bytes) return p.invalid("argument byte limit exceeded");
    const args = std.json.parseFromSliceLeaky(Arguments, scratch, arguments, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // No numeric fields are parsed; Overflow denotes the bounded list.
        error.Overflow => p.invalid("preconditions requires 1..=64 exact path entries"),
        // Report parser causes without echoing rejected values or the input body.
        else => p.invalidFmt("invalid patch arguments: {s}", .{@errorName(err)}),
    };
    const entries = try p.grammar(args.patch.value);
    if (args.preconditions.items.len == 0) return p.invalid("preconditions requires 1..=64 exact path entries");
    var table: std.StringHashMapUnmanaged(PreconditionEntry) = .{};
    for (args.preconditions.items.constSlice()) |item| {
        try p.text(item.path.value, 4096, true);
        if (item.expected == .version) {
            const version = item.expected.version.value;
            if (version.len != 64) return p.invalid("expected_version must be a SHA-256 hex digest");
            for (version) |c| if (!std.ascii.isHex(c)) return p.invalid("expected_version must be a SHA-256 hex digest");
        }
        const found = try table.getOrPut(scratch, item.path.value);
        if (found.found_existing) return p.invalid("duplicate precondition path");
        found.value_ptr.* = .{ .expected = item.expected };
    }

    var requests: [operations]t.FileMutation = undefined;
    var unchanged = [_]bool{false} ** operations;
    var counts = [_]LineCounts{.{}} ** operations;
    var source_bytes: usize = 0;
    var result_bytes: usize = 0;
    var used: usize = 0;
    var matcher: Matcher = .{ .prefix = std.ArrayList(u32).init(scratch) };
    defer matcher.prefix.deinit();
    for (entries.constSlice(), 0..) |entry, index| {
        const condition = table.getPtr(entry.path) orelse return p.invalidFmt("missing precondition for {s}", .{entry.path});
        if (condition.used) return p.invalid("duplicate patch source path");
        condition.used = true;
        used += 1;
        requests[index] = switch (entry.change) {
            .add => |content| blk: {
                if (condition.expected != .missing) return p.invalid("add destination must require missing");
                try p.text(content, file_bytes, false);
                result_bytes += content.len;
                counts[index].after_lines = lineCount(content);
                break :blk .{ .write = .{ .path = entry.path, .content = content, .precondition = .missing } };
            },
            .delete => blk: {
                const original = try p.existing(host, entry.path, condition.expected, &source_bytes);
                counts[index].before_lines = lineCount(original.content);
                break :blk .{ .delete = .{ .path = entry.path, .expected_version = original.version } };
            },
            .update => |update| blk: {
                const original = try p.existing(host, entry.path, condition.expected, &source_bytes);
                var buffer = std.ArrayList(u8).init(scratch);
                var content = original.content;
                if (update.hunks.len != 0) {
                    try buffer.appendSlice(original.content);
                    for (update.hunks, 1..) |h, step| {
                        if (try matcher.replace(&buffer, h)) |reason| {
                            return p.invalidFmt("operation {d}, hunk {d} ({s}): {s}", .{ index + 1, step, entry.path, reason });
                        }
                    }
                    content = buffer.items;
                }
                try p.text(content, file_bytes, false);
                counts[index] = .{ .before_lines = lineCount(original.content), .after_lines = lineCount(content) };
                result_bytes += content.len;
                if (update.destination) |destination| {
                    const target = table.getPtr(destination) orelse return p.invalid("move destination requires its own missing precondition");
                    if (target.used) return p.invalid("move destination collides with another patch path");
                    if (target.expected != .missing) return p.invalid("move destination requires its own missing precondition");
                    target.used = true;
                    used += 1;
                    break :blk .{ .move = .{
                        .path = entry.path,
                        .destination = destination,
                        .expected_version = original.version,
                        .content = content,
                    } };
                }
                unchanged[index] = eq(u8, content, original.content);
                break :blk .{ .write = .{ .path = entry.path, .content = content, .precondition = .{ .version = original.version } } };
            },
        };
        if (result_bytes > total_bytes) return p.invalid("aggregate result bytes exceed 4194304");
    }
    if (used != table.count()) return p.invalid("unused precondition entries are not allowed");

    const normalized = try p.unwrap([]const t.FileMutation, host.preflight(scratch, requests[0..entries.len]));
    if (normalized.len != entries.len) return p.invalid("Host preflight changed operation count");
    for (normalized, unchanged[0..normalized.len]) |request, noop| {
        if (!noop) {
            const paths = mutationPaths(request);
            for (paths.constSlice()) |path| try p.unwrap(void, host.capture(scratch, path, file_bytes));
        }
    }

    var receipts: [operations]Receipt = undefined;
    var stopped = false;
    for (normalized, unchanged[0..normalized.len], counts[0..normalized.len], 0..) |request, noop, lines, index| {
        const paths = mutationPaths(request);
        const state: Receipt.State = blk: {
            if (stopped) break :blk .not_started;
            if (noop) break :blk .unchanged;
            switch (host.mutate(scratch, request)) {
                .ok => |outcome| {
                    var evidence: Evidence = .{};
                    for (paths.constSlice()) |path| switch (host.capture(scratch, path, file_bytes)) {
                        .ok => {},
                        .err => |err| evidence.appendAssumeCapacity(boundedError(err)),
                    };
                    stopped = outcome.diagnostic != null or evidence.len != 0;
                    break :blk .{ .committed = .{ .line_counts = lines, .outcome = outcome, .evidence_errors = evidence } };
                },
                .err => |err| {
                    stopped = true;
                    // These are the only typed errors that prove rejection. An
                    // IO, timeout, or cancellation may hide admitted effects.
                    break :blk switch (err.code) {
                        .conflict, .invalid_request, .unsupported, .denied, .limit => .{ .failed = boundedError(err) },
                        .io, .timeout, .cancelled => .{ .uncertain = boundedError(err) },
                    };
                },
            }
        };
        receipts[index] = .{ .operation = index + 1, .paths = paths, .state = state };
    }
    return std.json.stringifyAlloc(scratch, .{
        .complete = !stopped,
        .receipts = receipts[0..normalized.len],
        .replay_safe = false,
    }, .{});
}

const Paths = std.BoundedArray([]const u8, 2);
const Evidence = std.BoundedArray(t.OperationError, 2);

fn mutationPaths(request: t.FileMutation) Paths {
    return switch (request) {
        .write => |r| .{ .buffer = .{ r.path, undefined }, .len = 1 },
        .delete => |r| .{ .buffer = .{ r.path, undefined }, .len = 1 },
        .move => |r| .{ .buffer = .{ r.path, r.destination }, .len = 2 },
    };
}

fn boundedError(err: t.OperationError) t.OperationError {
    // WIT error messages are UTF-8 strings. Count scalars, not bytes.
    const utf8 = std.unicode.Utf8View.initUnchecked(err.message);
    var iter = utf8.iterator();
    var remaining: usize = 512;
    while (remaining != 0) : (remaining -= 1) {
        if (iter.nextCodepointSlice() == null) break;
    }
    return .{ .code = err.code, .message = err.message[0..iter.i] };
}

const Receipt = struct {
    operation: usize,
    paths: Paths,
    state: State,

    const State = union(enum) {
        not_started: void,
        unchanged: void,
        committed: struct {
            line_counts: LineCounts,
            outcome: t.MutationOutput,
            evidence_errors: Evidence,
        },
        failed: t.OperationError,
        uncertain: t.OperationError,
    };

    pub fn jsonStringify(self: Receipt, json: anytype) !void {
        try json.beginObject();
        try json.objectField("operation");
        try json.write(self.operation);
        try json.objectField("paths");
        try json.write(self.paths.constSlice());
        try json.objectField("status");
        try json.write(@tagName(self.state));
        switch (self.state) {
            .not_started, .unchanged => {},
            .committed => |committed| {
                try json.objectField("line_counts");
                try json.write(committed.line_counts);
                try json.objectField("outcome");
                try json.write(committed.outcome);
                try json.objectField("evidence_errors");
                try json.write(committed.evidence_errors.constSlice());
            },
            .failed, .uncertain => |err| {
                try json.objectField("error");
                try json.write(err);
            },
        }
        try json.endObject();
    }
};
