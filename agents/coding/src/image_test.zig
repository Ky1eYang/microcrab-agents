const std = @import("std");
const types = @import("coding_abi").types;
const image = @import("image.zig");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const string = std.testing.expectEqualStrings;
const chunk_bytes = 16 * 1024;

fn Host(comptime T: type) type {
    return types.Result(T, types.HostError);
}

const Files = struct {
    threadlocal var source: []const u8 = undefined;
    threadlocal var size: u64 = undefined;
    threadlocal var kind: @TypeOf(@as(types.FileMeta, undefined).kind) = undefined;
    threadlocal var stat_calls: usize = undefined;
    threadlocal var open_calls: usize = undefined;
    threadlocal var read_calls: usize = undefined;
    threadlocal var close_calls: usize = undefined;
    threadlocal var read_failure: bool = undefined;
    threadlocal var close_failure: bool = undefined;
    threadlocal var open_failure: bool = undefined;
    threadlocal var oversized_chunk: bool = undefined;
    const file_id = std.math.maxInt(u64) - 3;

    fn reset(bytes: []const u8) void {
        source = bytes;
        size = bytes.len;
        kind = .file;
        stat_calls = 0;
        open_calls = 0;
        read_calls = 0;
        close_calls = 0;
        read_failure = false;
        close_failure = false;
        open_failure = false;
        oversized_chunk = false;
    }

    pub fn stat(_: Allocator, path: []const u8) Host(types.FileMeta) {
        string("not-an-extension.txt", path) catch unreachable;
        stat_calls += 1;
        return .{ .ok = .{ .kind = kind, .size = size, .modified_ms = null } };
    }
    pub fn openRead(_: Allocator, path: []const u8) Host(types.FileHandle) {
        string("not-an-extension.txt", path) catch unreachable;
        open_calls += 1;
        if (open_failure) return .{ .err = .{ .category = .permission, .retryable = false, .message = "image read denied" } };
        return .{ .ok = .{ .id = file_id } };
    }
    pub fn read(scratch: Allocator, handle: types.FileHandle, offset: u64, len: u32) Host([]const u8) {
        equal(@as(u64, file_id), handle.id) catch unreachable;
        expect(len > 0 and len <= chunk_bytes) catch unreachable;
        if (offset == size) equal(@as(u32, 1), len) catch unreachable;
        read_calls += 1;
        if (read_failure) return .{ .err = .{
            .category = .cancelled,
            .retryable = true,
            .message = scratch.dupe(u8, "read cancelled") catch unreachable,
        } };
        const start: usize = @min(source.len, @as(usize, @intCast(offset)));
        return .{ .ok = scratch.dupe(u8, source[start..@min(start + len + @intFromBool(oversized_chunk), source.len)]) catch unreachable };
    }
    pub fn close(_: Allocator, handle: types.FileHandle) Host(void) {
        equal(@as(u64, file_id), handle.id) catch unreachable;
        close_calls += 1;
        if (close_failure) return .{ .err = .{ .category = .io, .retryable = false, .message = "close not acknowledged" } };
        return .{ .ok = {} };
    }
};

fn invoke(scratch: Allocator) types.InvokeResult {
    return image.invokeWith(scratch, "{\"path\":\"not-an-extension.txt\"}", Files);
}

test "image retains original binary, bounded chunks, EOF probe, and typed attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bytes = try scratch.alloc(u8, chunk_bytes * 2 + 17);
    @memset(bytes, 0xff);
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    Files.reset(bytes);
    const result = invoke(scratch).ok.final;
    try string("{\"bytes\":32785,\"media_type\":\"image/png\"}", result.content);
    try equal(@as(usize, 1), result.attachments.len);
    try string("image/png", result.attachments[0].media_type);
    try std.testing.expectEqualSlices(u8, bytes, result.attachments[0].data);
    try equal(@as(usize, 4), Files.read_calls);
    try equal(@as(usize, 1), Files.close_calls);

    for ([_][]const u8{ "\xff\xd8\xff", "GIF87a", "GIF89a", "RIFF\x00\x00\x00\x00WEBP" }, [_][]const u8{ "image/jpeg", "image/gif", "image/gif", "image/webp" }) |bytes_for_mime, mime| {
        Files.reset(bytes_for_mime);
        try string(mime, invoke(scratch).ok.final.attachments[0].media_type);
    }
}

test "image rejects invalid input, metadata, and denied open before reading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Files.reset("");
    for ([_][]const u8{ "null", "{}", "{\"path\":\"\"}", "{\"path\":\"a\\u0000b\"}", "{\"path\":[65]}", "{\"path\":\"x\",\"path\":\"y\"}", "{\"path\":\"x\",\"extra\":true}" }) |args| {
        try string("invalid_request", image.invokeWith(scratch, args, Files).err.code);
    }
    try equal(@as(usize, 0), Files.stat_calls);
    try string("limit", invoke(scratch).err.code);
    Files.size = 20 * 1024 * 1024 + 1;
    try string("limit", invoke(scratch).err.code);
    Files.kind = .directory;
    try string("invalid_request", invoke(scratch).err.code);
    try equal(@as(usize, 0), Files.open_calls);
    try equal(@as(usize, 0), Files.read_calls);
    Files.reset("GIF89a");
    Files.open_failure = true;
    try string("denied", invoke(scratch).err.code);
    try equal(@as(usize, 0), Files.close_calls);
}

test "image closes on size races, bad magic, and cancellation; failed close has no attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    Files.reset("bad magic");
    try string("invalid_request", invoke(scratch).err.code);
    try equal(@as(usize, 1), Files.close_calls);
    for ([_]u64{ 5, 7 }) |size| {
        Files.reset("GIF89a");
        Files.size = size;
        try string("conflict", invoke(scratch).err.code);
        try equal(@as(usize, 1), Files.close_calls);
    }
    Files.reset("GIF89a!");
    Files.size = 6;
    Files.oversized_chunk = true;
    try string("image changed size during bounded read", invoke(scratch).err.message);
    try equal(@as(usize, 1), Files.close_calls);
    Files.reset("GIF89a");
    Files.close_failure = true;
    try string("close not acknowledged", invoke(scratch).err.message);
    Files.read_failure = true;
    const failure = invoke(scratch).err;
    try equal(.cancelled, failure.kind);
    try string("read cancelled", failure.message);
    try expect(!failure.retryable);
    try equal(@as(usize, 2), Files.close_calls);
}
