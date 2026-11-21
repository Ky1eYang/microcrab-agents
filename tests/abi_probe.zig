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
    if (std.mem.eql(u8, name, "bulk")) return runBulk(scratch, args);
    if (std.mem.eql(u8, name, "session")) return runSession(scratch);
    const attachments = scratch.dupe(types.MediaAttachment, &.{
        .{ .media_type = "image/png", .data = args },
        .{ .media_type = "image/gif", .data = "\x00\xff" },
    }) catch @trap();
    return .{ .ok = .{ .final = .{
        .content = info,
        .failure = .{ .kind = .timeout, .code = "probe", .message = name, .retryable = true },
        .attachments = attachments,
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

fn runBulk(scratch: Scratch, path: []const u8) types.InvokeResult {
    const result = verify(host.glob.glob(scratch, .{
        .root = path,
        .pattern = "*",
        .include_hidden = false,
        .include_ignored = false,
        .include_directories = false,
        .max_results = 4096,
    }));
    check(result.entries.len == 4096 and !result.truncated);
    for (result.entries) |entry| {
        check(entry.kind == .file and std.mem.eql(u8, entry.path, "entry.txt"));
    }
    return .{ .ok = .{ .final = .{ .content = result.entries[4095].path } } };
}

fn runSession(scratch: Scratch) types.InvokeResult {
    const session = abi.session;
    const facts = verify(session.toolCallFacts(scratch));
    check(std.mem.eql(u8, facts.session_id, "session-exact-🦀"));
    check(std.mem.eql(u8, facts.admitted_mode.?, "plan"));
    check(facts.observed_at_unix_ms == 0xfedc_ba98_7654_3210);
    const unselected = verify(session.toolCallFacts(scratch));
    check(unselected.admitted_mode == null and unselected.observed_at_unix_ms == 1);
    switch (session.toolCallFacts(scratch)) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .unavailable and std.mem.eql(u8, failure.message, "not admitted")),
    }

    const single = verify(session.variableGet(scratch, "null-value"));
    check(std.mem.eql(u8, single, "null"));
    switch (session.variableGet(scratch, "missing")) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .absent and std.mem.eql(u8, failure.message, "not found")),
    }
    const values = verify(session.variableGetAll(scratch));
    check(values.len == 2);
    check(std.mem.eql(u8, values[0].name, "value-🦀") and std.mem.eql(u8, values[0].value_json, "[false,{},null]"));
    check(std.mem.eql(u8, values[1].name, "other") and std.mem.eql(u8, values[1].value_json, "true"));
    const meta = verify(session.variableMetadata(scratch));
    check(meta.len == 2);
    check(std.mem.eql(u8, meta[0].name, "value-🦀") and meta[0].visibility == .invisible);
    check(meta[0].persistence == .persisted and meta[0].owner == .client);
    check(std.mem.eql(types.Role, meta[0].editors, &.{ .runtime, .agent }));
    check(std.mem.eql(u8, meta[1].name, "secret") and meta[1].visibility == .secret);
    check(meta[1].persistence == .ephemeral and meta[1].owner == .client and meta[1].editors.len == 0);

    verify(session.variableChange(scratch, .{
        .set = &.{ .{ .name = "plain", .value_json = "{\"a\":1}" }, .{ .name = "bool", .value_json = "false" } },
        .remove = &.{ "gone", "gone-🦀" },
        .scoped_set = &.{
            .{ .name = "keep-editors", .value_json = "null", .visibility = .invisible, .persistence = .ephemeral, .editors = null },
            .{ .name = "clear-editors", .value_json = "[]", .visibility = .visible, .persistence = .persisted, .editors = &.{} },
            .{ .name = "new-editors", .value_json = "42", .visibility = .invisible, .persistence = .persisted, .editors = &.{ .client, .runtime, .agent } },
        },
    }));
    switch (session.variableChange(scratch, .{ .set = &.{}, .remove = &.{}, .scoped_set = &.{} })) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .rejected and std.mem.eql(u8, failure.message, "fixture rejection")),
    }
    // The first result must still own its lifted string after later allocations.
    return .{ .ok = .{ .final = .{ .content = facts.session_id } } };
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
