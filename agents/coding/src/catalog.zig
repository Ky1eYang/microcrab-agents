//! Capability-shaped Coding metadata. Core/Host retain all policy and linkage authority.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const HostInfo = struct {
    os_family: enum { unix, windows, other },
    os: []const u8,
    arch: []const u8,
    shell: []const u8,
    path_separator: []const u8,
    newline: []const u8,
    capabilities: []const []const u8,
    resources: ?struct {
        platform: []const u8,
        features: struct {
            process_pty: bool,
            process_kill_tree: bool,
            fs_watch: bool,
            fs_symlink: bool,
            net_listen: bool,
            net_udp: bool,
        },
    } = null,
    virtual_shell: ?struct {
        engine: []const u8,
        python: ?struct { implementation: []const u8, version: ?[]const u8 = null } = null,
    } = null,
    description: ?[]const u8 = null,

    fn linked(self: HostInfo, required: []const u8) bool {
        for (self.capabilities) |capability| if (eq(capability, required)) return true;
        return false;
    }

    pub fn shellName(self: HostInfo) ?[]const u8 {
        if (!self.linked("shell") or !self.linked("process")) return null;
        const name = switch (self.os_family) {
            .windows => "pwsh",
            .unix => "bash",
            .other => self.shell,
        };
        if (name.len == 0 or name.len > 64) return null;
        for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return null;
        }
        // Keep the removed tool name reserved so a Host shell cannot reintroduce it.
        // The Runtime independently reserves built-in names.
        const reserved = [_][]const u8{ "read", "read_image", "write", "edit", "patch", "apply_patch", "switch_mode", "glob", "grep", "job", "delegate", "sleep", "expand" };
        for (reserved) |collision| if (eq(name, collision)) return null;
        return name;
    }

    pub fn offers(self: HostInfo, name: []const u8) bool {
        if (eq(name, "read") or eq(name, "write") or eq(name, "edit") or eq(name, "patch") or eq(name, "apply_patch")) {
            if (!self.linked("file_versions_v1")) return false;
        }
        if (eq(name, "edit") or eq(name, "patch")) return self.linked("read") and self.linked("write");
        if (eq(name, "apply_patch")) return self.linked("read") and self.linked("file_mutation");
        const ordinary = [_][]const u8{ "read", "write", "glob", "grep" };
        for (ordinary) |tool| if (eq(name, tool)) return self.linked(tool);
        return if (self.shellName()) |shell| eq(shell, name) else false;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn checkedHost(scratch: Allocator, input: []const u8, canonical: []const u8) !HostInfo {
    const supplied = try std.json.parseFromSliceLeaky(HostInfo, scratch, input, .{});
    const imported = try std.json.parseFromSliceLeaky(HostInfo, scratch, canonical, .{});
    const a = try std.json.stringifyAlloc(scratch, supplied, .{});
    const b = try std.json.stringifyAlloc(scratch, imported, .{});
    if (!eq(a, b)) return error.HostInfoMismatch;
    return supplied;
}

const Tool = struct { name: []const u8, description: []const u8, parameters: Value };
const Rule = struct { name: []const u8, description: []const u8 };
const Variables = struct { description: []const u8, rules: []const Rule, hints: []const Rule };
const Role = enum { main_agent, both };
const ModeBase = struct { name: []const u8, description: []const u8, prompt: []const u8, role: Role };
const Shell = struct { descriptions: struct { unix: []const u8, windows: []const u8, other: []const u8 }, parameters: Value };
const Baseline = struct {
    name: []const u8,
    modes: []const ModeBase,
    tools: []const Tool,
    variables: Variables,
    shell: Shell,
};
const Matcher = struct { kind: enum { exact, regex }, value: []const u8 };
const Predicate = struct { pointer: []const u8, matcher: Matcher };
const Permission = struct {
    agent: []const u8,
    mode: []const u8,
    tool: Matcher,
    args: []const Predicate = &.{},
    action: enum { allow, ask, deny },
};
// Core anchors argument regexes to the full input string.
const markdown = [_]Predicate{.{ .pointer = "/path", .matcher = .{ .kind = .regex, .value = "(?s:.*)\\.md" } }};
// Predicates see strings only. The schema rejects other types; the guest also
// rejects a supplied expected_version in the actual resolved write arguments.
const version_present = [_]Predicate{.{ .pointer = "/expected_version", .matcher = .{ .kind = .regex, .value = "(?s:.*)" } }};
const Mode = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    role: Role,
    permissions: []const Permission,
};
const Agent = struct {
    name: []const u8,
    modes: []const Mode,
    tools: []const Tool,
    variables: Variables,
};

pub fn describe(scratch: Allocator, host: HostInfo) ![]const u8 {
    const base = try std.json.parseFromSliceLeaky(Baseline, scratch, @embedFile("catalog-baseline.json"), .{ .max_value_len = 4096 });
    var tools = std.ArrayList(Tool).init(scratch);
    for (base.tools) |tool| if (host.offers(tool.name)) try tools.append(tool);
    const shell = host.shellName();
    if (shell) |name| {
        try tools.append(.{
            .name = name,
            .description = switch (host.os_family) {
                .unix => base.shell.descriptions.unix,
                .windows => base.shell.descriptions.windows,
                .other => base.shell.descriptions.other,
            },
            .parameters = base.shell.parameters,
        });
    }
    const modes = try scratch.alloc(Mode, base.modes.len);
    for (base.modes, modes) |mode, *out| {
        var permissions = try std.ArrayList(Permission).initCapacity(scratch, tools.items.len + 3);
        for (tools.items) |tool| {
            const name = tool.name;
            const read_only = eq(name, "read") or eq(name, "glob") or eq(name, "grep");
            const actual_shell = if (shell) |actual| eq(name, actual) else false;
            const plan_mode = eq(mode.name, "plan");
            var rule: Permission = .{
                .agent = base.name,
                .mode = mode.name,
                .tool = .{ .kind = .exact, .value = name },
                .action = if (read_only) .allow else if (actual_shell or !plan_mode or eq(name, "patch")) .ask else .deny,
            };
            permissions.appendAssumeCapacity(rule);
            // Core evaluates last match first: deny a versioned write before
            // allowing Markdown paths, with the unconditional deny as fallback.
            if (plan_mode and (eq(name, "write") or eq(name, "edit"))) {
                rule.action = .allow;
                rule.args = &markdown;
                permissions.appendAssumeCapacity(rule);
                if (eq(name, "write")) {
                    rule.action = .deny;
                    rule.args = &version_present;
                    permissions.appendAssumeCapacity(rule);
                }
            }
        }
        out.* = .{ .name = mode.name, .description = mode.description, .prompt = mode.prompt, .role = mode.role, .permissions = permissions.items };
    }
    var variables = base.variables;
    if (host.description) |description| {
        const hints = try scratch.alloc(Rule, variables.hints.len + 1);
        @memcpy(hints[0..variables.hints.len], variables.hints);
        hints[variables.hints.len] = .{ .name = "host_environment", .description = description };
        variables.hints = hints;
    }
    const agent = Agent{
        .name = base.name,
        .modes = modes,
        .tools = tools.items,
        .variables = variables,
    };
    return std.json.stringifyAlloc(scratch, &[_]Agent{agent}, .{ .emit_null_optional_fields = false });
}
