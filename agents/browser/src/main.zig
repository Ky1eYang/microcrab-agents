//! Browser's concrete wasm32 canonical ABI boundary. Wire offsets describe
//! the pinned WIT types, not Zig struct layout. No operation runs in discovery.
const std = @import("std");
const memory = @import("wasm_abi");
const observation = @import("observation.zig");
const catalog = @import("catalog.zig");
const guest = @import("guest.zig");
const Allocator = std.mem.Allocator;

comptime {
    _ = memory.cabi_realloc;
}

// Runtime serializes calls to this exact Session/epoch instance and retains
// authoritative ownership. Never load/store this value through Session State.
var browser = observation.Browser{};
var transport_context: u8 = 0;
const transport = observation.Transport{
    .context = &transport_context,
    .httpGet = httpGet,
    .open = open,
    .status = status,
    .send = send,
    .receive = receive,
    .close = close,
    .observe = observe,
    .checkpoint = if (@import("browser_options").debug_observation) recordCheckpoint else null,
    .scoped = .{ .pull = pull, .budget = transportBudget, .settle = settle },
};

fn observe(_: *anyopaque, event: observation.Diagnostic) void {
    // Flatten the fixed scalar WIT record; no guest text crosses this import.
    import(fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, "microcrab:session/observation@0.2.2", "record-event")(
        @intFromEnum(event.severity),
        @intFromEnum(event.code),
        @intFromEnum(event.stage),
        @intFromEnum(event.method_family),
        @intFromEnum(event.metric),
        event.measured,
        event.limit,
        @intFromEnum(event.confirmation),
    );
}

fn recordCheckpoint(_: *anyopaque, event: observation.Checkpoint) void {
    import(fn (u32, u32, u32, u32) callconv(.C) void, "microcrab:session/browser-observation@0.2.3", "record-checkpoint")(
        @intFromEnum(event.command),
        @intFromEnum(event.stage),
        event.exchange,
        @intFromEnum(event.reply),
    );
}

const host_info_module = "microcrab:agent/host-info@0.9.0";
const execution_module = "microcrab:agent/execution@0.9.0";
const session_module = "microcrab:session/session@0.4.0";
const transport_module = "microcrab:host/web-transport@0.1.0";
const scoped_transport_module = "microcrab:host/web-transport-scoped@0.1.1";

fn import(comptime T: type, comptime module: []const u8, comptime name: []const u8) *const T {
    return @extern(*const T, .{ .library_name = module, .name = name });
}

export fn init() u32 {
    return reply(20, 4);
}

export fn describe(info_at: u32, info_len: u32) u32 {
    const info = view(info_at, info_len);
    defer release(info, 1);
    var arena = std.heap.ArenaAllocator.init(memory.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = reply(12, 4);
    const wire = view(result, 12);
    _ = compatible(a, info) catch {
        wire[0] = 1;
        lowerText(wire[4..], "Browser received invalid or inconsistent Host facts.");
        return result;
    };
    const description = catalog.describe(a) catch {
        wire[0] = 1;
        lowerText(wire[4..], "Browser could not encode its tool catalog.");
        return result;
    };
    lowerText(wire[4..], description);
    return result;
}

export fn invoke(info_at: u32, info_len: u32, name_at: u32, name_len: u32, args_at: u32, args_len: u32) u32 {
    const info = view(info_at, info_len);
    const name = view(name_at, name_len);
    const args = view(args_at, args_len);
    defer release(info, 1);
    defer release(name, 1);
    defer release(args, 1);
    var arena = std.heap.ArenaAllocator.init(memory.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = reply(52, 4);
    const wire = view(result, 52);
    const ready = compatible(a, info) catch {
        wire[0] = 1;
        lowerFailure(wire[4..], .{ .code = "invalid_host_info", .message = "Browser received invalid or inconsistent Host facts." });
        return result;
    };
    const mode = if (ready and catalog.needsToolCallFacts(name)) admittedMode() else null;
    switch (guest.invoke(&browser, transport, createReference, a, memory.allocator, ready, mode, name, args)) {
        .ok => |text| {
            if (std.mem.eql(u8, name, "connect")) {
                switch (startConnectionJob(a, browser.handle())) {
                    .ok => |buffer| {
                        wire[4] = 1; // tool-output::buffered
                        std.mem.writeInt(u32, wire[8..12], buffer, .little);
                        wire[12] = 1; // include-initial
                    },
                    .err => |msg| {
                        browser.retire(transport) catch {};
                        wire[0] = 1;
                        lowerFailure(wire[4..], .{ .code = "connection_job_failed", .message = msg });
                    },
                }
            } else if (std.mem.eql(u8, name, "execute_js") and text.len > observation.max_js_inline_output_bytes) {
                if (startBufferedOutput(text)) |buffer| {
                    wire[4] = 1; // tool-output::buffered
                    std.mem.writeInt(u32, wire[8..12], buffer, .little);
                    wire[12] = 1; // include-initial
                } else {
                    wire[0] = 1;
                    lowerFailure(wire[4..], .{ .code = "limit", .message = "Browser could not buffer large execute_js output." });
                }
            } else lowerText(wire[8..], text);
        },
        .fail => |failure| {
            wire[0] = 1;
            lowerFailure(wire[4..], failure);
        },
    }
    return result;
}

export fn drive(buffer: u32, state_at: u32, state_len: u32, cancelled: u32) u32 {
    const id = view(state_at, state_len);
    defer release(id, 1);
    defer dropBuffer(buffer);
    const result = reply(32, 8);
    const wire = view(result, 32);
    if (cancelled != 0 or !browser.reusable() or !std.mem.eql(u8, browser.handle(), id)) {
        if (cancelled != 0 and std.mem.eql(u8, browser.handle(), id)) browser.clear(.closed);
        wire[24] = 1; // finished
        return result;
    }
    if (!browser.acquireTool()) {
        lowerDriveStep(wire, id, 10);
        return result;
    }
    defer browser.releaseTool();
    const more = browser.driveReceive(transport, memory.allocator) catch {
        wire[0] = 1;
        lowerFailure(wire[8..], .{ .code = "connection_receive_failed", .message = "The Browser connection receiver stopped; inspect the Job status before reconnecting." });
        return result;
    };
    var sink = JobSink{ .buffer = buffer };
    browser.publishNetwork(16, &sink) catch {
        wire[0] = 1;
        lowerFailure(wire[8..], .{ .code = "connection_job_output", .message = "Unable to publish Browser Job output." });
        return result;
    };
    lowerDriveStep(wire, id, if (more) 1 else 25);
    return result;
}

const JobSink = struct {
    buffer: u32,
    pub fn publish(self: *const JobSink, publication: @import("network_queue.zig").Publication) !void {
        var scratch: [512]u8 = undefined;
        const line = switch (publication) {
            .summary => |row| blk: {
                var number: [20]u8 = undefined;
                const record = try std.fmt.bufPrint(&number, "{d}", .{row.summary.record_id});
                var stream = std.io.fixedBufferStream(&scratch);
                try std.json.stringify(.{ .kind = "network", .page_ref = @as([]const u8, &row.summary.page_ref), .record_id = record, .outcome = @tagName(row.summary.outcome), .http_status = row.summary.http_status }, .{ .emit_null_optional_fields = false }, stream.writer());
                try stream.writer().writeByte('\n');
                break :blk stream.getWritten();
            },
            .loss => |loss| try std.fmt.bufPrint(&scratch, "[... dropped {d} network events; sequence {d}–{d} ...]\n", .{ loss.count(), loss.first_sequence, loss.last_sequence }),
        };
        if (!appendJob(self.buffer, line)) return error.JobOutputRejected;
    }
};

fn lowerDriveStep(wire: []u8, id: []const u8, delay: u64) void {
    lowerText(wire[8..], id);
    std.mem.writeInt(u64, wire[16..24], delay, .little);
}

fn dropBuffer(buffer: u32) void {
    import(fn (u32) callconv(.C) void, execution_module, "[resource-drop]buffer")(buffer);
}

fn executionFailureReason(alloc: Allocator, wire: []const u8) ?[]const u8 {
    if (wire[0] == 0) return null;
    defer releaseFailure(wire[4..]);
    const code = wireText(wire[8..]);
    const message = wireText(wire[16..]);
    if (message.len > 0 and code.len > 0) {
        return std.fmt.allocPrint(alloc, "Unable to start the connection Job ({s}): {s}", .{ code, message }) catch "Unable to start the connection Job.";
    }
    if (message.len > 0) return alloc.dupe(u8, message) catch "Unable to start the connection Job.";
    if (code.len > 0) return std.fmt.allocPrint(alloc, "Unable to start the connection Job ({s}).", .{code}) catch "Unable to start the connection Job.";
    return "Unable to start the connection Job.";
}

fn acceptedExecution(wire: []const u8) bool {
    if (wire[0] == 0) return true;
    releaseFailure(wire[4..]);
    return false;
}

const ConnectionJobResult = union(enum) { ok: u32, err: []const u8 };

fn startConnectionJob(alloc: Allocator, id: []const u8) ConnectionJobResult {
    const initial = std.json.stringifyAlloc(alloc, .{ .status = "connected", .connect_id = id }, .{}) catch |err| return .{ .err = @errorName(err) };
    var out: [28]u8 align(4) = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, execution_module, "create")(0, 0, ptr(&out));
    if (executionFailureReason(alloc, &out)) |msg| return .{ .err = msg };
    const buffer = std.mem.readInt(u32, out[4..8], .little);
    if (!appendJob(buffer, initial)) {
        dropBuffer(buffer);
        return .{ .err = "Unable to append initial connection payload to execution Job." };
    }
    import(fn (u32, u32, u32, u32) callconv(.C) void, execution_module, "attach-guest")(buffer, ptr(id), id.len, ptr(&out));
    if (executionFailureReason(alloc, &out)) |msg| {
        dropBuffer(buffer);
        return .{ .err = msg };
    }
    return .{ .ok = buffer };
}

fn startBufferedOutput(text: []const u8) ?u32 {
    var out: [28]u8 align(4) = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, execution_module, "create")(0, 0, ptr(&out));
    if (!acceptedExecution(&out)) return null;
    const buffer = std.mem.readInt(u32, out[4..8], .little);
    if (!appendJob(buffer, text)) {
        dropBuffer(buffer);
        return null;
    }
    import(fn (u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, execution_module, "finish")(buffer, 0, 0, 0, 0, 0, 0, 0, ptr(&out));
    if (!acceptedExecution(&out)) {
        dropBuffer(buffer);
        return null;
    }
    return buffer;
}

fn appendJob(buffer: u32, text: []const u8) bool {
    var out: [28]u8 align(4) = undefined;
    import(fn (u32, u32, u32, u32, u32, u32, u32) callconv(.C) void, execution_module, "append")(buffer, 0, 0, 0, ptr(text), text.len, ptr(&out));
    return acceptedExecution(&out);
}

export fn cabi_post_init(at: u32) void {
    release(view(at, 20), 4);
}

export fn cabi_post_describe(at: u32) void {
    const wire = view(at, 12);
    releaseText(wire[4..]);
    release(wire, 4);
}

export fn cabi_post_invoke(at: u32) void {
    const wire = view(at, 52);
    if (wire[0] != 0) releaseFailure(wire[4..]) else if (wire[4] == 0) releaseText(wire[8..]);
    release(wire, 4);
}

export fn cabi_post_drive(at: u32) void {
    const wire = view(at, 32);
    if (wire[0] == 0) releaseText(wire[8..]) else releaseFailure(wire[8..]);
    release(wire, 8);
}

fn compatible(a: Allocator, supplied: []const u8) !bool {
    var out: [16]u8 align(4) = undefined;
    import(fn (u32) callconv(.C) void, host_info_module, "host-info")(ptr(&out));
    switch (out[0]) {
        0 => {},
        1 => {
            releaseText(out[8..]);
            return error.HostInfoUnavailable;
        },
        else => @trap(),
    }
    const imported = wireText(out[4..]);
    defer release(imported, 1);
    return catalog.compatible(a, supplied, imported);
}

const CallFactsMode = struct {
    admitted_mode: ?[]const u8 = null,
};

const EvalResult = union(enum) {
    ok: []u8,
    err: struct { code: u8, message: []u8 },
};

fn sessionEval(script: []const u8, args_json: ?[]const u8) EvalResult {
    var out: [16]u8 align(4) = undefined;
    const args_tag: u32 = if (args_json != null) 1 else 0;
    const args_bytes = args_json orelse "";
    import(fn (u32, u32, u32, u32, u32, u32) callconv(.C) void, session_module, "eval")(
        ptr(script),
        script.len,
        args_tag,
        ptr(args_bytes),
        args_bytes.len,
        ptr(&out),
    );
    switch (out[0]) {
        0 => return .{ .ok = wireText(out[4..]) },
        1 => return .{ .err = .{ .code = out[4], .message = wireText(out[8..]) } },
        else => @trap(),
    }
}

fn admittedMode() ?[]const u8 {
    const raw = switch (sessionEval("vars::call_facts()", null)) {
        .ok => |bytes| bytes,
        .err => |failure| {
            release(failure.message, 1);
            return null;
        },
    };
    defer release(raw, 1);
    const parsed = std.json.parseFromSlice(CallFactsMode, memory.allocator, raw, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const mode = parsed.value.admitted_mode orelse return null;
    const known = std.meta.stringToEnum(catalog.Mode, mode) orelse return null;
    return @tagName(known);
}

fn createReference(alloc: Allocator, title: []const u8, media_type: []const u8, b64: []const u8) guest.ReferenceResult {
    // Only JSON-escape title/media_type; b64 has already been validated as strict
    // standard Base64 ASCII, avoiding both encode/decode and 150 KB JSON escaping in WASM.
    const header = std.json.stringifyAlloc(alloc, .{
        .title = title,
        .media_type = media_type,
    }, .{}) catch return .{ .err = "Out of memory encoding reference request." };
    defer alloc.free(header);
    const field = ",\"data\":\"";
    const suffix = "\"}";
    const prefix = header[0 .. header.len - 1];
    const args_json = alloc.alloc(u8, prefix.len + field.len + b64.len + suffix.len) catch return .{ .err = "Out of memory encoding reference request." };
    defer alloc.free(args_json);
    var pos: usize = 0;
    @memcpy(args_json[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(args_json[pos .. pos + field.len], field);
    pos += field.len;
    @memcpy(args_json[pos .. pos + b64.len], b64);
    pos += b64.len;
    @memcpy(args_json[pos .. pos + suffix.len], suffix);

    const raw = switch (sessionEval("refs::create_base64(args.title, args.media_type, args.data)", args_json)) {
        .ok => |bytes| bytes,
        .err => |failure| {
            defer release(failure.message, 1);
            const msg = std.fmt.allocPrint(alloc, "refs::create_base64 failed (code={d}): {s}", .{ failure.code, failure.message }) catch "refs::create_base64 failed.";
            return .{ .err = msg };
        },
    };
    defer release(raw, 1);

    const id = std.json.parseFromSliceLeaky([]const u8, alloc, raw, .{}) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "refs::create_base64 returned invalid JSON id ({s}): {s}", .{ @errorName(err), raw }) catch "refs::create_base64 returned invalid JSON id.";
        return .{ .err = msg };
    };
    return .{ .ok = id };
}

const TE = observation.TransportError;
fn transportError(tag: u8) TE {
    return switch (tag) {
        0 => error.Unsupported,
        1 => error.Denied,
        2 => error.InvalidRequest,
        3 => error.Oversized,
        4 => error.Cancelled,
        5 => error.Timeout,
        6 => error.Stale,
        7 => error.Closed,
        8 => error.OutcomeUnknown,
        9 => error.TransportFailure,
        else => @trap(),
    };
}

fn checkReturn(out: []const u8, error_offset: usize) TE!void {
    switch (out[0]) {
        0 => {},
        1 => return transportError(out[error_offset]),
        else => @trap(),
    }
}

fn lift(a: Allocator, wire: []const u8, max_len: usize) TE![]const u8 {
    const bytes = wireText(wire);
    defer release(bytes, 1);
    if (bytes.len > max_len) return error.Oversized;
    return a.dupe(u8, bytes);
}

fn httpGet(_: *anyopaque, a: Allocator, url: []const u8, cap: usize) TE!observation.HttpResponse {
    var out: [16]u8 align(4) = undefined;
    import(fn (u32, u32, u32, u32) callconv(.C) void, transport_module, "http-get")(ptr(url), url.len, cap, ptr(&out));
    try checkReturn(&out, 4);
    return .{ .status = std.mem.readInt(u16, out[4..6], .little), .body = try lift(a, out[8..], cap) };
}

fn open(_: *anyopaque, a: Allocator, url: []const u8) TE![]const u8 {
    var out: [12]u8 align(4) = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, transport_module, "ws-open")(ptr(url), url.len, ptr(&out));
    try checkReturn(&out, 4);
    return lift(a, out[4..], observation.max_connection_bytes);
}

fn status(_: *anyopaque, id: []const u8) TE!void {
    var out: [2]u8 = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, transport_module, "ws-status")(ptr(id), id.len, ptr(&out));
    return checkReturn(&out, 1);
}

fn send(_: *anyopaque, id: []const u8, text: []const u8) TE!void {
    var out: [2]u8 = undefined;
    import(fn (u32, u32, u32, u32, u32) callconv(.C) void, transport_module, "ws-send")(ptr(id), id.len, ptr(text), text.len, ptr(&out));
    return checkReturn(&out, 1);
}

fn receive(_: *anyopaque, a: Allocator, id: []const u8, cap: usize) TE![]const u8 {
    var out: [16]u8 align(4) = undefined;
    import(fn (u32, u32, u32, u32) callconv(.C) void, transport_module, "ws-receive")(ptr(id), id.len, cap, ptr(&out));
    try checkReturn(&out, 4);
    return switch (out[4]) {
        0 => lift(a, out[8..], cap),
        1 => error.Timeout,
        2 => error.Closed,
        else => @trap(),
    };
}

fn pull(_: *anyopaque, a: Allocator, id: []const u8, cap: usize, soft_wait_ms: u32) TE!observation.Pull {
    var out: [16]u8 align(4) = undefined;
    import(fn (u32, u32, u32, u32, u32) callconv(.C) void, scoped_transport_module, "ws-pull")(ptr(id), id.len, cap, soft_wait_ms, ptr(&out));
    try checkReturn(&out, 4);
    return switch (out[4]) {
        0 => .{ .message = try lift(a, out[8..], cap) },
        1 => .empty,
        2 => .closed,
        else => @trap(),
    };
}

fn transportBudget(_: *anyopaque, id: []const u8) TE!observation.Clock {
    var out: [12]u8 align(4) = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, scoped_transport_module, "ws-budget")(ptr(id), id.len, ptr(&out));
    try checkReturn(&out, 4);
    return .{ .transport_ms = std.mem.readInt(u32, out[4..8], .little), .guest_ms = std.mem.readInt(u32, out[8..12], .little) };
}

fn settle(_: *anyopaque, id: []const u8) TE!void {
    var out: [2]u8 = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, scoped_transport_module, "ws-settle")(ptr(id), id.len, ptr(&out));
    return checkReturn(&out, 1);
}

fn close(_: *anyopaque, id: []const u8) TE!void {
    var out: [2]u8 = undefined;
    import(fn (u32, u32, u32) callconv(.C) void, transport_module, "ws-close")(ptr(id), id.len, ptr(&out));
    return checkReturn(&out, 1);
}

fn ptr(bytes: []const u8) u32 {
    return if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
}

fn view(at: u32, size: u32) []u8 {
    if (size == 0) return &.{};
    if (at == 0 or @as(u64, at) + size > @as(u64, @wasmMemorySize(0)) * 65536) @trap();
    return @as([*]u8, @ptrFromInt(at))[0..size];
}

fn release(bytes: []u8, alignment: u32) void {
    if (bytes.len != 0) memory.allocator.rawFree(bytes, std.math.log2_int(u32, alignment), @returnAddress());
}

fn reply(size: u32, alignment: u32) u32 {
    const at = memory.cabi_realloc(null, 0, alignment, size);
    @memset(view(at, size), 0);
    return at;
}

fn wireText(wire: []const u8) []u8 {
    return view(std.mem.readInt(u32, wire[0..4], .little), std.mem.readInt(u32, wire[4..8], .little));
}

fn releaseText(wire: []const u8) void {
    release(wireText(wire), 1);
}

fn lowerText(wire: []u8, text: []const u8) void {
    if (text.len == 0) return;
    const at = memory.cabi_realloc(null, 0, 1, text.len);
    @memcpy(view(at, text.len), text);
    std.mem.writeInt(u32, wire[0..4], at, .little);
    std.mem.writeInt(u32, wire[4..8], text.len, .little);
}

fn lowerFailure(wire: []u8, fail: guest.Failure) void {
    wire[0] = @intFromEnum(fail.kind);
    lowerText(wire[4..], fail.code);
    lowerText(wire[12..], fail.message);
    // retryable=false; the adapter never requests an implicit retry.
}

fn releaseFailure(wire: []const u8) void {
    releaseText(wire[4..]);
    releaseText(wire[12..]);
}
