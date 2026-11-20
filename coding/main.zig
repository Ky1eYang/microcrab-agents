//! Coding Guest entry for the canonical Agent 0.8 world.
const std = @import("std");
const abi = @import("coding_abi");
const catalog = @import("catalog.zig");
const text = @import("text.zig");
const patch = @import("apply_patch.zig");
const image = @import("image.zig");
const shell = @import("shell.zig");
const types = abi.types;
const Allocator = std.mem.Allocator;

comptime {
    abi.exportAgent(@This());
}

pub fn init(_: Allocator) types.InitResult {
    return .{ .ready = {} };
}

fn hostInfo(scratch: Allocator, supplied: []const u8) types.Result(catalog.HostInfo, []const u8) {
    const imported = switch (abi.host.hostInfo(scratch)) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure.message },
    };
    return .{ .ok = catalog.checkedHost(scratch, supplied, imported) catch |err| {
        return .{ .err = switch (err) {
            error.HostInfoMismatch => "host-info import does not match the supplied HostInfo",
            else => @errorName(err),
        } };
    } };
}

pub fn describe(scratch: Allocator, supplied: []const u8) types.DescribeResult {
    const host = switch (hostInfo(scratch, supplied)) {
        .ok => |value| value,
        .err => |message| return .{ .err = message },
    };
    return .{ .ok = catalog.describe(scratch, host) catch |err| return .{ .err = @errorName(err) } };
}

fn failed(message: []const u8) types.InvokeResult {
    return .{ .err = .{ .kind = .failed, .code = "failed", .message = message, .retryable = false } };
}

pub fn invoke(scratch: Allocator, supplied: []const u8, name: []const u8, arguments: []const u8) types.InvokeResult {
    const host = switch (hostInfo(scratch, supplied)) {
        .ok => |value| value,
        .err => |message| return failed(message),
    };
    var reserved = switch (abi.execution.create(scratch, &.{ "result", "stdout", "stderr" })) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure },
    };
    defer abi.execution.drop(&reserved);
    if (!host.offers(name)) return .{ .err = .{
        .kind = .failed,
        .code = "invalid_request",
        .message = "unknown or unavailable tool on this Host",
        .retryable = false,
    } };
    const eq = std.mem.eql;
    if (host.shellName()) |name_of_shell| {
        if (eq(u8, name, name_of_shell)) return shell.invoke(scratch, arguments, &reserved);
    }
    if (eq(u8, name, "read_image")) return image.invoke(scratch, arguments);
    const multi_patch = eq(u8, name, "apply_patch");
    const result = if (multi_patch) patch.invoke(scratch, arguments) else text.invoke(scratch, name, arguments, abi.host);
    const content = switch (result) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure },
    };
    if (content.len <= 512 or multi_patch) return .{ .ok = .{ .final = .{ .content = content } } };
    switch (abi.execution.append(scratch, reserved.borrow(), "result", content)) {
        .ok => {},
        .err => |failure| return .{ .err = failure },
    }
    switch (abi.execution.finish(scratch, reserved.borrow(), null)) {
        .ok => {},
        .err => |failure| return .{ .err = failure },
    }
    return .{ .ok = .{ .buffered = .{ .output = reserved.take(), .include_initial = true } } };
}

pub fn drive(scratch: Allocator, output: types.BorrowedBuffer, state: []const u8, cancelled: bool) types.DriveResult {
    return shell.drive(scratch, output, state, cancelled);
}
