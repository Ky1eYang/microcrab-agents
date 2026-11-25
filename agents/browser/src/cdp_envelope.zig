//! Classify one complete CDP text message without materializing payloads.
//! The tokenizer validates JSON grammar, Unicode and trailing data. Only
//! discriminators are interpreted here; selected payloads have their own decoder.
const std = @import("std");

pub const max_json_depth = 32;
pub const max_session_bytes = 256;
pub const max_command_id = std.math.maxInt(u31);
const Error = error{InvalidCdpMessage};

const Key = enum { id, method, sessionId, result, @"error", params };
pub const Method = enum {
    unknown,
    @"Target.attachedToTarget",
    @"Target.detachedFromTarget",
    @"Target.targetDestroyed",
    @"Target.targetCrashed",
    @"Inspector.detached",
    @"Inspector.targetCrashed",
    @"Runtime.executionContextCreated",
    @"Runtime.executionContextDestroyed",
    @"Runtime.executionContextsCleared",
    @"WebMCP.toolsAdded",
    @"WebMCP.toolsRemoved",
    @"WebMCP.toolInvoked",
    @"WebMCP.toolResponded",
    @"Network.responseReceived",
    @"Network.loadingFinished",
    @"Network.loadingFailed",
};
pub const Session = struct {
    buffer: [max_session_bytes]u8 = undefined,
    len: usize = 0,

    pub fn matches(self: *const Session, expected: []const u8) bool {
        return self.len <= self.buffer.len and std.mem.eql(u8, self.buffer[0..self.len], expected);
    }
};
pub const Envelope = struct {
    session: ?Session,
    kind: union(enum) {
        reply: struct { id: u32, payload: []const u8, rejected: bool },
        event: struct { method: Method, params: ?[]const u8 },
    },

    pub fn matches(self: *const Envelope, expected: ?[]const u8) bool {
        if (self.session) |*session| return session.matches(expected orelse return false);
        return expected == null;
    }
};

pub fn scan(frame: []const u8) Error!Envelope {
    // Fixed tokenizer storage: the bit stack cannot exceed max_json_depth + 2.
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), frame);
    defer scanner.deinit();
    if (try next(&scanner) != .object_begin) return error.InvalidCdpMessage;
    var seen = std.EnumSet(Key).initEmpty();
    var id: ?u32 = null;
    var method: ?Method = null;
    var session: ?Session = null;
    var result: ?[]const u8 = null;
    var rejection: ?[]const u8 = null;
    var params: ?[]const u8 = null;
    var name: ["sessionId".len]u8 = undefined;
    while (try peek(&scanner) != .object_end) {
        const key = if (try readString(&scanner, &name)) |text| std.meta.stringToEnum(Key, text) else null;
        if (key) |field| {
            if (seen.contains(field)) return error.InvalidCdpMessage;
            seen.insert(field);
            switch (field) {
                .id => {
                    const token = try next(&scanner);
                    if (token != .number or token.number.len == 0 or token.number[0] == '-' or
                        !std.json.isNumberFormattedLikeAnInteger(token.number)) return error.InvalidCdpMessage;
                    id = std.fmt.parseUnsigned(u31, token.number, 10) catch return error.InvalidCdpMessage;
                    if (id.? == 0) return error.InvalidCdpMessage;
                },
                .method => {
                    var text: [64]u8 = undefined;
                    method = if (try readString(&scanner, &text)) |value| blk: {
                        if (value.len == 0) return error.InvalidCdpMessage;
                        break :blk std.meta.stringToEnum(Method, value) orelse .unknown;
                    } else .unknown;
                },
                .sessionId => {
                    var decoded = Session{};
                    // Only locally issued bounded IDs can match. A longer
                    // valid string is still a valid unequal session identity.
                    const value = try readString(&scanner, &decoded.buffer);
                    decoded.len = if (value) |text| text.len else max_session_bytes + 1;
                    session = decoded;
                },
                .result, .@"error", .params => {
                    if (try peek(&scanner) != .object_begin) return error.InvalidCdpMessage;
                    const payload = try valueRange(&scanner);
                    switch (field) {
                        .result => result = payload,
                        .@"error" => rejection = payload,
                        .params => params = payload,
                        else => unreachable,
                    }
                },
            }
        } else _ = try valueRange(&scanner);
    }
    if (try next(&scanner) != .object_end or try next(&scanner) != .end_of_document) return error.InvalidCdpMessage;
    if (id) |reply_id| {
        if (method != null or params != null or (result == null) == (rejection == null)) return error.InvalidCdpMessage;
        return .{ .session = session, .kind = .{ .reply = .{ .id = reply_id, .payload = result orelse rejection.?, .rejected = rejection != null } } };
    }
    if (result != null or rejection != null) return error.InvalidCdpMessage;
    return .{ .session = session, .kind = .{ .event = .{ .method = method orelse return error.InvalidCdpMessage, .params = params } } };
}

/// Locate a plain screenshot string only at the direct `result.data` key.
/// The caller has already validated the full frame and matched the reply.
pub fn screenshotData(result: []const u8) Error!?[]const u8 {
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), result);
    defer scanner.deinit();
    if (try next(&scanner) != .object_begin) return error.InvalidCdpMessage;
    var found = false;
    var payload: ?[]const u8 = null;
    var name: [4]u8 = undefined;
    while (try peek(&scanner) != .object_end) {
        const is_data = if (try readString(&scanner, &name)) |key| std.mem.eql(u8, key, "data") else false;
        const value = try valueRange(&scanner);
        if (!is_data) continue;
        if (found) return error.InvalidCdpMessage;
        found = true;
        if (value[0] == '"' and std.mem.indexOfScalar(u8, value, '\\') == null) payload = value[1 .. value.len - 1];
    }
    return payload;
}

fn next(scanner: *std.json.Scanner) Error!std.json.Token {
    return scanner.next() catch error.InvalidCdpMessage;
}

fn peek(scanner: *std.json.Scanner) Error!std.json.TokenType {
    return scanner.peekNextTokenType() catch error.InvalidCdpMessage;
}

// Stream decoded key/string chunks into fixed storage. Even an unknown large
// value or escaped spelling is consumed and validated, not allocated.
fn readString(scanner: *std.json.Scanner, buffer: []u8) Error!?[]const u8 {
    var len: usize = 0;
    var fits = true;
    while (true) {
        const token = try next(scanner);
        const chunk = switch (token) {
            .string, .partial_string => |part| part,
            .partial_string_escaped_1 => |*part| part,
            .partial_string_escaped_2 => |*part| part,
            .partial_string_escaped_3 => |*part| part,
            .partial_string_escaped_4 => |*part| part,
            else => return error.InvalidCdpMessage,
        };
        if (fits and chunk.len <= buffer.len - len) {
            @memcpy(buffer[len..][0..chunk.len], chunk);
            len += chunk.len;
        } else fits = false;
        if (token == .string) return if (fits) buffer[0..len] else null;
    }
}

fn valueRange(scanner: *std.json.Scanner) Error![]const u8 {
    _ = try peek(scanner); // consumes leading separators/whitespace
    const start = scanner.cursor;
    const height = scanner.stackHeight();
    while (true) {
        const token = try next(scanner);
        // readJson counts values from the outer object at depth 0. An empty
        // object at depth 32 is legal, but any value nested further is not.
        if (scanner.stackHeight() > max_json_depth + 1) return error.InvalidCdpMessage;
        // A nonempty container at the highest stack level would require
        // a value at depth 33 (the first item, or the first object key).
        if (scanner.stackHeight() == max_json_depth + 1 and token != .object_begin and token != .array_begin) return error.InvalidCdpMessage;
        if (scanner.stackHeight() != height) continue;
        switch (token) {
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => continue,
            .end_of_document => return error.InvalidCdpMessage,
            else => return scanner.input[start..scanner.cursor],
        }
    }
}
