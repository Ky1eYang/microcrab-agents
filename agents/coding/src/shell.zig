//! Run the Host's linked shell; the catalog and Runtime own authority and cleanup.
const std = @import("std");
const abi = @import("coding_abi");
const support = @import("shell_support.zig");
const types = abi.types;
const Allocator = std.mem.Allocator;

const initial_read_bytes = 65_536;
const final_bytes = 64;
const drive_delay_ms = 20;
// Drain is all-or-nothing; Runtime clamps this to the granted capture/response
// budgets. Reusing the initial read ceiling here would reject larger captures.
const drain_bytes = std.math.maxInt(u64);
const Arguments = struct {
    command: support.String,
    cwd: support.PresentString = .{},
    yield_ms: support.Unsigned(u64) = .{ .value = 1000 },
};
const StoredState = struct {
    id: support.Unsigned(u64),
    pid: ?support.Unsigned(u32),
    loss_seen: bool,
};
const HostCalls = struct {
    const shell = abi.host.shell;
    const process = abi.host.process;
    const execution = abi.execution;
};

/// Entry checks the actual advertised tool/capabilities and reserves the standard
/// result/stdout/stderr buffer. Only a successful Buffered result takes the owner.
pub fn invoke(scratch: Allocator, arguments: []const u8, reserved: *types.OwnedBuffer) types.InvokeResult {
    return invokeWith(scratch, arguments, reserved, HostCalls);
}

/// The shell, process and execution fields implement the respective ABI calls.
/// Runtime cleans up invocation-owned handles after errors, including any partial
/// transfer to a buffer. No guest retry, process lookup or duplicate launch.
pub fn invokeWith(scratch: Allocator, arguments: []const u8, reserved: *types.OwnedBuffer, calls: anytype) types.InvokeResult {
    const args = switch (support.parse(Arguments, scratch, arguments)) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure },
    };
    if (support.checkString(args.command.value, 65_536)) |failure| return .{ .err = failure };
    if (args.cwd.value) |cwd| if (support.checkString(cwd, 4096)) |failure| return .{ .err = failure };
    if (args.yield_ms.value > 60_000) return .{ .err = support.invalid("numeric argument must be between 0 and 60000") };
    if (reserved.index == null) return .{ .err = support.failed("conflict", "Shell requires one reserved invocation output") };

    const handle = switch (calls.shell.launch(scratch, types.ShellRequest{ .command = args.command.value, .cwd = args.cwd.value })) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    const status = switch (calls.process.waitForState(scratch, handle, args.yield_ms.value)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    // Observe without consuming before selecting the continuation path. Output
    // is subsequently appended only from drain, never from this observation.
    const truncated = switch (calls.shell.read(scratch, handle, initial_read_bytes)) {
        .ok => |observed| observed.truncated,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    const output = switch (calls.shell.drain(scratch, handle, drain_bytes)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };

    if (status.state == .running or truncated) {
        const buffer = reserved.borrow();
        if (appendOutput(scratch, calls.execution, buffer, output, output.truncated)) |failure| return .{ .err = failure };
        const state = encodeState(scratch, handle, output.truncated) catch return .{ .err = support.allocationFailed() };
        switch (calls.execution.retainProcess(scratch, buffer, handle, .shell_text)) {
            .ok => {},
            .err => |failure| return .{ .err = failure },
        }
        switch (calls.execution.attachGuest(scratch, buffer, state)) {
            .ok => {},
            .err => |failure| return .{ .err = failure },
        }
        return buffered(reserved);
    }

    switch (calls.process.release(scratch, handle)) {
        .ok => {},
        .err => |err| return .{ .err = support.hostFailure(err) },
    }
    const failure = terminalFailure(scratch, status.state);
    if (output.truncated or output.stdout.len + output.stderr.len > final_bytes) {
        const buffer = reserved.borrow();
        if (appendOutput(scratch, calls.execution, buffer, output, output.truncated)) |err| return .{ .err = err };
        switch (calls.execution.finish(scratch, buffer, failure)) {
            .ok => {},
            .err => |err| return .{ .err = err },
        }
        return buffered(reserved);
    }
    const content = std.json.stringifyAlloc(scratch, .{
        .exit_code = if (status.state == .exited) status.state.exited.code else null,
        .stderr = output.stderr,
        .stdout = output.stdout,
    }, .{}) catch return .{ .err = support.allocationFailed() };
    return .{ .ok = .{ .final = .{ .content = content, .failure = failure } } };
}

pub fn drive(scratch: Allocator, output: types.BorrowedBuffer, state: []const u8, cancelled: bool) types.DriveResult {
    return driveWith(scratch, output, state, cancelled, HostCalls);
}

pub fn driveWith(scratch: Allocator, buffer: types.BorrowedBuffer, state: []const u8, cancelled: bool, calls: anytype) types.DriveResult {
    const saved = std.json.parseFromSliceLeaky(StoredState, scratch, state, .{}) catch |err| return .{ .err = if (err == error.OutOfMemory) support.allocationFailed() else support.failed("failed", "Invalid shell continuation state") };
    const handle = types.ProcessHandle{ .id = saved.id.value, .pid = if (saved.pid) |pid| pid.value else null };
    const status: ?types.ProcessStatus = if (cancelled) blk: {
        switch (calls.process.killTree(scratch, handle, true)) {
            .ok => {},
            .err => |err| return .{ .err = support.hostFailure(err) },
        }
        break :blk null;
    } else switch (calls.process.status(scratch, handle)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    const tail = switch (calls.shell.drain(scratch, handle, drain_bytes)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    if (appendOutput(scratch, calls.execution, buffer, tail, tail.truncated and !saved.loss_seen)) |failure| return .{ .err = failure };
    if (status) |current| {
        if (current.state == .running) {
            const next = encodeState(scratch, handle, saved.loss_seen or tail.truncated) catch return .{ .err = support.allocationFailed() };
            return .{ .ok = .{ .state = next, .wake_after_ms = drive_delay_ms, .finished = false } };
        }
    }
    switch (calls.process.release(scratch, handle)) {
        .ok => {},
        .err => |err| return .{ .err = support.hostFailure(err) },
    }
    if (status) |current| if (terminalFailure(scratch, current.state)) |failure| return .{ .err = failure };
    // Runtime settles the driver result (including cancellation); drive only
    // borrows the buffer and must not finish it a second time.
    return .{ .ok = .{ .state = &.{}, .wake_after_ms = 0, .finished = true } };
}

fn appendOutput(scratch: Allocator, execution: anytype, buffer: types.BorrowedBuffer, output: types.ShellOutput, new_loss: bool) ?types.ToolFailure {
    if (new_loss) switch (execution.markTruncated(scratch, buffer)) {
        .ok => {},
        .err => |failure| return failure,
    };
    switch (execution.append(scratch, buffer, "stdout", output.stdout)) {
        .ok => {},
        .err => |failure| return failure,
    }
    return switch (execution.append(scratch, buffer, "stderr", output.stderr)) {
        .ok => null,
        .err => |failure| failure,
    };
}

fn terminalFailure(scratch: Allocator, state: types.ProcessState) ?types.ToolFailure {
    return switch (state) {
        .running => null,
        .failed => |message| support.failed("failed", message),
        .exited => |exit| blk: {
            const code = exit.code orelse break :blk null;
            if (code == 0) break :blk null;
            const message = std.fmt.allocPrint(scratch, "Process exited with code {d}", .{code}) catch break :blk support.allocationFailed();
            break :blk support.failed("failed", message);
        },
    };
}

fn encodeState(scratch: Allocator, handle: types.ProcessHandle, loss_seen: bool) Allocator.Error![]const u8 {
    return std.json.stringifyAlloc(scratch, .{ .id = handle.id, .loss_seen = loss_seen, .pid = handle.pid }, .{ .emit_null_optional_fields = true });
}

fn buffered(reserved: *types.OwnedBuffer) types.InvokeResult {
    return .{ .ok = .{ .buffered = .{ .output = reserved.take(), .include_initial = true } } };
}
