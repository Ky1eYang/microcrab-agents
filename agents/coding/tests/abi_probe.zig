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
    var buffer = switch (execution.create(scratch, &.{
        types.OutputChannel.text("stdout"),
        .{ .name = "fixture-bytes", .kind = .{ .bytes = "image/png" } },
    })) {
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
    verify(execution.attachProcess(scratch, borrow, .{ .id = 0x1_0000_0007, .pid = 42 }, .raw_pipes));
    verify(execution.retainProcess(scratch, borrow, .{ .id = 0x1_0000_0008, .pid = null }, .shell_text));
    verify(execution.attachGuest(scratch, borrow, state));
    return .{ .ok = .{ .buffered = .{ .output = buffer.take(), .include_initial = true } } };
}

fn runHost(scratch: Scratch, path: []const u8) types.InvokeResult {
    const observed = verify(host.file_versions.read(scratch, .{
        .path = path,
        .offset_line = 0x1_0000_0002,
        .max_lines = 3,
        .max_bytes = 4,
    }));
    check(std.mem.eql(u8, observed.reference, "fv_0123456789abcdef"));
    const read = observed.page;
    check(read.start_line == 3 and read.next_line == 0x1_0000_0003 and read.truncated);
    check(std.mem.eql(u8, read.version, "v1"));
    const write: types.WriteRequest = .{ .path = path, .content = read.content, .precondition = .{ .version = read.version } };
    const receipt = verify(host.file_versions.write(scratch, write));
    check(receipt.bytes == 0x1_0000_0004 and std.mem.eql(u8, receipt.version, "v2"));
    const missing: types.WriteRequest = .{ .path = path, .content = "", .precondition = .{ .missing = {} } };
    const mutations = verify(host.file_versions.preflight(scratch, &.{
        .{ .write = missing },
        .{ .delete = .{ .path = path, .expected_version = "v2" } },
        .{ .move = .{ .path = path, .destination = "dest", .expected_version = "v3", .content = "moved" } },
    }));
    check(mutations.len == 3);
    for (mutations) |mutation| {
        const applied = verify(host.file_versions.mutate(scratch, mutation));
        check(applied.version == null and applied.bytes == 17 and !applied.source_removed);
        check(applied.destination_written and std.mem.eql(u8, applied.diagnostic.?, "partial"));
    }
    switch (host.cache_points.capture(scratch, path, 999)) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .conflict and std.mem.eql(u8, failure.message, "cache conflict")),
    }
    const globs = verify(host.glob_ignore.globFromState(scratch, .{
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
    const result = verify(host.glob_ignore.globFromState(scratch, .{
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
    const facts_json = verify(session.eval(scratch, "vars::call_facts()", null));
    const facts = std.json.parseFromSliceLeaky(types.CallFacts, scratch, facts_json, .{ .ignore_unknown_fields = true }) catch @trap();
    check(std.mem.eql(u8, facts.session_id, "session-exact-🦀"));
    check(std.mem.eql(u8, facts.admitted_mode.?, "plan"));
    check(facts.observed_at_unix_ms == 0xfedc_ba98_7654_3210);

    const unselected_json = verify(session.eval(scratch, "vars::call_facts()", null));
    const unselected = std.json.parseFromSliceLeaky(types.CallFacts, scratch, unselected_json, .{ .ignore_unknown_fields = true }) catch @trap();
    check(unselected.admitted_mode == null and unselected.observed_at_unix_ms == 1);
    switch (session.eval(scratch, "vars::call_facts()", null)) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .unavailable and std.mem.eql(u8, failure.message, "not admitted")),
    }

    const single = verify(session.eval(scratch, "vars::get(\"null-value\")", null));
    check(std.mem.eql(u8, single, "null"));
    switch (session.eval(scratch, "vars::get(\"missing\")", null)) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .absent and std.mem.eql(u8, failure.message, "not found")),
    }
    const echoed = verify(session.eval(scratch, "args.value", "{\"value\":\"val-🦀\"}"));
    check(std.mem.eql(u8, echoed, "\"val-🦀\""));
    switch (session.eval(scratch, "vars::set(\"blocked\", true)", "{\"blocked\":true}")) {
        .ok => @trap(),
        .err => |failure| check(failure.code == .denied and std.mem.eql(u8, failure.message, "fixture rejection")),
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
