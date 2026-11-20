//! Call-scoped argument validation and failure translation for image and shell.
const std = @import("std");
const types = @import("coding_abi").types;
const Allocator = std.mem.Allocator;

const max_arguments = 4_300_000;

pub const String = struct {
    value: []const u8,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!String {
        return switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            .string, .allocated_string => |value| .{ .value = value },
            else => error.UnexpectedToken,
        };
    }
};

// Optional field, but an explicit null is not permitted by the tool schema.
pub const PresentString = struct {
    value: ?[]const u8 = null,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!PresentString {
        return .{ .value = (try String.jsonParse(allocator, source, options)).value };
    }
};

// Zig's default integer decoder accepts strings and integral floats. Require a
// nonnegative JSON integer token (including for exact continuation identities).
pub fn Unsigned(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
            const digits = switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
                .number, .allocated_number => |value| value,
                else => return error.UnexpectedToken,
            };
            for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
            return .{ .value = try std.fmt.parseInt(T, digits, 10) };
        }
    };
}

pub fn parse(comptime T: type, scratch: Allocator, arguments: []const u8) types.Result(T, types.ToolFailure) {
    if (arguments.len > max_arguments) return .{ .err = invalid("argument byte limit exceeded") };
    const value = std.json.parseFromSliceLeaky(T, scratch, arguments, .{}) catch |err| return .{ .err = switch (err) {
        error.OutOfMemory => allocationFailed(),
        error.DuplicateField => invalid("duplicate argument field"),
        error.UnknownField => invalid("unknown argument field"),
        error.MissingField => invalid("missing required argument field"),
        error.UnexpectedToken => invalid("unexpected JSON value in arguments"),
        error.InvalidNumber, error.Overflow, error.InvalidCharacter => invalid("invalid unsigned integer argument"),
        else => invalid("malformed JSON arguments"),
    } };
    return .{ .ok = value };
}

pub fn checkString(value: []const u8, comptime limit: usize) ?types.ToolFailure {
    if (value.len > limit) return invalid(std.fmt.comptimePrint("string exceeds maximum {d} bytes", .{limit}));
    if (std.mem.indexOfScalar(u8, value, 0) != null) return invalid("string contains NUL");
    if (value.len == 0) return invalid("string must not be empty");
    return null;
}

pub fn failed(code: []const u8, message: []const u8) types.ToolFailure {
    return .{ .kind = .failed, .code = code, .message = message, .retryable = false };
}

pub fn allocationFailed() types.ToolFailure {
    return failed("failed", "tool allocation failed");
}

pub fn invalid(message: []const u8) types.ToolFailure {
    return failed("invalid_request", message);
}

pub fn hostFailure(err: types.HostError) types.ToolFailure {
    return switch (err.category) {
        .timeout => .{ .kind = .timeout, .code = "timeout", .message = err.message, .retryable = false },
        .cancelled => .{ .kind = .cancelled, .code = "cancelled", .message = err.message, .retryable = false },
        .permission => failed("denied", err.message),
        .not_found, .io => failed("io", err.message),
        .conflict, .unsupported => failed(@tagName(err.category), err.message),
    };
}
