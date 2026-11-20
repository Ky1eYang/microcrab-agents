//! Memory-form lowering/lifting and transitive release for the Coding layouts.
const builtin = @import("builtin");
const std = @import("std");
const abi = @import("wasm_abi");
const layout = @import("layout.zig");
const types = @import("types.zig");

comptime {
    if (builtin.cpu.arch != .wasm32) @compileError("Coding wire pointers are wasm32");
}

pub fn alloc(comptime T: type) []u8 {
    return allocBytes(abi.allocator, layout.of(T), 1);
}

pub fn lower(comptime T: type, value: T, bytes: []u8) void {
    // A result can refer to caller inputs, scratch values, or literals. Its
    // canonical allocation tree must survive teardown of all three sources.
    @memset(bytes, 0);
    put(T, abi.allocator, value, bytes);
}

pub fn lowerScratch(comptime T: type, scratch: std.mem.Allocator, value: T, bytes: []u8) void {
    @memset(bytes, 0);
    put(T, scratch, value, bytes);
}

pub fn liftAndRelease(comptime T: type, scratch: std.mem.Allocator, bytes: []const u8) T {
    const value = get(T, scratch, bytes);
    releaseNested(T, bytes);
    return value;
}

pub fn release(comptime T: type, address: u32) void {
    const bytes = view(address, layout.of(T).size);
    releaseNested(T, bytes);
    free(bytes, layout.of(T).alignment);
}

pub fn pointer(bytes: []const u8) u32 {
    return @intFromPtr(bytes.ptr);
}

pub fn view(address: u32, size: u32) []const u8 {
    if (size == 0) return &.{};
    const memory_bytes = @as(u64, @wasmMemorySize(0)) * std.wasm.page_size;
    if (address == 0 or @as(u64, address) + size > memory_bytes) @trap();
    return @as([*]const u8, @ptrFromInt(address))[0..size];
}

pub fn releaseInput(address: u32, size: u32) void {
    free(view(address, size), 1);
}

fn allocBytes(allocator: std.mem.Allocator, spec: layout.Layout, count: u32) []u8 {
    const size = byteCount(spec.size, count);
    if (size == 0) return &.{};
    const alignment = std.math.log2_int(u32, spec.alignment);
    const address = allocator.rawAlloc(size, alignment, @returnAddress()) orelse @trap();
    return address[0..size];
}

fn free(bytes: []const u8, alignment: u32) void {
    if (bytes.len == 0) return;
    const log_alignment = std.math.log2_int(u32, alignment);
    abi.allocator.rawFree(@constCast(bytes), log_alignment, @returnAddress());
}

fn byteCount(stride: u32, count: u32) u32 {
    return std.math.mul(u32, stride, count) catch @trap();
}

pub fn writeInt(comptime T: type, bytes: []u8, offset: u32, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn readInt(comptime T: type, bytes: []const u8, offset: u32) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn listBytes(comptime Item: type, bytes: []const u8) []const u8 {
    const item = layout.of(Item);
    const address = readInt(u32, bytes, 0);
    const size = byteCount(item.size, readInt(u32, bytes, 4));
    if (size != 0 and !std.mem.isAligned(address, item.alignment)) @trap();
    return view(address, size);
}

fn put(comptime T: type, allocator: std.mem.Allocator, value: T, bytes: []u8) void {
    if (T == types.OwnedBuffer or T == types.BorrowedBuffer) {
        writeInt(u32, bytes, 0, if (T == types.OwnedBuffer) value.index orelse @trap() else value.index);
        return;
    }
    switch (@typeInfo(T)) {
        .Void => {},
        .Bool => bytes[0] = @intFromBool(value),
        .Enum => bytes[0] = @intCast(@intFromEnum(value)),
        .Int => writeInt(T, bytes, 0, value),
        .Float => writeInt(u64, bytes, 0, @bitCast(value)),
        .Optional => |optional| if (value) |child| {
            bytes[0] = 1;
            put(optional.child, allocator, child, bytes[layout.payloadOffset(T)..]);
        },
        .Union => switch (value) {
            inline else => |child, tag| {
                bytes[0] = @intCast(@intFromEnum(tag));
                put(@TypeOf(child), allocator, child, bytes[layout.payloadOffset(T)..]);
            },
        },
        .Struct => |record| {
            comptime var offset = 0;
            inline for (record.fields) |field| {
                const item = comptime layout.of(field.type);
                offset = comptime layout.alignForward(offset, item.alignment);
                put(field.type, allocator, @field(value, field.name), bytes[offset..]);
                offset += item.size;
            }
        },
        .Pointer => |slice| {
            const item = comptime layout.of(slice.child);
            const elements = allocBytes(allocator, item, value.len);
            if (slice.child == u8) {
                @memcpy(elements, value);
            } else {
                @memset(elements, 0);
                for (value, 0..) |child, index| {
                    put(slice.child, allocator, child, elements[index * item.size ..]);
                }
            }
            writeInt(u32, bytes, 0, if (value.len == 0) 0 else pointer(elements));
            writeInt(u32, bytes, 4, value.len);
        },
        else => unreachable,
    }
}

fn get(comptime T: type, scratch: std.mem.Allocator, bytes: []const u8) T {
    if (T == types.OwnedBuffer or T == types.BorrowedBuffer) {
        return .{ .index = readInt(u32, bytes, 0) };
    }
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => switch (bytes[0]) {
            0 => false,
            1 => true,
            else => @trap(),
        },
        .Enum => std.meta.intToEnum(T, bytes[0]) catch @trap(),
        .Int => readInt(T, bytes, 0),
        .Float => @bitCast(readInt(u64, bytes, 0)),
        .Optional => |optional| if (caseIndex(bytes, 2) == 1)
            get(optional.child, scratch, bytes[layout.payloadOffset(T)..])
        else
            null,
        .Union => |tagged| blk: {
            const index = caseIndex(bytes, tagged.fields.len);
            inline for (tagged.fields, 0..) |field, tag| {
                if (tag == index) {
                    const child = get(field.type, scratch, bytes[layout.payloadOffset(T)..]);
                    break :blk @unionInit(T, field.name, child);
                }
            }
            unreachable;
        },
        .Struct => |record| blk: {
            var value: T = undefined;
            comptime var offset = 0;
            inline for (record.fields) |field| {
                const item = comptime layout.of(field.type);
                offset = comptime layout.alignForward(offset, item.alignment);
                @field(value, field.name) = get(field.type, scratch, bytes[offset..]);
                offset += item.size;
            }
            break :blk value;
        },
        .Pointer => |slice| blk: {
            const elements = listBytes(slice.child, bytes);
            const count = readInt(u32, bytes, 4);
            if (count == 0) break :blk &.{};
            if (slice.child == u8) break :blk scratch.dupe(u8, elements) catch @trap();
            const values = scratch.alloc(slice.child, count) catch @trap();
            const item = comptime layout.of(slice.child);
            for (values, 0..) |*value, index| {
                value.* = get(slice.child, scratch, elements[index * item.size ..]);
            }
            break :blk values;
        },
        else => unreachable,
    };
}

fn caseIndex(bytes: []const u8, count: u32) u8 {
    if (bytes[0] >= count) @trap();
    return bytes[0];
}

fn releaseNested(comptime T: type, bytes: []const u8) void {
    // Buffer handles in an export have already transferred to the Runtime when
    // post-return runs; only linear-memory allocations are released here.
    if (T == types.OwnedBuffer or T == types.BorrowedBuffer) return;
    switch (@typeInfo(T)) {
        .Optional => |optional| if (caseIndex(bytes, 2) == 1) {
            releaseNested(optional.child, bytes[layout.payloadOffset(T)..]);
        },
        .Union => |tagged| {
            const index = caseIndex(bytes, tagged.fields.len);
            inline for (tagged.fields, 0..) |field, tag| {
                if (index == tag) releaseNested(field.type, bytes[layout.payloadOffset(T)..]);
            }
        },
        .Struct => |record| {
            comptime var offset = 0;
            inline for (record.fields) |field| {
                const item = comptime layout.of(field.type);
                offset = comptime layout.alignForward(offset, item.alignment);
                releaseNested(field.type, bytes[offset..]);
                offset += item.size;
            }
        },
        .Pointer => |slice| {
            const elements = listBytes(slice.child, bytes);
            const item = comptime layout.of(slice.child);
            if (slice.child != u8) {
                const count = readInt(u32, bytes, 4);
                for (0..count) |index| {
                    releaseNested(slice.child, elements[index * item.size ..]);
                }
            }
            free(elements, item.alignment);
        },
        else => {},
    }
}
