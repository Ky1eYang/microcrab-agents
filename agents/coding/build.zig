const std = @import("std");

comptime {
    const version = @import("builtin").zig_version;
    if (version.order(.{ .major = 0, .minor = 13, .patch = 0 }) != .eq)
        @compileError("MicroCrab Agents requires Zig 0.13.0");
}

pub fn build(b: *std.Build) void {
    const shared = b.dependency("shared", .{});
    const memory = shared.module("wasm_abi");
    const coding_abi = b.createModule(.{
        .root_source_file = b.path("abi/root.zig"),
        .imports = &.{.{ .name = "wasm_abi", .module = memory }},
    });

    const tests = b.step("test", "Run native Coding tool, catalog and ABI tests (default)");
    b.default_step = tests;
    tests.dependOn(shared.builder.default_step);
    const layout_tests = b.addTest(.{
        .root_source_file = b.path("abi/layout.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(layout_tests).step);
    for ([_][]const u8{ "catalog_test", "text_test", "apply_patch_test", "shell_test" }) |name| {
        const tool_test = b.addTest(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = b.host,
            .optimize = .Debug,
        });
        tool_test.root_module.addImport("coding_abi", coding_abi);
        tests.dependOn(&b.addRunArtifact(tool_test).step);
    }

    const smoke = b.step("test-wasm", "Test the freestanding ABI memory module (requires Node.js)");
    smoke.dependOn(&shared.builder.top_level_steps.get("test-wasm").?.step);

    const core = b.option([]const u8, "core", "Canonical microcrab-core checkout for WIT drift checks");
    const guest_source = b.option([]const u8, "coding-guest", "Override the Coding guest source for an isolated fixture");
    const check = b.step("check-wit", "Fail on any byte drift from the canonical Core WIT");
    if (core) |path| {
        const drift = b.addSystemCommand(&.{"bash"});
        drift.addFileArg(b.path("tools/check-wit.sh"));
        drift.addArg(path);
        drift.setCwd(.{ .cwd_relative = "." });
        // The authoritative inputs live outside this package and may change.
        drift.has_side_effects = true;
        check.dependOn(&drift.step);
    } else {
        check.makeFn = requireCore;
    }

    const guest = freestanding(b, "coding", b.path("src/main.zig"));
    addCodingAbi(guest, coding_abi);
    const vendored = addCodingComponent(b, addWitTree(b, null, "wit/world.wit"), guest);
    const vendored_check = b.step("check-vendored-component", "Verify the included Coding Component against vendored WIT only");
    vendored_check.dependOn(vendored.verified);

    const probe = freestanding(b, "coding-abi-probe", b.path("tests/abi_probe.zig"));
    addCodingAbi(probe, coding_abi);
    const wire = b.addSystemCommand(&.{"node"});
    wire.addFileArg(b.path("tools/test-coding-abi.mjs"));
    wire.addFileArg(probe.getEmittedBin());
    wire.addFileArg(guest.getEmittedBin());
    const probe_step = b.step("test-coding-abi", "Test Coding wire values and validate a test-only component");
    probe_step.dependOn(&wire.step);
    probe_step.dependOn(check);

    const check_component = b.step("check-component", "Validate the opt-in Coding Component against Core WIT");
    const component = b.step("component", "Build the opt-in Coding Component without staging it");
    check_component.dependOn(check);
    component.dependOn(check_component);
    if (core != null) {
        const wit = addWitTree(b, check, "wit/world.wit");
        const probe_packaging = addCodingComponent(b, wit, probe);
        probe_step.dependOn(probe_packaging.verified);

        const selected = if (guest_source) |path| blk: {
            const wasm = freestanding(b, "coding", .{ .cwd_relative = path });
            addCodingAbi(wasm, coding_abi);
            break :blk wasm;
        } else guest;
        const selected_wit = if (guest_source != null) addWitTree(b, check, "tests/core_abi_probe.wit") else wit;
        const packaging = addCodingComponent(b, selected_wit, selected);
        check_component.dependOn(packaging.verified);
        // Export the verified output to the aggregate without attaching it to install.
        const output = b.addNamedWriteFiles("component");
        output.step.dependOn(check_component);
        const artifact = output.addCopyFile(packaging.artifact, "coding.component.wasm");
        component.dependOn(&b.addInstallFile(artifact, "coding.component.wasm").step);
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

fn addWitTree(b: *std.Build, check: ?*std.Build.Step, world: []const u8) std.Build.LazyPath {
    // Zig 0.13 hashes a directory argument's path, not its contents.
    const wit = b.addWriteFiles();
    if (check) |drift| wit.step.dependOn(drift);
    _ = wit.addCopyFile(b.path(world), "world.wit");
    for ([_][]const u8{
        "deps/agent/agent.wit",
        "deps/host/host.wit",
        "deps/session-scoped/scoped-variables.wit",
        "deps/session-scoped/file-versions.wit",
    }) |file| {
        _ = wit.addCopyFile(b.path(b.fmt("wit/{s}", .{file})), file);
    }
    return wit.getDirectory();
}

const ComponentBuild = struct {
    artifact: std.Build.LazyPath,
    verified: *std.Build.Step,
};

fn addCodingComponent(
    b: *std.Build,
    wit: std.Build.LazyPath,
    wasm: *std.Build.Step.Compile,
) ComponentBuild {
    const embed = b.addSystemCommand(&.{
        "wasm-tools", "component", "embed", "--world", "coding", "--encoding", "utf8",
    });
    embed.addDirectoryArg(wit);
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
    targets.addDirectoryArg(wit);
    targets.addArgs(&.{ "--world", "coding" });
    targets.addFileArg(artifact);
    targets.step.dependOn(&validate.step);
    targets.step.dependOn(&extract.step);
    return .{ .artifact = artifact, .verified = &targets.step };
}

fn addCodingAbi(wasm: *std.Build.Step.Compile, coding_abi: *std.Build.Module) void {
    wasm.root_module.addImport("coding_abi", coding_abi);
    wasm.root_module.export_symbol_names = &.{
        "cabi_realloc",   "init",               "describe",         "invoke",          "drive",
        "cabi_post_init", "cabi_post_describe", "cabi_post_invoke", "cabi_post_drive",
    };
}

fn requireCore(step: *std.Build.Step, _: std.Progress.Node) !void {
    return step.fail("pass -Dcore=/path/to/microcrab-core to check canonical WIT", .{});
}
