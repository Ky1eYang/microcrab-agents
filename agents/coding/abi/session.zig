//! Unified Session Rhai scripting boundary (`microcrab:session/session@0.4.0`).
const wire = @import("imports.zig");
const types = @import("types.zig");
const std = @import("std");
const Scratch = std.mem.Allocator;
const module = "microcrab:session/session@0.4.0";

pub fn eval(scratch: Scratch, script: []const u8, args_json: ?[]const u8) types.Result([]const u8, types.SessionError) {
    const raw = wire.function(fn (u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "eval");
    const script_wire = wire.slice(script);
    const args_wire = wire.optionalSlice(args_json);
    return wire.call(
        types.Result([]const u8, types.SessionError),
        scratch,
        raw,
        .{ script_wire[0], script_wire[1], args_wire[0], args_wire[1], args_wire[2] },
    );
}
