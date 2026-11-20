//! Canonical entrypoints for a real Coding guest or a test-only ABI probe.
const std = @import("std");
const memory = @import("wasm_abi");
const types = @import("types.zig");
const codec = @import("codec.zig");

/// Export the Agent 0.8 core signatures plus its canonical post-return functions.
pub fn exportAgent(comptime Guest: type) void {
    _ = memory.cabi_realloc;
    const Entry = struct {
        fn init() callconv(.C) u32 {
            var scratch = std.heap.ArenaAllocator.init(memory.allocator);
            defer scratch.deinit();
            return reply(types.InitResult, Guest.init(scratch.allocator()));
        }

        fn describe(info: u32, info_size: u32) callconv(.C) u32 {
            defer codec.releaseInput(info, info_size);
            var scratch = std.heap.ArenaAllocator.init(memory.allocator);
            defer scratch.deinit();
            const result = Guest.describe(scratch.allocator(), text(info, info_size));
            return reply(types.DescribeResult, result);
        }

        fn invoke(
            info: u32,
            info_size: u32,
            name: u32,
            name_size: u32,
            args: u32,
            args_size: u32,
        ) callconv(.C) u32 {
            defer codec.releaseInput(info, info_size);
            defer codec.releaseInput(name, name_size);
            defer codec.releaseInput(args, args_size);
            var scratch = std.heap.ArenaAllocator.init(memory.allocator);
            defer scratch.deinit();
            const result = Guest.invoke(
                scratch.allocator(),
                text(info, info_size),
                text(name, name_size),
                text(args, args_size),
            );
            return reply(types.InvokeResult, result);
        }

        fn drive(buffer: u32, state: u32, state_size: u32, cancelled: u32) callconv(.C) u32 {
            defer codec.releaseInput(state, state_size);
            var scratch = std.heap.ArenaAllocator.init(memory.allocator);
            defer scratch.deinit();
            const is_cancelled = switch (cancelled) {
                0 => false,
                1 => true,
                else => @trap(),
            };
            const result = Guest.drive(
                scratch.allocator(),
                .{ .index = buffer },
                codec.view(state, state_size),
                is_cancelled,
            );
            return reply(types.DriveResult, result);
        }
    };
    @export(Entry.init, .{ .name = "init" });
    @export(Entry.describe, .{ .name = "describe" });
    @export(Entry.invoke, .{ .name = "invoke" });
    @export(Entry.drive, .{ .name = "drive" });
    @export(Post(types.InitResult).call, .{ .name = "cabi_post_init" });
    @export(Post(types.DescribeResult).call, .{ .name = "cabi_post_describe" });
    @export(Post(types.InvokeResult).call, .{ .name = "cabi_post_invoke" });
    @export(Post(types.DriveResult).call, .{ .name = "cabi_post_drive" });
}

fn Post(comptime T: type) type {
    return struct {
        fn call(address: u32) callconv(.C) void {
            codec.release(T, address);
        }
    };
}

fn reply(comptime T: type, value: T) u32 {
    const result = codec.alloc(T);
    codec.lower(T, value, result);
    return codec.pointer(result);
}

fn text(address: u32, size: u32) []const u8 {
    const bytes = codec.view(address, size);
    if (!std.unicode.utf8ValidateSlice(bytes)) @trap();
    return bytes;
}
