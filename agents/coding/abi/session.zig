//! Typed Session imports. Only arbitrary variable values are JSON on the wire.
const std = @import("std");
const wire = @import("imports.zig");
const codec = @import("codec.zig");
const types = @import("types.zig");
const Scratch = std.mem.Allocator;
const module = "microcrab:session/variables@0.2.0";

fn Reply(comptime T: type) type {
    return types.Result(T, types.CommunicationError);
}

pub fn toolCallFacts(scratch: Scratch) Reply(types.CallFacts) {
    const raw = wire.function(fn (u32) callconv(.C) void, module, "tool-call-facts");
    return wire.call(Reply(types.CallFacts), scratch, raw, .{});
}

pub fn variableGet(scratch: Scratch, name: []const u8) Reply([]const u8) {
    const raw = wire.function(fn (u32, u32, u32) callconv(.C) void, module, "variable-get");
    return wire.call(Reply([]const u8), scratch, raw, wire.slice(name));
}

pub fn variableGetAll(scratch: Scratch) Reply([]const types.VariableEntry) {
    const raw = wire.function(fn (u32) callconv(.C) void, module, "variable-get-all");
    return wire.call(Reply([]const types.VariableEntry), scratch, raw, .{});
}

pub fn variableMetadata(scratch: Scratch) Reply([]const types.MetadataEntry) {
    const raw = wire.function(fn (u32) callconv(.C) void, module, "variable-metadata");
    return wire.call(Reply([]const types.MetadataEntry), scratch, raw, .{});
}

pub fn variableChange(scratch: Scratch, change: types.VariableChangeSet) Reply(void) {
    const raw = wire.function(fn (u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, module, "variable-change");
    // Flat parameter lanes are the three (pointer, length) list pairs. The
    // nested lists/records use canonical wasm32 layout and live in call scratch.
    var lists: [@import("layout.zig").of(types.VariableChangeSet).size]u8 = undefined;
    codec.lowerScratch(types.VariableChangeSet, scratch, change, &lists);
    return wire.call(Reply(void), scratch, raw, .{
        std.mem.readInt(u32, lists[0..4], .little),
        std.mem.readInt(u32, lists[4..8], .little),
        std.mem.readInt(u32, lists[8..12], .little),
        std.mem.readInt(u32, lists[12..16], .little),
        std.mem.readInt(u32, lists[16..20], .little),
        std.mem.readInt(u32, lists[20..24], .little),
    });
}
