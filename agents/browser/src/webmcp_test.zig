const std = @import("std");
const webmcp = @import("webmcp.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const t = std.testing;
const page = "0123456789abcdef0123456789abcdef";
const frame = "main-frame";
const tool = "opaque-production-id";
const registration =
    \\{"method":"WebMCP.toolsAdded","params":{"tools":[
    \\  {"frameId":"child-frame","toolId":"other","name":"echo","description":"child"},
    \\  {"frameId":"main-frame","toolId":"opaque-production-id","name":"echo","description":"main","inputSchema":{"type":"object","properties":{"word":{"type":"string"}}},"outputSchema":{"type":"object"},"annotations":{"readOnly":true,"untrustedContent":false}}]}}
;
const start =
    \\{"method":"WebMCP.toolInvoked","params":{"invocationId":"this-invocation","frameId":"main-frame","toolId":"opaque-production-id","input":"{}"}}
;
const completed =
    \\{"method":"WebMCP.toolResponded","params":{"invocationId":"this-invocation","status":"Completed","output":{"message":"echo"}}}
;
const canceled =
    \\{"method":"WebMCP.toolResponded","params":{"invocationId":"this-invocation","status":"Canceled"}}
;
const unrelated =
    \\{"method":"WebMCP.toolResponded","params":{"invocationId":"other-invocation","status":"Completed","output":"other"}}
;

fn json(a: Allocator, bytes: []const u8) !Value {
    return try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
}

const Fixture = struct {
    pub const ProtocolError = Error;
    const Error = Allocator.Error || error{ InvalidCdpMessage, WebMcpUnsupported, WebMcpRegistryLimit, CdpRejected, Timeout, Cancelled, MessageBudgetExceeded, RawByteBudgetExceeded, DecodeByteBudgetExceeded, DecodeTokenBudgetExceeded };
    a: Allocator,
    enable_event: ?[]const u8 = registration,
    fence_event: ?[]const u8 = null,
    enable_error: ?Error = null,
    events: []const []const u8 = &.{},
    receive_error: ?Error = null,
    cancel_event: ?[]const u8 = null,
    loader: []const u8 = "loader-one",
    invoked: usize = 0,
    canceled: usize = 0,
    invalidated: bool = false,

    pub fn command(self: *Fixture, call: webmcp.Command, witness: ?webmcp.Witness) Error!Value {
        switch (call) {
            .enable => {
                if (self.enable_error) |err| return err;
                if (self.enable_event) |event| try witness.?.capture(json(self.a, event) catch return error.InvalidCdpMessage);
                return json(self.a, "{}") catch error.InvalidCdpMessage;
            },
            .invoke_tool => |params| {
                self.invoked += 1;
                tryCheck(std.mem.eql(u8, params.frameId, frame));
                tryCheck(std.mem.eql(u8, params.toolId, tool));
                tryCheck(params.input == .object);
                // Check the actual serialized wire does not include toolName.
                const encoded = try call.encode(self.a, 9, "attach-one");
                tryCheck(std.mem.indexOf(u8, encoded, "\"toolName\"") == null);
                tryCheck(std.mem.indexOf(u8, encoded, "\"method\":\"WebMCP.invokeTool\"") != null);
                return json(self.a, "{\"invocationId\":\"this-invocation\"}") catch error.InvalidCdpMessage;
            },
            .cancel_invocation => unreachable,
        }
    }

    pub fn rootLoader(self: *Fixture, expected: []const u8, witness: ?webmcp.Witness) Error!?[]const u8 {
        tryCheck(std.mem.eql(u8, expected, frame));
        if (witness) |capture| if (self.fence_event) |event| try capture.capture(json(self.a, event) catch return error.InvalidCdpMessage);
        return self.loader;
    }

    pub fn receive(self: *Fixture, witness: webmcp.Witness) Error!void {
        if (self.events.len == 0) return self.receive_error orelse error.MessageBudgetExceeded;
        const event = self.events[0];
        self.events = self.events[1..];
        try witness.capture(json(self.a, event) catch return error.InvalidCdpMessage);
    }

    pub fn cancel(self: *Fixture, call: webmcp.Command, witness: webmcp.Witness) Error!Value {
        self.canceled += 1;
        tryCheck(std.mem.eql(u8, call.cancel_invocation.invocationId, "this-invocation"));
        if (self.cancel_event) |event| try witness.capture(json(self.a, event) catch return error.InvalidCdpMessage);
        return json(self.a, "{}") catch error.InvalidCdpMessage;
    }

    pub fn invalidate(self: *Fixture) void {
        self.invalidated = true;
    }
};

fn tryCheck(check: bool) void {
    t.expect(check) catch @panic("invalid WebMCP transcript");
}

fn list(fixture: *Fixture) !webmcp.Receipt {
    return webmcp.run(fixture, fixture.a, page, frame, .list);
}

fn invoke(fixture: *Fixture, ref: []const u8) !webmcp.Receipt {
    return webmcp.run(fixture, fixture.a, page, frame, .{ .invoke = .{ .page_ref = page, .tool_ref = ref, .input = try json(fixture.a, "{}") } });
}

test "list exposes top-frame schema and annotations as untrusted and binds registration identity" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .a = a };
    const listed = try list(&fixture);
    try t.expectEqual(.listed, listed.outcome);
    try t.expect(listed.untrusted);
    try t.expectEqual(@as(usize, 1), listed.tools.?.len);
    const entry = listed.tools.?[0];
    try t.expect(webmcp.validRef(&entry.tool_ref));
    try t.expectEqualStrings("main", entry.description);
    try t.expectEqualStrings("string", entry.inputSchema.?.object.get("properties").?.object.get("word").?.object.get("type").?.string);
    try t.expectEqual(@as(?bool, true), entry.annotations.?.readOnly);
    try t.expectEqual(@as(?bool, false), entry.annotations.?.untrustedContent);
    fixture.loader = "loader-two";
    const stale = try invoke(&fixture, &entry.tool_ref);
    try t.expectEqual(.stale_tool_ref, stale.outcome);
    try t.expectEqual(@as(usize, 0), fixture.invoked);
    fixture.loader = "loader-one";
    fixture.fence_event =
        \\{"method":"WebMCP.toolsRemoved","params":{"tools":[{"frameId":"main-frame","toolId":"opaque-production-id","name":"echo"}]}}
    ;
    try t.expectEqual(.stale_tool_ref, (try invoke(&fixture, &entry.tool_ref)).outcome);
    try t.expectEqual(@as(usize, 0), fixture.invoked);
}

test "optional domain and name-only Chrome yield unsupported, empty modern registry is listed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .a = a, .enable_error = error.WebMcpUnsupported };
    try t.expectEqual(.unsupported, (try list(&fixture)).outcome);
    fixture.enable_error = null;
    fixture.enable_event =
        \\{"method":"WebMCP.toolsAdded","params":{"tools":[{"frameId":"main-frame","name":"echo","description":"legacy"}]}}
    ;
    try t.expectEqual(.unsupported, (try list(&fixture)).outcome);
    fixture.enable_event = null;
    try t.expectEqual(@as(usize, 0), (try list(&fixture)).tools.?.len);
}

test "exact start and terminal required; unrelated invocation and cross-frame reuse cannot settle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .a = a, .events = &.{ unrelated, start, completed } };
    const ref = (try list(&fixture)).tools.?[0].tool_ref;
    const receipt = try invoke(&fixture, &ref);
    try t.expectEqual(.completed, receipt.outcome);
    try t.expectEqualStrings("echo", receipt.output.?.object.get("message").?.string);
    try t.expectEqual(@as(usize, 1), fixture.invoked);
    fixture.events = &.{completed};
    try t.expectEqual(.outcome_unknown, (try invoke(&fixture, &ref)).outcome);
    try t.expect(fixture.invalidated);
    fixture.events = &.{
        \\{"method":"WebMCP.toolInvoked","params":{"invocationId":"this-invocation","frameId":"child-frame","toolId":"opaque-production-id","input":"{}"}}
        ,
        completed,
    };
    try t.expectEqual(.outcome_unknown, (try invoke(&fixture, &ref)).outcome);
}

test "large page schema and output are omitted rather than falsely presented as complete" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 9 * 1024);
    @memset(long, 'a');
    const tool_event = try std.fmt.allocPrint(a, "{{\"method\":\"WebMCP.toolsAdded\",\"params\":{{\"tools\":[{{\"frameId\":\"main-frame\",\"toolId\":\"opaque-production-id\",\"name\":\"echo\",\"description\":\"fixture\",\"inputSchema\":{{\"description\":\"{s}\"}}}}]}}}}", .{long});
    const response_event = try std.fmt.allocPrint(a, "{{\"method\":\"WebMCP.toolResponded\",\"params\":{{\"invocationId\":\"this-invocation\",\"status\":\"Completed\",\"output\":\"{s}\"}}}}", .{long});
    var fixture: Fixture = .{ .a = a, .enable_event = tool_event, .events = &.{ start, response_event } };
    const entry = (try list(&fixture)).tools.?[0];
    try t.expect(entry.input_schema_omitted);
    try t.expect(entry.inputSchema == null);
    const receipt = try invoke(&fixture, &entry.tool_ref);
    try t.expectEqual(.completed, receipt.outcome);
    try t.expectEqual(@as(?bool, true), receipt.output_omitted);
    try t.expect(receipt.output == null);
}

test "cancel ACK differs from exact canceled event; host timeout and cancel do not replay" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .a = a, .events = &.{start} };
    const ref = (try list(&fixture)).tools.?[0].tool_ref;
    const ack_only = try invoke(&fixture, &ref);
    try t.expectEqual(.outcome_unknown, ack_only.outcome);
    try t.expectEqual(.acknowledged, ack_only.cancellation.?);
    try t.expectEqual(@as(usize, 1), fixture.canceled);
    fixture.events = &.{start};
    fixture.cancel_event = canceled;
    const canceled_terminal = try invoke(&fixture, &ref);
    try t.expectEqual(.canceled, canceled_terminal.outcome);
    try t.expectEqual(.acknowledged, canceled_terminal.cancellation.?);
    fixture.receive_error = error.Timeout;
    try t.expectEqual(.timeout, (try invoke(&fixture, &ref)).outcome);
    fixture.receive_error = error.Cancelled;
    try t.expectEqual(.cancelled, (try invoke(&fixture, &ref)).outcome);
    try t.expectEqual(@as(usize, 2), fixture.canceled);
    try t.expectEqual(@as(usize, 4), fixture.invoked);
}
