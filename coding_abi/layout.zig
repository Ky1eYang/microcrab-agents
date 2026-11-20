//! Canonical ABI memory layout for the types used by the Coding world.
//! Do not use Zig struct layout, pointer size, or a C tagged union as the wire layout.
const std = @import("std");
const types = @import("types.zig");

pub const Layout = struct { size: u32, alignment: u32 };
const empty: Layout = .{ .size = 0, .alignment = 1 };
const word: Layout = .{ .size = 4, .alignment = 4 };
const pair: Layout = .{ .size = 8, .alignment = 4 };

pub fn of(comptime T: type) Layout {
    if (T == types.OwnedBuffer or T == types.BorrowedBuffer) return word;
    return comptime switch (@typeInfo(T)) {
        .Void => empty,
        .Bool => .{ .size = 1, .alignment = 1 },
        .Enum => |enumeration| blk: {
            if (enumeration.fields.len > 256) @compileError("oversized Coding enum");
            for (enumeration.fields, 0..) |field, index| {
                if (field.value != index) @compileError("WIT enums use ordinal tags");
            }
            break :blk .{ .size = 1, .alignment = 1 };
        },
        .Int => |integer| switch (integer.bits) {
            8, 16, 32, 64 => .{ .size = integer.bits / 8, .alignment = integer.bits / 8 },
            else => @compileError("unsupported Coding integer width"),
        },
        .Float => |float| if (float.bits == 64)
            .{ .size = 8, .alignment = 8 }
        else
            @compileError("only f64 is used by the Coding world"),
        .Pointer => |pointer| if (pointer.size == .Slice) pair else @compileError("not a list"),
        .Optional => |optional| variant(of(optional.child)),
        .Union => |tagged| blk: {
            const Tag = tagged.tag_type orelse @compileError("Coding variants must be tagged");
            _ = of(Tag);
            var payload = empty;
            for (tagged.fields) |field| {
                payload.size = @max(payload.size, of(field.type).size);
                payload.alignment = @max(payload.alignment, of(field.type).alignment);
            }
            break :blk variant(payload);
        },
        .Struct => |record| blk: {
            var layout = empty;
            for (record.fields) |field| {
                const member = of(field.type);
                layout.size = alignForward(layout.size, member.alignment) + member.size;
                layout.alignment = @max(layout.alignment, member.alignment);
            }
            layout.size = alignForward(layout.size, layout.alignment);
            break :blk layout;
        },
        else => @compileError("type is not part of the Coding canonical ABI"),
    };
}

pub fn alignForward(offset: u32, alignment: u32) u32 {
    return std.mem.alignForward(u32, offset, alignment);
}

// All WIT enum/variant discriminants in this world fit in one byte.
fn variant(payload: Layout) Layout {
    const payload_start = alignForward(1, payload.alignment);
    return .{
        .size = alignForward(payload_start + payload.size, payload.alignment),
        .alignment = payload.alignment,
    };
}

pub fn payloadOffset(comptime T: type) u32 {
    // Use the enclosing variant or option, not the selected case's alignment.
    return alignForward(1, of(T).alignment);
}

fn expect(comptime T: type, size: u32, alignment: u32) !void {
    try std.testing.expectEqual(Layout{ .size = size, .alignment = alignment }, of(T));
}

test "wasm32 layouts are independent of the compiling target and Zig niche layout" {
    try expect([]const u8, 8, 4);
    try expect(?[]const u8, 12, 4);
    try expect(?u64, 16, 8);
    try expect(types.InitResult, 20, 4);
    try expect(types.DescribeResult, 12, 4);
    try expect(types.InvokeResult, 52, 4);
    try expect(types.DriveResult, 32, 8);
    try expect(types.ProcessHandle, 16, 8);
    try expect(types.ProcessStatus, 32, 8);
    try expect(types.FileMutation, 36, 4);
    try expect(types.ReadOutput, 48, 8);
    try expect(types.MutationOutput, 40, 8);
}
