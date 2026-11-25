const std = @import("std");

comptime {
    if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 13, .patch = 0 }) != .eq)
        @compileError("MicroCrab Agents requires Zig 0.13.0");
}

pub fn build(b: *std.Build) void {
    const tests = b.step("test", "Run isolated Browser native tests");
    b.default_step = tests;
    const native = b.addTest(.{
        .root_source_file = b.path("src/observation_test.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(native).step);
    const webmcp_tests = b.addTest(.{
        .root_source_file = b.path("src/webmcp_test.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(webmcp_tests).step);
    const network_queue_tests = b.addTest(.{
        .root_source_file = b.path("src/network_queue_test.zig"),
        .target = b.host,
        .optimize = .Debug,
    });
    tests.dependOn(&b.addRunArtifact(network_queue_tests).step);

    const core = b.option([]const u8, "core", "Canonical microcrab-core checkout for Browser WIT drift checks");
    const drift = b.step("check-wit", "Fail on Browser byte drift from canonical Core WIT");
    if (core) |path| {
        const compare = b.addSystemCommand(&.{"bash"});
        compare.addFileArg(b.path("tools/check-wit.sh"));
        compare.addArg(path);
        compare.has_side_effects = true;
        drift.dependOn(&compare.step);
    } else {
        drift.makeFn = requireCore;
    }

    const memory = b.dependency("shared", .{}).module("wasm_abi");
    const debug_guest = b.option(bool, "browser-debug", "Enable the Browser guest's bounded DEBUG observation checkpoints") orelse false;
    const unoptimized = b.option(bool, "browser-unoptimized", "Use Zig Debug optimization for diagnostics (may exceed default Runtime fuel)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "debug_observation", debug_guest);
    const guest = b.addExecutable(.{
        .name = "browser",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = if (unoptimized) .Debug else if (debug_guest) .ReleaseFast else .ReleaseSmall,
    });
    guest.entry = .disabled;
    guest.export_memory = true;
    guest.root_module.addImport("wasm_abi", memory);
    guest.root_module.addOptions("browser_options", options);
    guest.root_module.export_symbol_names = &.{
        "cabi_realloc",   "init",               "describe",         "invoke",          "drive",
        "cabi_post_init", "cabi_post_describe", "cabi_post_invoke", "cabi_post_drive",
    };

    const wire = b.addSystemCommand(&.{"node"});
    wire.addFileArg(b.path("tools/test-browser-abi.mjs"));
    wire.addFileArg(guest.getEmittedBin());
    if (debug_guest) wire.addArg("--debug-observation");
    b.step("test-wasm", "Run Browser wasm32 wire tests against synthetic imports").dependOn(&wire.step);

    // Copy individually so Zig 0.13 caches changes to WIT file contents.
    const wit = b.addWriteFiles();
    for ([_][]const u8{
        "world.wit",
        "deps/agent/agent.wit",
        "deps/host/host.wit",
        "deps/host-scoped/scoped-web-transport.wit",
        "deps/session-scoped/scoped-variables.wit",
        "deps/session-private/private-bytes.wit",
        "deps/session-observation/observation.wit",
        "deps/session-browser-observation/browser-observation.wit",
    }) |file| {
        _ = wit.addCopyFile(b.path(b.fmt("wit/{s}", .{file})), file);
    }
    const world = if (debug_guest) "browser-debug" else "browser";
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", world, "--encoding", "utf8" });
    embed.addDirectoryArg(wit.getDirectory());
    embed.addFileArg(guest.getEmittedBin());
    embed.addArg("-o");
    const embedded = embed.addOutputFileArg("browser.embedded.wasm");
    const compose = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    compose.addFileArg(embedded);
    compose.addArg("-o");
    const artifact = compose.addOutputFileArg("browser.component.wasm");
    const verify = b.addSystemCommand(&.{ "wasm-tools", "validate" });
    verify.addFileArg(artifact);
    const targets = b.addSystemCommand(&.{ "wasm-tools", "component", "targets" });
    targets.addDirectoryArg(wit.getDirectory());
    targets.addArgs(&.{ "--world", world });
    targets.addFileArg(artifact);
    targets.step.dependOn(&verify.step);
    b.step("check-vendored-component", "Verify Browser against the vendored WIT only").dependOn(&targets.step);

    const check = b.step("check-component", "Verify Browser against the selected canonical Core WIT");
    check.dependOn(drift);
    if (core != null) check.dependOn(&targets.step);
    const component = b.step("component", "Build an explicit Browser Component without staging it in Runtime");
    component.dependOn(check);
    if (core != null) {
        const output = b.addNamedWriteFiles("component");
        output.step.dependOn(check);
        const result = output.addCopyFile(artifact, "browser.component.wasm");
        component.dependOn(&b.addInstallFile(result, "browser.component.wasm").step);
    }
}

fn requireCore(step: *std.Build.Step, _: std.Progress.Node) !void {
    return step.fail("pass -Dcore=/absolute/path/to/microcrab-core to check Browser canonical WIT", .{});
}
