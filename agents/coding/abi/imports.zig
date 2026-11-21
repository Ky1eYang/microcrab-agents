//! Shared mechanics for lowering synchronous WIT imports.
const std = @import("std");
const codec = @import("codec.zig");
const layout = @import("layout.zig");

pub fn call(comptime T: type, scratch: std.mem.Allocator, raw: anytype, args: anytype) T {
    const spec = comptime layout.of(T);
    var result: [spec.size]u8 align(spec.alignment) = undefined;
    @call(.auto, raw, args ++ .{codec.pointer(&result)});
    return codec.liftAndRelease(T, scratch, &result);
}

pub fn function(comptime F: type, comptime module: []const u8, comptime name: []const u8) *const F {
    return @extern(*const F, .{ .library_name = module, .name = name });
}

/// The canonical intrinsic removes an owned or scoped borrowed table entry.
/// Runtime's underlying buffer destructor runs only for an owned entry.
pub fn dropBufferEntry(index: u32) void {
    const raw = function(
        fn (u32) callconv(.C) void,
        "microcrab:agent/execution@0.8.0",
        "[resource-drop]buffer",
    );
    raw(index);
}

pub fn slice(value: []const u8) struct { u32, u32 } {
    return .{ if (value.len == 0) 0 else codec.pointer(value), value.len };
}

pub fn optionalSlice(value: ?[]const u8) struct { u32, u32, u32 } {
    if (value) |bytes| return .{ 1, slice(bytes)[0], bytes.len };
    return .{ 0, 0, 0 };
}
