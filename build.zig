const std = @import("std");

pub fn build(b: *std.Build) void {
    const core = b.option([]const u8, "core", "Canonical microcrab-core checkout for WIT drift checks");
    const guest = b.option([]const u8, "coding-guest", "Override the Coding guest source for an isolated fixture");
    const coding = if (core) |path| blk: {
        if (guest) |source| {
            break :blk b.dependency("coding", .{ .core = path, .@"coding-guest" = source });
        }
        break :blk b.dependency("coding", .{ .core = path });
    } else if (guest) |source| b.dependency("coding", .{ .@"coding-guest" = source }) else b.dependency("coding", .{});

    for ([_][]const u8{
        "test",
        "test-wasm",
        "check-wit",
        "test-coding-abi",
        "check-component",
        "check-vendored-component",
    }) |name| {
        const child = coding.builder.top_level_steps.get(name).?;
        const step = b.step(name, child.description);
        step.dependOn(&child.step);
        if (std.mem.eql(u8, name, "test")) b.default_step = step;
    }

    const component = b.step("component", "Build the opt-in Coding Component without staging it");
    if (core != null) {
        const output = coding.namedWriteFiles("component").getDirectory();
        const artifact = output.path(b, "coding.component.wasm");
        // Use the invoking prefix, not Zig 0.13's cache-only dependency prefix.
        component.dependOn(&b.addInstallFile(artifact, "coding.component.wasm").step);
    } else {
        component.dependOn(&coding.builder.top_level_steps.get("check-wit").?.step);
    }
}
