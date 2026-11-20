//! Coding text tools: validate and render here; the Host owns effects and permissions.
const std = @import("std");
const types = @import("coding_abi").types;
const Allocator = std.mem.Allocator;
const ToolFailure = types.ToolFailure;
const Result = types.Result;

const max_bytes = 1_048_576;
const max_arguments = 4_300_000;
const max_lines = 10_000;
const max_results = 4096;
const max_replacements = 64;
const path_bytes = 4096;
const pattern_bytes = 1024;

/// The caller gates availability against the same catalog used by describe. Pass
/// `abi.host` in the guest, or matching interfaces in native tests. Results and
/// requests may borrow the call inputs or scratch (the callback arena).
pub fn invoke(scratch: Allocator, name: []const u8, arguments: []const u8, host: anytype) Result([]const u8, ToolFailure) {
    return invokeInner(scratch, name, arguments, host) catch .{ .err = allocation_failure };
}

const allocation_failure: ToolFailure = .{
    .kind = .failed,
    .code = "failed",
    .message = "text tool allocation failed",
    .retryable = false,
};

pub fn operationFailure(err: types.OperationError) ToolFailure {
    return .{
        .kind = switch (err.code) {
            .timeout => .timeout,
            .cancelled => .cancelled,
            else => .failed,
        },
        .code = @tagName(err.code),
        .message = err.message,
        .retryable = false,
    };
}

pub fn invalid(message: []const u8) ToolFailure {
    return operationFailure(.{ .code = .invalid_request, .message = message });
}

fn replyLimit() ToolFailure {
    return operationFailure(.{ .code = .limit, .message = "Host reply exceeds the text tool output limit" });
}

// Zig's built-in integer decoder permits quoted and float-form numbers, and
// its byte slices can accept JSON arrays. These decoders take exact token kinds.
const String = struct {
    value: []const u8,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!String {
        return switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            .string, .allocated_string => |value| .{ .value = value },
            else => error.UnexpectedToken,
        };
    }
};

const PresentString = struct {
    value: ?[]const u8 = null,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!PresentString {
        return .{ .value = (try String.jsonParse(allocator, source, options)).value };
    }
};

const Unsigned = struct {
    value: u64,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Unsigned {
        const digits = switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            .number, .allocated_number => |value| value,
            else => return error.UnexpectedToken,
        };
        if (digits.len > 20) return error.Overflow; // u64::MAX has 20 decimal digits.
        for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
        return .{ .value = try std.fmt.parseInt(u64, digits, 10) };
    }
};

const ReadArgs = struct {
    path: String,
    offset_line: Unsigned = .{ .value = 1 },
    max_lines: Unsigned = .{ .value = 200 },
    max_bytes: Unsigned = .{ .value = 65536 },
};
const GlobArgs = struct {
    root: String,
    pattern: String,
    include_hidden: bool = false,
    include_ignored: bool = false,
    include_directories: bool = false,
    max_results: Unsigned = .{ .value = 100 },
};
const GrepArgs = struct {
    root: String,
    pattern: String,
    include_glob: PresentString = .{},
    case_sensitive: bool = true,
    literal: bool = false,
    max_matches: Unsigned = .{ .value = 100 },
    max_bytes: Unsigned = .{ .value = 65536 },
};
const WriteArgs = struct { path: String, content: String, expected_version: PresentString = .{} };
const EditArgs = struct {
    path: String,
    expected_version: String,
    old_string: String,
    new_string: String,
    replace_all: bool = false,
};
const Replacement = struct { old_string: String, new_string: String, replace_all: bool = false };
const Replacements = struct {
    values: std.BoundedArray(Replacement, max_replacements),

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Replacements {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var values: std.BoundedArray(Replacement, max_replacements) = .{};
        while (try source.peekNextTokenType() != .array_end) {
            if (values.len == max_replacements) return error.LengthMismatch;
            values.appendAssumeCapacity(try std.json.innerParse(Replacement, allocator, source, options));
        }
        _ = try source.next();
        if (values.len == 0) return error.LengthMismatch;
        return .{ .values = values };
    }
};
const PatchArgs = struct { path: String, expected_version: String, replacements: Replacements };

fn parse(comptime T: type, scratch: Allocator, arguments: []const u8) Allocator.Error!Result(T, ToolFailure) {
    const value = std.json.parseFromSliceLeaky(T, scratch, arguments, .{}) catch |err| return .{ .err = invalid(switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => "duplicate argument field",
        error.UnknownField => "unknown argument field",
        error.MissingField => "missing required argument field",
        error.UnexpectedToken => "unexpected JSON value in arguments",
        error.LengthMismatch => "patch requires 1..=64 replacements",
        error.InvalidNumber, error.Overflow, error.InvalidCharacter => "invalid unsigned integer argument",
        else => "malformed JSON arguments",
    }) };
    return .{ .ok = value };
}

fn checkString(value: []const u8, comptime limit: usize, nonempty: bool) ?ToolFailure {
    if (value.len > limit) return invalid(std.fmt.comptimePrint("string exceeds maximum {d} bytes", .{limit}));
    if (std.mem.indexOfScalar(u8, value, 0) != null) return invalid("string contains NUL");
    if (nonempty and value.len == 0) return invalid("string must not be empty");
    return null;
}

fn checkRange(value: u64, comptime max: u64) ?ToolFailure {
    if (value < 1 or value > max) return invalid(std.fmt.comptimePrint("numeric argument must be between 1 and {d}", .{max}));
    return null;
}

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

const invalid_digest: ToolFailure = invalid("expected_version must be a SHA-256 hex digest");

fn json(scratch: Allocator, value: anytype) Allocator.Error!Result([]const u8, ToolFailure) {
    return .{ .ok = try std.json.stringifyAlloc(scratch, value, .{}) };
}

fn invokeInner(scratch: Allocator, name: []const u8, arguments: []const u8, host: anytype) Allocator.Error!Result([]const u8, ToolFailure) {
    if (arguments.len > max_arguments) return .{ .err = invalid("argument byte limit exceeded") };
    const Tool = enum { read, glob, grep, write, edit, patch };
    switch (std.meta.stringToEnum(Tool, name) orelse return .{ .err = invalid("unknown tool") }) {
        .read => {
            const a = switch (try parse(ReadArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            if (checkString(a.path.value, path_bytes, true) orelse checkRange(a.offset_line.value, std.math.maxInt(u64)) orelse
                checkRange(a.max_lines.value, max_lines) orelse checkRange(a.max_bytes.value, max_bytes)) |err| return .{ .err = err };
            const output = switch (host.text_read.read(scratch, .{
                .path = a.path.value,
                .offset_line = a.offset_line.value,
                .max_lines = a.max_lines.value,
                .max_bytes = a.max_bytes.value,
            })) {
                .ok => |out| out,
                .err => |err| return .{ .err = operationFailure(err) },
            };
            if (output.content.len > a.max_bytes.value or output.version.len > 64) return .{ .err = replyLimit() };
            const line_count = countLines(output.content);
            if (line_count > a.max_lines.value) return .{ .err = replyLimit() };
            var numbered = std.ArrayList(u8).init(scratch);
            defer numbered.deinit();
            // At most 20 decimal digits and one tab per line; preserve newlines.
            try numbered.ensureTotalCapacityPrecise(output.content.len + line_count * 21);
            var remaining = output.content;
            var number = output.start_line;
            while (remaining.len != 0) : (number +|= 1) {
                const end = if (std.mem.indexOfScalar(u8, remaining, '\n')) |lf| lf + 1 else remaining.len;
                try numbered.writer().print("{d}\t{s}", .{ number, remaining[0..end] });
                remaining = remaining[end..];
            }
            return json(scratch, .{ .content = numbered.items, .start_line = output.start_line, .next_line = output.next_line, .truncated = output.truncated, .version = output.version });
        },
        .glob => {
            const a = switch (try parse(GlobArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            if (checkString(a.root.value, path_bytes, true) orelse checkString(a.pattern.value, pattern_bytes, true) orelse
                checkRange(a.max_results.value, max_results)) |err| return .{ .err = err };
            const output = switch (host.glob.glob(scratch, .{
                .root = a.root.value,
                .pattern = a.pattern.value,
                .include_hidden = a.include_hidden,
                .include_ignored = a.include_ignored,
                .include_directories = a.include_directories,
                .max_results = a.max_results.value,
            })) {
                .ok => |out| out,
                .err => |err| return .{ .err = operationFailure(err) },
            };
            return renderGlob(scratch, output, a.max_results.value);
        },
        .grep => {
            const a = switch (try parse(GrepArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            if (checkString(a.root.value, path_bytes, true) orelse checkString(a.pattern.value, pattern_bytes, true)) |err| return .{ .err = err };
            if (a.include_glob.value) |g| if (checkString(g, pattern_bytes, true)) |err| return .{ .err = err };
            if (checkRange(a.max_matches.value, max_results) orelse checkRange(a.max_bytes.value, max_bytes)) |err| return .{ .err = err };
            const output = switch (host.grep.grep(scratch, .{
                .root = a.root.value,
                .pattern = a.pattern.value,
                .include_glob = a.include_glob.value,
                .case_sensitive = a.case_sensitive,
                .literal = a.literal,
                .max_matches = a.max_matches.value,
                .max_bytes = a.max_bytes.value,
            })) {
                .ok => |out| out,
                .err => |err| return .{ .err = operationFailure(err) },
            };
            return renderGrep(scratch, output, a.max_matches.value, @intCast(a.max_bytes.value));
        },
        .write => {
            const a = switch (try parse(WriteArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            if (checkString(a.path.value, path_bytes, true) orelse checkString(a.content.value, max_bytes, false)) |err| return .{ .err = err };
            var lower: [64]u8 = undefined;
            const precondition: types.WritePrecondition = if (a.expected_version.value) |version| blk: {
                if (!validDigest(version)) return .{ .err = invalid_digest };
                break :blk .{ .version = std.ascii.lowerString(&lower, version) };
            } else .missing;
            const output = switch (controlledWrite(scratch, host, .{ .path = a.path.value, .content = a.content.value, .precondition = precondition })) {
                .ok => |out| out,
                .err => |err| return .{ .err = err },
            };
            return committedJson(scratch, output);
        },
        .edit => {
            const a = switch (try parse(EditArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            return replace(scratch, host, a.path.value, a.expected_version.value, &.{.{ .old_string = a.old_string, .new_string = a.new_string, .replace_all = a.replace_all }});
        },
        .patch => {
            const a = switch (try parse(PatchArgs, scratch, arguments)) {
                .ok => |args| args,
                .err => |err| return .{ .err = err },
            };
            return replace(scratch, host, a.path.value, a.expected_version.value, a.replacements.values.constSlice());
        },
    }
}

fn renderGlob(scratch: Allocator, output: types.GlobOutput, limit: u64) Allocator.Error!Result([]const u8, ToolFailure) {
    if (output.entries.len > limit) return .{ .err = replyLimit() };
    const Kind = @TypeOf(@as(types.GlobEntry, undefined).kind);
    const Group = struct { kind: Kind, path: []const []const u8 };
    const kinds = [_]Kind{ .file, .directory, .symlink };
    const paths = try scratch.alloc([]const u8, output.entries.len);
    defer scratch.free(paths);
    var groups: std.BoundedArray(Group, kinds.len) = .{};
    var remaining = paths;
    // Native searches budget platform paths before converting them to WIT UTF-8.
    // Lossy path decoding may expand each native byte up to three UTF-8 bytes.
    var budget: usize = max_bytes * 3;
    for (kinds) |kind| {
        var written: usize = 0;
        for (output.entries) |entry| {
            if (entry.kind != kind) continue;
            if (entry.path.len > budget) return .{ .err = replyLimit() };
            budget -= entry.path.len;
            remaining[written] = entry.path;
            written += 1;
        }
        if (written == 0) continue;
        groups.appendAssumeCapacity(.{ .kind = kind, .path = remaining[0..written] });
        remaining = remaining[written..];
    }
    return json(scratch, .{ .groups = groups.constSlice(), .truncated = output.truncated });
}

fn renderGrep(scratch: Allocator, output: types.GrepOutput, limit: u64, bytes: usize) Allocator.Error!Result([]const u8, ToolFailure) {
    if (output.matches.len > limit) return .{ .err = replyLimit() };
    var budget = bytes;
    var rendered_bytes: usize = 0;
    for (output.matches) |m| {
        // Text is already UTF-8; only paths can expand in lossy conversion.
        const min_path_bytes = m.path.len / 3 + @intFromBool(m.path.len % 3 != 0);
        if (min_path_bytes > budget) return .{ .err = replyLimit() };
        budget -= min_path_bytes;
        if (m.text.len > budget) return .{ .err = replyLimit() };
        budget -= m.text.len;
        rendered_bytes += m.path.len + m.text.len;
    }
    var rendered = std.ArrayList(u8).init(scratch);
    defer rendered.deinit();
    // 20 decimal digits, two colons, and at most one newline per match.
    try rendered.ensureTotalCapacityPrecise(rendered_bytes + 23 * output.matches.len);
    for (output.matches, 0..) |m, i| {
        if (i != 0) try rendered.append('\n');
        try rendered.writer().print("{s}:{d}:{s}", .{ m.path, m.line, m.text });
    }
    return json(scratch, .{ .content = rendered.items, .matches = output.matches, .truncated = output.truncated });
}

fn countLines(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n") + @intFromBool(bytes.len != 0 and bytes[bytes.len - 1] != '\n');
}

fn controlledWrite(scratch: Allocator, host: anytype, request: types.WriteRequest) Result(types.WriteOutput, ToolFailure) {
    switch (host.cache_points.capture(scratch, request.path, max_bytes)) {
        .ok => {},
        .err => |err| return .{ .err = operationFailure(err) },
    }
    const output = switch (host.text_write.write(scratch, request)) {
        .ok => |out| out,
        .err => |err| return .{ .err = operationFailure(err) },
    };
    switch (host.cache_points.capture(scratch, request.path, max_bytes)) {
        .ok => return .{ .ok = output },
        .err => |err| {
            var failure = operationFailure(err);
            failure.message = std.fmt.allocPrint(scratch, "write succeeded; after cache-point capture failed: {s}", .{err.message}) catch
                "write succeeded; after cache-point capture failed";
            return .{ .err = failure };
        },
    }
}

fn committedJson(scratch: Allocator, value: anytype) Result([]const u8, ToolFailure) {
    if (value.version.len > 64) return .{ .err = operationFailure(.{ .code = .limit, .message = "write succeeded; Host version exceeds the text tool output limit" }) };
    return json(scratch, value) catch .{ .err = .{
        .kind = .failed,
        .code = "failed",
        .message = "write succeeded; could not encode the result",
        .retryable = false,
    } };
}

fn replace(scratch: Allocator, host: anytype, path: []const u8, expected: []const u8, replacements: []const Replacement) Allocator.Error!Result([]const u8, ToolFailure) {
    if (checkString(path, path_bytes, true)) |err| return .{ .err = err };
    if (!validDigest(expected)) return .{ .err = invalid_digest };
    for (replacements) |r| {
        if (checkString(r.old_string.value, max_bytes, true) orelse checkString(r.new_string.value, max_bytes, false)) |err| return .{ .err = err };
    }
    const original = switch (host.text_read.read(scratch, .{ .path = path, .offset_line = 1, .max_lines = max_lines, .max_bytes = max_bytes })) {
        .ok => |out| out,
        .err => |err| return .{ .err = operationFailure(err) },
    };
    if (original.truncated or original.next_line != null or original.start_line != 1 or
        original.content.len > max_bytes or countLines(original.content) > max_lines)
        return .{ .err = invalid("edit requires a complete bounded read; file exceeds edit limits") };
    if (!std.ascii.eqlIgnoreCase(original.version, expected)) return .{ .err = operationFailure(.{
        .code = .conflict,
        .message = "file version differs from expected_version",
    }) };

    var workspace: LiteralWorkspace = .{};
    defer workspace.deinit(scratch);
    var buffers: [2]std.ArrayListUnmanaged(u8) = .{ .{}, .{} };
    defer for (&buffers) |*buffer| buffer.deinit(scratch);
    var counts: std.BoundedArray(usize, max_replacements) = .{};
    var added: usize = 0;
    var removed: usize = 0;
    var content = original.content;
    for (replacements, 0..) |r, i| {
        const old = r.old_string.value;
        const new = r.new_string.value;
        const buffer = &buffers[i % 2];
        const count = switch (try workspace.replace(scratch, content, old, new, r.replace_all, buffer)) {
            .ok => |count| count,
            .err => |reason| return .{ .err = invalid(try std.fmt.allocPrint(scratch, "replacement step {d}: {s}", .{ i + 1, reason })) },
        };
        content = buffer.items;
        counts.appendAssumeCapacity(count);
        if (!std.mem.eql(u8, old, new)) {
            // Each bounded output/input is <= 1 MiB, so at most that many
            // lines may be added/removed per replacement step.
            added += countLines(new) * count;
            removed += countLines(old) * count;
        }
    }
    if (std.mem.eql(u8, original.content, content)) return json(scratch, .{
        .version = original.version,
        .bytes = content.len,
        .changed = false,
        .replacement_counts = counts.constSlice(),
    });
    const output = switch (controlledWrite(scratch, host, .{ .path = path, .content = content, .precondition = .{ .version = original.version } })) {
        .ok => |out| out,
        .err => |err| return .{ .err = err },
    };
    return committedJson(scratch, .{
        .version = output.version,
        .bytes = output.bytes,
        .changed = true,
        .replacement_counts = counts.constSlice(),
        .lines_added = added,
        .lines_removed = removed,
    });
}

/// Shared literal replacement, also usable for exact unified-patch hunks.
/// Retain one search workspace across steps and alternate two output buffers
/// to avoid retaining one whole changed file per step in an arena.
pub const LiteralWorkspace = struct {
    prefix: std.ArrayListUnmanaged(u32) = .{},

    pub fn deinit(self: *LiteralWorkspace, scratch: Allocator) void {
        self.prefix.deinit(scratch);
    }

    /// Inputs are UTF-8; output must not alias the inputs. On success output
    /// contains the replacement bytes and ok holds the non-overlapping count.
    pub fn replace(self: *LiteralWorkspace, scratch: Allocator, content: []const u8, old: []const u8, new: []const u8, replace_all: bool, output: *std.ArrayListUnmanaged(u8)) Allocator.Error!Result(usize, []const u8) {
        if (old.len == 0) return .{ .err = "old_string must not be empty" };
        if (old.len > content.len) return .{ .err = "old_string was not found (zero literal matches)" };
        if (content.len > max_bytes) return .{ .err = "replacement exceeds the file byte limit" };
        var matches = MatchIterator{ .needle = old, .content = content };
        // KMP keeps adversarial near-matches linear. Short patterns can use the
        // standard byte search without allocating a prefix table.
        if (old.len > 4) {
            try self.prefix.resize(scratch, old.len);
            const prefix = self.prefix.items;
            prefix[0] = 0;
            var matched: u32 = 0;
            for (old[1..], 1..) |byte, i| {
                while (matched != 0 and old[matched] != byte) matched = prefix[matched - 1];
                if (old[matched] == byte) matched += 1;
                prefix[i] = matched;
            }
            matches.prefix = prefix;
        }
        const start = matches;
        var count: usize = 0;
        var end: usize = 0;
        while (matches.next()) |at| {
            // Valid UTF-8 needles cannot match starting at a continuation byte.
            if (at < end) return .{ .err = "old_string has overlapping matches; provide larger exact context" };
            end = at + old.len;
            count += 1;
        }
        if (count == 0) return .{ .err = "old_string was not found (zero literal matches)" };
        if (!replace_all and count != 1) return .{ .err = try std.fmt.allocPrint(scratch, "old_string is ambiguous: {d} matches; provide unique context or set replace_all=true", .{count}) };

        const unchanged = content.len - old.len * count;
        const added = std.math.mul(usize, new.len, count) catch return .{ .err = "replacement byte size overflow" };
        const size = std.math.add(usize, unchanged, added) catch return .{ .err = "replacement byte size overflow" };
        if (size > max_bytes) return .{ .err = "replacement exceeds the file byte limit" };
        try output.ensureTotalCapacity(scratch, size);
        output.clearRetainingCapacity();
        matches = start;
        end = 0;
        while (matches.next()) |at| {
            output.appendSliceAssumeCapacity(content[end..at]);
            output.appendSliceAssumeCapacity(new);
            end = at + old.len;
        }
        output.appendSliceAssumeCapacity(content[end..]);
        return .{ .ok = count };
    }
};

const MatchIterator = struct {
    needle: []const u8,
    content: []const u8,
    prefix: []const u32 = &.{},
    cursor: usize = 0,
    matched: usize = 0,

    fn next(self: *MatchIterator) ?usize {
        if (self.prefix.len == 0) {
            const at = std.mem.indexOfPos(u8, self.content, self.cursor, self.needle) orelse return null;
            self.cursor = at + 1;
            return at;
        }
        while (self.cursor < self.content.len) {
            const byte = self.content[self.cursor];
            self.cursor += 1;
            while (self.matched != 0 and self.needle[self.matched] != byte) self.matched = self.prefix[self.matched - 1];
            if (self.needle[self.matched] == byte) self.matched += 1;
            if (self.matched == self.needle.len) {
                self.matched = self.prefix[self.matched - 1];
                return self.cursor - self.needle.len;
            }
        }
        return null;
    }
};

test {
    _ = @import("text_test.zig");
}
