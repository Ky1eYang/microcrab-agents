//! Bounded CDP observation and interaction. All I/O is through an invocation-bound
//! transport. One Browser belongs to a serialized, ephemeral Session/epoch slot.
const std = @import("std");
const cdp = @import("cdp_envelope.zig");
const diagnostics = @import("diagnostic.zig");
pub const Diagnostic = diagnostics.Event;
pub const Checkpoint = diagnostics.Checkpoint;
const endpoint = @import("endpoint.zig");
const webmcp = @import("webmcp.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const max_endpoint_bytes = endpoint.max_bytes;
pub const max_navigation_url_bytes = 4096;
pub const max_input_text_bytes = 3072;
pub const max_js_expression_bytes = 2048;
pub const default_js_timeout_ms: u16 = 1000;
pub const max_js_timeout_ms: u16 = 2000;
pub const max_js_inline_output_bytes = 8 * 1024;
pub const max_js_output_bytes = 48 * 1024;
const max_js_reply_bytes = 64 * 1024;
pub const JsWorld = enum { isolated, main };
pub const ExecuteJs = struct {
    page_ref: []const u8,
    expression: []const u8,
    world: JsWorld = .isolated,
    timeout_ms: u16 = default_js_timeout_ms,

    pub fn valid(self: ExecuteJs) bool {
        return validRef(self.page_ref) and self.expression.len > 0 and self.expression.len <= max_js_expression_bytes and
            std.unicode.utf8ValidateSlice(self.expression) and self.timeout_ms > 0 and self.timeout_ms <= max_js_timeout_ms;
    }
};
pub const JsReceipt = struct {
    outcome: enum { evaluated, undefined, result_unavailable, output_limit, script_exception, execution_timed_out, page_not_allowed, context_unavailable },
    result: ?Value = null,
    max_bytes: ?usize = null,
    exception_name: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
};
pub const max_jpeg_bytes = 112 * 1024;
pub const default_jpeg_quality = 55;
pub const min_screenshot_scale = 0.1;
pub const Clip = struct { x: f64, y: f64, width: f64, height: f64 };
pub const ScreenshotOptions = struct {
    clip: ?Clip = null,
    scale: ?f64 = null,
    quality: u8 = default_jpeg_quality,

    fn validate(self: ScreenshotOptions) Error!void {
        const scale = self.scale orelse 1;
        if (!std.math.isFinite(scale) or scale < min_screenshot_scale or scale > 1 or self.quality > 100) return error.InvalidScreenshotOptions;
        if (self.clip) |clip| {
            if (!std.math.isFinite(clip.x) or !std.math.isFinite(clip.y) or
                !std.math.isFinite(clip.width) or !std.math.isFinite(clip.height) or
                clip.x < 0 or clip.y < 0 or clip.width * scale < 1 or clip.height * scale < 1) return error.InvalidScreenshotOptions; // Prevent an empty rounded capture.
        }
    }
};
pub const Modifier = enum { Control, Alt, Shift, Meta };
pub const named_keys = [_][]const u8{
    "Enter",   "Escape",    "Tab",       "Backspace",  "Delete", "Insert", "Home", "End", "PageUp", "PageDown",
    "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "F1",     "F2",     "F3",   "F4",  "F5",     "F6",
    "F7",      "F8",        "F9",        "F10",        "F11",    "F12",
};
const KeyInput = struct { key: []const u8, ctrlKey: bool = false, altKey: bool = false, shiftKey: bool = false, metaKey: bool = false };
const project_function = @embedFile("project.js");
// Share only the isolated-world authority, reference store and semantic helpers.
// Keep each fixed declaration small enough for the unchanged CDP send cap.
const scoped_prefix_end = blk: {
    @setEvalBranchQuota(20_000);
    break :blk std.mem.indexOf(u8, project_function, "  // Legacy projection and effects.").?;
};
const scoped_function = project_function[0..scoped_prefix_end] ++ @embedFile("project_scoped.js");
pub const max_scroll_delta: i32 = 2000;
pub const max_find_text_bytes = 120;
pub const max_option_value_bytes = 512;
pub const max_wait_ms: u16 = 7000;
pub const WaitCondition = enum { document_ready, element_visible, element_hidden };
pub const max_discovery_bytes = 16 * 1024;
pub const max_text_bytes = 256 * 1024;
pub const max_connection_bytes = 128;
pub const max_pages = 64;
pub const max_nodes = 256;
pub const max_field_bytes = 512;
pub const max_result_field_bytes = 16 * 1024;
const legacy_receive_messages = 32;
const pending_detach_limit = 32;
// Raw scan work and JSON materialization are independent. All complete frames
// count against the raw budget, even skipped events and screenshot bytes.
pub const max_raw_bytes = 256 * 1024;
pub const max_decode_bytes = 64 * 1024;
pub const max_decode_tokens = 6_000;
const cleanup_bytes = 8 * 1024;
const cleanup_decode_tokens = 512;
const cleanup_messages = 4;
const max_cdp_identifier_bytes = cdp.max_session_bytes;

pub const TransportError = error{ Unsupported, Denied, InvalidRequest, Cancelled, Stale, Closed, Timeout, Oversized, OutcomeUnknown, TransportFailure } || Allocator.Error;
pub const Error = TransportError || endpoint.Error || error{
    NotConnected,
    SettledTimeout,
    BadHttpStatus,
    InvalidDiscovery,
    WebMcpUnsupported,
    WebMcpRegistryLimit,
    InvalidCdpMessage,
    UnexpectedCdpResponse,
    CdpRejected,
    MessageBudgetExceeded,
    RawByteBudgetExceeded,
    DecodeByteBudgetExceeded,
    DecodeTokenBudgetExceeded,
    CommandIdsExhausted,
    InvalidPageRef,
    StalePage,
    AttachmentCleanupFailed,
    InvalidElementRef,
    InvalidNavigationUrl,
    InvalidInputText,
    InvalidScroll,
    InvalidFind,
    InvalidOptionValue,
    InvalidWait,
    InvalidKeyboardInput,
    InvalidScreenshot,
    InvalidScreenshotOptions,
    ScreenshotGeometryUnavailable,
    ScreenshotClipOutOfBounds,
    ScreenshotWireLimit,
    ScreenshotTooLarge,
    StaleElementRef,
    NotActionable,
    ProjectionUnavailable,
    NavigationRejected,
    TabCreationRejected,
    TabActivationRejected,
    TabCloseRejected,
    TabCloseBlocked,
    HistoryNavigationRejected,
    JsExecutionTimedOut,
    JsOutputLimit,
};

pub const HttpResponse = struct { status: u16, body: []const u8 };
pub const Pull = union(enum) { message: []const u8, empty, closed };
pub const Clock = struct { transport_ms: u32, guest_ms: u32 };
pub const ScopedTransport = struct {
    pull: *const fn (*anyopaque, Allocator, []const u8, usize, u32) TransportError!Pull,
    budget: *const fn (*anyopaque, []const u8) TransportError!Clock,
    settle: *const fn (*anyopaque, []const u8) TransportError!void,
};
const cleanup_reserve_ms: u32 = 2000;
const cleanup_egress_reserve_ms: u32 = 400;
const soft_pull_max_ms: u32 = 1000;
// An inbox can hold 32 frames. Allow the Bridge to refill while we drain,
// but bound per-boundary work and keep it separate from command budgets.
const handoff_max_messages = 64;
const handoff_max_bytes = 2 * max_raw_bytes;

/// This is a test seam, not an ABI. The caller must enforce the invocation
/// deadline, exact admitted endpoint, scope, and close/cancellation cleanup.
/// Returned slices live at least as long as their supplied allocator.
pub const Transport = struct {
    context: *anyopaque,
    httpGet: *const fn (*anyopaque, Allocator, []const u8, usize) TransportError!HttpResponse,
    open: *const fn (*anyopaque, Allocator, []const u8) TransportError![]const u8,
    status: *const fn (*anyopaque, []const u8) TransportError!void,
    send: *const fn (*anyopaque, []const u8, []const u8) TransportError!void,
    receive: *const fn (*anyopaque, Allocator, []const u8, usize) TransportError![]const u8,
    close: *const fn (*anyopaque, []const u8) TransportError!void,
    observe: ?*const fn (*anyopaque, Diagnostic) void = null,
    checkpoint: ?*const fn (*anyopaque, Checkpoint) void = null,
    scoped: ?ScopedTransport = null,
};

pub const JpegDimensions = struct { width: u16, height: u16 };
pub const ScreenshotCapture = struct {
    base64: []const u8,
    bytes: usize,
    width: u16,
    height: u16,
};

pub const Status = enum { connected, disconnected, stale, closed };
pub const PageRef = [32]u8;
pub const HistoryAction = enum { reload, back, forward };
pub const NewTabReceipt = struct { outcome: enum { tab_created }, page_ref: PageRef };
pub const CloseTabReceipt = struct { outcome: enum { tab_close_requested }, page_ref: PageRef };
pub const SelectTabReceipt = struct { outcome: enum { tab_activation_requested }, page_ref: PageRef };
const HistoryOutcome = enum { history_navigation_requested, history_boundary };
pub const HistoryReceipt = struct { outcome: HistoryOutcome, page_ref: PageRef, action: HistoryAction };
pub const Page = struct { ref: PageRef, title: []const u8, url: []const u8 };
pub const Pages = struct { pages: []const Page, omitted_pages: usize, fields_truncated: bool };
pub const Node = struct {
    parent_index: ?usize,
    ignored: bool,
    role: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8,
};
pub const Snapshot = struct { nodes: []const Node, omitted_nodes: usize, fields_truncated: bool };

const network = @import("network_capture.zig");
const network_details = @import("network_details.zig");

pub const Browser = struct {
    capture: ?network.Capture = null,
    capture_generation: u64 = 0,
    record_floor: u64 = 0,
    connection: [max_connection_bytes]u8 = undefined,
    connection_len: usize = 0,
    state: Status = .disconnected,
    next_command: u32 = 1,
    tool_active: bool = false,
    soft_timed_out: bool = false,
    exchange_count: u8 = 0,
    last_failure_buf: [2048]u8 = undefined,
    last_failure_len: usize = 0,

    pub fn lastFailure(self: *const Browser) []const u8 {
        return self.last_failure_buf[0..self.last_failure_len];
    }

    pub fn clearFailure(self: *Browser) void {
        self.last_failure_len = 0;
    }

    fn setFailure(self: *Browser, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(&self.last_failure_buf, fmt, args)) |written| {
            self.last_failure_len = written.len;
        } else |_| {
            const suffix = "...";
            const keep = self.last_failure_buf.len - suffix.len;
            @memcpy(self.last_failure_buf[keep..], suffix);
            self.last_failure_len = self.last_failure_buf.len;
        }
    }

    pub fn noteFailureIfEmpty(self: *Browser, comptime fmt: []const u8, args: anytype) void {
        if (self.last_failure_len == 0) self.setFailure(fmt, args);
    }

    // The Runtime serializes calls to one Store. This linear-memory guard also
    // fences reentry across Host calls and covers replacement of the owned socket.
    pub fn acquireTool(self: *Browser) bool {
        if (self.tool_active) return false;
        self.tool_active = true;
        self.soft_timed_out = false;
        self.exchange_count = 0;
        self.clearFailure();
        return true;
    }

    pub fn releaseTool(self: *Browser) void {
        std.debug.assert(self.tool_active);
        self.tool_active = false;
    }

    pub fn timedOut(self: *const Browser) bool {
        return self.soft_timed_out;
    }

    pub fn reusable(self: *const Browser) bool {
        return self.state == .connected and self.connection_len != 0;
    }

    /// This is a snapshot of currently available input, not a server barrier.
    /// No command may be pending and temporary attachments must be settled.
    /// Reuse after a typed failure additionally requires Runtime confirmation.
    pub fn drain(self: *Browser, transport: Transport, output: Allocator, settle: bool) Error!void {
        const scoped_io = transport.scoped orelse return;
        if (self.state != .connected or self.connection_len == 0) return;
        errdefer |err| self.invalidate(transport, if (err == error.Stale) .stale else .closed);
        var budget = MessageBudget{ .message_limit = handoff_max_messages, .bound = .handoff, .raw_limit = handoff_max_bytes };
        const method: diagnostics.Method = .browser;
        while (true) {
            const clock = try scoped_io.budget(transport.context, self.handle());
            if (clock.guest_ms == 0 or clock.transport_ms <= cleanup_egress_reserve_ms) {
                self.setFailure("scoped drain budget exhausted (guest_ms={d}, transport_ms={d}, reserve_ms={d})", .{ clock.guest_ms, clock.transport_ms, cleanup_egress_reserve_ms });
                return error.Timeout;
            }
            var arena = std.heap.ArenaAllocator.init(output);
            defer arena.deinit();
            const scratch = arena.allocator();
            const packet = switch (try scoped_io.pull(transport.context, scratch, self.handle(), max_text_bytes, 0)) {
                .empty => break,
                .closed => {
                    self.setFailure("scoped transport stream closed during drain", .{});
                    return error.Closed;
                },
                .message => |bytes| try scanPacket(transport, scratch, &budget, method, null, bytes),
            };
            switch (packet.envelope.kind) {
                .event => {
                    self.observeNetwork(transport, scratch, &budget, method, &packet);
                    try dispatchEvent(transport, scratch, &budget, method, &packet, null);
                },
                .reply => |reply| {
                    // An older duplicate cannot be a new command's reply.
                    if (reply.id >= self.next_command) {
                        self.setFailure("unexpected CDP reply id={d} during drain (next_command={d})", .{ reply.id, self.next_command });
                        return error.UnexpectedCdpResponse;
                    }
                },
            }
        }
        if (settle) try scoped_io.settle(transport.context, self.handle());
    }

    /// Drain a bounded slice without requiring an idle queue. The Runtime
    /// owns continuation cleanup; this step never sends or waits on the peer.
    pub fn driveReceive(self: *Browser, transport: Transport, alloc: Allocator) Error!bool {
        const scoped_io = transport.scoped orelse return error.Unsupported;
        errdefer self.clear(.closed);
        var budget = MessageBudget{};
        var raw: usize = 0;
        for (0..16) |_| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const scratch = arena.allocator();
            const bytes = switch (try scoped_io.pull(transport.context, scratch, self.handle(), max_text_bytes, 0)) {
                .empty => return false,
                .closed => return error.Closed,
                .message => |bytes| bytes,
            };
            const packet = try scanPacket(transport, scratch, &budget, .browser, null, bytes);
            switch (packet.envelope.kind) {
                .event => {
                    self.observeNetwork(transport, scratch, &budget, .browser, &packet);
                    try dispatchEvent(transport, scratch, &budget, .browser, &packet, null);
                },
                .reply => |received| if (received.id >= self.next_command) return error.UnexpectedCdpResponse,
            }
            raw += bytes.len;
            if (raw >= max_text_bytes) return true;
        }
        return true;
    }

    fn clearCapture(self: *Browser) void {
        if (self.capture) |*capture| {
            self.record_floor = capture.records.last_record;
            capture.deinit();
        }
        self.capture = null;
    }

    pub fn publishNetwork(self: *Browser, limit: usize, sink: anytype) !void {
        if (self.capture) |*capture| {
            _ = try capture.summaries.drain(limit, sink);
        }
    }

    pub fn configureNetwork(self: *Browser, transport: Transport, a: Allocator, persistent: Allocator, page: []const u8, enable: bool, prefix: ?[]const u8, body_prefix: ?[]const u8) Error![]const u8 {
        if (!validRef(page)) return error.InvalidPageRef;
        if (enable) {
            const match = prefix orelse return error.InvalidRequest;
            if (!validNetworkPrefix(match)) return error.InvalidRequest;
            if (body_prefix) |body_match| {
                if (!validNetworkPrefix(body_match) or !std.mem.startsWith(u8, body_match, match)) return error.InvalidRequest;
            }
        } else if (prefix != null or body_prefix != null) return error.InvalidRequest;
        if (self.capture) |*current| {
            if (!std.mem.eql(u8, page, &current.page)) return error.InvalidRequest;
            var cleanup = MessageBudget{ .attachment = .{ .session = current.session(), .target = current.target() } };
            // Copy before the operation; a lifecycle event may clear capture.
            const session = try a.dupe(u8, current.session());
            cleanup.attachment = .{ .session = session, .target = try a.dupe(u8, current.target()) };
            try self.detach(transport, a, &cleanup, session);
            self.clearCapture();
        }
        if (!enable) return "disabled";
        const match = prefix orelse return error.InvalidRequest;
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, a, &budget, page);
        if (target.special or !allowedHistoryUrl(target.url)) return error.InvalidPageRef;
        const session = try self.attach(transport, a, &budget, target.id);
        errdefer self.detach(transport, a, &budget, session) catch {};
        self.capture_generation = std.math.add(u64, self.capture_generation, 1) catch return error.InvalidRequest;
        self.capture = network.Capture.init(persistent, page[0..32].*, session, target.id, match, body_prefix, self.capture_generation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidRequest,
        };
        self.capture.?.records.last_record = self.record_floor;
        errdefer self.clearCapture();
        _ = try self.command(transport, a, &budget, .network_enable, session);
        return "enabled";
    }

    pub fn networkDetail(self: *Browser, transport: Transport, a: Allocator, page: []const u8, record: u64, body: bool) Error!?network_details.Detail {
        if (!validRef(page)) return error.InvalidPageRef;
        const page_ref = page[0..32].*;
        const capture = if (self.capture) |*value| value else return null;
        const detail = capture.records.get(page_ref, record, network.Capture.cache_epoch) catch return null;
        if (!body or detail.body != .fetchable) return detail;
        const fetch = capture.records.beginBodyFetch(page_ref, record, network.Capture.cache_epoch) catch return null;
        const key = fetch.correlation();
        var budget = MessageBudget{};
        const reply = self.command(transport, a, &budget, .{ .network_body = key.request_id }, key.session_id) catch |err| switch (err) {
            error.CdpRejected => null,
            else => return err,
        };
        const live = if (self.capture) |*value| value else return null;
        const result: network_details.BodyResult = if (reply) |value| blk: {
            const encoded = value.object.get("base64Encoded") orelse break :blk .unavailable;
            if (encoded != .bool) break :blk .unavailable;
            if (encoded.bool) break :blk .binary;
            break :blk .{ .text = stringField(value, "body") orelse break :blk .unavailable };
        } else .unavailable;
        live.records.finishBodyFetch(fetch.ticket, result, network.Capture.cache_epoch) catch return null;
        return live.records.get(page_ref, record, network.Capture.cache_epoch) catch null;
    }

    pub fn connect(self: *Browser, transport: Transport, alloc: Allocator, requested: []const u8) Error!void {
        return self.connectImpl(transport, alloc, requested, true);
    }

    // The Runtime rejects an open while an exact live scope already exists.
    // A closed Job can leave stale Guest memory; never close an older scope here.
    pub fn connectJob(self: *Browser, transport: Transport, alloc: Allocator, requested: []const u8) Error!void {
        return self.connectImpl(transport, alloc, requested, false);
    }

    fn connectImpl(self: *Browser, transport: Transport, alloc: Allocator, requested: []const u8, replace: bool) Error!void {
        const admitted = try endpoint.parse(requested);
        var url_buf: [max_endpoint_bytes]u8 = undefined;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const scratch = arena.allocator();

        const url = if (admitted.websocket()) requested else blk: {
            const discovery = try admitted.discoveryUrl(&url_buf);
            const response = try transport.httpGet(transport.context, scratch, discovery, max_discovery_bytes);
            if (response.status != 200) {
                self.setFailure("HTTP GET {s} returned status {d} (expected 200)", .{ discovery, response.status });
                return error.BadHttpStatus;
            }
            if (response.body.len > max_discovery_bytes) {
                self.setFailure("HTTP GET {s} response body ({d} B) exceeds max discovery limit ({d} B)", .{ discovery, response.body.len, max_discovery_bytes });
                return error.Oversized;
            }
            var decode = DecodeBudget{};
            const json = parseJson(scratch, response.body, &decode) catch |err| switch (err) {
                error.OutOfMemory, error.DecodeByteBudgetExceeded, error.DecodeTokenBudgetExceeded => return err,
                else => {
                    self.setFailure("GET {s} returned invalid discovery JSON ({s}, body len={d})", .{ discovery, @errorName(err), response.body.len });
                    return error.InvalidDiscovery;
                },
            };
            const candidate = stringField(json, "webSocketDebuggerUrl") orelse {
                self.setFailure("GET {s} discovery JSON omitted string field 'webSocketDebuggerUrl'", .{discovery});
                return error.InvalidDiscovery;
            };
            admitted.checkDiscovered(candidate) catch |err| {
                self.setFailure("discovery URL {s} returned disallowed debugger endpoint '{s}' ({s})", .{ discovery, candidate, @errorName(err) });
                return err;
            };
            break :blk candidate;
        };

        // Keep the old socket until endpoint/discovery validation succeeds. Open
        // only when its predecessor has been retired; never leave two owned.
        if (replace and self.connection_len != 0) try self.retire(transport);
        const connection = try transport.open(transport.context, scratch, url);
        if (!validConnectionId(connection)) {
            transport.close(transport.context, connection) catch {};
            self.setFailure("ws-open for {s} returned invalid connection handle '{s}'", .{ url, connection });
            return error.TransportFailure;
        }
        self.clearCapture();
        @memcpy(self.connection[0..connection.len], connection);
        self.connection_len = connection.len;
        self.state = .connected;
        self.next_command = 1;
        errdefer if (self.state == .connected) self.invalidate(transport, .closed);
        var budget = MessageBudget{};
        const version = try self.command(transport, scratch, &budget, .version, null);
        if (stringField(version, "protocolVersion") == null or stringField(version, "product") == null) {
            self.setFailure("Browser.getVersion from {s} omitted protocolVersion or product", .{url});
            return error.InvalidCdpMessage;
        }
        if (self.soft_timed_out) return error.SettledTimeout;
    }

    pub fn status(self: *Browser, transport: Transport) Error!Status {
        if (self.state != .connected or self.connection_len == 0) return self.state;
        transport.status(transport.context, self.handle()) catch |err| switch (err) {
            error.Stale => self.clear(.stale),
            error.Closed => self.clear(.closed),
            else => return err,
        };
        return self.state;
    }

    /// `output` is invocation-owned (e.g. an arena for serialization); no wire
    /// data is kept in Browser. Returned slices belong to `output`.
    pub fn listPages(self: *Browser, transport: Transport, output: Allocator) Error!Pages {
        var arena = std.heap.ArenaAllocator.init(output);
        defer arena.deinit();
        var budget = MessageBudget{};
        const observed = try self.targets(transport, arena.allocator(), &budget);
        var fields = FieldBudget{};
        var pages = std.ArrayList(Page).init(output);
        errdefer {
            for (pages.items) |page| {
                output.free(page.title);
                output.free(page.url);
            }
            pages.deinit();
        }
        var omitted: usize = 0;
        for (observed) |target| {
            if (pages.items.len == max_pages) {
                omitted += 1;
                continue;
            }
            const title = try fields.copy(output, target.title);
            errdefer output.free(title);
            const url = try fields.copy(output, target.url);
            errdefer output.free(url);
            try pages.append(.{ .ref = self.pageRef(target.id), .title = title, .url = url });
        }
        return .{ .pages = try pages.toOwnedSlice(), .omitted_pages = omitted, .fields_truncated = fields.truncated };
    }

    pub fn observe(self: *Browser, transport: Transport, output: Allocator, page: []const u8, region: ?[]const u8) Error!Value {
        if (region) |ref| if (!validRef(ref)) return error.InvalidElementRef;
        return self.pageOperation(transport, output, page, .{ .project = .{ .op = "scan", .ref = region } });
    }

    pub fn click(self: *Browser, transport: Transport, output: Allocator, page: []const u8, element: []const u8) Error!Value {
        if (!validRef(element)) return error.InvalidElementRef;
        return self.pageOperation(transport, output, page, .{ .project = .{ .op = "click", .ref = element } });
    }

    pub fn typeText(self: *Browser, transport: Transport, output: Allocator, page: []const u8, element: []const u8, text: []const u8) Error!Value {
        if (!validRef(element)) return error.InvalidElementRef;
        if (text.len > max_input_text_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidInputText;
        return self.pageOperation(transport, output, page, .{ .project = .{ .op = "type", .ref = element, .input = text } });
    }

    pub fn navigate(self: *Browser, transport: Transport, output: Allocator, page: []const u8, url: []const u8) Error!Value {
        if (!validNavigationUrl(url)) return error.InvalidNavigationUrl;
        return self.pageOperation(transport, output, page, .{ .navigate = url });
    }

    pub fn newTab(self: *Browser, transport: Transport, scratch: Allocator, url: ?[]const u8) Error!NewTabReceipt {
        if (url) |explicit| if (!validNavigationUrl(explicit)) {
            self.setFailure("new_tab URL '{s}' must be an explicit http:// or https:// URL without credentials or backslash", .{explicit});
            return error.InvalidNavigationUrl;
        };
        var budget = MessageBudget{};
        const created = self.command(transport, scratch, &budget, .{ .create_tab = url orelse "about:blank" }, null) catch |err| switch (err) {
            error.CdpRejected => return error.TabCreationRejected,
            else => return err,
        };
        const id = checkedId(created, "targetId") orelse {
            self.setFailure("Target.createTarget reply omitted targetId", .{});
            self.invalidate(transport, .closed);
            return error.OutcomeUnknown;
        };
        return .{ .outcome = .tab_created, .page_ref = self.pageRef(id) };
    }

    pub fn selectTab(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8) Error!SelectTabReceipt {
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, ref);
        const page = self.pageRef(target.id);
        self.acknowledgeEffect(transport, scratch, &budget, .{ .activate_tab = target.id }, null) catch |err| switch (err) {
            error.CdpRejected => return error.TabActivationRejected,
            else => return err,
        };
        return .{ .outcome = .tab_activation_requested, .page_ref = page };
    }

    pub fn closeTab(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8) Error!CloseTabReceipt {
        var budget = MessageBudget{};
        var ordinary_pages: usize = 0;
        const target = try self.selectTargetCount(transport, scratch, &budget, ref, &ordinary_pages);
        const page = self.pageRef(target.id);
        // No atomic close-if-not-last command exists. Refuse when the current
        // target listing has no other ordinary page, and never close a browser,
        // window, browser context, or a privileged/prerendered target directly.
        if (!target.ordinary()) {
            self.setFailure("close_tab refused for page_ref {s} (targetId={s}, url='{s}', special={}): privileged, non-HTTP(S), or special targets cannot be closed", .{ page, target.id, target.url, target.special });
            return error.TabCloseBlocked;
        }
        if (ordinary_pages < 2) {
            self.setFailure("close_tab refused for page_ref {s} (targetId={s}, url='{s}'): only {d} ordinary page remains; refusing to close the last ordinary tab", .{ page, target.id, target.url, ordinary_pages });
            return error.TabCloseBlocked;
        }
        const reply = self.command(transport, scratch, &budget, .{ .close_tab = target.id }, null) catch |err| switch (err) {
            error.CdpRejected => return error.TabCloseRejected,
            else => return err,
        };
        const success = reply.object.get("success") orelse Value.null;
        if (success != .bool or !success.bool) {
            self.setFailure("Target.closeTarget for page_ref {s} (targetId={s}) did not return success=true", .{ page, target.id });
            self.invalidate(transport, .closed);
            return error.OutcomeUnknown;
        }
        return .{ .outcome = .tab_close_requested, .page_ref = page };
    }

    pub fn scroll(self: *Browser, transport: Transport, output: Allocator, page: []const u8, y: i32, x: i32) Error!Value {
        if (@abs(y) > max_scroll_delta or @abs(x) > max_scroll_delta) return error.InvalidScroll;
        return self.scoped(transport, output, page, null, .{ .scroll = .{ .x = x, .y = y } });
    }

    pub fn find(self: *Browser, transport: Transport, output: Allocator, page: []const u8, text: ?[]const u8, role: ?[]const u8, cursor: ?[]const u8) Error!Value {
        if (text == null and role == null) return error.InvalidFind;
        if (text) |value| {
            if (value.len == 0 or value.len > max_find_text_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidFind;
        }
        if (role) |value| {
            if (value.len == 0 or value.len > 40 or !std.ascii.isLower(value[0])) return error.InvalidFind;
            for (value[1..]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return error.InvalidFind;
        }
        return self.scoped(transport, output, page, cursor, .{ .find = .{ .text = text, .role = role } });
    }

    pub fn setChecked(self: *Browser, transport: Transport, output: Allocator, page: []const u8, element: []const u8, checked: bool) Error!Value {
        return self.scoped(transport, output, page, element, .{ .set_checked = checked });
    }

    pub fn selectOption(self: *Browser, transport: Transport, output: Allocator, page: []const u8, element: []const u8, value: []const u8) Error!Value {
        if (value.len > max_option_value_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidOptionValue;
        return self.scoped(transport, output, page, element, .{ .select_option = value });
    }

    pub fn waitFor(self: *Browser, transport: Transport, output: Allocator, page: []const u8, condition: WaitCondition, element: ?[]const u8, timeout_ms: u16) Error!Value {
        if (timeout_ms == 0 or timeout_ms > max_wait_ms or (element == null) != (condition == .document_ready)) return error.InvalidWait;
        return self.scoped(transport, output, page, element, .{ .wait_for = .{ .condition = condition, .timeout_ms = timeout_ms } });
    }

    fn scoped(self: *Browser, transport: Transport, output: Allocator, page: []const u8, ref: ?[]const u8, input: ScopedInput) Error!Value {
        if (ref) |id| if (!validRef(id)) return error.InvalidElementRef;
        return self.pageOperation(transport, output, page, .{ .project = .{ .op = @tagName(input), .ref = ref, .scoped_input = input } });
    }

    pub fn historyNavigation(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8, action: HistoryAction) Error!HistoryReceipt {
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, ref);
        const page = self.pageRef(target.id);
        const session = try self.attach(transport, scratch, &budget, target.id);
        const result = self.historyAttached(transport, scratch, &budget, session, target.id, action);
        self.detach(transport, scratch, &budget, session) catch |cleanup_error| {
            // Never publish a success without a detach ACK. A mutation may
            // already have been accepted; don't invite a second submission.
            if (result) |outcome| {
                if (outcome == .history_navigation_requested) return error.OutcomeUnknown;
            } else |err| {
                if (err == error.OutcomeUnknown) return err;
            }
            return cleanup_error;
        };
        return .{ .outcome = try result, .page_ref = page, .action = action };
    }

    fn historyAttached(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, target: []const u8, history_action: HistoryAction) Error!HistoryOutcome {
        const action: Action = switch (history_action) {
            .reload => blk: {
                const tree = self.command(transport, scratch, budget, .frame_tree, session) catch |err| switch (err) {
                    error.CdpRejected => return error.HistoryNavigationRejected,
                    else => return err,
                };
                const root = objectField(tree, "frameTree") orelse return error.InvalidCdpMessage;
                const frame = objectField(root, "frame") orelse return error.InvalidCdpMessage;
                const frame_id = checkedId(frame, "id") orelse return error.InvalidCdpMessage;
                if (!std.mem.eql(u8, frame_id, target)) return error.InvalidCdpMessage;
                const url = stringField(frame, "url") orelse return error.InvalidCdpMessage;
                if (!allowedHistoryUrl(url)) {
                    self.setFailure("reload rejected: current frame {s} has disallowed URL '{s}'", .{ frame_id, url });
                    return error.HistoryNavigationRejected;
                }
                // Chrome discards reload if the selected document has since changed.
                break :blk .{ .reload = checkedId(frame, "loaderId") orelse return error.InvalidCdpMessage };
            },
            .back, .forward => blk: {
                const history = self.command(transport, scratch, budget, .navigation_history, session) catch |err| switch (err) {
                    error.CdpRejected => return error.HistoryNavigationRejected,
                    else => return err,
                };
                const entries = arrayField(history, "entries") orelse return error.InvalidCdpMessage;
                const current = jsonInteger(history.object.get("currentIndex") orelse return error.InvalidCdpMessage) orelse return error.InvalidCdpMessage;
                if (entries.len == 0 and current == -1) return .history_boundary;
                if (current < 0 or current >= entries.len) return error.InvalidCdpMessage;
                const adjacent = if (history_action == .back) current - 1 else current + 1;
                if (adjacent < 0 or adjacent >= entries.len) return .history_boundary;
                const entry = entries[@intCast(adjacent)];
                const url = stringField(entry, "url") orelse return error.InvalidCdpMessage;
                if (!allowedHistoryUrl(url)) {
                    self.setFailure("history_navigation {s} rejected: target entry URL '{s}' is not http://, https://, or about:blank", .{ @tagName(history_action), url });
                    return error.HistoryNavigationRejected;
                }
                const id = try historyEntryId(entry);
                for (entries, 0..) |other, index| {
                    if (index != adjacent and try historyEntryId(other) == id) return error.InvalidCdpMessage;
                }
                // Use the exact ID, not a second index lookup or an explicit URL.
                break :blk .{ .history_entry = id };
            },
        };
        self.acknowledgeEffect(transport, scratch, budget, action, session) catch |err| switch (err) {
            error.CdpRejected => return error.HistoryNavigationRejected,
            else => return err,
        };
        return .history_navigation_requested;
    }

    fn acknowledgeEffect(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, action: Action, session: ?[]const u8) Error!void {
        const reply = try self.command(transport, scratch, budget, action, session);
        if (reply.object.count() != 0) {
            self.setFailure("CDP {s} returned unexpected non-empty reply ({d} fields)", .{ @tagName(action), reply.object.count() });
            self.invalidate(transport, .closed);
            return error.OutcomeUnknown;
        }
    }

    pub fn pressKey(self: *Browser, transport: Transport, output: Allocator, page: []const u8, element: []const u8, key: []const u8, modifiers: []const Modifier) Error!Value {
        if (!validRef(element)) return error.InvalidElementRef;
        if (!validKey(key) or modifiers.len > 4) return error.InvalidKeyboardInput;
        var input = KeyInput{ .key = key };
        for (modifiers) |modifier| {
            const flag = switch (modifier) {
                .Control => &input.ctrlKey,
                .Alt => &input.altKey,
                .Shift => &input.shiftKey,
                .Meta => &input.metaKey,
            };
            if (flag.*) return error.InvalidKeyboardInput;
            flag.* = true;
        }
        return self.pageOperation(transport, output, page, .{ .project = .{ .op = "key", .ref = element, .keyboard = input } });
    }

    fn captureScreenshotReply(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8, options: ScreenshotOptions) Error!Value {
        try options.validate();
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, ref);
        const session = try self.attach(transport, scratch, &budget, target.id);
        const capture = self.captureAttached(transport, scratch, &budget, session, options);
        try self.detach(transport, scratch, &budget, session);
        return capture;
    }

    pub fn screenshot(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8, options: ScreenshotOptions) Error![]const u8 {
        return decodeScreenshot(scratch, try self.captureScreenshotReply(transport, scratch, ref, options));
    }

    /// Validates Base64 JPEG framing (SOI, SOF dimensions, EOI) while keeping
    /// the borrowed Base64 payload intact so callers do not decode and re-encode
    /// full images inside WASM fuel limits.
    pub fn screenshotCapture(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8, options: ScreenshotOptions) Error!ScreenshotCapture {
        return validateScreenshotCapture(scratch, try self.captureScreenshotReply(transport, scratch, ref, options));
    }

    fn captureAttached(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, options: ScreenshotOptions) Error!Value {
        const clip = if (options.clip != null or options.scale != null) blk: {
            const metrics = self.command(transport, scratch, budget, .layout_metrics, session) catch |err| switch (err) {
                error.CdpRejected => return error.ScreenshotGeometryUnavailable,
                else => return err,
            };
            break :blk try screenshotClip(metrics, options);
        } else null;
        return self.command(transport, scratch, budget, .{ .screenshot = .{ .quality = options.quality, .clip = clip } }, session) catch |err| switch (err) {
            error.Oversized => return error.ScreenshotWireLimit,
            else => return err,
        };
    }

    const PageOperation = union(enum) { project: ProjectQuery, navigate: []const u8 };

    fn selectTarget(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, ref: []const u8) Error!Target {
        return self.selectTargetCount(transport, scratch, budget, ref, null);
    }

    fn selectTargetCount(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, ref: []const u8, ordinary_count: ?*usize) Error!Target {
        if (!validRef(ref)) return error.InvalidPageRef;
        const pages = try self.targets(transport, scratch, budget);
        var selected: ?Target = null;
        for (pages) |target| {
            if (ordinary_count) |count| {
                if (target.ordinary()) count.* += 1;
            }
            const candidate = self.pageRef(target.id);
            if (std.mem.eql(u8, ref, &candidate)) {
                if (selected != null) return error.InvalidCdpMessage;
                selected = target;
            }
        }
        return selected orelse {
            self.setFailure("page_ref '{s}' was not found among {d} current page targets", .{ ref, pages.len });
            return error.StalePage;
        };
    }

    fn attach(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, target: []const u8) Error![]const u8 {
        const attached = self.command(transport, scratch, budget, .{ .attach = target }, null) catch |err| switch (err) {
            error.CdpRejected => {
                const detail = std.fmt.allocPrint(scratch, "Target.attachToTarget failed for targetId={s}: {s}", .{ target, self.lastFailure() }) catch null;
                if (detail) |msg| self.setFailure("{s}", .{msg});
                return error.StalePage;
            },
            else => return err,
        };
        const session = checkedId(attached, "sessionId") orelse {
            self.invalidate(transport, .closed);
            return error.InvalidCdpMessage;
        };
        budget.attachment = .{ .session = session, .target = target };
        return session;
    }

    pub fn executeJs(self: *Browser, transport: Transport, scratch: Allocator, args: ExecuteJs) Error!JsReceipt {
        if (!args.valid()) return error.InvalidRequest;
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, args.page_ref);
        if (!target.ordinary()) return .{ .outcome = .page_not_allowed };
        const session = try self.attach(transport, scratch, &budget, target.id);
        var evaluation_attempted = false;
        const result = self.evaluateAttached(transport, scratch, &budget, session, target.id, args, &evaluation_attempted);
        self.detach(transport, scratch, &budget, session) catch |err| {
            return if (evaluation_attempted) error.OutcomeUnknown else err;
        };
        return result;
    }

    fn evaluateAttached(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, frame: []const u8, args: ExecuteJs, attempted: *bool) Error!JsReceipt {
        const loader = (self.jsRootLoader(transport, scratch, budget, session, frame) catch |err| switch (err) {
            error.CdpRejected => return .{ .outcome = .context_unavailable },
            else => return err,
        }) orelse return .{ .outcome = .page_not_allowed };
        var witness: ContextWitness = .{ .frame = frame, .world = .main };
        if (args.world == .isolated) {
            // Do not share a script world with the typed observation tools.
            const name = try std.fmt.allocPrint(scratch, "microcrab-execute-{s}", .{self.handle()});
            const result = self.command(transport, scratch, budget, .{ .world = .{ .name = name, .frame = frame } }, session) catch |err| switch (err) {
                error.CdpRejected => return .{ .outcome = .context_unavailable },
                else => return err,
            };
            const id = jsonInteger(result.object.get("executionContextId") orelse .null) orelse return error.InvalidCdpMessage;
            if (id <= 0) return error.InvalidCdpMessage;
            witness.world = .{ .isolated = .{ .id = id, .name = name } };
        }
        budget.witness = &witness;
        const unique = blk: {
            defer budget.witness = null;
            _ = try self.command(transport, scratch, budget, .enable_runtime, session);
            const initial = witness.unique;
            _ = try self.command(transport, scratch, budget, .disable_runtime, session);
            const current_loader = (try self.jsRootLoader(transport, scratch, budget, session, frame)) orelse return .{ .outcome = .context_unavailable };
            if (!std.mem.eql(u8, loader, current_loader)) return .{ .outcome = .context_unavailable };
            const unique = initial orelse return .{ .outcome = .context_unavailable };
            if (!std.mem.eql(u8, unique, witness.unique orelse return .{ .outcome = .context_unavailable })) return .{ .outcome = .context_unavailable };
            break :blk unique;
        };
        // The globally unique context identity (never its renderer-local numeric
        // ID or an implicit context) prevents redirection after navigation.
        attempted.* = true;
        const reply = self.command(transport, scratch, budget, .{ .evaluate = .{
            .context = unique,
            .expression = args.expression,
            .timeout_ms = args.timeout_ms,
        } }, session) catch |err| switch (err) {
            error.JsExecutionTimedOut => return .{ .outcome = .execution_timed_out },
            error.JsOutputLimit => return .{ .outcome = .output_limit, .max_bytes = max_js_output_bytes },
            error.CdpRejected => return .{ .outcome = .result_unavailable },
            else => return err,
        };
        // Exceptions can echo the expression or page secrets; return only a
        // validated exception class name and 0-based line/column, never text or handles.
        if (reply.object.get("exceptionDetails")) |details| return safeScriptException(scratch, details);
        const remote = objectField(reply, "result") orelse {
            self.setFailure("Runtime.evaluate reply missing object 'result' field", .{});
            return error.OutcomeUnknown;
        };
        const result_type = stringField(remote, "type") orelse {
            self.setFailure("Runtime.evaluate result missing string 'type' field", .{});
            return error.OutcomeUnknown;
        };
        if (std.mem.eql(u8, result_type, "undefined")) return .{ .outcome = .undefined };
        const value = remote.object.get("value") orelse return .{ .outcome = .result_unavailable };
        const output = try scratch.alloc(u8, max_js_output_bytes);
        var stream = std.io.fixedBufferStream(output);
        std.json.stringify(value, .{}, stream.writer()) catch return .{ .outcome = .output_limit, .max_bytes = max_js_output_bytes };
        return .{ .outcome = .evaluated, .result = value };
    }

    fn safeScriptException(scratch: Allocator, details: Value) JsReceipt {
        var receipt = JsReceipt{ .outcome = .script_exception };
        if (details != .object) return receipt;
        if (jsonInteger(details.object.get("lineNumber") orelse .null)) |line| {
            if (line >= 0 and line <= std.math.maxInt(u32)) receipt.line = @intCast(line);
        }
        if (jsonInteger(details.object.get("columnNumber") orelse .null)) |col| {
            if (col >= 0 and col <= std.math.maxInt(u32)) receipt.column = @intCast(col);
        }
        if (details.object.get("exception")) |exc| {
            if (exc == .object) {
                if (stringField(exc, "className")) |name| {
                    if (name.len > 0 and name.len <= 32) {
                        var valid_name = true;
                        for (name) |c| {
                            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                                valid_name = false;
                                break;
                            }
                        }
                        if (valid_name) {
                            receipt.exception_name = scratch.dupe(u8, name) catch null;
                        }
                    }
                }
            }
        }
        return receipt;
    }

    fn jsRootLoader(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, expected: []const u8) Error!?[]const u8 {
        const tree = try self.command(transport, scratch, budget, .frame_tree, session);
        const frame = objectField(objectField(tree, "frameTree") orelse return error.InvalidCdpMessage, "frame") orelse return error.InvalidCdpMessage;
        const id = checkedId(frame, "id") orelse return error.InvalidCdpMessage;
        if (frame.object.contains("parentId") or !std.mem.eql(u8, id, expected)) return error.InvalidCdpMessage;
        if (!allowedHistoryUrl(stringField(frame, "url") orelse return error.InvalidCdpMessage)) return null;
        return checkedId(frame, "loaderId") orelse error.InvalidCdpMessage;
    }

    pub fn webMcp(self: *Browser, transport: Transport, scratch: Allocator, page_ref: []const u8, op: webmcp.Operation) Error!webmcp.Receipt {
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, page_ref);
        const tool_ref = if (op == .invoke) op.invoke.tool_ref else null;
        if (target.special or !allowedHistoryUrl(target.url)) return .{ .outcome = .page_not_allowed, .page_ref = page_ref, .tool_ref = tool_ref };
        const session = try self.attach(transport, scratch, &budget, target.id);
        var attached: WebMcpAttached = .{ .browser = self, .transport = transport, .scratch = scratch, .budget = &budget, .session = session };
        const result = webmcp.run(&attached, scratch, page_ref, target.id, op);
        self.detach(transport, scratch, &budget, session) catch |err| {
            // An exact result might have been observed before attachment cleanup
            // failed. Do not advertise success or invite another submission.
            if (attached.invoke_attempted) return error.OutcomeUnknown;
            return err;
        };
        return result;
    }

    fn detach(self: *Browser, transport: Transport, scratch: Allocator, budget: *const MessageBudget, session: []const u8) Error!void {
        if (self.state != .connected) return;
        var cleanup = MessageBudget.cleanup(budget.attachment);
        const reply = self.command(transport, scratch, &cleanup, .{ .detach = session }, null) catch |err| {
            const msg = std.fmt.allocPrint(scratch, "Target.detachFromTarget failed ({s}): {s}", .{ @errorName(err), self.lastFailure() }) catch null;
            if (msg) |m| self.setFailure("{s}", .{m});
            self.invalidate(transport, .closed);
            return error.AttachmentCleanupFailed;
        };
        if (reply.object.count() != 0) {
            self.setFailure("Target.detachFromTarget returned unexpected non-empty reply ({d} fields)", .{reply.object.count()});
            self.invalidate(transport, .closed);
            return error.AttachmentCleanupFailed;
        }
    }

    fn pageOperation(self: *Browser, transport: Transport, scratch: Allocator, ref: []const u8, operation: PageOperation) Error!Value {
        var budget = MessageBudget{};
        const target = try self.selectTarget(transport, scratch, &budget, ref);
        if (operation == .navigate and !allowedHistoryUrl(target.url)) {
            self.setFailure("navigate rejected: selected tab {s} (targetId={s}) currently has non-navigable URL '{s}' (must be http://, https://, or about:blank)", .{ ref, target.id, target.url });
            return error.NavigationRejected;
        }
        const session = try self.attach(transport, scratch, &budget, target.id);
        const result = switch (operation) {
            .project => |query| self.project(transport, scratch, &budget, session, target.id, query),
            .navigate => |url| self.navigateAttached(transport, scratch, &budget, session, url),
        };
        self.detach(transport, scratch, &budget, session) catch |err| {
            if (operation == .navigate or (operation == .project and operation.project.effect())) return error.OutcomeUnknown;
            return err;
        };
        return result;
    }

    fn project(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, frame_id: []const u8, query: ProjectQuery) Error!Value {
        // Chromium page targets are keyed by their main frame token. Other
        // target types are filtered before attach; unsupported engines fail
        // closed rather than asking for an unbounded recursive frame tree.
        const world = try std.fmt.allocPrint(scratch, "microcrab-observe-{s}", .{self.handle()});
        const context = self.command(transport, scratch, budget, .{ .world = .{ .name = world, .frame = frame_id } }, session) catch |err| switch (err) {
            error.CdpRejected => {
                const detail = std.fmt.allocPrint(scratch, "Page.createIsolatedWorld '{s}' failed on frame {s}: {s}", .{ world, frame_id, self.lastFailure() }) catch null;
                if (detail) |msg| self.setFailure("{s}", .{msg});
                return error.ProjectionUnavailable;
            },
            else => return err,
        };
        const context_id = jsonInteger(context.object.get("executionContextId") orelse return error.InvalidCdpMessage) orelse return error.InvalidCdpMessage;
        if (context_id <= 0) return error.InvalidCdpMessage;
        // Numeric IDs are renderer-local. Capture the unique ID from the
        // exact attachment/frame/world before evaluating anything, so a
        // cross-process navigation cannot redirect the call into another world.
        var witness = ContextWitness{ .world = .{ .isolated = .{ .id = context_id, .name = world } }, .frame = frame_id };
        budget.witness = &witness;
        {
            defer budget.witness = null;
            _ = try self.command(transport, scratch, budget, .enable_runtime, session);
            if (witness.unique == null) {
                self.setFailure("Runtime.enable did not report executionContextCreated uniqueId for isolated world '{s}' on frame {s} (executionContextId={d})", .{ world, frame_id, context_id });
                return error.ProjectionUnavailable;
            }
            _ = try self.command(transport, scratch, budget, .disable_runtime, session);
        }
        const unique_id = witness.unique orelse {
            self.setFailure("isolated world '{s}' uniqueId lost after Runtime.disable on frame {s}", .{ world, frame_id });
            return error.ProjectionUnavailable;
        };
        const effect = query.effect();
        const reply = self.command(transport, scratch, budget, .{ .projection = .{ .query = query, .context = unique_id, .key = world } }, session) catch |err| {
            return if (effect) error.OutcomeUnknown else err;
        };
        if (reply.object.get("exceptionDetails")) |details| {
            const detail_text = stringField(details, "text") orelse "script exception";
            const exc_obj = objectField(details, "exception");
            const exc_desc = if (exc_obj) |e| stringField(e, "description") orelse stringField(e, "className") else null;
            const line_num = if (details == .object) jsonInteger(details.object.get("lineNumber") orelse .null) else null;
            self.setFailure("isolated-world {s} threw exception ({s}; line={d}): {s}", .{ query.op, detail_text, line_num orelse -1, exc_desc orelse "no description" });
            return if (effect) error.OutcomeUnknown else error.ProjectionUnavailable;
        }
        const outer = objectField(reply, "result") orelse return if (effect) error.OutcomeUnknown else error.InvalidCdpMessage;
        const data = objectField(outer, "value") orelse return if (effect) error.OutcomeUnknown else error.InvalidCdpMessage;
        if (stringField(data, "error")) |err| {
            const detail = stringField(data, "detail") orelse "";
            if (detail.len > 0) {
                self.setFailure("{s} reported '{s}': {s}", .{ query.op, err, detail });
            } else {
                self.setFailure("{s} reported '{s}'", .{ query.op, err });
            }
            if (std.mem.eql(u8, err, "stale_ref")) return error.StaleElementRef;
            if (std.mem.eql(u8, err, "not_actionable")) return error.NotActionable;
            if (query.scoped_input != null and std.mem.eql(u8, err, "unavailable")) return error.ProjectionUnavailable;
            return if (effect) error.OutcomeUnknown else error.ProjectionUnavailable;
        }
        if (query.scoped_input) |input| {
            return switch (input) {
                .find => safeProjection(scratch, data, 16),
                .wait_for => checkedOutcome(scratch, data, &.{ "condition_met", "timed_out" }, error.InvalidCdpMessage),
                .scroll => checkedOutcome(scratch, data, &.{"scroll_requested"}, error.OutcomeUnknown),
                .set_checked => checkedOutcome(scratch, data, &.{ "checked_set", "already_checked_state", "change_dispatched_unconfirmed" }, error.OutcomeUnknown),
                .select_option => checkedOutcome(scratch, data, &.{ "option_selected", "already_selected", "change_dispatched_unconfirmed" }, error.OutcomeUnknown),
            };
        }
        if (effect) {
            const outcome = stringField(data, "outcome") orelse return error.OutcomeUnknown;
            const expected = if (query.keyboard != null) "keys_dispatched" else if (std.mem.eql(u8, query.op, "click")) "click_dispatched" else "text_replaced";
            if (std.mem.eql(u8, outcome, expected)) return singleton(scratch, "outcome", expected);
            if (query.keyboard != null and std.mem.eql(u8, outcome, "keydown_dispatched_unconfirmed")) return singleton(scratch, "outcome", "keydown_dispatched_unconfirmed");
            if (std.mem.eql(u8, query.op, "type") and std.mem.eql(u8, outcome, "input_dispatched_unconfirmed")) return singleton(scratch, "outcome", "input_dispatched_unconfirmed");
            return error.OutcomeUnknown;
        }
        return safeProjection(scratch, data, 24);
    }

    fn navigateAttached(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, session: []const u8, url: []const u8) Error!Value {
        const reply = self.command(transport, scratch, budget, .{ .navigate = url }, session) catch |err| switch (err) {
            error.CdpRejected => {
                const detail = std.fmt.allocPrint(scratch, "Page.navigate to '{s}' rejected by CDP: {s}", .{ url, self.lastFailure() }) catch null;
                if (detail) |msg| self.setFailure("{s}", .{msg});
                return error.NavigationRejected;
            },
            else => return error.OutcomeUnknown,
        };
        if (reply.object.get("errorText")) |err_val| {
            const err_text = if (err_val == .string) err_val.string else "non-string errorText";
            self.setFailure("Page.navigate to '{s}' failed with errorText: {s}", .{ url, err_text });
            return error.NavigationRejected;
        }
        if (reply.object.get("isDownload")) |download| {
            if (download != .bool or download.bool) {
                self.setFailure("Page.navigate to '{s}' resulted in a file download or non-boolean isDownload", .{url});
                return error.OutcomeUnknown;
            }
        }
        if (checkedId(reply, "frameId") == null) {
            self.setFailure("Page.navigate to '{s}' reply omitted frameId", .{url});
            return error.OutcomeUnknown;
        }
        return singleton(scratch, "outcome", "navigation_requested");
    }

    // Historical AX seam retained for fixture comparison, never used as a
    // fallback when the source-bounded projection is unavailable.
    pub fn snapshot(self: *Browser, transport: Transport, output: Allocator, ref: []const u8) Error!Snapshot {
        if (ref.len != @typeInfo(PageRef).Array.len) return error.InvalidPageRef;
        for (ref) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidPageRef;
        var arena = std.heap.ArenaAllocator.init(output);
        defer arena.deinit();
        const scratch = arena.allocator();
        var budget = MessageBudget{};
        const pages = try self.targets(transport, scratch, &budget);
        var selected: ?[]const u8 = null;
        for (pages) |target| {
            const candidate = self.pageRef(target.id);
            if (std.mem.eql(u8, ref, &candidate)) {
                if (selected != null) return error.InvalidCdpMessage;
                selected = target.id;
            }
        }
        const target_id = selected orelse return error.StalePage;
        const session = try self.attach(transport, scratch, &budget, target_id);
        const tree = self.command(transport, scratch, &budget, .tree, session);
        // Independent detach allowance; never reuse a connection without cleanup.
        try self.detach(transport, scratch, &budget, session);
        return projectTree(output, scratch, tree catch |err| switch (err) {
            error.CdpRejected => return error.StalePage,
            else => return err,
        });
    }

    pub fn handle(self: *const Browser) []const u8 {
        return self.connection[0..self.connection_len];
    }

    pub fn clear(self: *Browser, state: Status) void {
        self.clearCapture();
        @memset(self.connection[0..self.connection_len], 0);
        self.connection_len = 0;
        self.state = state;
    }

    pub fn retire(self: *Browser, transport: Transport) Error!void {
        transport.close(transport.context, self.handle()) catch |err| switch (err) {
            error.Stale, error.Closed => {},
            else => return err,
        };
        self.clear(.closed);
    }

    fn invalidate(self: *Browser, transport: Transport, state: Status) void {
        self.state = state;
        if (self.connection_len != 0) transport.close(transport.context, self.handle()) catch |err| switch (err) {
            error.Stale, error.Closed => {},
            // Keep an unusable handle only to retry retirement on an explicit
            // connect; do not open a second socket while its outcome is unclear.
            else => return,
        };
        self.clear(state);
    }

    fn pageRef(self: *const Browser, target: []const u8) PageRef {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("microcrab/browser/page-ref/v1\x00");
        hash.update(&std.mem.toBytes(@as(u16, @intCast(self.connection_len))));
        hash.update(self.handle());
        hash.update(target);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.fmt.bytesToHex(digest[0..16].*, .lower);
    }

    fn observeNetwork(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, packet: *const Packet) void {
        const capture = if (self.capture) |*value| value else return;
        const event = packet.envelope.kind.event;
        switch (event.method) {
            .@"Target.detachedFromTarget", .@"Target.targetDestroyed", .@"Target.targetCrashed" => {
                if (packet.envelope.session != null) return;
                const params = eventParams(transport, scratch, budget, method, packet) catch return;
                const selected = if (event.method == .@"Target.detachedFromTarget") capture.session() else capture.target();
                const key = if (event.method == .@"Target.detachedFromTarget") "sessionId" else "targetId";
                if (checkedId(params, key)) |id| if (std.mem.eql(u8, selected, id)) self.clearCapture();
            },
            .@"Inspector.detached", .@"Inspector.targetCrashed" => if (packet.envelope.matches(capture.session())) self.clearCapture(),
            .@"Network.responseReceived", .@"Network.loadingFinished", .@"Network.loadingFailed" => {
                if (!packet.envelope.matches(capture.session())) return;
                // Lossy observation cannot exhaust the command's decode budget.
                var event_budget = MessageBudget{};
                const params = eventParams(transport, scratch, &event_budget, method, packet) catch {
                    capture.summaries.noteDrop() catch {};
                    return;
                };
                const request = checkedId(params, "requestId") orelse return;
                if (event.method == .@"Network.responseReceived") {
                    const response = objectField(params, "response") orelse return;
                    const url = stringField(response, "url") orelse return;
                    if (!allowedHistoryUrl(url)) return;
                    const mime = stringField(response, "mimeType") orelse "";
                    const http_status = if (jsonInteger(response.object.get("status") orelse .null)) |value| std.math.cast(u16, value) else null;
                    capture.response(request, url, mime, http_status) catch {};
                } else {
                    capture.finish(request, event.method == .@"Network.loadingFinished") catch {};
                }
            },
            else => {},
        }
    }

    fn targets(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget) Error![]const Target {
        const result = try self.command(transport, scratch, budget, .targets, null);
        const infos = arrayField(result, "targetInfos") orelse return error.InvalidCdpMessage;
        var list = std.ArrayList(Target).init(scratch);
        var seen = std.StringHashMap(void).init(scratch);
        for (infos) |info| {
            const kind = stringField(info, "type") orelse return error.InvalidCdpMessage;
            if (!std.mem.eql(u8, kind, "page")) continue;
            const id = checkedId(info, "targetId") orelse return error.InvalidCdpMessage;
            if ((try seen.getOrPut(id)).found_existing) return error.InvalidCdpMessage;
            try list.append(.{
                .id = id,
                .title = stringField(info, "title") orelse return error.InvalidCdpMessage,
                .url = stringField(info, "url") orelse return error.InvalidCdpMessage,
                .special = info.object.contains("subtype") or info.object.contains("parentId") or info.object.contains("parentFrameId"),
            });
        }
        return list.toOwnedSlice();
    }

    fn command(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, action: Action, session: ?[]const u8) Error!Value {
        if (self.connection_len == 0 or self.state != .connected) return switch (self.state) {
            .closed => error.Closed,
            .stale => error.Stale,
            else => error.NotConnected,
        };
        const method = action.diagnosticMethod();
        if (transport.scoped) |scoped_io| {
            const clock = try scoped_io.budget(transport.context, self.handle());
            if (clock.guest_ms == 0 or clock.transport_ms <= cleanup_egress_reserve_ms) {
                self.invalidate(transport, .closed);
                return error.Timeout;
            }
            if (!budget.cleaning and (self.soft_timed_out or clock.transport_ms <= cleanup_reserve_ms)) {
                self.soft_timed_out = true;
                return error.SettledTimeout;
            }
        }
        budget.useTransport(transport);
        try budget.checkMessageCount(transport, method);
        const id = self.next_command;
        if (id > cdp.max_command_id) {
            self.invalidate(transport, .closed);
            return error.CommandIdsExhausted;
        }
        const message = try action.encode(scratch, id, session);
        if (message.len > 16 * 1024) return error.Oversized;
        self.next_command += 1;
        // After send is attempted, an ambiguous outcome poisons the connection.
        // Do not retry, silently reconnect, or allow a subsequent tool to reuse it.
        return self.exchange(transport, scratch, budget, id, message, session, action) catch |err| {
            if (err == error.CdpRejected or err == error.WebMcpUnsupported or err == error.JsExecutionTimedOut or err == error.JsOutputLimit) return err;
            self.invalidate(transport, if (err == error.Stale) .stale else .closed);
            if (action.tabEffect()) {
                if (self.lastFailure().len == 0) {
                    self.setFailure("CDP {s} (id={d}) failed before confirmed reply: {s}", .{ @tagName(action), id, @errorName(err) });
                } else if (std.fmt.allocPrint(scratch, "CDP {s} (id={d}) failed ({s}): {s}", .{ @tagName(action), id, @errorName(err), self.lastFailure() })) |msg| {
                    self.setFailure("{s}", .{msg});
                } else |_| {}
                return error.OutcomeUnknown;
            }
            self.noteFailureIfEmpty("CDP {s} (id={d}) failed: {s}", .{ @tagName(action), id, @errorName(err) });
            return err;
        };
    }

    fn exchange(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, id: u32, message: []const u8, session: ?[]const u8, action: Action) Error!Value {
        const method = action.diagnosticMethod();
        const command_name = action.diagnosticCommand();
        self.exchange_count +|= 1;
        const ordinal = self.exchange_count;
        checkpoint(transport, command_name, .send, ordinal, .not_confirmed);
        transport.send(transport.context, self.handle(), message) catch |err| {
            failure(transport, .send, method, .not_confirmed, err);
            return err;
        };
        checkpoint(transport, command_name, .receive, ordinal, .not_confirmed);
        while (true) {
            const packet = try self.readEnvelope(transport, scratch, budget, method, if (action == .screenshot) CaptureExpectation{ .id = id, .session = session } else null);
            switch (packet.envelope.kind) {
                .event => {
                    self.observeNetwork(transport, scratch, budget, method, &packet);
                    try dispatchEvent(transport, scratch, budget, method, &packet, action);
                },
                .reply => |reply| {
                    // Preserve monotonically older reply handling: they cannot
                    // satisfy this exchange and consume only raw scan budget.
                    if (reply.id < id) continue;
                    if (reply.id != id or !packet.envelope.matches(session)) {
                        failure(transport, .classify, method, .not_confirmed, error.UnexpectedCdpResponse);
                        return error.UnexpectedCdpResponse;
                    }
                    checkpoint(transport, command_name, .classify, ordinal, .confirmed);
                    if (action == .evaluate and !reply.rejected and packet.bytes.len > max_js_reply_bytes) return error.JsOutputLimit;
                    const value = if (packet.capture_data) |data| blk: {
                        var value = try materialize(transport, scratch, budget, method, packet.bytes.len - data.len, reply.payload, .confirmed);
                        const field = value.object.getPtr("data") orelse return error.InvalidCdpMessage;
                        field.* = .{ .string = data };
                        break :blk value;
                    } else decodeReply(transport, scratch, budget, method, packet.bytes.len, reply.payload, action == .screenshot and !reply.rejected) catch |err| {
                        if (action == .evaluate and !reply.rejected and (err == error.DecodeByteBudgetExceeded or err == error.DecodeTokenBudgetExceeded)) return error.JsOutputLimit;
                        return err;
                    };
                    if (reply.rejected) {
                        // A contradictory attach event may announce an owned
                        // attachment despite a rejection. Do not reuse it.
                        if (action == .attach and budget.attach_event != null) {
                            failure(transport, .dispatch, method, .confirmed, error.UnexpectedCdpResponse);
                            return error.UnexpectedCdpResponse;
                        }
                        const code = jsonInteger(value.object.get("code") orelse .null) orelse {
                            failure(transport, .decode, method, .confirmed, error.InvalidCdpMessage);
                            return error.InvalidCdpMessage;
                        };
                        const reason = stringField(value, "message") orelse {
                            failure(transport, .decode, method, .confirmed, error.InvalidCdpMessage);
                            return error.InvalidCdpMessage;
                        };
                        self.setFailure("CDP {s} rejected (code={d}): {s}", .{ @tagName(action), code, reason });
                        failure(transport, .dispatch, method, .confirmed, error.CdpRejected);
                        if (action == .evaluate and code == -32000 and std.mem.eql(u8, reason, "Execution was terminated")) return error.JsExecutionTimedOut;
                        if (action == .web_mcp) {
                            if (code == -32601) return error.WebMcpUnsupported;
                            // Transitional Chrome builds exposed toolId in metadata,
                            // but still required the deprecated toolName on invoke.
                            if (code == -32602 and std.mem.startsWith(u8, reason, "Failed to deserialize params.toolName - ")) return error.WebMcpUnsupported;
                        }
                        return error.CdpRejected;
                    }
                    if (action == .attach) {
                        const acquired = checkedId(value, "sessionId") orelse {
                            failure(transport, .dispatch, method, .confirmed, error.InvalidCdpMessage);
                            return error.InvalidCdpMessage;
                        };
                        if (budget.attach_event) |announced| {
                            if (!std.mem.eql(u8, announced, acquired)) {
                                failure(transport, .dispatch, method, .confirmed, error.UnexpectedCdpResponse);
                                return error.UnexpectedCdpResponse;
                            }
                        }
                        for (budget.pending_detach[0..budget.pending_detach_count]) |detached| {
                            if (std.mem.eql(u8, detached, acquired)) {
                                failure(transport, .dispatch, method, .confirmed, error.StalePage);
                                return error.StalePage;
                            }
                        }
                    }
                    return value;
                },
            }
        }
    }

    fn readEnvelope(self: *Browser, transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, capture: ?CaptureExpectation) Error!Packet {
        budget.useTransport(transport);
        try budget.checkMessageCount(transport, method);
        const bytes = self.receiveBytes(transport, scratch, budget) catch |err| {
            if (err == error.Oversized) reportLimit(transport, .receive, method, .raw_bytes, 0, max_text_bytes, .not_confirmed) else failure(transport, .receive, method, .not_confirmed, err);
            return err;
        };
        return scanPacket(transport, scratch, budget, method, capture, bytes);
    }

    fn receiveBytes(self: *Browser, transport: Transport, scratch: Allocator, budget: *const MessageBudget) Error![]const u8 {
        // After the soft work deadline, stop dispatching commands but still
        // read the pending command's exact reply within the cleanup reserve.
        const scoped_io = transport.scoped orelse return transport.receive(transport.context, scratch, self.handle(), max_text_bytes);
        while (true) {
            const clock = try scoped_io.budget(transport.context, self.handle());
            if (clock.guest_ms == 0 or clock.transport_ms <= cleanup_egress_reserve_ms) {
                self.setFailure("scoped receive budget exhausted before reply (guest_ms={d}, transport_ms={d}, reserve_ms={d}, cleaning={any})", .{ clock.guest_ms, clock.transport_ms, cleanup_egress_reserve_ms, budget.cleaning });
                return error.Timeout;
            }
            if (!budget.cleaning and clock.transport_ms <= cleanup_reserve_ms) self.soft_timed_out = true;
            const floor: u32 = if (budget.cleaning or self.soft_timed_out) cleanup_egress_reserve_ms else cleanup_reserve_ms;
            switch (try scoped_io.pull(transport.context, scratch, self.handle(), max_text_bytes, @min(soft_pull_max_ms, clock.transport_ms - floor))) {
                .message => |bytes| {
                    // Native wait starts at Bridge admission, so a reply can
                    // cross the soft deadline in transit without an Empty.
                    if (!budget.cleaning and !self.soft_timed_out) {
                        const received = try scoped_io.budget(transport.context, self.handle());
                        if (received.transport_ms <= cleanup_reserve_ms) self.soft_timed_out = true;
                    }
                    return bytes;
                },
                .empty => continue,
                .closed => {
                    self.setFailure("scoped transport stream closed while waiting for CDP reply", .{});
                    return error.Closed;
                },
            }
        }
    }
};

fn scanPacket(transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, capture: ?CaptureExpectation, bytes: []const u8) Error!Packet {
    try budget.checkMessageCount(transport, method);
    budget.received += 1;
    if (bytes.len > max_text_bytes) {
        reportLimit(transport, .receive, method, .raw_bytes, bytes.len, max_text_bytes, .not_confirmed);
        return error.Oversized;
    }
    budget.raw_received += bytes.len;
    if (budget.raw_received > budget.raw_limit) {
        reportLimit(transport, .receive, method, .raw_bytes, budget.raw_received, budget.raw_limit, .not_confirmed);
        return error.RawByteBudgetExceeded;
    }
    if (capture) |expected| {
        const compact = compactCaptureEnvelope(scratch, bytes, expected) catch |err| {
            failure(transport, .classify, method, .not_confirmed, err);
            return err;
        };
        if (compact) |packet| return packet;
    }
    const envelope = cdp.scan(bytes) catch |err| {
        failure(transport, .classify, method, .not_confirmed, err);
        return err;
    };
    return .{ .bytes = bytes, .envelope = envelope };
}

const Packet = struct { bytes: []const u8, envelope: cdp.Envelope, capture_data: ?[]const u8 = null };
const CaptureExpectation = struct { id: u32, session: ?[]const u8 };

fn compactCaptureEnvelope(alloc: Allocator, bytes: []const u8, expected: CaptureExpectation) Error!?Packet {
    const cap = 8 * 1024;
    const key = "\"data\"";
    const whitespace = " \t\r\n";
    if (bytes.len <= cap) return null;
    const key_at = std.mem.indexOf(u8, bytes[0..cap], key) orelse return null;
    var tail = std.mem.trimLeft(u8, bytes[key_at + key.len ..], whitespace);
    if (tail.len == 0 or tail[0] != ':') return null;
    tail = std.mem.trimLeft(u8, tail[1..], whitespace);
    if (tail.len == 0 or tail[0] != '"') return null;
    const start = @intFromPtr(tail.ptr) - @intFromPtr(bytes.ptr) + 1;
    const end = start + (std.mem.indexOfScalar(u8, bytes[start..], '"') orelse return null);
    if (start + bytes.len - end > cap) return null;
    const compact = try std.mem.concat(alloc, u8, &.{ bytes[0..start], bytes[end..] });
    const envelope = cdp.scan(compact) catch return null;
    if (envelope.kind != .reply or !envelope.matches(expected.session)) return null;
    const reply = envelope.kind.reply;
    if (reply.id != expected.id or reply.rejected) return null;
    const placeholder = (cdp.screenshotData(reply.payload) catch return null) orelse return null;
    if (placeholder.len != 0 or placeholder.ptr != compact[start..].ptr) return null;
    const data = bytes[start..end];
    // Prove the skipped string is unescaped ASCII JSON. The JPEG decoder
    // validates the Base64 payload if its admitted size permits decoding.
    if (!validCaptureJsonString(data)) return error.InvalidCdpMessage;
    return .{ .bytes = bytes, .envelope = envelope, .capture_data = data };
}

fn validCaptureJsonString(data: []const u8) bool {
    const lanes: u64 = 0x0101010101010101;
    const high: u64 = lanes * 0x80;
    var offset: usize = 0;
    while (offset + 8 <= data.len) : (offset += 8) {
        const word = std.mem.readInt(u64, data[offset..][0..8], .little);
        // With high bits clear, adding 0x60 detects bytes below 0x20.
        if (((word | ~(word +% (lanes * 0x60))) & high) != 0) return false;
        const escaped = word ^ (lanes * '\\');
        if (((escaped -% lanes) & ~escaped & high) != 0) return false;
    }
    for (data[offset..]) |c| if (c < 0x20 or c >= 0x80 or c == '\\') return false;
    return true;
}

test "screenshot fast path accepts only plain JSON bytes and matches the exact reply" {
    const expected = CaptureExpectation{ .id = 7, .session = "scope" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const head = "{\"result\":{\"data\":\"";
    const suffix = "\"},\"sessionId\":\"scope\",\"id\":7}";
    const message = try std.mem.concat(alloc, u8, &.{ head, "A" ** 9000, suffix });
    try std.testing.expectEqual(@as(usize, 9000), (try compactCaptureEnvelope(alloc, message, expected)).?.capture_data.?.len);
    try std.testing.expect((try compactCaptureEnvelope(alloc, message, .{ .id = 8, .session = "scope" })) == null);
    try std.testing.expect((try compactCaptureEnvelope(alloc, message, .{ .id = 7, .session = "other" })) == null);
    for (0..9) |offset| {
        var sample = [_]u8{'A'} ** 9;
        for (0..256) |byte| {
            sample[offset] = @intCast(byte);
            try std.testing.expectEqual(byte >= 0x20 and byte < 0x80 and byte != '\\', validCaptureJsonString(&sample));
        }
    }
}

fn dispatchEvent(transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, packet: *const Packet, action: ?Action) Error!void {
    dispatch(transport, scratch, budget, method, packet, action) catch |err| {
        switch (err) {
            error.DecodeByteBudgetExceeded, error.DecodeTokenBudgetExceeded => {}, // reported by the decoder
            else => failure(transport, .dispatch, method, .not_confirmed, err),
        }
        return err;
    };
}

fn dispatch(transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, packet: *const Packet, action: ?Action) Error!void {
    const event = packet.envelope.kind.event;
    const attached = budget.attachment;
    const exact_session = if (attached) |active| packet.envelope.matches(active.session) else false;
    switch (event.method) {
        .@"Inspector.detached", .@"Inspector.targetCrashed", .@"Target.attachedToTarget", .@"Target.detachedFromTarget", .@"Target.targetDestroyed", .@"Target.targetCrashed" => try dispatchLifecycle(transport, scratch, budget, method, packet, action, exact_session),
        .@"Runtime.executionContextCreated", .@"Runtime.executionContextDestroyed", .@"Runtime.executionContextsCleared" => {
            const witness = budget.witness orelse return;
            if (!exact_session) return;
            const params = try eventParams(transport, scratch, budget, method, packet);
            switch (event.method) {
                .@"Runtime.executionContextCreated" => try witness.capture(params),
                .@"Runtime.executionContextDestroyed" => try witness.destroy(params),
                .@"Runtime.executionContextsCleared" => witness.clear(),
                else => unreachable,
            }
        },
        .@"WebMCP.toolsAdded", .@"WebMCP.toolsRemoved", .@"WebMCP.toolInvoked", .@"WebMCP.toolResponded" => {
            const witness = budget.web_mcp_witness orelse return;
            if (!exact_session) return;
            const registry = event.method == .@"WebMCP.toolsAdded" or event.method == .@"WebMCP.toolsRemoved";
            if (registry != (witness == .registry)) return;
            try witness.captureParams(@tagName(event.method), try eventParams(transport, scratch, budget, method, packet));
        },
        .unknown, .@"Network.responseReceived", .@"Network.loadingFinished", .@"Network.loadingFailed" => {},
    }
}

// Lifecycle data is considered with the outstanding command *or* while
// idle waiting for WebMCP events. It is not gated by a payload witness.
fn dispatchLifecycle(transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, packet: *const Packet, action: ?Action, exact_session: bool) Error!void {
    const attached = budget.attachment;
    const root = packet.envelope.session == null;
    const attach_target = if (action) |a| if (a == .attach) a.attach else null else null;
    const event = packet.envelope.kind.event;
    switch (event.method) {
        .@"Inspector.detached", .@"Inspector.targetCrashed" => {
            // These notifications are scoped by the flat header (or root).
            if (root or exact_session) return error.StalePage;
        },
        .@"Target.attachedToTarget" => {
            if (!root or (attach_target == null and attached == null)) return;
            const params = try eventParams(transport, scratch, budget, method, packet);
            const info = objectField(params, "targetInfo") orelse return error.InvalidCdpMessage;
            const target = checkedId(info, "targetId") orelse return error.InvalidCdpMessage;
            const session = checkedId(params, "sessionId") orelse return error.InvalidCdpMessage;
            if (!std.mem.eql(u8, target, attach_target orelse attached.?.target)) return;
            const waiting = params.object.get("waitingForDebugger") orelse return error.InvalidCdpMessage;
            if (waiting != .bool or waiting.bool) return error.UnexpectedCdpResponse;
            if (attached) |active| {
                if (!std.mem.eql(u8, active.session, session)) return error.UnexpectedCdpResponse;
            } else {
                if (budget.attach_event != null) return error.UnexpectedCdpResponse;
                budget.attach_event = session;
            }
        },
        .@"Target.detachedFromTarget" => {
            if (!root or (attach_target == null and attached == null)) return;
            const params = try eventParams(transport, scratch, budget, method, packet);
            const detached = checkedId(params, "sessionId") orelse return error.InvalidCdpMessage;
            if (attach_target) |target| {
                if (budget.attach_event) |announced| {
                    if (std.mem.eql(u8, announced, detached)) return error.StalePage;
                    return;
                }
                // The ACK may arrive before the attach event; a late detach
                // for an older session must not poison the new attachment.
                if (params.object.contains("targetId")) {
                    const reported = checkedId(params, "targetId") orelse return error.InvalidCdpMessage;
                    if (!std.mem.eql(u8, reported, target)) return;
                }
                if (budget.pending_detach_count == budget.pending_detach.len) return error.MessageBudgetExceeded;
                budget.pending_detach[budget.pending_detach_count] = detached;
                budget.pending_detach_count += 1;
                return;
            }
            if (!std.mem.eql(u8, attached.?.session, detached)) return;
            // An expected notification can precede the cleanup reply but does
            // not replace the exact detach acknowledgement.
            if (action) |a| if (a == .detach and std.mem.eql(u8, a.detach, detached)) return;
            return error.StalePage;
        },
        .@"Target.targetDestroyed", .@"Target.targetCrashed" => {
            if (!root or (attach_target == null and attached == null)) return;
            const params = try eventParams(transport, scratch, budget, method, packet);
            const target = checkedId(params, "targetId") orelse return error.InvalidCdpMessage;
            if (std.mem.eql(u8, target, attach_target orelse attached.?.target)) return error.StalePage;
        },
        else => unreachable,
    }
}

fn eventParams(transport: Transport, scratch: Allocator, budget: *MessageBudget, method: diagnostics.Method, packet: *const Packet) Error!Value {
    const params = packet.envelope.kind.event.params orelse return .null;
    return materialize(transport, scratch, budget, method, packet.bytes.len, params, .not_confirmed);
}

const WebMcpAttached = struct {
    pub const ProtocolError = Error;
    browser: *Browser,
    transport: Transport,
    scratch: Allocator,
    budget: *MessageBudget,
    session: []const u8,
    invoke_attempted: bool = false,

    pub fn command(self: *WebMcpAttached, action: webmcp.Command, witness: ?webmcp.Witness) Error!Value {
        self.budget.web_mcp_witness = witness;
        defer self.budget.web_mcp_witness = null;
        if (action == .invoke_tool) self.invoke_attempted = true;
        return self.browser.command(self.transport, self.scratch, self.budget, .{ .web_mcp = action }, self.session);
    }

    pub fn rootLoader(self: *WebMcpAttached, expected: []const u8, witness: ?webmcp.Witness) Error!?[]const u8 {
        self.budget.web_mcp_witness = witness;
        defer self.budget.web_mcp_witness = null;
        const tree = try self.browser.command(self.transport, self.scratch, self.budget, .frame_tree, self.session);
        const root = objectField(tree, "frameTree") orelse return error.InvalidCdpMessage;
        const frame = objectField(root, "frame") orelse return error.InvalidCdpMessage;
        if (!std.mem.eql(u8, checkedId(frame, "id") orelse return error.InvalidCdpMessage, expected) or frame != .object or frame.object.contains("parentId")) return null;
        if (!allowedHistoryUrl(stringField(frame, "url") orelse return error.InvalidCdpMessage)) return null;
        return checkedId(frame, "loaderId") orelse error.InvalidCdpMessage;
    }

    pub fn receive(self: *WebMcpAttached, witness: webmcp.Witness) Error!void {
        const method = .web_mcp_invoke;
        const packet = try self.browser.readEnvelope(self.transport, self.scratch, self.budget, method, null);
        switch (packet.envelope.kind) {
            .reply => |reply| {
                // No command is outstanding during event waiting.
                if (reply.id < self.browser.next_command) return;
                failure(self.transport, .classify, method, .not_confirmed, error.UnexpectedCdpResponse);
                return error.UnexpectedCdpResponse;
            },
            .event => {
                self.budget.web_mcp_witness = witness;
                defer self.budget.web_mcp_witness = null;
                self.browser.observeNetwork(self.transport, self.scratch, self.budget, method, &packet);
                try dispatchEvent(self.transport, self.scratch, self.budget, method, &packet, null);
            },
        }
    }

    pub fn cancel(self: *WebMcpAttached, action: webmcp.Command, witness: webmcp.Witness) Error!Value {
        // Reserve a small separate decode/message budget for exact cancellation
        // after a local cap. This never extends the Host transport deadline.
        var cleanup = MessageBudget.cleanup(self.budget.attachment);
        cleanup.web_mcp_witness = witness;
        return self.browser.command(self.transport, self.scratch, &cleanup, .{ .web_mcp = action }, self.session);
    }

    pub fn invalidate(self: *WebMcpAttached) void {
        if (self.browser.state == .connected) self.browser.invalidate(self.transport, .closed);
    }
};

fn validKey(key: []const u8) bool {
    if (key.len == 1 and key[0] >= ' ' and key[0] <= '~') return true;
    for (named_keys) |named| if (std.mem.eql(u8, key, named)) return true;
    return false;
}

fn validRef(ref: []const u8) bool {
    if (ref.len != 32) return false;
    for (ref) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn validNavigationUrl(url: []const u8) bool {
    if (url.len > max_navigation_url_bytes) return false;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return false;
    const base = url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];
    for (url) |c| switch (c) {
        0...32, 127, '\\' => return false,
        else => {},
    };
    _ = endpoint.parse(base) catch return false;
    return true;
}

fn validNetworkPrefix(value: []const u8) bool {
    return value.len <= network.max_filter and validNavigationUrl(value);
}

fn allowedHistoryUrl(url: []const u8) bool {
    return std.mem.eql(u8, url, "about:blank") or validNavigationUrl(url);
}

fn historyEntryId(entry: Value) Error!i32 {
    if (entry != .object) return error.InvalidCdpMessage;
    const id = jsonInteger(entry.object.get("id") orelse return error.InvalidCdpMessage) orelse return error.InvalidCdpMessage;
    if (id <= 0 or id > std.math.maxInt(i32)) return error.InvalidCdpMessage;
    return @intCast(id);
}

fn objectField(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    return if (child == .object) child else null;
}

fn singleton(a: Allocator, key: []const u8, value: []const u8) Error!Value {
    var result = std.json.ObjectMap.init(a);
    try result.put(key, .{ .string = value });
    return .{ .object = result };
}

fn checkedOutcome(a: Allocator, data: Value, allowed: []const []const u8, fallback: Error) Error!Value {
    const outcome = stringField(data, "outcome") orelse return fallback;
    for (allowed) |expected| {
        if (std.mem.eql(u8, outcome, expected)) return singleton(a, "outcome", expected);
    }
    return fallback;
}

fn safeProjection(a: Allocator, data: Value, row_cap: usize) Error!Value {
    const rows = arrayField(data, "rows") orelse return error.InvalidCdpMessage;
    if (rows.len > row_cap) return error.InvalidCdpMessage;
    const coverage = stringField(data, "coverage") orelse return error.InvalidCdpMessage;
    if (!std.mem.eql(u8, coverage, "more") and !std.mem.eql(u8, coverage, "depth_limit") and !std.mem.eql(u8, coverage, "end_of_scope")) return error.InvalidCdpMessage;
    var result = (try singleton(a, "representation", "light_dom_semantic")).object;
    try result.put("coverage", .{ .string = coverage });
    const cursor = data.object.get("continuation") orelse return error.InvalidCdpMessage;
    if (cursor != .null and (cursor != .string or !validRef(cursor.string))) return error.InvalidCdpMessage;
    if (std.mem.eql(u8, coverage, "more") and cursor == .null) return error.InvalidCdpMessage;
    if (cursor != .null) try result.put("continuation", cursor);
    const limited = data.object.get("presentationLimited") orelse return error.InvalidCdpMessage;
    if (limited != .bool) return error.InvalidCdpMessage;
    try result.put("presentation_limited", limited);
    var output = std.json.Array.init(a);
    var fields = FieldBudget{};
    for (rows) |row| {
        const kind = stringField(row, "r") orelse return error.InvalidCdpMessage;
        if (kind.len == 0) return error.InvalidCdpMessage;
        var line = (try singleton(a, "role", try fields.copy(a, kind))).object;
        for ([_][]const u8{ "n", "g", "v", "d" }, [_][]const u8{ "name", "group", "value", "detail" }) |source, dest| {
            const text = stringField(row, source) orelse continue;
            if (text.len != 0) try line.put(dest, .{ .string = try fields.copy(a, text) });
        }
        if (row.object.get("gi")) |group_value| {
            const group = jsonInteger(group_value) orelse return error.InvalidCdpMessage;
            if (group < 0 or group > std.math.maxInt(u31)) return error.InvalidCdpMessage;
            if (group != 0) try line.put("group_index", group_value);
        }
        if (stringField(row, "ref")) |id| {
            if (!validRef(id)) return error.InvalidCdpMessage;
            try line.put("ref", .{ .string = id });
        }
        if (arrayField(row, "s")) |flags| {
            if (flags.len > 12) return error.InvalidCdpMessage;
            if (flags.len != 0) {
                var safe = std.json.Array.init(a);
                for (flags) |flag| {
                    if (flag != .string or flag.string.len > 24) return error.InvalidCdpMessage;
                    try safe.append(flag);
                }
                try line.put("states", .{ .array = safe });
            }
        }
        try output.append(.{ .object = line });
    }
    try result.put("rows", .{ .array = output });
    const source_truncated: Value = data.object.get("fieldsTruncated") orelse .{ .bool = false };
    if (source_truncated != .bool) return error.InvalidCdpMessage;
    try result.put("fields_truncated", .{ .bool = fields.truncated or source_truncated.bool });
    return .{ .object = result };
}

fn validConnectionId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_connection_bytes) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

const Target = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    special: bool,

    fn ordinary(self: Target) bool {
        return !self.special and allowedHistoryUrl(self.url);
    }
};
const ContextWitness = struct {
    frame: []const u8,
    world: union(enum) { isolated: struct { id: i64, name: []const u8 }, main },
    unique: ?[]const u8 = null,
    observed_id: ?i64 = null,

    fn capture(self: *ContextWitness, params: Value) Error!void {
        const ctx = objectField(params, "context") orelse return;
        const aux = objectField(ctx, "auxData") orelse return;
        const id = jsonInteger(ctx.object.get("id") orelse return) orelse return;
        if (id <= 0 or !std.mem.eql(u8, stringField(aux, "frameId") orelse "", self.frame)) return;
        const kind = stringField(aux, "type") orelse return;
        const is_default = aux.object.get("isDefault") orelse return;
        if (is_default != .bool) return;
        switch (self.world) {
            .isolated => |expected| if (is_default.bool or !std.mem.eql(u8, kind, "isolated") or id != expected.id or
                !std.mem.eql(u8, stringField(ctx, "name") orelse "", expected.name)) return,
            .main => if (!is_default.bool or !std.mem.eql(u8, kind, "default")) return,
        }
        const unique = checkedId(ctx, "uniqueId") orelse return;
        if (self.unique != null and (!std.mem.eql(u8, self.unique.?, unique) or self.observed_id != id)) return error.UnexpectedCdpResponse;
        self.unique = unique;
        self.observed_id = id;
    }

    fn clear(self: *ContextWitness) void {
        self.unique = null;
        self.observed_id = null;
    }

    fn destroy(self: *ContextWitness, params: Value) Error!void {
        if (params != .object) return error.InvalidCdpMessage;
        if (params.object.contains("executionContextUniqueId")) {
            const unique = checkedId(params, "executionContextUniqueId") orelse return error.InvalidCdpMessage;
            if (self.unique) |expected| if (std.mem.eql(u8, expected, unique)) {
                self.clear();
            };
        } else {
            const id = jsonInteger(params.object.get("executionContextId") orelse .null) orelse return error.InvalidCdpMessage;
            if (self.observed_id == id) self.clear();
        }
    }
};
const Attachment = struct { session: []const u8, target: []const u8 };
const MessageBudget = struct {
    received: usize = 0,
    message_limit: usize = legacy_receive_messages,
    bound: enum { normal, handoff, cleanup } = .normal,
    cleaning: bool = false,
    raw_received: usize = 0,
    raw_limit: usize = max_raw_bytes,
    decode_limit: usize = max_decode_bytes,
    decode: DecodeBudget = .{},
    attachment: ?Attachment = null,
    attach_event: ?[]const u8 = null,
    pending_detach_count: usize = 0,
    pending_detach: [pending_detach_limit][]const u8 = undefined,
    witness: ?*ContextWitness = null,
    web_mcp_witness: ?webmcp.Witness = null,

    fn useTransport(self: *MessageBudget, transport: Transport) void {
        // Scoped receives have time, raw-byte, fuel and Host-call ceilings.
        // Do not impose an additional small count on ordinary CDP events.
        if (self.bound == .normal and transport.scoped != null) self.message_limit = 0;
    }

    fn checkMessageCount(self: *const MessageBudget, transport: Transport, method: diagnostics.Method) Error!void {
        if (self.message_limit != 0 and self.received >= self.message_limit) return messageLimit(transport, self, method);
    }

    fn cleanup(attachment: ?Attachment) MessageBudget {
        return .{
            .message_limit = cleanup_messages,
            .bound = .cleanup,
            .cleaning = true,
            .raw_limit = cleanup_bytes,
            .decode_limit = cleanup_bytes,
            .decode = .{ .bytes = cleanup_bytes, .tokens = cleanup_decode_tokens },
            .attachment = attachment,
        };
    }
};
const ScopedInput = union(enum) {
    scroll: struct { x: i32, y: i32 },
    find: struct { text: ?[]const u8, role: ?[]const u8 },
    set_checked: bool,
    select_option: []const u8,
    wait_for: struct { condition: WaitCondition, timeout_ms: u16 },
};
const ProjectQuery = struct {
    op: []const u8,
    ref: ?[]const u8,
    input: ?[]const u8 = null,
    keyboard: ?KeyInput = null,
    scoped_input: ?ScopedInput = null,

    fn effect(self: ProjectQuery) bool {
        if (self.scoped_input) |input| return input != .find and input != .wait_for;
        return !std.mem.eql(u8, self.op, "scan");
    }
};
const CaptureClip = struct { x: f64, y: f64, width: f64, height: f64, scale: f64 };

fn viewportNumber(viewport: Value, key: []const u8) Error!f64 {
    const field = viewport.object.get(key) orelse return error.ScreenshotGeometryUnavailable;
    if (field != .number_string) return error.ScreenshotGeometryUnavailable;
    const number = std.fmt.parseFloat(f64, field.number_string) catch return error.ScreenshotGeometryUnavailable;
    if (!std.math.isFinite(number)) return error.ScreenshotGeometryUnavailable;
    return number;
}

fn screenshotClip(metrics: Value, options: ScreenshotOptions) Error!CaptureClip {
    const viewport = objectField(metrics, "cssVisualViewport") orelse return error.ScreenshotGeometryUnavailable;
    // Capture clips use document-relative DIPs, while these metrics use CSS
    // pixels. Require both scales to be known and neutral. Device pixel ratio
    // is not browser zoom and affects only the final output pixel dimensions.
    if (try viewportNumber(viewport, "scale") != 1 or try viewportNumber(viewport, "zoom") != 1) return error.ScreenshotGeometryUnavailable;
    const x = try viewportNumber(viewport, "pageX");
    const y = try viewportNumber(viewport, "pageY");
    const width = try viewportNumber(viewport, "clientWidth");
    const height = try viewportNumber(viewport, "clientHeight");
    // Do not pass anomalous geometry into Chromium's finite-precision
    // compositor. Reject rather than clamp or substitute document dimensions.
    const max_viewport_side = 16 * 1024;
    const max_document_edge = 1 << 24;
    const scale = options.scale orelse 1;
    if (x < 0 or y < 0 or width * scale < 1 or height * scale < 1 or
        width > max_viewport_side or height > max_viewport_side or
        x + width > max_document_edge or y + height > max_document_edge) return error.ScreenshotGeometryUnavailable;
    const clip = options.clip orelse Clip{ .x = 0, .y = 0, .width = width, .height = height };
    // Compare against the remaining space from both sides instead of adding
    // edges: a tiny positive x must not disappear when width equals the viewport.
    if (clip.x > width - clip.width or clip.width > width - clip.x or
        clip.y > height - clip.height or clip.height > height - clip.y) return error.ScreenshotClipOutOfBounds;
    if (clip.width * scale * clip.height * scale > 16 * 1024 * 1024) return error.InvalidScreenshotOptions;
    return .{ .x = x + clip.x, .y = y + clip.y, .width = clip.width, .height = clip.height, .scale = scale };
}

const Action = union(enum) {
    version,
    targets,
    attach: []const u8,
    tree,
    enable_runtime,
    disable_runtime,
    world: struct { name: []const u8, frame: []const u8 },
    projection: struct { query: ProjectQuery, context: []const u8, key: []const u8 },
    evaluate: struct { context: []const u8, expression: []const u8, timeout_ms: u16 },
    navigate: []const u8,
    create_tab: []const u8,
    activate_tab: []const u8,
    close_tab: []const u8,
    frame_tree,
    web_mcp: webmcp.Command,
    reload: []const u8,
    navigation_history,
    history_entry: i32,
    layout_metrics,
    network_enable,
    network_body: []const u8,
    screenshot: struct { quality: u8, clip: ?CaptureClip },
    detach: []const u8,

    fn tabEffect(self: Action) bool {
        return switch (self) {
            .create_tab, .activate_tab, .close_tab, .reload, .history_entry, .evaluate => true,
            else => false,
        };
    }

    fn diagnosticCommand(self: Action) ?diagnostics.Command {
        return switch (self) {
            .version => .browser_get_version,
            .targets => .target_get_targets,
            .attach => .target_attach_to_target,
            .detach => .target_detach_from_target,
            .create_tab => .target_create_target,
            .activate_tab => .target_activate_target,
            .close_tab => .target_close_target,
            .tree => .accessibility_get_full_ax_tree,
            .enable_runtime => .runtime_enable,
            .disable_runtime => .runtime_disable,
            .projection => .runtime_call_function_on,
            .world => .page_create_isolated_world,
            .navigate => .page_navigate,
            .frame_tree => .page_get_frame_tree,
            .reload => .page_reload,
            .navigation_history => .page_get_navigation_history,
            .history_entry => .page_navigate_to_history_entry,
            .layout_metrics => .page_get_layout_metrics,
            .screenshot => .page_capture_screenshot,
            .network_enable, .network_body, .evaluate => null,
            .web_mcp => |cmd| switch (cmd) {
                .enable => .web_mcp_enable,
                .invoke_tool => .web_mcp_invoke_tool,
                .cancel_invocation => .web_mcp_cancel_invocation,
            },
        };
    }

    fn diagnosticMethod(self: Action) diagnostics.Method {
        return switch (self) {
            .version => .browser,
            .targets => .target_get_targets,
            .attach => .target_attach,
            .detach => .target_detach,
            .enable_runtime => .runtime_enable,
            .disable_runtime => .runtime_disable,
            .projection => .runtime_call_function_on,
            .evaluate => .runtime,
            .screenshot => .page_capture_screenshot,
            .create_tab, .activate_tab, .close_tab => .target,
            .tree => .dom,
            .web_mcp => |command| switch (command) {
                .enable => .web_mcp_enable,
                .invoke_tool => .web_mcp_invoke,
                .cancel_invocation => .web_mcp,
            },
            else => .page,
        };
    }

    fn encode(self: Action, alloc: Allocator, id: u32, session: ?[]const u8) Allocator.Error![]const u8 {
        const options = std.json.StringifyOptions{ .emit_null_optional_fields = false };
        return switch (self) {
            .version => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Browser.getVersion" }, options),
            .targets => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.getTargets" }, options),
            .attach => |target| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.attachToTarget", .params = .{ .targetId = target, .flatten = true } }, options),
            .tree => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Accessibility.getFullAXTree", .sessionId = session }, options),
            .enable_runtime => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Runtime.enable", .sessionId = session }, options),
            .disable_runtime => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Runtime.disable", .sessionId = session }, options),
            .world => |world| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.createIsolatedWorld", .sessionId = session, .params = .{ .frameId = world.frame, .worldName = world.name } }, options),
            .projection => |projection| blk: {
                const encoder = std.base64.standard.Encoder;
                const input: ?[]const u8 = if (projection.query.input) |text| encoded: {
                    const buffer = try alloc.alloc(u8, encoder.calcSize(text.len));
                    break :encoded encoder.encode(buffer, text);
                } else if (projection.query.keyboard) |keyboard| try std.json.stringifyAlloc(alloc, keyboard, .{}) else if (projection.query.scoped_input) |scoped| switch (scoped) {
                    // Avoid nested JSON escaping of an exact page value (up
                    // to 512 UTF-8 bytes) inside the fixed command envelope.
                    .select_option => |value| encoded: {
                        const buffer = try alloc.alloc(u8, encoder.calcSize(value.len));
                        break :encoded encoder.encode(buffer, value);
                    },
                    inline else => |value| try std.json.stringifyAlloc(alloc, value, .{}),
                } else null;
                break :blk std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Runtime.callFunctionOn", .sessionId = session, .params = .{
                    .functionDeclaration = if (projection.query.scoped_input != null) scoped_function else project_function,
                    .awaitPromise = if (projection.query.scoped_input) |scoped| scoped == .wait_for else false,
                    .uniqueContextId = projection.context,
                    .returnByValue = true,
                    .silent = true,
                    .arguments = [_]struct { value: ?[]const u8 }{
                        .{ .value = projection.key }, .{ .value = projection.query.op }, .{ .value = projection.query.ref }, .{ .value = input },
                    },
                } }, .{});
            },
            .evaluate => |evaluate| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Runtime.evaluate", .sessionId = session, .params = .{
                .expression = evaluate.expression,
                .uniqueContextId = evaluate.context,
                .timeout = evaluate.timeout_ms,
                .returnByValue = true,
                .generatePreview = false,
                .includeCommandLineAPI = false,
                .awaitPromise = false,
                .allowUnsafeEvalBlockedByCSP = false,
                .disableBreaks = true,
                .silent = true,
            } }, options),
            .navigate => |url| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.navigate", .sessionId = session, .params = .{ .url = url } }, options),
            .create_tab => |url| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.createTarget", .params = .{ .url = url, .newWindow = false, .forTab = false } }, options),
            .activate_tab => |target| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.activateTarget", .params = .{ .targetId = target } }, options),
            .close_tab => |target| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.closeTarget", .params = .{ .targetId = target } }, options),
            .web_mcp => |command| command.encode(alloc, id, session.?),
            .frame_tree => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.getFrameTree", .sessionId = session }, options),
            .reload => |loader| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.reload", .sessionId = session, .params = .{ .loaderId = loader } }, options),
            .navigation_history => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.getNavigationHistory", .sessionId = session }, options),
            .history_entry => |entry| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.navigateToHistoryEntry", .sessionId = session, .params = .{ .entryId = entry } }, options),
            .layout_metrics => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.getLayoutMetrics", .sessionId = session }, options),
            .network_enable => std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Network.enable", .sessionId = session, .params = .{ .maxTotalBufferSize = @as(u32, 256 * 1024), .maxResourceBufferSize = @as(u32, 16 * 1024), .maxPostDataSize = @as(u32, 0) } }, options),
            .network_body => |request| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Network.getResponseBody", .sessionId = session, .params = .{ .requestId = request } }, options),
            .screenshot => |capture| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Page.captureScreenshot", .sessionId = session, .params = .{
                .format = "jpeg",
                .quality = capture.quality,
                .fromSurface = true,
                .captureBeyondViewport = false,
                .clip = capture.clip,
            } }, options),
            .detach => |attached| std.json.stringifyAlloc(alloc, .{ .id = id, .method = "Target.detachFromTarget", .params = .{ .sessionId = attached } }, options),
        };
    }
};

const FieldBudget = struct {
    remaining: usize = max_result_field_bytes,
    escaped_remaining: usize = 24 * 1024,
    truncated: bool = false,

    fn copy(self: *FieldBudget, alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
        const cap = @min(self.remaining, max_field_bytes, text.len);
        var escaped: usize = 0;
        var len: usize = 0;
        while (len < cap) : (len += 1) {
            const cost: usize = switch (text[len]) {
                0...31 => 6, // conservative JSON escape bound
                '"', '\\' => 2,
                else => 1,
            };
            if (escaped + cost > self.escaped_remaining) break;
            escaped += cost;
        }
        if (len < text.len) {
            self.truncated = true;
            while (len > 0 and (text[len] & 0xc0) == 0x80) {
                len -= 1;
                escaped -= 1;
            }
        }
        self.remaining -= len;
        self.escaped_remaining -= escaped;
        return alloc.dupe(u8, text[0..len]);
    }
};

fn projectTree(output: Allocator, scratch: Allocator, tree: Value) Error!Snapshot {
    const raw = arrayField(tree, "nodes") orelse return error.InvalidCdpMessage;
    const count = @min(raw.len, max_nodes);
    var indexes = std.StringHashMap(usize).init(scratch);
    for (raw, 0..) |node, i| {
        const id = checkedId(node, "nodeId") orelse return error.InvalidCdpMessage;
        const entry = try indexes.getOrPut(id);
        if (entry.found_existing) return error.InvalidCdpMessage;
        entry.value_ptr.* = i;
    }
    var budget = FieldBudget{};
    const nodes = try output.alloc(Node, count);
    errdefer output.free(nodes);
    var written: usize = 0;
    errdefer for (nodes[0..written]) |node| {
        output.free(node.role);
        output.free(node.name);
        output.free(node.value);
        output.free(node.description);
    };
    for (raw[0..count], nodes, 0..) |source, *node, i| {
        const ignored = source.object.get("ignored") orelse return error.InvalidCdpMessage;
        if (ignored != .bool) return error.InvalidCdpMessage;
        var parent: ?usize = null;
        if (source.object.get("parentId")) |field| {
            if (field != .string) return error.InvalidCdpMessage;
            if (indexes.get(field.string)) |p| {
                if (p == i) return error.InvalidCdpMessage;
                if (p < count) parent = p;
            }
        }
        const role = try budget.copy(output, try axText(scratch, source, "role"));
        errdefer output.free(role);
        const name = try budget.copy(output, try axText(scratch, source, "name"));
        errdefer output.free(name);
        const value = try budget.copy(output, try axText(scratch, source, "value"));
        errdefer output.free(value);
        const description = try budget.copy(output, try axText(scratch, source, "description"));
        node.* = .{ .parent_index = parent, .ignored = ignored.bool, .role = role, .name = name, .value = value, .description = description };
        written += 1;
    }
    return .{ .nodes = nodes, .omitted_nodes = raw.len - count, .fields_truncated = budget.truncated };
}

const DecodeError = error{ InvalidCdpMessage, DecodeByteBudgetExceeded, DecodeTokenBudgetExceeded } || Allocator.Error;
const DecodeBudget = struct {
    bytes: usize = max_decode_bytes,
    tokens: usize = max_decode_tokens,

    fn next(self: *DecodeBudget, alloc: Allocator, scanner: *std.json.Scanner) DecodeError!std.json.Token {
        if (self.tokens == 0) return error.DecodeTokenBudgetExceeded;
        self.tokens -= 1;
        // Complete input belongs to the same arena. Unescaped strings and
        // numbers need no additional copy; the scanner validates UTF-8.
        return scanner.nextAlloc(alloc, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidCdpMessage,
        };
    }
};

fn checkpoint(transport: Transport, maybe_command: ?diagnostics.Command, stage: diagnostics.CheckpointPhase, exchange: u8, reply: diagnostics.Reply) void {
    const command = maybe_command orelse return;
    if (transport.checkpoint) |observe| observe(transport.context, .{ .command = command, .stage = stage, .exchange = exchange, .reply = reply });
}

fn report(transport: Transport, event: Diagnostic) void {
    if (transport.observe) |observe| observe(transport.context, event);
}

fn failure(transport: Transport, stage: diagnostics.Phase, method: diagnostics.Method, confirmation: diagnostics.Confirmation, err: Error) void {
    report(transport, .{
        .severity = .warn,
        .code = switch (err) {
            error.InvalidCdpMessage => .invalid_envelope,
            error.UnexpectedCdpResponse => .unexpected_reply,
            error.OutcomeUnknown => .effect_uncertain,
            else => .failed,
        },
        .stage = stage,
        .method_family = method,
        .confirmation = confirmation,
    });
}

fn reportLimit(transport: Transport, stage: diagnostics.Phase, method: diagnostics.Method, metric: diagnostics.Counter, measured: usize, limit: usize, confirmation: diagnostics.Confirmation) void {
    report(transport, .{ .severity = .warn, .code = .limit_exceeded, .stage = stage, .method_family = method, .metric = metric, .measured = @intCast(measured), .limit = @intCast(limit), .confirmation = confirmation });
}

fn messageLimit(transport: Transport, budget: *const MessageBudget, method: diagnostics.Method) Error {
    reportLimit(transport, .receive, method, .raw_messages, budget.message_limit, budget.message_limit, .not_confirmed);
    return error.MessageBudgetExceeded;
}

fn materialize(transport: Transport, alloc: Allocator, budget: *MessageBudget, method: diagnostics.Method, charged_bytes: usize, payload: []const u8, confirmation: diagnostics.Confirmation) DecodeError!Value {
    if (charged_bytes > budget.decode.bytes) {
        reportLimit(transport, .decode, method, .decoded_bytes, budget.decode_limit - budget.decode.bytes + charged_bytes, budget.decode_limit, confirmation);
        return error.DecodeByteBudgetExceeded;
    }
    // Charge the full frame for materialized payloads (including headers),
    // but only allocate a JSON Value for the actual result/error/params range.
    budget.decode.bytes -= charged_bytes - payload.len;
    return parseJson(alloc, payload, &budget.decode) catch |err| {
        if (err == error.DecodeTokenBudgetExceeded) {
            const limit: usize = if (budget.message_limit == cleanup_messages) cleanup_decode_tokens else max_decode_tokens;
            reportLimit(transport, .decode, method, .decoded_tokens, limit + 1, limit, confirmation);
        } else failure(transport, .decode, method, confirmation, err);
        return err;
    };
}

fn decodeReply(transport: Transport, alloc: Allocator, budget: *MessageBudget, method: diagnostics.Method, wire_len: usize, result: []const u8, capture: bool) Error!Value {
    const metadata_cap = 8 * 1024;
    if (capture and wire_len > metadata_cap) {
        const selected = cdp.screenshotData(result) catch |err| {
            failure(transport, .decode, method, .confirmed, err);
            return err;
        };
        if (selected) |data| {
            const metadata_len = wire_len - data.len;
            if (metadata_len <= metadata_cap) {
                // Remove only the exact validated, unescaped result.data
                // content. The Base64 text is borrowed, not passed to JSON.
                const start = @intFromPtr(data.ptr) - @intFromPtr(result.ptr);
                const metadata = try std.mem.concat(alloc, u8, &.{ result[0..start], result[start + data.len ..] });
                var value = try materialize(transport, alloc, budget, method, metadata_len, metadata, .confirmed);
                value.object.getPtr("data").?.* = .{ .string = data }; // scanner and decoder agree on the exact key
                return value;
            }
        }
    }
    return materialize(transport, alloc, budget, method, wire_len, result, .confirmed);
}

fn decodeScreenshot(alloc: Allocator, result: Value) Error![]const u8 {
    const data = stringField(result, "data") orelse return error.InvalidScreenshot;
    const decoder = std.base64.standard.Decoder;
    const length = decoder.calcSizeForSlice(data) catch return error.InvalidScreenshot;
    if (length > max_jpeg_bytes) return error.ScreenshotTooLarge;
    if (length < 4) return error.InvalidScreenshot;
    const jpeg = try alloc.alloc(u8, length);
    errdefer alloc.free(jpeg);
    decoder.decode(jpeg, data) catch return error.InvalidScreenshot;
    if (!std.mem.startsWith(u8, jpeg, "\xff\xd8") or !std.mem.endsWith(u8, jpeg, "\xff\xd9")) return error.InvalidScreenshot;
    return jpeg;
}

const base64_alphabet = blk: {
    var table = [_]bool{false} ** 256;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/") |c| table[c] = true;
    break :blk table;
};

fn validBase64Body(body: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= body.len) : (i += 4) {
        if (!base64_alphabet[body[i]] or
            !base64_alphabet[body[i + 1]] or
            !base64_alphabet[body[i + 2]] or
            !base64_alphabet[body[i + 3]]) return false;
    }
    while (i < body.len) : (i += 1) {
        if (!base64_alphabet[body[i]]) return false;
    }
    return true;
}

const HeaderParse = union(enum) {
    dimensions: JpegDimensions,
    need_more,
    invalid,
};

fn parseJpegDimensionsBounded(jpeg: []const u8) HeaderParse {
    if (jpeg.len < 2) return .need_more;
    if (!std.mem.startsWith(u8, jpeg, "\xff\xd8")) return .invalid;
    var offset: usize = 2;
    while (offset < jpeg.len) {
        if (jpeg[offset] != 0xff) return .invalid;
        while (offset < jpeg.len and jpeg[offset] == 0xff) offset += 1;
        if (jpeg.len - offset < 3) return .need_more;
        const marker = jpeg[offset];
        offset += 1;
        if (marker == 0xda or marker == 0xd9 or marker == 0) return .invalid;
        const length = std.mem.readInt(u16, jpeg[offset..][0..2], .big);
        if (length < 2) return .invalid;
        if (length > jpeg.len - offset) return .need_more;
        switch (marker) {
            0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => {
                if (length < 8) return .invalid;
                const height = std.mem.readInt(u16, jpeg[offset + 3 ..][0..2], .big);
                const width = std.mem.readInt(u16, jpeg[offset + 5 ..][0..2], .big);
                if (width == 0 or height == 0) return .invalid;
                return .{ .dimensions = .{ .width = width, .height = height } };
            },
            else => offset += length,
        }
    }
    return .need_more;
}

pub fn jpegDimensions(jpeg: []const u8) ?JpegDimensions {
    return switch (parseJpegDimensionsBounded(jpeg)) {
        .dimensions => |dims| dims,
        .need_more, .invalid => null,
    };
}

/// Validates a borrowed Base64 JPEG string without decoding or re-encoding the
/// full payload: checks bounds, Base64 body characters + EOI tail (`\xff\xd9`),
/// and incrementally decodes only the JPEG header prefix needed to find SOF.
fn validateScreenshotCapture(alloc: Allocator, result: Value) Error!ScreenshotCapture {
    const data = stringField(result, "data") orelse return error.InvalidScreenshot;
    const decoder = std.base64.standard.Decoder;
    const length = decoder.calcSizeForSlice(data) catch return error.InvalidScreenshot;
    if (length > max_jpeg_bytes) return error.ScreenshotTooLarge;
    if (length < 4 or data.len < 8) return error.InvalidScreenshot;

    const tail_start = data.len - 8;
    const tail_len = decoder.calcSizeForSlice(data[tail_start..]) catch return error.InvalidScreenshot;
    var tail_buf: [6]u8 = undefined;
    decoder.decode(tail_buf[0..tail_len], data[tail_start..]) catch return error.InvalidScreenshot;
    if (!std.mem.endsWith(u8, tail_buf[0..tail_len], "\xff\xd9")) return error.InvalidScreenshot;

    if (!validBase64Body(data[0..tail_start])) return error.InvalidScreenshot;

    const prefix_b64: usize = @min(data.len, 4096);
    var decoded = try alloc.alloc(u8, decoder.calcSizeForSlice(data[0..prefix_b64]) catch return error.InvalidScreenshot);
    defer alloc.free(decoded);
    decoder.decode(decoded, data[0..prefix_b64]) catch return error.InvalidScreenshot;

    var decoded_len = decoded.len;
    var prev_b64: usize = prefix_b64;
    while (true) {
        switch (parseJpegDimensionsBounded(decoded[0..decoded_len])) {
            .dimensions => |dims| return .{
                .base64 = data,
                .bytes = length,
                .width = dims.width,
                .height = dims.height,
            },
            .invalid => return error.InvalidScreenshot,
            .need_more => {
                if (prev_b64 >= data.len) return error.InvalidScreenshot;
                const next_b64 = @min(data.len, prev_b64 * 2);
                const extra_len = decoder.calcSizeForSlice(data[prev_b64..next_b64]) catch return error.InvalidScreenshot;
                const grown = try alloc.alloc(u8, decoded_len + extra_len);
                @memcpy(grown[0..decoded_len], decoded[0..decoded_len]);
                alloc.free(decoded);
                decoded = grown;
                decoder.decode(decoded[decoded_len .. decoded_len + extra_len], data[prev_b64..next_b64]) catch return error.InvalidScreenshot;
                decoded_len += extra_len;
                prev_b64 = next_b64;
            },
        }
    }
}

pub fn parseWebMcpArguments(alloc: Allocator, bytes: []const u8) DecodeError!Value {
    var budget = DecodeBudget{ .bytes = webmcp.max_args_bytes, .tokens = 1024 };
    return parseJson(alloc, bytes, &budget);
}

fn parseJson(alloc: Allocator, bytes: []const u8, budget: *DecodeBudget) DecodeError!Value {
    if (bytes.len > budget.bytes) return error.DecodeByteBudgetExceeded;
    budget.bytes -= bytes.len;
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();
    const root = (try readJson(alloc, &scanner, budget, 0)) orelse return error.InvalidCdpMessage;
    if ((try budget.next(alloc, &scanner)) != .end_of_document) return error.InvalidCdpMessage;
    return root;
}

// Zig 0.13's dynamic Value parser overwrites duplicate keys regardless of
// ParseOptions. Use the stdlib tokenizer, but reject duplicate object keys and
// bound recursion ourselves before inspecting any envelope or discovery URL.
fn readJson(alloc: Allocator, scanner: *std.json.Scanner, budget: *DecodeBudget, depth: usize) DecodeError!?Value {
    if (depth > cdp.max_json_depth) return error.InvalidCdpMessage;
    const token = try budget.next(alloc, scanner);
    return switch (token) {
        .string, .allocated_string => |s| .{ .string = s },
        .number, .allocated_number => |n| .{ .number_string = n },
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .null => .null,
        .array_end => null,
        .array_begin => blk: {
            var items = std.json.Array.init(alloc);
            while (try readJson(alloc, scanner, budget, depth + 1)) |item| try items.append(item);
            break :blk .{ .array = items };
        },
        .object_begin => blk: {
            var fields = std.json.ObjectMap.init(alloc);
            while (true) {
                const token_key = try budget.next(alloc, scanner);
                if (token_key == .object_end) break;
                const key = switch (token_key) {
                    .string, .allocated_string => |s| s,
                    else => return error.InvalidCdpMessage,
                };
                const entry = try fields.getOrPut(key);
                if (entry.found_existing) return error.InvalidCdpMessage;
                entry.value_ptr.* = (try readJson(alloc, scanner, budget, depth + 1)) orelse return error.InvalidCdpMessage;
            }
            break :blk .{ .object = fields };
        },
        else => error.InvalidCdpMessage,
    };
}

fn jsonInteger(value: Value) ?i64 {
    if (value != .number_string or !std.json.isNumberFormattedLikeAnInteger(value.number_string)) return null;
    return std.fmt.parseInt(i64, value.number_string, 10) catch null;
}

fn stringField(value: Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn checkedId(value: Value, name: []const u8) ?[]const u8 {
    const id = stringField(value, name) orelse return null;
    if (id.len == 0 or id.len > max_cdp_identifier_bytes) return null;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return null;
    return id;
}

fn arrayField(value: Value, name: []const u8) ?[]const Value {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .array) field.array.items else null;
}

fn axText(scratch: Allocator, value: Value, key: []const u8) Error![]const u8 {
    const wrapped = value.object.get(key) orelse return "";
    if (wrapped != .object) return error.InvalidCdpMessage;
    const field = wrapped.object.get("value") orelse return "";
    return switch (field) {
        .string, .number_string => |text| text,
        .bool => |boolean| if (boolean) "true" else "false",
        .integer, .float => std.json.stringifyAlloc(scratch, field, .{}),
        .null => "",
        else => error.InvalidCdpMessage,
    };
}
