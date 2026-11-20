//! Agent execution imports; buffers are the only WIT resources used by Coding.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("imports.zig");
const codec = @import("codec.zig");
const host = @import("host.zig");
const Scratch = std.mem.Allocator;
const module = "microcrab:agent/execution@0.8.0";
const Status = types.Result(void, types.ToolFailure);

pub fn create(scratch: Scratch, channels: []const []const u8) types.Result(types.OwnedBuffer, types.ToolFailure) {
    const raw = wire.function(fn (u32, u32, u32) callconv(.C) void, module, "create");
    var pair: [8]u8 = undefined;
    codec.lowerScratch([]const []const u8, scratch, channels, &pair);
    const address = std.mem.readInt(u32, pair[0..4], .little);
    return wire.call(types.Result(types.OwnedBuffer, types.ToolFailure), scratch, raw, .{ address, @as(u32, channels.len) });
}

/// Drop an owned resource unless already transferred. Never call this for a borrow.
pub fn drop(buffer: *types.OwnedBuffer) void {
    const index = buffer.index orelse return;
    buffer.index = null;
    const raw = wire.function(fn (u32) callconv(.C) void, module, "[resource-drop]buffer");
    raw(index);
}

pub fn append(scratch: Scratch, buffer: types.BorrowedBuffer, channel: ?[]const u8, content: []const u8) Status {
    const raw = wire.function(fn (u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "append");
    return wire.call(Status, scratch, raw, .{buffer.index} ++ wire.optionalSlice(channel) ++ wire.slice(content));
}

pub fn markTruncated(scratch: Scratch, buffer: types.BorrowedBuffer) Status {
    const raw = wire.function(fn (u32, u32) callconv(.C) void, module, "mark-truncated");
    return wire.call(Status, scratch, raw, .{buffer.index});
}

pub fn finish(scratch: Scratch, buffer: types.BorrowedBuffer, failure: ?types.ToolFailure) Status {
    const raw = wire.function(
        fn (u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void,
        module,
        "finish",
    );
    const args: struct { u32, u32, u32, u32, u32, u32, u32, u32 } = if (failure) |value|
        .{ buffer.index, @as(u32, 1), @as(u32, @intFromEnum(value.kind)) } ++
            wire.slice(value.code) ++ wire.slice(value.message) ++ .{@as(u32, @intFromBool(value.retryable))}
    else
        .{ buffer.index, 0, 0, 0, 0, 0, 0, 0 };
    return wire.call(Status, scratch, raw, args);
}

pub fn attachProcess(scratch: Scratch, buffer: types.BorrowedBuffer, process: types.ProcessHandle, captured: bool) Status {
    return linkProcess(scratch, buffer, process, captured, "attach-process");
}

pub fn retainProcess(scratch: Scratch, buffer: types.BorrowedBuffer, process: types.ProcessHandle, captured: bool) Status {
    return linkProcess(scratch, buffer, process, captured, "retain-process");
}

pub fn attachGuest(scratch: Scratch, buffer: types.BorrowedBuffer, state: []const u8) Status {
    const raw = wire.function(fn (u32, u32, u32, u32) callconv(.C) void, module, "attach-guest");
    return wire.call(Status, scratch, raw, .{buffer.index} ++ wire.slice(state));
}

fn linkProcess(scratch: Scratch, buffer: types.BorrowedBuffer, process: types.ProcessHandle, captured: bool, comptime name: []const u8) Status {
    const raw = wire.function(fn (u32, u64, u32, u32, u32, u32) callconv(.C) void, module, name);
    return wire.call(Status, scratch, raw, .{buffer.index} ++ host.processArgs(process) ++ .{@as(u32, @intFromBool(captured))});
}
