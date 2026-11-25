//! Narrow adapters used by the Coding ports; no generic filesystem or process spawn.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("imports.zig");
const codec = @import("codec.zig");
const layout = @import("layout.zig");
const Scratch = std.mem.Allocator;
const Result = types.Result;

/// Exact compatibility imports are retained only for detached ABI probes.
pub const text_read = struct {
    pub fn read(scratch: Scratch, request: types.ReadRequest) Op(types.ReadOutput) {
        const raw = wire.function(
            fn (u32, u32, u64, u64, u64, u32) callconv(.C) void,
            "microcrab:host/text-read@0.1.0",
            "read",
        );
        return wire.call(Op(types.ReadOutput), scratch, raw, wire.slice(request.path) ++ .{
            request.offset_line, request.max_lines, request.max_bytes,
        });
    }
};

pub const text_write = struct {
    pub fn write(scratch: Scratch, request: types.WriteRequest) Op(types.WriteOutput) {
        const raw = wire.function(
            fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void,
            "microcrab:host/text-write@0.1.0",
            "write",
        );
        return wire.call(Op(types.WriteOutput), scratch, raw, writeArgs(request));
    }
};

pub const file_versions = struct {
    const module = "microcrab:session/file-versions@0.2.0";
    pub const VersionedRead = struct { page: types.ReadOutput, reference: []const u8 };

    pub fn read(scratch: Scratch, request: types.ReadRequest) Op(VersionedRead) {
        const raw = wire.function(fn (u32, u32, u64, u64, u64, u32) callconv(.C) void, module, "read");
        return wire.call(Op(VersionedRead), scratch, raw, wire.slice(request.path) ++ .{ request.offset_line, request.max_lines, request.max_bytes });
    }

    pub fn write(scratch: Scratch, request: types.WriteRequest) Op(types.WriteOutput) {
        const raw = wire.function(fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "write");
        return wire.call(Op(types.WriteOutput), scratch, raw, writeArgs(request));
    }

    pub fn preflight(scratch: Scratch, requests: []const types.FileMutation) Op([]const types.FileMutation) {
        return mutationPreflight(module, scratch, requests);
    }

    pub fn mutate(scratch: Scratch, request: types.FileMutation) Op(types.MutationOutput) {
        return mutationApply(module, scratch, request);
    }
};

pub const cache_points = struct {
    pub fn capture(scratch: Scratch, path: []const u8, max_bytes: u64) Op(void) {
        const raw = wire.function(
            fn (u32, u32, u64, u32) callconv(.C) void,
            "microcrab:host/cache-points@0.1.0",
            "capture",
        );
        return wire.call(Op(void), scratch, raw, wire.slice(path) ++ .{max_bytes});
    }
};

pub const file_mutation = struct {
    const module = "microcrab:host/file-mutation@0.1.0";

    pub fn preflight(scratch: Scratch, requests: []const types.FileMutation) Op([]const types.FileMutation) {
        return mutationPreflight(module, scratch, requests);
    }

    pub fn mutate(scratch: Scratch, request: types.FileMutation) Op(types.MutationOutput) {
        return mutationApply(module, scratch, request);
    }
};

fn mutationPreflight(comptime module: []const u8, scratch: Scratch, requests: []const types.FileMutation) Op([]const types.FileMutation) {
    const raw = wire.function(fn (u32, u32, u32) callconv(.C) void, module, "preflight");
    const RequestList = []const types.FileMutation;
    var pair: [layout.of(RequestList).size]u8 = undefined;
    codec.lowerScratch(RequestList, scratch, requests, &pair);
    const address = std.mem.readInt(u32, pair[0..4], .little);
    return wire.call(Op(RequestList), scratch, raw, .{ address, @as(u32, requests.len) });
}

fn mutationApply(comptime module: []const u8, scratch: Scratch, request: types.FileMutation) Op(types.MutationOutput) {
    const raw = wire.function(
        fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void,
        module,
        "mutate",
    );
    const Output = Op(types.MutationOutput);
    // Keep the variant tag and the padded payload slots explicit.
    return switch (request) {
        .write => |item| wire.call(Output, scratch, raw, .{@as(u32, 0)} ++ writeArgs(item) ++ .{@as(u32, 0)}),
        .delete => |item| wire.call(Output, scratch, raw, .{@as(u32, 1)} ++ wire.slice(item.path) ++
            wire.slice(item.expected_version) ++ .{ 0, 0, 0, 0 }),
        .move => |item| wire.call(Output, scratch, raw, .{@as(u32, 2)} ++ wire.slice(item.path) ++
            wire.slice(item.destination) ++ wire.slice(item.expected_version) ++
            wire.slice(item.content)),
    };
}

pub const glob_ignore = struct {
    const module = "microcrab:host/glob-ignore@0.1.0";

    pub fn globIgnoredPaths(scratch: Scratch) Op([]const []const u8) {
        const raw = wire.function(fn (u32) callconv(.C) void, module, "glob-ignored-paths");
        return wire.call(Op([]const []const u8), scratch, raw, .{});
    }

    pub fn globWithIgnoredPaths(scratch: Scratch, request: types.GlobRequest, paths: []const []const u8) Op(types.ResolvedGlobOutput) {
        const raw = wire.function(
            fn (u32, u32, u32, u32, u32, u32, u32, u64, u32, u32, u32) callconv(.C) void,
            module,
            "glob-with-ignored-paths",
        );
        const Paths = []const []const u8;
        var pair: [layout.of(Paths).size]u8 = undefined;
        codec.lowerScratch(Paths, scratch, paths, &pair);
        const address = std.mem.readInt(u32, pair[0..4], .little);
        return wire.call(Op(types.ResolvedGlobOutput), scratch, raw, wire.slice(request.root) ++ wire.slice(request.pattern) ++ .{
            @as(u32, @intFromBool(request.include_hidden)),
            @as(u32, @intFromBool(request.include_ignored)),
            @as(u32, @intFromBool(request.include_directories)),
            request.max_results,
            address,
            @as(u32, paths.len),
        });
    }

    pub fn snapshot(scratch: Scratch) Op([]const u8) {
        const raw = wire.function(fn (u32) callconv(.C) void, module, "snapshot");
        return wire.call(Op([]const u8), scratch, raw, .{});
    }

    pub fn globFromState(scratch: Scratch, request: types.GlobRequest) Op(types.GlobOutput) {
        const raw = wire.function(
            fn (u32, u32, u32, u32, u32, u32, u32, u64, u32) callconv(.C) void,
            module,
            "glob-from-state",
        );
        return wire.call(Op(types.GlobOutput), scratch, raw, wire.slice(request.root) ++ wire.slice(request.pattern) ++ .{
            @as(u32, @intFromBool(request.include_hidden)),
            @as(u32, @intFromBool(request.include_ignored)),
            @as(u32, @intFromBool(request.include_directories)),
            request.max_results,
        });
    }
};

pub const grep = struct {
    pub fn grep(scratch: Scratch, request: types.GrepRequest) Op(types.GrepOutput) {
        const raw = wire.function(
            fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u64, u64, u32) callconv(.C) void,
            "microcrab:host/grep@0.1.0",
            "grep",
        );
        return wire.call(Op(types.GrepOutput), scratch, raw, wire.slice(request.root) ++ wire.slice(request.pattern) ++
            wire.optionalSlice(request.include_glob) ++ .{
            @as(u32, @intFromBool(request.case_sensitive)),
            @as(u32, @intFromBool(request.literal)),
            request.max_matches,
            request.max_bytes,
        });
    }
};

pub const process = struct {
    const module = "microcrab:host/process@0.1.0";
    const HandleOut = fn (u64, u32, u32, u32) callconv(.C) void;

    pub fn status(scratch: Scratch, handle: types.ProcessHandle) Host(types.ProcessStatus) {
        const raw = wire.function(HandleOut, module, "status");
        return wire.call(Host(types.ProcessStatus), scratch, raw, processArgs(handle));
    }

    pub fn waitForState(scratch: Scratch, handle: types.ProcessHandle, yield_ms: u64) Host(types.ProcessStatus) {
        const raw = wire.function(fn (u64, u32, u32, u64, u32) callconv(.C) void, module, "wait-for-state");
        return wire.call(Host(types.ProcessStatus), scratch, raw, processArgs(handle) ++ .{yield_ms});
    }

    pub fn release(scratch: Scratch, handle: types.ProcessHandle) Host(void) {
        const raw = wire.function(HandleOut, module, "release");
        return wire.call(Host(void), scratch, raw, processArgs(handle));
    }

    pub fn killTree(scratch: Scratch, handle: types.ProcessHandle, force: bool) Host(void) {
        const raw = wire.function(fn (u64, u32, u32, u32, u32) callconv(.C) void, module, "kill-tree");
        return wire.call(Host(void), scratch, raw, processArgs(handle) ++ .{@as(u32, @intFromBool(force))});
    }
};

pub const shell = struct {
    const module = "microcrab:host/shell@0.1.0";

    pub fn launch(scratch: Scratch, request: types.ShellRequest) Host(types.ProcessHandle) {
        const raw = wire.function(fn (u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "launch");
        return wire.call(Host(types.ProcessHandle), scratch, raw, wire.slice(request.command) ++ wire.optionalSlice(request.cwd));
    }

    pub fn read(scratch: Scratch, handle: types.ProcessHandle, max_bytes: u64) Host(types.ShellOutput) {
        return observe(scratch, handle, max_bytes, "read");
    }

    pub fn drain(scratch: Scratch, handle: types.ProcessHandle, max_bytes: u64) Host(types.ShellOutput) {
        return observe(scratch, handle, max_bytes, "drain");
    }

    pub fn write(scratch: Scratch, handle: types.ProcessHandle, data: []const u8, eof: bool) Host(void) {
        const raw = wire.function(fn (u64, u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "write");
        return wire.call(Host(void), scratch, raw, processArgs(handle) ++ wire.slice(data) ++ .{@as(u32, @intFromBool(eof))});
    }

    fn observe(scratch: Scratch, handle: types.ProcessHandle, max_bytes: u64, comptime name: []const u8) Host(types.ShellOutput) {
        const raw = wire.function(fn (u64, u32, u32, u64, u32) callconv(.C) void, module, name);
        return wire.call(Host(types.ShellOutput), scratch, raw, processArgs(handle) ++ .{max_bytes});
    }
};

pub fn hostInfo(scratch: Scratch) Result([]const u8, types.CommunicationError) {
    const raw = wire.function(fn (u32) callconv(.C) void, "microcrab:agent/host-info@0.9.0", "host-info");
    return wire.call(Result([]const u8, types.CommunicationError), scratch, raw, .{});
}

pub fn processArgs(handle: types.ProcessHandle) struct { u64, u32, u32 } {
    if (handle.pid) |pid| return .{ handle.id, 1, pid };
    return .{ handle.id, 0, 0 };
}

fn writeArgs(request: types.WriteRequest) struct { u32, u32, u32, u32, u32, u32, u32 } {
    const version = switch (request.precondition) {
        .missing => null,
        .version => |v| v,
    };
    return wire.slice(request.path) ++ wire.slice(request.content) ++ wire.optionalSlice(version);
}

fn Op(comptime T: type) type {
    return Result(T, types.OperationError);
}

fn Host(comptime T: type) type {
    return Result(T, types.HostError);
}
