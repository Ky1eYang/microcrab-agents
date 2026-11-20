//! Test-only WIT round-trip probe. Not a Coding guest or a selectable catalog.
const std = @import("std");
const abi = @import("coding_abi");
const types = abi.types;
const host = abi.host;
const execution = abi.execution;
const Scratch = std.mem.Allocator;

comptime {
    abi.exportAgent(@This());
}

pub fn init(scratch: Scratch) types.InitResult {
    return switch (host.hostInfo(scratch)) {
        .ok => .{ .ready = {} },
        .err => |failure| .{ .failed = .{ .code = @tagName(failure.code), .message = failure.message } },
    };
}

pub fn describe(_: Scratch, info: []const u8) types.DescribeResult {
    if (std.mem.eql(u8, info, "invalid")) return .{ .err = info };
    return .{ .ok = info };
}

pub fn invoke(scratch: Scratch, info: []const u8, name: []const u8, args: []const u8) types.InvokeResult {
    if (std.mem.eql(u8, name, "buffer")) return runBuffer(scratch, info, args);
    if (std.mem.eql(u8, name, "host")) return runHost(scratch, args);
    return .{ .ok = .{ .final = .{
        .content = info,
        .failure = .{ .kind = .timeout, .code = "probe", .message = name, .retryable = true },
        .attachments = &.{ .{ .media_type = "image/png", .data = args }, .{
            .media_type = "image/gif",
            .data = "\x00\xff",
        } },
    } } };
}

pub fn drive(scratch: Scratch, buffer: types.BorrowedBuffer, state: []const u8, cancelled: bool) types.DriveResult {
    if (cancelled) return .{ .err = .{
        .kind = .cancelled,
        .code = "cancelled",
        .message = "drive",
        .retryable = false,
    } };
    switch (execution.markTruncated(scratch, buffer)) {
        .ok => {},
        .err => |failure| return .{ .err = failure },
    }
    return .{ .ok = .{ .state = state, .wake_after_ms = 0x1_0000_0001, .finished = true } };
}

fn runBuffer(scratch: Scratch, info: []const u8, state: []const u8) types.InvokeResult {
    var buffer = switch (execution.create(scratch, &.{ "stdout", "stderr" })) {
        .ok => |output| output,
        .err => |failure| return .{ .err = failure },
    };
    defer execution.drop(&buffer);
    const borrow = buffer.borrow();
    verify(execution.append(scratch, borrow, "stdout", info));
    verify(execution.append(scratch, borrow, null, ""));
    if (std.mem.eql(u8, state, "drop")) {
        verify(execution.finish(scratch, borrow, .{
            .kind = .failed,
            .code = "probe-code",
            .message = "probe-message",
            .retryable = true,
        }));
        return .{ .err = .{ .kind = .failed, .code = "drop", .message = info, .retryable = false } };
    }
    verify(execution.finish(scratch, borrow, null));
    verify(execution.attachProcess(scratch, borrow, .{ .id = 0x1_0000_0007, .pid = 42 }, true));
    verify(execution.retainProcess(scratch, borrow, .{ .id = 0x1_0000_0008, .pid = null }, false));
    verify(execution.attachGuest(scratch, borrow, state));
    return .{ .ok = .{ .buffered = .{ .output = buffer.take(), .include_initial = true } } };
}

fn runHost(scratch: Scratch, path: []const u8) types.InvokeResult {
    const read = verify(host.text_read.read(scratch, .{
        .path = path,
        .offset_line = 0x1_0000_0002,
        .max_lines = 3,
        .max_bytes = 4,
    }));
    check(read.start_line == 3 and read.next_line == 0x1_0000_0003 and read.truncated);
    check(std.mem.eql(u8, read.version, "v1"));
    const write: types.WriteRequest = .{ .path = path, .content = read.content, .precondition = .{ .version = read.version } };
    const receipt = verify(host.text_write.write(scratch, write));
    check(receipt.bytes == 0x1_0000_0004 and std.mem.eql(u8, receipt.version, "v2"));
    const missing: types.WriteRequest = .{ .path = path, .content = "", .precondition = .{ .missing = {} } };
    const mutations = verify(host.file_mutation.preflight(scratch, &.{
        .{ .write = missing },
        .{ .delete = .{ .path = path, .expected_version = "v2" } },
        .{ .move = .{ .path = path, .destination = "dest", .expected_version = "v3", .content = "moved" } },
    }));
    check(mutations.len == 3);
    for (mutations) |mutation| {
        const applied = verify(host.file_mutation.mutate(scratch, mutation));
        check(applied.version == null and applied.bytes == 17 and !applied.source_removed);
        check(applied.destination_written and std.mem.eql(u8, applied.diagnostic.?, "partial"));
    }
    switch (host.cache_points.capture(scratch, path, 999)) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .conflict and std.mem.eql(u8, failure.message, "cache conflict")),
    }
    const globs = verify(host.glob.glob(scratch, .{
        .root = path,
        .pattern = "*",
        .include_hidden = true,
        .include_ignored = false,
        .include_directories = true,
        .max_results = 0x1_0000_0005,
    }));
    check(globs.entries.len == 2 and globs.entries[0].kind == .symlink and globs.truncated);
    check(std.mem.eql(u8, globs.entries[1].path, "second"));
    const matches = verify(host.grep.grep(scratch, .{
        .root = path,
        .pattern = "find",
        .include_glob = "*.zig",
        .case_sensitive = false,
        .literal = true,
        .max_matches = 10,
        .max_bytes = 11,
    }));
    check(matches.matches.len == 1 and !matches.truncated);
    check(matches.matches[0].line == 0x1_0000_0006);
    check(std.mem.eql(u8, matches.matches[0].text, "found"));
    const meta = verify(host.filesystem.stat(scratch, path));
    check(meta.kind == .file and meta.size == 13 and meta.modified_ms == 0x1_0000_0007);
    const file = verify(host.filesystem.openRead(scratch, path));
    const bytes = verify(host.filesystem.read(scratch, file, 2, 10));
    check(std.mem.eql(u8, bytes, "\xff\x00"));
    verify(host.filesystem.close(scratch, file));
    const process = verify(host.shell.launch(scratch, .{ .command = "test", .cwd = path }));
    check(process.id == 0x1_0000_0008 and process.pid == null);
    const status = verify(host.process.status(scratch, process));
    check(status.pid == 42 and status.state.exited.code == -3 and status.state.exited.signal == .kill);
    check(status.elapsed_s == 1.25);
    check(verify(host.process.waitForState(scratch, process, 50)).state == .running);
    const output = verify(host.shell.read(scratch, process, 100));
    check(std.mem.eql(u8, output.stdout, "out") and std.mem.eql(u8, output.stderr, "err") and output.truncated);
    check(verify(host.shell.drain(scratch, process, 101)).stdout.len == 0);
    verify(host.shell.write(scratch, process, "write", true));
    switch (host.process.killTree(scratch, process, true)) {
        .ok => @trap(),
        .err => |failure| check(failure.category == .permission and failure.retryable and std.mem.eql(u8, failure.message, "deny")),
    }
    verify(host.process.release(scratch, process));
    return .{ .ok = .{ .final = .{ .content = read.content } } };
}

fn verify(result: anytype) std.meta.FieldType(@TypeOf(result), .ok) {
    return switch (result) {
        .ok => |value| value,
        .err => @trap(),
    };
}

fn check(condition: bool) void {
    if (!condition) @trap();
}
