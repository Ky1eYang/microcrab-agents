//! Isolated Core ABI integration fixture, not a production guest.
const std = @import("std");
const abi = @import("coding_abi");
const t = abi.types;
const Scratch = std.mem.Allocator;
comptime {
    abi.exportAgent(@This());
}

pub fn init(scratch: Scratch) t.InitResult {
    return switch (abi.host.hostInfo(scratch)) {
        .ok => .{ .ready = {} },
        .err => |err| .{ .failed = .{ .code = @tagName(err.code), .message = err.message } },
    };
}

pub fn describe(scratch: Scratch, supplied: []const u8) t.DescribeResult {
    const info = switch (abi.host.hostInfo(scratch)) {
        .ok => |info| info,
        .err => |err| return .{ .err = err.message },
    };
    if (!std.mem.eql(u8, info, supplied)) return .{ .err = "HostInfo differs" };
    const catalog =
        \\[{"name":"abi-probe","modes":[{"name":"build","role":"both"}],
        \\ "variables":{"rules":[],"hints":[]},"tools":[{"name":"read",
        \\ "description":"ABI probe: read a controlled file","parameters":{"type":"object"}}]}]
    ;
    return .{ .ok = catalog };
}

pub fn invoke(scratch: Scratch, _: []const u8, name: []const u8, arguments: []const u8) t.InvokeResult {
    std.debug.assert(std.mem.eql(u8, name, "read"));
    const Args = struct { path: []const u8, buffered: bool = false };
    const request = std.json.parseFromSliceLeaky(Args, scratch, arguments, .{}) catch @trap();
    const result = switch (abi.host.text_read.read(scratch, .{
        .path = request.path,
        .offset_line = 1,
        .max_lines = 20,
        .max_bytes = 4096,
    })) {
        .ok => |result| result,
        .err => |err| return .{ .err = .{
            .kind = .failed,
            .code = @tagName(err.code),
            .message = err.message,
            .retryable = false,
        } },
    };
    if (!request.buffered) return .{ .ok = .{ .final = .{ .content = result.content } } };
    var buffer = switch (abi.execution.create(scratch, &.{"result"})) {
        .ok => |owned| owned,
        .err => |err| return .{ .err = err },
    };
    defer abi.execution.drop(&buffer);
    const borrow = buffer.borrow();
    switch (abi.execution.append(scratch, borrow, "result", "initial:")) {
        .ok => {},
        .err => |err| return .{ .err = err },
    }
    const state = std.mem.concat(scratch, u8, &.{ "\x00", result.content }) catch @trap();
    switch (abi.execution.attachGuest(scratch, borrow, state)) {
        .ok => {},
        .err => |err| return .{ .err = err },
    }
    return .{ .ok = .{ .buffered = .{ .output = buffer.take(), .include_initial = true } } };
}

pub fn drive(scratch: Scratch, buffer: t.BorrowedBuffer, state: []const u8, cancelled: bool) t.DriveResult {
    if (cancelled) return .{ .err = .{
        .kind = .cancelled,
        .code = "cancelled",
        .message = "fixture cancelled",
        .retryable = false,
    } };
    if (state.len == 0 or state[0] > 7) @trap();
    if (state[0] == 7) {
        switch (abi.execution.append(scratch, buffer, "result", state[1..])) {
            .ok => {},
            .err => |err| return .{ .err = err },
        }
        return .{ .ok = .{ .state = &.{}, .wake_after_ms = 0, .finished = true } };
    }
    const next = scratch.dupe(u8, state) catch @trap();
    next[0] += 1;
    switch (abi.execution.append(scratch, buffer, "result", ".")) {
        .ok => {},
        .err => |err| return .{ .err = err },
    }
    return .{ .ok = .{ .state = next, .wake_after_ms = 1, .finished = false } };
}
