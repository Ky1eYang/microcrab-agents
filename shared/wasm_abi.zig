//! Single-memory wasm32-freestanding adapter for the shared realloc helper.
const builtin = @import("builtin");
const std = @import("std");
const memory = @import("abi_memory.zig");

comptime {
    if (builtin.cpu.arch != .wasm32 or builtin.os.tag != .freestanding)
        @compileError("the canonical ABI boundary requires wasm32-freestanding");
}

pub const allocator = std.heap.page_allocator;

/// The Canonical ABI expects a trap on allocation failure, not a null address.
pub export fn cabi_realloc(old: ?[*]u8, old_size: usize, alignment: usize, new_size: usize) usize {
    // Canonical Coding value layouts align to at most 8 bytes. Allow up to a
    // page, so the backing allocator never needs to over-align memory.grow.
    if (alignment > std.mem.page_size) @trap();
    const ptr = memory.realloc(allocator, old, old_size, alignment, new_size) catch @trap();
    return @intFromPtr(ptr);
}
