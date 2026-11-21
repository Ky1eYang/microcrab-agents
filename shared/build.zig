const std = @import("std");

comptime {
    const version = @import("builtin").zig_version;
    if (version.order(.{ .major = 0, .minor = 13, .patch = 0 }) != .eq)
        @compileError("MicroCrab Agents requires Zig 0.13.0");
}

pub fn build(b: *std.Build) void {
    const wasm_source = b.path("src/wasm_abi.zig");
    _ = b.addModule("wasm_abi", .{ .root_source_file = wasm_source });

    const tests = b.step("test", "Run native ABI memory tests (default)");
    b.default_step = tests;
    const memory_tests = b.addTest(.{
        .root_source_file = b.path("src/abi_memory.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(memory_tests).step);

    const abi = b.addExecutable(.{
        .name = "abi-memory",
        .root_source_file = wasm_source,
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    abi.entry = .disabled;
    abi.export_memory = true;
    abi.root_module.export_symbol_names = &.{"cabi_realloc"};
    const smoke = b.addSystemCommand(&.{"node"});
    smoke.addFileArg(b.path("tools/test-wasm-abi.mjs"));
    smoke.addFileArg(abi.getEmittedBin());
    const test_wasm = b.step("test-wasm", "Test the freestanding ABI memory module (requires Node.js)");
    test_wasm.dependOn(&smoke.step);
}
