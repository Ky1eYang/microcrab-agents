//! Bounded guest facts. Tag ordering mirrors microcrab:session/observation@0.2.2.
pub const Level = enum(u8) { debug, info, warn, @"error" };
pub const Code = enum(u8) { checkpoint, failed, limit_exceeded, invalid_envelope, unexpected_reply, effect_uncertain };
pub const Phase = enum(u8) { initialize, connect, send, receive, classify, decode, dispatch, cleanup };
pub const Method = enum(u8) {
    none,
    target,
    page,
    runtime,
    dom,
    input,
    web_mcp,
    browser,
    target_get_targets,
    target_attach,
    target_detach,
    runtime_enable,
    runtime_disable,
    runtime_call_function_on,
    page_capture_screenshot,
    web_mcp_enable,
    web_mcp_invoke,
};
pub const Counter = enum(u8) { none, raw_messages, raw_bytes, decoded_bytes, elapsed_ms, decoded_tokens };
pub const Confirmation = enum(u8) { unknown, not_confirmed, confirmed };
pub const Event = struct {
    severity: Level,
    code: Code,
    stage: Phase,
    method_family: Method,
    metric: Counter = .none,
    measured: u32 = 0,
    limit: u32 = 0,
    // Confirmation describes the exact envelope, not whether an effect ran.
    confirmation: Confirmation = .unknown,
};

// Tag ordering mirrors microcrab:session/browser-observation@0.2.3.
// This DEBUG lane describes the exact command; legacy WARN families stay fixed.
pub const Command = enum(u8) {
    browser_get_version,
    target_get_targets,
    target_attach_to_target,
    target_detach_from_target,
    target_create_target,
    target_activate_target,
    target_close_target,
    accessibility_get_full_ax_tree,
    runtime_enable,
    runtime_disable,
    runtime_call_function_on,
    page_create_isolated_world,
    page_navigate,
    page_get_frame_tree,
    page_reload,
    page_get_navigation_history,
    page_navigate_to_history_entry,
    page_get_layout_metrics,
    page_capture_screenshot,
    web_mcp_enable,
    web_mcp_invoke_tool,
    web_mcp_cancel_invocation,
};
pub const CheckpointPhase = enum(u8) { send, receive, classify };
pub const Reply = enum(u8) { not_confirmed, confirmed };
pub const Checkpoint = struct {
    command: Command,
    stage: CheckpointPhase,
    // One-based per tool invocation, not the CDP wire command ID.
    exchange: u8,
    // Exact envelope observation only; does not confirm completion or effects.
    reply: Reply,
};
