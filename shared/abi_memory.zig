//! Allocation side of the wasm32 canonical ABI. No Coding DTOs or Host resources.
const std = @import("std");

pub const ReallocError = error{ InvalidAlignment, InvalidOldAllocation, OutOfMemory };

/// `old_ptr` with an `old_size` greater than zero must be a live allocation
/// from `allocator`, with the exact original byte size and alignment. Do not
/// pass borrowed Host memory, an interior pointer, or an already freed pointer.
/// These ownership requirements cannot be validated from a raw pointer.
/// An empty result is represented by the aligned, non-dereferenceable address
/// `alignment`. On error, a valid old allocation remains owned by the caller.
pub fn realloc(
    allocator: std.mem.Allocator,
    old_ptr: ?[*]u8,
    old_size: usize,
    alignment: usize,
    new_size: usize,
) ReallocError![*]u8 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    const log2_align = std.math.log2_int(usize, alignment);
    const old: ?[]u8 = if (old_size == 0) null else blk: {
        const ptr = old_ptr orelse return error.InvalidOldAllocation;
        const address = @intFromPtr(ptr);
        if (!std.mem.isAligned(address, alignment) or old_size > std.math.maxInt(usize) - address)
            return error.InvalidOldAllocation;
        break :blk ptr[0..old_size];
    };
    const ra = @returnAddress();

    if (new_size == 0) {
        if (old) |bytes| allocator.rawFree(bytes, log2_align, ra);
        return @ptrFromInt(alignment);
    }
    if (old) |bytes| {
        if (new_size == old_size) return bytes.ptr;
        if (allocator.rawResize(bytes, log2_align, new_size, ra)) return bytes.ptr;
    }

    const new = allocator.rawAlloc(new_size, log2_align, ra) orelse return error.OutOfMemory;
    if (old) |bytes| {
        const copy_len = @min(old_size, new_size);
        @memcpy(new[0..copy_len], bytes[0..copy_len]);
        allocator.rawFree(bytes, log2_align, ra);
    }
    return new;
}

const testing = std.testing;

test "aligned allocation, growth, shrink and release preserve the common prefix" {
    const allocator = testing.allocator;
    var size: usize = 8;
    var ptr = try realloc(allocator, null, 0, 16, size);
    errdefer _ = realloc(allocator, ptr, size, 16, 0) catch unreachable;
    @memcpy(ptr[0..8], "abcdefgh");
    try testing.expect(std.mem.isAligned(@intFromPtr(ptr), 16));
    try testing.expectEqual(ptr, try realloc(allocator, ptr, size, 16, size));

    ptr = try realloc(allocator, ptr, size, 16, 8192);
    size = 8192;
    try testing.expect(std.mem.isAligned(@intFromPtr(ptr), 16));
    try testing.expectEqualSlices(u8, "abcdefgh", ptr[0..8]);
    ptr = try realloc(allocator, ptr, size, 16, 3);
    size = 3;
    try testing.expectEqualSlices(u8, "abc", ptr[0..3]);
    const empty = try realloc(allocator, ptr, size, 16, 0);
    size = 0;
    try testing.expectEqual(@as(usize, 16), @intFromPtr(empty));
}

test "empty sentinel is never freed, resized, or copied" {
    const allocator = testing.allocator;
    const empty = try realloc(allocator, null, 0, 8, 0);
    try testing.expectEqual(@as(usize, 8), @intFromPtr(empty));
    try testing.expectEqual(empty, try realloc(allocator, empty, 0, 8, 0));
    const ptr = try realloc(allocator, empty, 0, 8, 1);
    defer _ = realloc(allocator, ptr, 1, 8, 0) catch unreachable;
    try testing.expect(std.mem.isAligned(@intFromPtr(ptr), 8));
}

test "rejects invalid alignment and obviously invalid nonempty old ranges" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidAlignment, realloc(allocator, null, 0, 0, 1));
    try testing.expectError(error.InvalidAlignment, realloc(allocator, null, 0, 3, 1));
    try testing.expectError(error.InvalidOldAllocation, realloc(allocator, null, 1, 8, 1));
    try testing.expectError(error.InvalidOldAllocation, realloc(allocator, @ptrFromInt(3), 1, 8, 1));
    try testing.expectError(error.InvalidOldAllocation, realloc(allocator, @ptrFromInt(8), std.math.maxInt(usize), 8, 1));
}

test "failed growth leaves the old allocation intact and owned" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const ptr = try realloc(allocator, null, 0, 4, 4);
    defer _ = realloc(allocator, ptr, 4, 4, 0) catch unreachable;
    @memcpy(ptr[0..4], "stay");
    try testing.expectError(error.OutOfMemory, realloc(allocator, ptr, 4, 4, 8));
    try testing.expectEqualSlices(u8, "stay", ptr[0..4]);
}
