//! Bounded raster acquisition; Runtime owns image decoding and admission.
const std = @import("std");
const abi = @import("coding_abi");
const support = @import("media_shell_support.zig");
const types = abi.types;
const Allocator = std.mem.Allocator;

const max_image_bytes = 20 * 1024 * 1024;
const image_chunk_bytes = 16 * 1024;
const Arguments = struct { path: support.String };
const ImageResult = types.Result(types.MediaAttachment, types.ToolFailure);

/// Entry has already checked tool availability and reserved invocation output.
pub fn invoke(scratch: Allocator, arguments: []const u8) types.InvokeResult {
    return invokeWith(scratch, arguments, abi.host.filesystem);
}

/// `files` implements the `abi.host.filesystem` calls used here.
pub fn invokeWith(scratch: Allocator, arguments: []const u8, files: anytype) types.InvokeResult {
    const args = switch (support.parse(Arguments, scratch, arguments)) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure },
    };
    if (support.checkString(args.path.value, 4096)) |failure| return .{ .err = failure };
    const attachment = switch (readImage(scratch, args.path.value, files)) {
        .ok => |value| value,
        .err => |failure| return .{ .err = failure },
    };
    const content = std.json.stringifyAlloc(scratch, .{
        .bytes = attachment.data.len,
        .media_type = attachment.media_type,
    }, .{}) catch return .{ .err = support.allocationFailed() };
    const attachments = scratch.alloc(types.MediaAttachment, 1) catch return .{ .err = support.allocationFailed() };
    attachments[0] = attachment;
    return .{ .ok = .{ .final = .{ .content = content, .attachments = attachments } } };
}

fn readImage(scratch: Allocator, path: []const u8, files: anytype) ImageResult {
    const meta = switch (files.stat(scratch, path)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };
    if (meta.kind != .file) return .{ .err = support.invalid("image source must be an ordinary file") };
    if (meta.size == 0 or meta.size > max_image_bytes) return .{ .err = support.failed("limit", "image source must be nonempty and at most20MiB") };
    const data = scratch.alloc(u8, @intCast(meta.size)) catch return .{ .err = support.failed("limit", "image source exceeds guest allocation capacity") };
    const handle = switch (files.openRead(scratch, path)) {
        .ok => |value| value,
        .err => |err| return .{ .err = support.hostFailure(err) },
    };

    const result = readOpened(scratch, files, handle, data);
    // A failed close keeps Runtime cleanup ownership. Preserve the first failure
    // if acquisition also failed, and never send an attachment after a bad close.
    const closed = files.close(scratch, handle);
    if (result == .ok and closed == .err) return .{ .err = support.hostFailure(closed.err) };
    return result;
}

fn readOpened(scratch: Allocator, files: anytype, handle: types.FileHandle, data: []u8) ImageResult {
    // Lift and copy only one Host read at a time, keeping the assembled image in
    // the caller's arena. Reset still permits transient Host diagnostics.
    var chunk_arena = std.heap.ArenaAllocator.init(scratch);
    defer chunk_arena.deinit();
    const chunk_scratch = chunk_arena.allocator();
    var offset: usize = 0;
    while (offset < data.len) {
        const wanted = @min(data.len - offset, image_chunk_bytes);
        const chunk = switch (files.read(chunk_scratch, handle, offset, @as(u32, @intCast(wanted)))) {
            .ok => |value| value,
            .err => |err| return .{ .err = copyReadFailure(scratch, err) },
        };
        if (chunk.len == 0 or chunk.len > wanted) return .{ .err = support.failed("conflict", "image changed size during bounded read") };
        @memcpy(data[offset..][0..chunk.len], chunk);
        offset += chunk.len;
        _ = chunk_arena.reset(.retain_capacity);
    }
    const eof = switch (files.read(chunk_scratch, handle, offset, @as(u32, 1))) {
        .ok => |value| value,
        .err => |err| return .{ .err = copyReadFailure(scratch, err) },
    };
    if (eof.len != 0) return .{ .err = support.failed("conflict", "image grew during bounded read") };
    return .{ .ok = .{
        .data = data,
        .media_type = mime(data) orelse return .{ .err = support.invalid("unsupported image signature; expected PNG, JPEG, GIF or WebP") },
    } };
}

fn copyReadFailure(scratch: Allocator, err: types.HostError) types.ToolFailure {
    var failure = support.hostFailure(err);
    failure.message = scratch.dupe(u8, err.message) catch return support.allocationFailed();
    return failure;
}

fn mime(data: []const u8) ?[]const u8 {
    const startsWith = std.mem.startsWith;
    if (startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (startsWith(u8, data, "\xff\xd8\xff")) return "image/jpeg";
    if (startsWith(u8, data, "GIF87a") or startsWith(u8, data, "GIF89a")) return "image/gif";
    if (data.len >= 12 and startsWith(u8, data, "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    return null;
}
