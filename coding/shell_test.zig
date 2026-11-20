const std = @import("std");
const types = @import("coding_abi").types;
const shell = @import("shell.zig");
const Allocator = std.mem.Allocator;
const equal = std.testing.expectEqual;
const string = std.testing.expectEqualStrings;
const expect = std.testing.expect;

const Call = enum { launch, wait, read, drain, release, mark, stdout, stderr, retain, attach, finish, status, kill };
const HostStatus = Host(void);
const ExecStatus = types.Result(void, types.ToolFailure);
const Calls = struct {
    pub const shell = Mock;
    pub const process = Mock;
    pub const execution = Mock;
};
const command = "opaque host command";
const args = "{\"command\":\"" ++ command ++ "\"}";
const cwd_args = "{\"command\":\"" ++ command ++ "\",\"cwd\":\"relative/path\",\"yield_ms\":0}";
const id = std.math.maxInt(u64) - 11;
const empty_output: types.ShellOutput = .{ .stdout = "", .stderr = "", .truncated = false };

fn Host(comptime T: type) type {
    return types.Result(T, types.HostError);
}

const Mock = struct {
    var calls = std.BoundedArray(Call, 32).init(0) catch unreachable;
    var fail_at: ?Call = null;
    var pid: ?u32 = null;
    var cwd: ?[]const u8 = null;
    var yield: u64 = 1000;
    var running = false;
    var exit_code: ?i32 = 0;
    var producer_failure: ?[]const u8 = null;
    var observation_truncated = false;
    var captured = empty_output;
    var attached: []const u8 = "";
    var finished_failure: ?types.ToolFailure = null;

    fn reset() void {
        calls.len = 0;
        fail_at = null;
        pid = std.math.maxInt(u32);
        cwd = null;
        yield = 1000;
        running = false;
        exit_code = 0;
        producer_failure = null;
        observation_truncated = false;
        captured = empty_output;
        attached = "";
        finished_failure = null;
    }
    fn observe(comptime T: type, call: Call) ?T {
        calls.append(call) catch unreachable;
        if (fail_at) |failure_point| {
            if (failure_point == call) {
                if (T == ExecStatus) return T{ .err = .{ .kind = .failed, .code = "output", .message = "output failure", .retryable = false } };
                return T{ .err = .{ .category = .timeout, .message = "host timeout", .retryable = true } };
            }
        }
        return null;
    }
    fn exact(handle: types.ProcessHandle) void {
        equal(@as(u64, id), handle.id) catch unreachable;
        equal(pid, handle.pid) catch unreachable;
    }
    fn borrowed(buffer: types.BorrowedBuffer) void {
        equal(@as(u32, 74), buffer.index) catch unreachable;
    }
    fn processStatus(handle: types.ProcessHandle) types.ProcessStatus {
        exact(handle);
        // Never substitute an observed PID for the launch handle's identity.
        const state: types.ProcessState = if (running) .{ .running = {} } else if (producer_failure) |message| .{ .failed = message } else .{ .exited = .{ .code = exit_code, .signal = null } };
        return .{ .pid = 9, .state = state, .elapsed_s = 0.125 };
    }
    pub fn launch(_: Allocator, request: types.ShellRequest) Host(types.ProcessHandle) {
        string(command, request.command) catch unreachable;
        if (cwd) |dir| string(dir, request.cwd.?) catch unreachable else expect(request.cwd == null) catch unreachable;
        return observe(Host(types.ProcessHandle), .launch) orelse .{ .ok = .{ .id = id, .pid = pid } };
    }
    pub fn waitForState(_: Allocator, handle: types.ProcessHandle, yield_ms: u64) Host(types.ProcessStatus) {
        equal(yield, yield_ms) catch unreachable;
        const value = processStatus(handle);
        return observe(Host(types.ProcessStatus), .wait) orelse .{ .ok = value };
    }
    pub fn read(_: Allocator, handle: types.ProcessHandle, max_bytes: u64) Host(types.ShellOutput) {
        exact(handle);
        equal(@as(u64, 65_536), max_bytes) catch unreachable;
        return observe(Host(types.ShellOutput), .read) orelse .{ .ok = .{ .stdout = "not consumed", .stderr = "", .truncated = observation_truncated } };
    }
    pub fn drain(_: Allocator, handle: types.ProcessHandle, max_bytes: u64) Host(types.ShellOutput) {
        exact(handle);
        equal(@as(u64, std.math.maxInt(u64)), max_bytes) catch unreachable;
        return observe(Host(types.ShellOutput), .drain) orelse .{ .ok = captured };
    }
    pub fn release(_: Allocator, handle: types.ProcessHandle) HostStatus {
        exact(handle);
        return observe(HostStatus, .release) orelse .{ .ok = {} };
    }
    pub fn markTruncated(_: Allocator, buffer: types.BorrowedBuffer) ExecStatus {
        borrowed(buffer);
        return observe(ExecStatus, .mark) orelse .{ .ok = {} };
    }
    pub fn append(_: Allocator, buffer: types.BorrowedBuffer, channel: ?[]const u8, content: []const u8) ExecStatus {
        borrowed(buffer);
        const stdout = std.mem.eql(u8, "stdout", channel.?);
        if (!stdout) string("stderr", channel.?) catch unreachable;
        string(if (stdout) captured.stdout else captured.stderr, content) catch unreachable;
        return observe(ExecStatus, if (stdout) .stdout else .stderr) orelse .{ .ok = {} };
    }
    pub fn retainProcess(_: Allocator, buffer: types.BorrowedBuffer, handle: types.ProcessHandle, capture: bool) ExecStatus {
        borrowed(buffer);
        exact(handle);
        expect(capture) catch unreachable;
        return observe(ExecStatus, .retain) orelse .{ .ok = {} };
    }
    pub fn attachGuest(_: Allocator, buffer: types.BorrowedBuffer, state: []const u8) ExecStatus {
        borrowed(buffer);
        attached = state;
        return observe(ExecStatus, .attach) orelse .{ .ok = {} };
    }
    pub fn finish(_: Allocator, buffer: types.BorrowedBuffer, failure: ?types.ToolFailure) ExecStatus {
        borrowed(buffer);
        finished_failure = failure;
        return observe(ExecStatus, .finish) orelse .{ .ok = {} };
    }
    pub fn status(_: Allocator, handle: types.ProcessHandle) Host(types.ProcessStatus) {
        const value = processStatus(handle);
        return observe(Host(types.ProcessStatus), .status) orelse .{ .ok = value };
    }
    pub fn killTree(_: Allocator, handle: types.ProcessHandle, force: bool) HostStatus {
        exact(handle);
        expect(force) catch unreachable;
        return observe(HostStatus, .kill) orelse .{ .ok = {} };
    }
};

fn sequence(wanted: []const Call) !void {
    try std.testing.expectEqualSlices(Call, wanted, Mock.calls.slice());
}

test "shell uses strict arguments and requires reserved output before launch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Mock.reset();
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    for ([_][]const u8{
        "null",                                   "{}",                                     "{\"command\":\"\"}",                   "{\"command\":\"x\\u0000y\"}",            "{\"command\":[65]}",
        "{\"command\":\"x\",\"command\":\"y\"}",  "{\"command\":\"x\",\"shell\":\"init\"}", "{\"command\":\"x\",\"cwd\":null}",     "{\"command\":\"x\",\"cwd\":\"\"}",       "{\"command\":\"x\",\"yield_ms\":null}",
        "{\"command\":\"x\",\"yield_ms\":60001}", "{\"command\":\"x\",\"yield_ms\":-0}",    "{\"command\":\"x\",\"yield_ms\":0.0}", "{\"command\":\"x\",\"yield_ms\":\"0\"}",
    }) |invalid_args| try string("invalid_request", shell.invokeWith(scratch, invalid_args, &reserved, Calls).err.code);
    try sequence(&.{});
    try equal(@as(?u32, 74), reserved.index);
    reserved.index = null;
    try string("conflict", shell.invokeWith(scratch, args, &reserved, Calls).err.code);
    try sequence(&.{});
}

test "shell Final uses consumed JSON output and reports terminal exit after release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Mock.reset();
    Mock.cwd = "relative/path";
    Mock.yield = 0;
    Mock.captured.stdout = "\"done\"\n";
    Mock.captured.stderr = "stderr";
    Mock.exit_code = 17;
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    const final = shell.invokeWith(scratch, cwd_args, &reserved, Calls).ok.final;
    try sequence(&.{ .launch, .wait, .read, .drain, .release });
    try equal(@as(?u32, 74), reserved.index);
    try string("{\"exit_code\":17,\"stderr\":\"stderr\",\"stdout\":\"\\\"done\\\"\\n\"}", final.content);
    try string("Process exited with code 17", final.failure.?.message);
    try equal(@as(usize, 0), final.attachments.len);

    Mock.reset();
    Mock.producer_failure = "backend producer failed";
    const failed = shell.invokeWith(scratch, args, &reserved, Calls).ok.final;
    try sequence(&.{ .launch, .wait, .read, .drain, .release });
    try string("{\"exit_code\":null,\"stderr\":\"\",\"stdout\":\"\"}", failed.content);
    try string("backend producer failed", failed.failure.?.message);
}

test "shell terminal buffered output honors the exact inline ceiling and finishes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Mock.reset();
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    Mock.captured = .{ .stdout = "a" ** 32, .stderr = "b" ** 32, .truncated = false };
    try expect(shell.invokeWith(scratch, args, &reserved, Calls).ok == .final);
    Mock.calls.len = 0;
    Mock.captured.stdout = "a" ** 33;
    Mock.exit_code = -1;
    const output = shell.invokeWith(scratch, args, &reserved, Calls).ok.buffered;
    try expect(output.include_initial);
    try equal(@as(?u32, 74), output.output.index);
    try equal(@as(?u32, null), reserved.index);
    try sequence(&.{ .launch, .wait, .read, .drain, .release, .stdout, .stderr, .finish });
    try string("Process exited with code -1", Mock.finished_failure.?.message);
}

test "shell continuation preserves exact launch ID and nullable PID, and latches truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Mock.reset();
    Mock.pid = null;
    Mock.running = true;
    Mock.captured.stdout = "initial";
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    const output = shell.invokeWith(scratch, args, &reserved, Calls).ok.buffered;
    try sequence(&.{ .launch, .wait, .read, .drain, .stdout, .stderr, .retain, .attach });
    try string("{\"id\":18446744073709551604,\"loss_seen\":false,\"pid\":null}", Mock.attached);
    try equal(@as(?u32, null), reserved.index);
    const buffer = output.output.borrow();
    Mock.calls.len = 0;
    Mock.captured = .{ .stdout = "later", .stderr = "diagnostic", .truncated = true };
    const progress = shell.driveWith(scratch, buffer, Mock.attached, false, Calls).ok;
    try sequence(&.{ .status, .drain, .mark, .stdout, .stderr });
    try expect(!progress.finished);
    try equal(@as(u64, 20), progress.wake_after_ms);
    try string("{\"id\":18446744073709551604,\"loss_seen\":true,\"pid\":null}", progress.state);
    Mock.calls.len = 0;
    Mock.running = false;
    Mock.exit_code = 3;
    const failed = shell.driveWith(scratch, buffer, progress.state, false, Calls).err;
    try sequence(&.{ .status, .drain, .stdout, .stderr, .release });
    try string("Process exited with code 3", failed.message);
}

test "shell cancelled drive kills the exact tree and drains before release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Mock.reset();
    Mock.observation_truncated = true;
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    const output = shell.invokeWith(scratch, args, &reserved, Calls).ok.buffered;
    try sequence(&.{ .launch, .wait, .read, .drain, .stdout, .stderr, .retain, .attach });
    try string("{\"id\":18446744073709551604,\"loss_seen\":false,\"pid\":4294967295}", Mock.attached);
    Mock.calls.len = 0;
    Mock.captured.truncated = true;
    const stopped = shell.driveWith(scratch, output.output.borrow(), Mock.attached, true, Calls).ok;
    try sequence(&.{ .kill, .drain, .mark, .stdout, .stderr, .release });
    try expect(stopped.finished);
    try equal(@as(u64, 0), stopped.wake_after_ms);
    try equal(@as(usize, 0), stopped.state.len);
}

test "shell failure preserves Runtime cleanup ownership and does not retry Host effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var reserved: types.OwnedBuffer = .{ .index = 74 };
    Mock.reset();
    Mock.fail_at = .drain;
    const failed = shell.invokeWith(scratch, args, &reserved, Calls).err;
    try equal(.timeout, failed.kind);
    try string("host timeout", failed.message);
    try expect(!failed.retryable);
    try sequence(&.{ .launch, .wait, .read, .drain });
    try equal(@as(?u32, 74), reserved.index);
    Mock.reset();
    Mock.fail_at = .attach;
    Mock.running = true;
    try string("output", shell.invokeWith(scratch, args, &reserved, Calls).err.code);
    try sequence(&.{ .launch, .wait, .read, .drain, .stdout, .stderr, .retain, .attach });
    try equal(@as(?u32, 74), reserved.index);
    Mock.calls.len = 0;
    Mock.fail_at = .kill;
    try string("timeout", shell.driveWith(scratch, reserved.borrow(), Mock.attached, true, Calls).err.code);
    try sequence(&.{.kill});
    Mock.calls.len = 0;
    for ([_][]const u8{ "{}", "{\"id\":\"1\",\"pid\":null,\"loss_seen\":false}", "{\"id\":1,\"loss_seen\":false}", "{\"id\":1,\"pid\":4294967296,\"loss_seen\":false}" }) |bad_state| {
        try string("Invalid shell continuation state", shell.driveWith(scratch, reserved.borrow(), bad_state, false, Calls).err.message);
    }
    try sequence(&.{});
}
