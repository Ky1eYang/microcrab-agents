//! Experimental Chrome DevTools WebMCP. All page metadata and results are untrusted.
//! Protocol: https://chromedevtools.github.io/devtools-protocol/#/WebMCP
//! https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/WebMCP.pdl
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const max_args_bytes = 8 * 1024;
const max_registrations = 64;
const max_listed = 6;
const max_schema_bytes = 1536;
const max_output_bytes = 8 * 1024;
const max_wait_messages = 12;
const max_registry_events = 12;
const Ref = [32]u8;
const Invalid = error{InvalidCdpMessage};

pub const InvokeArgs = struct { page_ref: []const u8, tool_ref: []const u8, input: Value };
pub const Operation = union(enum) { list, invoke: InvokeArgs };
const Status = enum { listed, unsupported, page_not_allowed, page_changed, stale_tool_ref, rejected, completed, canceled, @"error", timeout, cancelled, outcome_unknown };
const Annotations = struct {
    readOnly: ?bool = null,
    untrustedContent: ?bool = null,
    consequential: ?bool = null,
    debugging: ?bool = null,
    autosubmit: ?bool = null,
};
const ListedTool = struct {
    tool_ref: Ref,
    name: []const u8,
    description: []const u8,
    inputSchema: ?Value = null,
    outputSchema: ?Value = null,
    input_schema_omitted: bool = false,
    output_schema_omitted: bool = false,
    fields_truncated: bool = false,
    annotations: ?Annotations = null,
};
pub const Receipt = struct {
    outcome: Status,
    page_ref: []const u8,
    tool_ref: ?[]const u8 = null,
    untrusted: bool = true,
    tools: ?[]const ListedTool = null,
    omitted_tools: ?usize = null,
    output: ?Value = null,
    output_omitted: ?bool = null,
    error_text: ?[]const u8 = null,
    error_text_truncated: ?bool = null,
    cancellation: ?enum { acknowledged, unconfirmed } = null,
    may_have_run: ?bool = null,
};

pub const Command = union(enum) {
    enable,
    invoke_tool: struct { frameId: []const u8, toolId: []const u8, input: Value },
    cancel_invocation: struct { invocationId: []const u8 },

    pub fn encode(self: Command, alloc: Allocator, id: u32, session_id: []const u8) Allocator.Error![]const u8 {
        return switch (self) {
            .enable => std.json.stringifyAlloc(alloc, .{ .id = id, .sessionId = session_id, .method = "WebMCP.enable" }, .{}),
            .invoke_tool => |params| std.json.stringifyAlloc(alloc, .{ .id = id, .sessionId = session_id, .method = "WebMCP.invokeTool", .params = params }, .{}),
            .cancel_invocation => |params| std.json.stringifyAlloc(alloc, .{ .id = id, .sessionId = session_id, .method = "WebMCP.cancelInvocation", .params = params }, .{}),
        };
    }
};

pub fn validRef(ref: []const u8) bool {
    if (ref.len != 32) return false;
    for (ref) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}

fn string(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}

fn opaqueId(value: Value, key: []const u8) ?[]const u8 {
    const id = string(value, key) orelse return null;
    return if (id.len != 0 and id.len <= 256) id else null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn encodedWithin(value: Value, limit: usize) bool {
    // Count escaped JSON (rather than decoded string length) without allocating
    // an intermediate copy. Recursion is already bounded by the CDP decoder.
    var sink = std.io.countingWriter(std.io.null_writer);
    std.json.stringify(value, .{}, sink.writer()) catch return false;
    return sink.bytes_written <= limit;
}

fn textPrefix(text: []const u8, max: usize) []const u8 {
    var end = @min(text.len, max);
    while (end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

const Registration = struct { id: []const u8, data: Value };

pub const Registry = struct {
    frame: []const u8,
    entries: std.BoundedArray(Registration, max_registrations) = .{},
    events: usize = 0,
    legacy: bool = false,

    pub fn capture(self: *Registry, method: []const u8, params: Value) (Invalid || error{WebMcpRegistryLimit})!void {
        const is_add = eq(method, "WebMCP.toolsAdded");
        if (!is_add and !eq(method, "WebMCP.toolsRemoved")) return;
        self.events += 1;
        if (self.events > max_registry_events) return error.WebMcpRegistryLimit;
        const tools = field(params, "tools") orelse return error.InvalidCdpMessage;
        if (tools != .array) return error.InvalidCdpMessage;
        for (tools.array.items) |tool| {
            const frame = opaqueId(tool, "frameId") orelse return error.InvalidCdpMessage;
            if (!eq(frame, self.frame)) continue;
            _ = string(tool, "name") orelse return error.InvalidCdpMessage;
            // Earlier Chrome implements the domain but identifies registrations
            // by name alone. Never advertise or use a name-derived reference.
            if (field(tool, "toolId") == null) {
                self.legacy = true;
                continue;
            }
            const id = opaqueId(tool, "toolId") orelse return error.InvalidCdpMessage;
            const existing = for (self.entries.slice(), 0..) |other, i| {
                if (eq(id, other.id)) break i;
            } else null;
            if (is_add) {
                if (existing != null) return error.InvalidCdpMessage;
                _ = string(tool, "description") orelse return error.InvalidCdpMessage;
                inline for (.{ "inputSchema", "outputSchema" }) |key| {
                    if (field(tool, key)) |schema| if (schema != .object) return error.InvalidCdpMessage;
                }
                _ = try annotations(tool);
                self.entries.append(.{ .id = id, .data = tool }) catch return error.WebMcpRegistryLimit;
            } else if (existing) |i| {
                _ = self.entries.orderedRemove(i);
            }
        }
    }

    fn list(self: *const Registry, a: Allocator, page: []const u8, loader: []const u8) (Allocator.Error || Invalid)!Receipt {
        const entries = self.entries.constSlice();
        const listed = try a.alloc(ListedTool, @min(entries.len, max_listed));
        for (entries[0..listed.len], listed) |entry, *item| {
            const name = string(entry.data, "name") orelse return error.InvalidCdpMessage;
            const description = string(entry.data, "description") orelse return error.InvalidCdpMessage;
            item.* = .{
                .tool_ref = registrationRef(page, self.frame, loader, entry.id),
                .name = textPrefix(name, 128),
                .description = textPrefix(description, 384),
                .annotations = try annotations(entry.data),
            };
            item.fields_truncated = item.name.len != name.len or item.description.len != description.len;
            if (field(entry.data, "inputSchema")) |schema| {
                if (encodedWithin(schema, max_schema_bytes)) item.inputSchema = schema else item.input_schema_omitted = true;
            }
            if (field(entry.data, "outputSchema")) |schema| {
                if (encodedWithin(schema, max_schema_bytes)) item.outputSchema = schema else item.output_schema_omitted = true;
            }
        }
        return .{ .outcome = .listed, .page_ref = page, .tools = listed, .omitted_tools = entries.len - listed.len };
    }

    fn resolve(self: *const Registry, page: []const u8, loader: []const u8, supplied: []const u8) Invalid!?[]const u8 {
        var exact: ?[]const u8 = null;
        for (self.entries.constSlice()) |entry| {
            if (!eq(&registrationRef(page, self.frame, loader, entry.id), supplied)) continue;
            if (exact != null) return error.InvalidCdpMessage;
            exact = entry.id;
        }
        return exact;
    }
};

fn annotations(tool: Value) Invalid!?Annotations {
    const source = field(tool, "annotations") orelse return null;
    if (source != .object) return error.InvalidCdpMessage;
    var result: Annotations = .{};
    inline for (std.meta.fields(Annotations)) |def| {
        if (field(source, def.name)) |value| {
            if (value != .bool) return error.InvalidCdpMessage;
            @field(result, def.name) = value.bool;
        }
    }
    return result;
}

fn registrationRef(page: []const u8, frame: []const u8, loader: []const u8, tool: []const u8) Ref {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("microcrab/browser/webmcp-ref/v1\x00");
    // Hash the connection-bound canonical page reference and every exact
    // identity component with length framing. Never use tool names as keys.
    for ([_][]const u8{ page, frame, loader, tool }) |id| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(id.len), .little);
        hash.update(&len);
        hash.update(id);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

pub const Invocation = struct {
    id: []const u8,
    frame: []const u8,
    tool: []const u8,
    started: bool = false,
    terminal: ?Receipt = null,

    pub fn capture(self: *Invocation, method: []const u8, params: Value) Invalid!void {
        const is_start = eq(method, "WebMCP.toolInvoked");
        if (!is_start and !eq(method, "WebMCP.toolResponded")) return;
        const id = opaqueId(params, "invocationId") orelse return error.InvalidCdpMessage;
        if (!eq(id, self.id)) return;
        if (self.terminal != null) return error.InvalidCdpMessage;
        if (is_start) {
            if (self.started or !eq(opaqueId(params, "frameId") orelse return error.InvalidCdpMessage, self.frame) or
                !eq(opaqueId(params, "toolId") orelse return error.InvalidCdpMessage, self.tool)) return error.InvalidCdpMessage;
            _ = string(params, "input") orelse return error.InvalidCdpMessage;
            self.started = true;
            return;
        }
        // ToolResponded carries no frame or tool ID. Accept it only after the
        // exact same invocation has supplied a verified start witness.
        if (!self.started) return error.InvalidCdpMessage;
        const status = string(params, "status") orelse return error.InvalidCdpMessage;
        var terminal: Receipt = .{ .outcome = if (eq(status, "Completed")) .completed else if (eq(status, "Canceled")) .canceled else if (eq(status, "Error")) .@"error" else return error.InvalidCdpMessage, .page_ref = "" };
        if (field(params, "output")) |output| {
            if (terminal.outcome != .completed) return error.InvalidCdpMessage;
            if (encodedWithin(output, max_output_bytes)) terminal.output = output else terminal.output_omitted = true;
        }
        if (string(params, "errorText")) |text| {
            terminal.error_text = textPrefix(text, 512);
            terminal.error_text_truncated = terminal.error_text.?.len != text.len;
        }
        self.terminal = terminal;
    }
};

pub const Witness = union(enum) {
    registry: *Registry,
    invocation: *Invocation,

    pub fn capture(self: Witness, envelope: Value) (Invalid || error{WebMcpRegistryLimit})!void {
        const method = string(envelope, "method") orelse return error.InvalidCdpMessage;
        return self.captureParams(method, field(envelope, "params") orelse .null);
    }

    pub fn captureParams(self: Witness, method: []const u8, params: Value) (Invalid || error{WebMcpRegistryLimit})!void {
        switch (self) {
            .registry => |tracker| try tracker.capture(method, params),
            .invocation => |tracker| try tracker.capture(method, params),
        }
    }
};

/// `io` is a page-bound adapter using the same attachment, parser and Runtime
/// deadline for commands and events. It never exposes an arbitrary CDP method.
pub fn run(io: anytype, a: Allocator, page: []const u8, frame: []const u8, op: Operation) @TypeOf(io.*).ProtocolError!Receipt {
    var fallback: Receipt = .{ .outcome = .unsupported, .page_ref = page, .tool_ref = if (op == .invoke) op.invoke.tool_ref else null };
    var registry: Registry = .{ .frame = frame };
    const witness: Witness = .{ .registry = &registry };
    const initial_loader = try io.rootLoader(frame, null) orelse {
        fallback.outcome = .page_not_allowed;
        return fallback;
    };
    const enabled = io.command(.enable, witness) catch |err| switch (err) {
        error.WebMcpUnsupported => return fallback,
        else => return err,
    };
    if (enabled.object.count() != 0) return error.InvalidCdpMessage;
    // Also fences WebMCP registration events around the enable ACK. Chrome
    // deliberately sends no initial toolsAdded for an empty registration set.
    const loader = try io.rootLoader(frame, witness) orelse {
        fallback.outcome = .page_not_allowed;
        return fallback;
    };
    if (!eq(loader, initial_loader)) {
        fallback.outcome = .page_changed;
        return fallback;
    }
    if (registry.legacy) return fallback;
    if (op == .list) return registry.list(a, page, loader);
    const tool = try registry.resolve(page, loader, op.invoke.tool_ref) orelse {
        fallback.outcome = .stale_tool_ref;
        return fallback;
    };
    const ack = io.command(.{ .invoke_tool = .{ .frameId = frame, .toolId = tool, .input = op.invoke.input } }, null) catch |err| switch (err) {
        error.WebMcpUnsupported => return fallback,
        error.CdpRejected => {
            fallback.outcome = .rejected;
            return fallback;
        },
        else => return uncertain(io, fallback, err),
    };
    const id = opaqueId(ack, "invocationId") orelse return uncertain(io, fallback, error.InvalidCdpMessage);
    var inv: Invocation = .{ .id = id, .frame = frame, .tool = tool };
    const track: Witness = .{ .invocation = &inv };
    for (0..max_wait_messages) |_| {
        if (io.receive(track)) |_| {
            if (inv.terminal) |terminal| return settle(fallback, terminal);
        } else |err| switch (err) {
            // A local decode/event bound leaves the exact accepted invocation
            // ID available. Transport-originated timeouts/cancels retire the
            // route and must not be represented as confirmed Chrome cancellation.
            error.MessageBudgetExceeded, error.RawByteBudgetExceeded, error.DecodeByteBudgetExceeded, error.DecodeTokenBudgetExceeded => break,
            else => return uncertain(io, fallback, err),
        }
    }
    fallback.outcome = .outcome_unknown;
    fallback.cancellation = .unconfirmed;
    const cancel = io.cancel(.{ .cancel_invocation = .{ .invocationId = id } }, track) catch |err| {
        if (err != error.CdpRejected) return uncertain(io, fallback, err);
        // Rejection is not proof the invocation completed, but it can race
        // with an independently witnessed terminal event.
        return if (inv.terminal) |terminal| settle(fallback, terminal) else uncertain(io, fallback, err);
    };
    if (cancel.object.count() != 0) return uncertain(io, fallback, error.InvalidCdpMessage);
    fallback.cancellation = .acknowledged;
    if (inv.terminal) |terminal| return settle(fallback, terminal);
    return uncertain(io, fallback, error.MessageBudgetExceeded);
}

fn uncertain(io: anytype, receipt: Receipt, err: @TypeOf(io.*).ProtocolError) Receipt {
    io.invalidate();
    var result = receipt;
    result.may_have_run = true;
    result.outcome = switch (err) {
        error.Timeout => .timeout,
        error.Cancelled => .cancelled,
        else => .outcome_unknown,
    };
    return result;
}

fn settle(receipt: Receipt, terminal: Receipt) Receipt {
    var result = terminal;
    result.page_ref = receipt.page_ref;
    result.tool_ref = receipt.tool_ref;
    result.cancellation = receipt.cancellation;
    return result;
}
