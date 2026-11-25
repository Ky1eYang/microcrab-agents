//! Agent value adapter. Does not lower canonical ABI or use a real transport.
const std = @import("std");
const catalog = @import("catalog.zig");
const observation = @import("observation.zig");
const Allocator = std.mem.Allocator;

pub const Failure = struct {
    kind: enum(u8) { failed, timeout, cancelled } = .failed,
    code: []const u8,
    message: []const u8,
};
pub const Outcome = union(enum) { ok: []const u8, fail: Failure };
const max_encoded_final = 48 * 1024;

pub const CreatePrivateBytes = *const fn (name: []const u8, media_type: []const u8, data: []const u8) bool;

pub fn invoke(state: *observation.Browser, transport: observation.Transport, create_private_bytes: CreatePrivateBytes, alloc: Allocator, persistent: Allocator, compatible: bool, mode: ?[]const u8, name: []const u8, raw: []const u8) Outcome {
    const bound = catalog.extractConnection(alloc, name, raw) catch {
        return fail("invalid_request", "Pass the exact connect_id returned by connect to every follow-up Browser tool.");
    };
    const args = catalog.parseArguments(alloc, name, bound.dispatch_json) catch {
        return fail("invalid_request", "Unknown Browser tool or invalid arguments.");
    };
    if (catalog.isInteraction(std.meta.activeTag(args))) {
        if (mode == null or !std.mem.eql(u8, mode.?, @tagName(catalog.Mode.interaction))) return fail("mode_required", "This operation requires the admitted Browser interaction mode.");
    }
    if (!compatible) return browserFailure(error.Unsupported);
    // Every current Browser tool accesses this slot, including status and
    // connect. This guard does not serialize unrelated tools or other Stores.
    if (!state.acquireTool()) return fail("browser_connection_busy", "The Browser connection already has an active tool. No command was sent for this call.");
    defer state.releaseTool();
    const tool = std.meta.activeTag(args);
    if (bound.connect_id) |id| {
        if (!std.mem.eql(u8, state.handle(), id)) return fail("stale_connection", "The connect_id does not identify the active Browser connection.");
    }
    if (tool != .connect and tool != .status) {
        state.drain(transport, alloc, false) catch |err| return browserFailure(err);
    }
    const outcome = switch (args) {
        .configure_connection, .read_network_detail => invokeNetwork(state, transport, alloc, persistent, args),
        else => invokeTool(state, transport, create_private_bytes, alloc, args),
    };
    // Failed validation/discovery may leave the previous generation alive.
    // The connect invocation is not authorized to pull from that predecessor.
    if (tool == .connect and outcome == .fail) return outcome;
    if (tool != .status) state.drain(transport, alloc, true) catch |err| {
        if (outcome == .fail) return outcome;
        return browserFailure(if (catalog.isInteraction(tool)) error.OutcomeUnknown else err);
    };
    // A late result can establish synchronization without turning an
    // expired tool into apparent success (or replay permission).
    if (state.timedOut() and state.reusable() and outcome == .ok) return browserFailure(error.SettledTimeout);
    return outcome;
}

pub fn invokeNetwork(state: *observation.Browser, transport: observation.Transport, a: Allocator, persistent: Allocator, args: catalog.Arguments) Outcome {
    switch (args) {
        .configure_connection => |arg| {
            const result = state.configureNetwork(transport, a, persistent, arg.page_ref, arg.network_enabled, arg.url_prefix, arg.body_url_prefix) catch |err| return browserFailure(err);
            return .{ .ok = encode(a, .{ .network = result, .page_ref = arg.page_ref }) catch return browserFailure(error.Oversized) };
        },
        .read_network_detail => |arg| {
            if (arg.record_id.len == 0 or arg.record_id.len > 20 or arg.record_id[0] == '0') return browserFailure(error.InvalidRequest);
            for (arg.record_id) |c| if (!std.ascii.isDigit(c)) return browserFailure(error.InvalidRequest);
            const id = std.fmt.parseUnsigned(u64, arg.record_id, 10) catch return browserFailure(error.InvalidRequest);
            const detail = (state.networkDetail(transport, a, arg.page_ref, id, arg.include_body) catch |err| return browserFailure(err)) orelse return fail("record_expired", "This network record no longer exists for the specified page and connection.");
            const encoded = std.json.stringifyAlloc(a, .{ .page_ref = arg.page_ref, .record_id = arg.record_id, .url = detail.url, .body_status = @tagName(detail.body), .body = if (arg.include_body and detail.body == .text) detail.body.text else null }, .{ .emit_null_optional_fields = false }) catch return browserFailure(error.OutOfMemory);
            if (encoded.len > max_encoded_final) return browserFailure(error.Oversized);
            return .{ .ok = encoded };
        },
        else => unreachable,
    }
}

fn invokeTool(state: *observation.Browser, transport: observation.Transport, create_private_bytes: CreatePrivateBytes, alloc: Allocator, args: catalog.Arguments) Outcome {
    const text = switch (args) {
        .configure_connection, .read_network_detail => unreachable,
        .webmcp_list => |arg| encodeWebMcp(alloc, state.webMcp(transport, alloc, arg.page_ref, .list) catch |err| return browserFailure(err)),
        .webmcp_invoke => |arg| encodeWebMcp(alloc, state.webMcp(transport, alloc, arg.page_ref, .{ .invoke = arg }) catch |err| return browserFailure(err)),
        .execute_js => |arg| blk: {
            const result = state.executeJs(transport, alloc, arg) catch |err| return browserFailure(err);
            break :blk std.json.stringifyAlloc(alloc, result, .{ .emit_null_optional_fields = false });
        },
        .connect => |address| blk: {
            state.connectJob(transport, alloc, address) catch |err| return browserFailure(err);
            break :blk encode(alloc, .{ .status = "connected" });
        },
        .status => encode(alloc, .{ .status = state.status(transport) catch |err| return browserFailure(err) }),
        .list_pages => encode(alloc, state.listPages(transport, alloc) catch |err| return browserFailure(err)),
        .snapshot => |args_| encode(alloc, state.observe(transport, alloc, args_.page_ref, args_.region_ref) catch |err| return browserFailure(err)),
        .click => |args_| encode(alloc, state.click(transport, alloc, args_.page_ref, args_.element_ref) catch |err| return browserFailure(err)),
        .type_text => |args_| encode(alloc, state.typeText(transport, alloc, args_.page_ref, args_.element_ref, args_.text) catch |err| return browserFailure(err)),
        .navigate => |args_| encode(alloc, state.navigate(transport, alloc, args_.page_ref, args_.url) catch |err| return browserFailure(err)),
        .press_key => |args_| encode(alloc, state.pressKey(transport, alloc, args_.page_ref, args_.element_ref, args_.key, args_.modifiers) catch |err| return browserFailure(err)),
        .new_tab => |url| blk: {
            const receipt = state.newTab(transport, alloc, url) catch |err| return browserFailure(err);
            if (receipt.page_ref == null) break :blk encode(alloc, .{ .outcome = receipt.outcome });
            break :blk encode(alloc, receipt);
        },
        .select_tab => |args_| encode(alloc, state.selectTab(transport, alloc, args_.page_ref) catch |err| return browserFailure(err)),
        .history_navigation => |args_| encode(alloc, state.historyNavigation(transport, alloc, args_.page_ref, args_.action) catch |err| return browserFailure(err)),
        .close_tab => |args_| encode(alloc, state.closeTab(transport, alloc, args_.page_ref) catch |err| return browserFailure(err)),
        .scroll => |args_| encode(alloc, state.scroll(transport, alloc, args_.page_ref, args_.delta_y.value.?, args_.delta_x.value orelse 0) catch |err| return browserFailure(err)),
        .find => |args_| encode(alloc, state.find(transport, alloc, args_.page_ref, args_.text.value, args_.role.value, args_.continuation.value) catch |err| return browserFailure(err)),
        .set_checked => |args_| encode(alloc, state.setChecked(transport, alloc, args_.page_ref, args_.element_ref, args_.checked) catch |err| return browserFailure(err)),
        .select_option => |args_| encode(alloc, state.selectOption(transport, alloc, args_.page_ref, args_.element_ref, args_.value) catch |err| return browserFailure(err)),
        .wait_for => |args_| encode(alloc, state.waitFor(transport, alloc, args_.page_ref, std.meta.stringToEnum(observation.WaitCondition, args_.condition).?, args_.element_ref.value, args_.timeout_ms.value.?) catch |err| return browserFailure(err)),
        .screenshot => |args_| blk: {
            if (!catalog.validVariable(args_.variable)) return fail("invalid_variable", "Name an exact private Session Bytes variable.");
            const jpeg = state.screenshot(transport, alloc, args_.page_ref, args_.options) catch |err| return browserFailure(err);
            if (state.timedOut()) return browserFailure(error.SettledTimeout);
            const media_type = "image/jpeg";
            const image_url = std.fmt.allocPrint(alloc, "{{{{var:base64:{s}}}}}", .{args_.variable}) catch return browserFailure(error.OutOfMemory);
            const dimensions = jpegDimensions(jpeg) orelse return browserFailure(error.InvalidScreenshot);
            const receipt = encode(alloc, .{ .storage = "session_bytes", .variable = args_.variable, .media_type = media_type, .bytes = jpeg.len, .width = dimensions.width, .height = dimensions.height, .image_url = image_url }) catch return fail("limit", "Browser result exceeds its output limit.");
            if (!create_private_bytes(args_.variable, media_type, jpeg)) return fail("private_bytes_rejected", "Runtime did not stage the screenshot for that private Session variable.");
            break :blk receipt;
        },
    } catch return fail("limit", "Browser result exceeds its output limit.");
    return .{ .ok = text };
}

fn jpegDimensions(jpeg: []const u8) ?struct { width: u16, height: u16 } {
    if (!std.mem.startsWith(u8, jpeg, "\xff\xd8")) return null;
    var offset: usize = 2;
    while (offset < jpeg.len) {
        if (jpeg[offset] != 0xff) return null;
        while (offset < jpeg.len and jpeg[offset] == 0xff) offset += 1;
        if (jpeg.len - offset < 3) return null;
        const marker = jpeg[offset];
        offset += 1;
        if (marker == 0xda or marker == 0xd9 or marker == 0) return null;
        const length = std.mem.readInt(u16, jpeg[offset..][0..2], .big);
        if (length < 2 or length > jpeg.len - offset) return null;
        switch (marker) {
            0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => {
                if (length < 8) return null;
                const height = std.mem.readInt(u16, jpeg[offset + 3 ..][0..2], .big);
                const width = std.mem.readInt(u16, jpeg[offset + 5 ..][0..2], .big);
                if (width == 0 or height == 0) return null;
                return .{ .width = width, .height = height };
            },
            else => offset += length,
        }
    }
    return null;
}

test "JPEG receipt derives dimensions from a bounded frame header" {
    const jpeg = "\xff\xd8\xff\xe0\x00\x03\x00\xff\xc0\x00\x08\x08\x01\x2c\x02\x58\x03\xff\xd9";
    const dimensions = jpegDimensions(jpeg).?;
    try std.testing.expectEqual(@as(u16, 600), dimensions.width);
    try std.testing.expectEqual(@as(u16, 300), dimensions.height);
    try std.testing.expect(jpegDimensions(jpeg[0..13]) == null);
}

fn encodeWebMcp(alloc: Allocator, value: @import("webmcp.zig").Receipt) ![]const u8 {
    const text = try std.json.stringifyAlloc(alloc, value, .{ .emit_null_optional_fields = false });
    if (text.len > max_encoded_final) return error.Oversized;
    return text;
}

fn encode(alloc: Allocator, value: anytype) ![]const u8 {
    // Internal projections bound both the raw and escaped field text. Keep a
    // separate final byte check to guard against changes in metadata overhead.
    const text = try std.json.stringifyAlloc(alloc, value, .{});
    if (text.len > max_encoded_final) return error.Oversized;
    return text;
}

fn fail(code: []const u8, message: []const u8) Outcome {
    return .{ .fail = .{ .code = code, .message = message } };
}

fn browserFailure(err: observation.Error) Outcome {
    // Never forward endpoint, raw CDP errors, handshake data or Host messages.
    return switch (err) {
        error.Unsupported => fail("unsupported", "Read-only Browser transport is unavailable on the selected native Bridge route; no fallback was tried."),
        error.Denied => fail("denied", "The Browser transport operation was denied."),
        error.InvalidScroll => fail("invalid_scroll", "Scroll deltas must be integers within ±2000 CSS pixels."),
        error.InvalidFind => fail("invalid_find", "Supply bounded literal text and/or an exact lowercase role."),
        error.InvalidOptionValue => fail("invalid_option_value", "Select option value must be valid UTF-8 and at most 512 bytes."),
        error.InvalidWait => fail("invalid_wait", "Set a timeout from 1 through 7000 ms; supply an element reference only for an element condition."),
        error.InvalidRequest => fail("invalid_request", "The selected Host rejected the Browser transport request."),
        error.Cancelled => .{ .fail = .{ .kind = .cancelled, .code = "cancelled", .message = "Browser observation was cancelled." } },
        error.Timeout => .{ .fail = .{ .kind = .timeout, .code = "timeout", .message = "Browser transport timed out. Check status before requesting an explicit reconnect." } },
        error.SettledTimeout => .{ .fail = .{ .kind = .timeout, .code = "timeout", .message = "The Browser tool exceeded its work deadline. An operation already sent may have taken effect; do not replay it automatically." } },
        error.InvalidEndpoint => fail("invalid_endpoint", "Use an explicit host:port, HTTP(S) discovery URL, or WS(S) browser debugger URL without userinfo or fragments."),
        error.EndpointTooLong => fail("limit", "Browser endpoint exceeds the byte limit."),
        error.DiscoveryAuthorityMismatch => fail("authority_mismatch", "Discovery advertised a different host or port. If intended, the user must explicitly request connect to that target."),
        error.DiscoveryTlsDowngrade => fail("tls_downgrade", "HTTPS discovery advertised a cleartext debugger URL; no WebSocket was opened."),
        error.BadHttpStatus => fail("discovery_http_status", "HTTP discovery did not return status 200. Supply the intended discovery URL, usually ending in /json/version."),
        error.InvalidDiscovery => fail("invalid_discovery", "Discovery did not return a valid browser debugger URL."),
        error.NotConnected => fail("not_connected", "No Browser connection. An explicit user-directed connect is required."),
        error.Stale => fail("stale_connection", "The Browser connection belongs to a retired scope. An explicit user-directed connect is required."),
        error.Closed => fail("closed_connection", "The Browser connection is closed. An explicit user-directed connect is required."),
        error.InvalidPageRef => fail("invalid_page_ref", "Use a page reference returned by list_pages on the current connection."),
        error.StalePage => fail("stale_page", "That page is no longer available. List pages again on the current connection."),
        error.InvalidElementRef => fail("invalid_browser_ref", "Use an element reference or continuation from the current page observation."),
        error.StaleElementRef => fail("stale_browser_ref", "The reference no longer matches the current document or observation. Request a fresh snapshot; do not replay an earlier effect."),
        error.InvalidNavigationUrl => fail("invalid_navigation_url", "Navigate requires an exact HTTP(S) URL without credentials."),
        error.InvalidKeyboardInput => fail("invalid_key", "Use a supported key and at most one of each supported modifier."),
        error.InvalidScreenshot => fail("invalid_screenshot", "Chrome did not return a valid JPEG screenshot."),
        error.InvalidScreenshotOptions => fail("invalid_screenshot_options", "Use nonnegative clip origins, scaled dimensions of at least one CSS pixel, scale from 0.1 to 1, and integer quality from 0 to 100. Framed output is limited to 16 Mi square CSS pixels before device scaling."),
        error.ScreenshotClipOutOfBounds => fail("screenshot_clip_out_of_bounds", "The entire clip must fit within the current visual viewport. No screenshot was taken."),
        error.ScreenshotGeometryUnavailable => fail("screenshot_geometry_unavailable", "Current viewport geometry could not be verified for framing. Use 100% browser zoom and no pinch zoom, or omit clip and scale."),
        error.ScreenshotWireLimit => fail("screenshot_wire_limit", "The screenshot reply exceeded the transport limit. No image was saved. Explicitly reconnect before making another request with a smaller clip, lower scale, or lower quality."),
        error.ScreenshotTooLarge => fail("screenshot_limit", std.fmt.comptimePrint("The screenshot exceeded the {d}-byte JPEG limit. No image was saved. Request a smaller clip, lower scale, or lower quality; check status and reconnect explicitly if closed.", .{observation.max_jpeg_bytes})),
        error.InvalidInputText => fail("invalid_input_text", std.fmt.comptimePrint("Input text exceeds the {d}-byte limit or is not UTF-8.", .{observation.max_input_text_bytes})),
        error.NotActionable => fail("not_actionable", "The referenced element is hidden, disabled, readonly, or unsuitable for this operation."),
        error.ProjectionUnavailable => fail("observation_unavailable", "A supported isolated context could not be verified. No raw or full-tree fallback was used."),
        error.NavigationRejected => fail("navigation_rejected", "Chrome rejected the navigation or the selected tab cannot be navigated by this tool."),
        error.JsExecutionTimedOut, error.JsOutputLimit => unreachable, // Converted to settled receipts before debugger detach.
        error.AttachmentCleanupFailed => fail("attachment_cleanup_failed", "Debugger detach could not be confirmed; the connection is no longer usable."),
        error.InvalidCdpMessage, error.UnexpectedCdpResponse => fail("invalid_cdp_response", "An invalid or unrelated CDP response could not be used."),
        error.WebMcpUnsupported => fail("unsupported", "The experimental exact-ID WebMCP command is unavailable; no fallback was used."),
        error.WebMcpRegistryLimit => fail("webmcp_registry_limit", "The Chrome WebMCP registration stream exceeded its bounded census. No partial registry was used."),
        error.CdpRejected => fail("cdp_rejected", "The browser rejected the read-only CDP operation."),
        error.Oversized => fail("limit", "Browser discovery or response exceeded its wire byte limit. No partial wire message was used."),
        error.MessageBudgetExceeded => fail("message_budget", "The read-only CDP operation reached its message budget before a reply could be confirmed."),
        error.RawByteBudgetExceeded => fail("cdp_raw_bytes", std.fmt.comptimePrint("CDP messages exceeded the per-operation wire budget of {d} bytes. No partial result was used; check status before another observation.", .{observation.max_raw_bytes})),
        error.DecodeByteBudgetExceeded => fail("cdp_decode_bytes", std.fmt.comptimePrint("Read-only CDP replies and events exceeded the per-operation decode limit of {d} bytes. No partial result was used; check status before another observation. Do not retry unchanged input.", .{observation.max_decode_bytes})),
        error.DecodeTokenBudgetExceeded => fail("cdp_decode_tokens", std.fmt.comptimePrint("Read-only CDP replies and events exhausted the per-operation limit of {d} JSON tokens. No partial result was used; check status before another observation. Do not retry unchanged input.", .{observation.max_decode_tokens})),
        error.CommandIdsExhausted => fail("command_ids_exhausted", "This Browser connection exhausted its command identifiers and must be explicitly replaced."),
        error.OutcomeUnknown => fail("outcome_unknown", "No confirmed Browser result was received. Check the current page or connection state before deciding what to do next. A closed or stale connection needs explicit connect and fresh page references. Do not automatically repeat the operation."),
        error.TransportFailure => fail("transport_failure", "The selected Browser transport failed. No fallback was tried."),
        error.OutOfMemory => fail("limit", "Browser observation ran out of guest memory."),
    };
}
