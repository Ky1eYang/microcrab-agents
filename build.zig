const std = @import("std");

comptime {
    const version = @import("builtin").zig_version;
    if (version.order(.{ .major = 0, .minor = 13, .patch = 0 }) != .eq)
        @compileError("MicroCrab Agents requires Zig 0.13.0");
}

pub fn build(b: *std.Build) void {
    const tests = b.step("test", "Run native Coding tool, catalog and ABI tests (default)");
    b.default_step = tests;
    const memory_tests = b.addTest(.{
        .root_source_file = b.path("shared/abi_memory.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(memory_tests).step);
    const layout_tests = b.addTest(.{
        .root_source_file = b.path("coding_abi/layout.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(layout_tests).step);
    const coding_abi = b.createModule(.{ .root_source_file = b.path("coding_abi/root.zig") });
    for ([_][]const u8{ "catalog_test", "text_test", "apply_patch_test", "image_test", "shell_test" }) |name| {
        const tool_test = b.addTest(.{
            .root_source_file = b.path(b.fmt("coding/{s}.zig", .{name})),
            .target = b.host,
            .optimize = .Debug,
        });
        tool_test.root_module.addImport("coding_abi", coding_abi);
        tests.dependOn(&b.addRunArtifact(tool_test).step);
    }

    const abi = freestanding(b, "abi-memory", b.path("shared/wasm_abi.zig"));
    abi.root_module.export_symbol_names = &.{"cabi_realloc"};
    const smoke = b.addSystemCommand(&.{"node"});
    smoke.addFileArg(b.path("tools/test-wasm-abi.mjs"));
    smoke.addFileArg(abi.getEmittedBin());
    b.step("test-wasm", "Instantiate and test the freestanding ABI memory module (requires Node.js)").dependOn(&smoke.step);

    const core = b.option([]const u8, "core", "Canonical microcrab-core checkout for WIT drift checks");
    const check = b.step("check-wit", "Fail on any byte drift from the canonical Core WIT");
    if (core) |path| {
        const drift = b.addSystemCommand(&.{"bash"});
        drift.addFileArg(b.path("tools/check-wit.sh"));
        drift.addArg(path);
        // The authoritative inputs live outside this workspace and may change.
        drift.has_side_effects = true;
        check.dependOn(&drift.step);
    } else {
        check.makeFn = requireCore;
    }

    const probe = freestanding(b, "coding-abi-probe", b.path("tests/abi_probe.zig"));
    addCodingAbi(b, probe);
    const wire = b.addSystemCommand(&.{"node"});
    wire.addFileArg(b.path("tools/test-coding-abi.mjs"));
    wire.addFileArg(probe.getEmittedBin());
    const probe_step = b.step("test-coding-abi", "Test Coding wire values and validate a test-only component");
    probe_step.dependOn(&wire.step);
    if (core != null) {
        const packaging = addCodingComponent(b, check, probe);
        probe_step.dependOn(packaging.verified);
    } else {
        probe_step.dependOn(check);
    }

    const component = b.step("component", "Build the opt-in Zig Coding Component without staging it");
    const guest_source = b.option([]const u8, "coding-guest", "Override the Coding guest source for an isolated fixture");
    if (core != null) {
        const source: std.Build.LazyPath = if (guest_source) |path| .{ .cwd_relative = path } else b.path("coding/main.zig");
        const wasm = freestanding(b, "coding", source);
        addCodingAbi(b, wasm);
        const packaging = addCodingComponent(b, check, wasm);
        // Explicit build output only; never selected by the default or install step.
        const output = b.addInstallFile(packaging.artifact, "coding.component.wasm");
        output.step.dependOn(packaging.verified);
        component.dependOn(&output.step);
    } else {
        component.makeFn = requireCore;
    }
}

fn freestanding(b: *std.Build, name: []const u8, source: std.Build.LazyPath) *std.Build.Step.Compile {
    const wasm = b.addExecutable(.{
        .name = name,
        .root_source_file = source,
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    wasm.entry = .disabled;
    wasm.export_memory = true;
    return wasm;
}

const ComponentBuild = struct {
    artifact: std.Build.LazyPath,
    verified: *std.Build.Step,
};

fn addCodingComponent(b: *std.Build, check: *std.Build.Step, wasm: *std.Build.Step.Compile) ComponentBuild {
    // Zig 0.13 hashes a directory argument's path, not its contents. Make a
    // content-addressed WIT input tree so any changed mirror invalidates embed.
    const wit = b.addWriteFiles();
    for ([_][]const u8{ "world.wit", "deps/agent/agent.wit", "deps/host/host.wit" }) |file| {
        _ = wit.addCopyFile(b.path(b.fmt("wit/{s}", .{file})), file);
    }
    wit.step.dependOn(check);
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "coding", "--encoding", "utf8" });
    embed.addDirectoryArg(wit.getDirectory());
    embed.addFileArg(wasm.getEmittedBin());
    embed.addArg("-o");
    const embedded = embed.addOutputFileArg("coding.embedded.wasm");

    const compose = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    compose.addFileArg(embedded);
    compose.addArg("-o");
    const artifact = compose.addOutputFileArg("coding.component.wasm");

    const validate = b.addSystemCommand(&.{ "wasm-tools", "validate" });
    validate.addFileArg(artifact);
    const extract = b.addSystemCommand(&.{ "wasm-tools", "component", "wit" });
    extract.addFileArg(artifact);
    extract.addArg("-o");
    _ = extract.addOutputFileArg("coding.component.wit");

    const targets = b.addSystemCommand(&.{ "wasm-tools", "component", "targets" });
    targets.addDirectoryArg(wit.getDirectory());
    targets.addArgs(&.{ "--world", "microcrab:coding/coding@0.1.0" });
    targets.addFileArg(artifact);
    targets.step.dependOn(&validate.step);
    targets.step.dependOn(&extract.step);
    return .{ .artifact = artifact, .verified = &targets.step };
}

fn addCodingAbi(b: *std.Build, wasm: *std.Build.Step.Compile) void {
    const memory = b.createModule(.{ .root_source_file = b.path("shared/wasm_abi.zig") });
    const coding = b.createModule(.{ .root_source_file = b.path("coding_abi/root.zig") });
    coding.addImport("wasm_abi", memory);
    wasm.root_module.addImport("wasm_abi", memory);
    wasm.root_module.addImport("coding_abi", coding);
    wasm.root_module.export_symbol_names = &.{
        "cabi_realloc",   "init",               "describe",         "invoke",          "drive",
        "cabi_post_init", "cabi_post_describe", "cabi_post_invoke", "cabi_post_drive",
    };
}

fn requireCore(step: *std.Build.Step, _: std.Progress.Node) !void {
    return step.fail("pass -Dcore=/path/to/microcrab-core to check canonical WIT", .{});
}
