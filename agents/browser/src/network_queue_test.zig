const std = @import("std");
const network = @import("network_queue.zig");
const t = std.testing;
const Queue = network.Queue;
const slot = Queue.slot_bytes;

fn summary(id: u64) network.Summary {
    return .{
        .page_ref = "0123456789abcdef0123456789abcdef".*,
        .record_id = id,
        .outcome = .response_received,
        .http_status = 200,
    };
}

const Sink = struct {
    items: [12]network.Publication = undefined,
    len: usize = 0,
    fail_at: ?usize = null,

    pub fn publish(self: *Sink, item: network.Publication) error{Backpressure}!void {
        if (self.fail_at == self.len) return error.Backpressure;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn expectSummary(self: *const Sink, index: usize, seq: u64, id: u64) !void {
        try t.expect(index < self.len);
        try t.expectEqualDeep(network.Publication{ .summary = .{
            .sequence = seq,
            .summary = summary(id),
        } }, self.items[index]);
    }

    fn expectLoss(self: *const Sink, index: usize, first: u64, last: u64, count: u64) !void {
        try t.expect(index < self.len);
        try t.expectEqualDeep(network.Publication{ .loss = .{
            .first_sequence = first,
            .last_sequence = last,
        } }, self.items[index]);
        try t.expectEqual(count, self.items[index].loss.count());
    }
};

test "count cap tail drops, ring wraps, and separate loss runs stay in order" {
    var queue = try Queue.init(t.allocator, .{ .max_records = 2, .max_allocated_bytes = 10 * slot });
    defer queue.deinit();
    var sink = Sink{};
    try t.expectEqual(2 * slot, queue.allocatedBytes());
    try t.expectEqual(.queued, try queue.offer(summary(11)));
    try t.expectEqual(.queued, try queue.offer(summary(12)));
    try t.expectEqual(.dropped, try queue.offer(summary(13)));
    try t.expectEqual(.dropped, try queue.offer(summary(14)));
    try t.expectEqual(2, queue.len());
    try t.expectEqual(0, try queue.drain(0, &sink));
    try t.expectEqual(1, try queue.drain(1, &sink));
    try sink.expectSummary(0, 1, 11);

    try t.expectEqual(.queued, try queue.offer(summary(15)));
    try t.expectEqual(.dropped, try queue.offer(summary(16)));
    try t.expectEqual(2, try queue.drain(2, &sink));
    try sink.expectSummary(1, 2, 12);
    try sink.expectLoss(2, 3, 4, 2);
    try t.expectEqual(1, queue.len());
    try t.expectEqual(.queued, try queue.offer(summary(17)));
    try t.expectEqual(3, try queue.drain(10, &sink));
    try sink.expectSummary(3, 5, 15);
    try sink.expectLoss(4, 6, 6, 1);
    try sink.expectSummary(5, 7, 17);
    try t.expectEqual(0, queue.len());
    try t.expectEqual(0, try queue.drain(10, &sink));
}

test "byte cap includes unused slots and repeated offers and drains do not allocate" {
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    var queue = try Queue.init(failing.allocator(), .{ .max_records = 10, .max_allocated_bytes = 2 * slot - 1 });
    defer queue.deinit();
    try t.expectEqual(0, queue.len());
    try t.expectEqual(slot, queue.allocatedBytes());
    try t.expectEqual(slot, failing.allocated_bytes);
    for (0..1_000) |id| {
        var sink = Sink{};
        try t.expectEqual(.queued, try queue.offer(summary(id)));
        try t.expectEqual(.dropped, try queue.offer(summary(id)));
        try t.expectEqual(2, try queue.drain(2, &sink));
        try sink.expectSummary(0, 2 * @as(u64, id) + 1, id);
        try sink.expectLoss(1, 2 * @as(u64, id) + 2, 2 * @as(u64, id) + 2, 1);
    }
    try t.expectEqual(1, failing.allocations);
    try t.expect(!failing.has_induced_failure);
}

test "sink refusal preserves the failing entry and does not undo prior publication" {
    var queue = try Queue.init(t.allocator, .{ .max_records = 1, .max_allocated_bytes = slot });
    defer queue.deinit();
    var sink = Sink{ .fail_at = 0 };
    try t.expectEqual(.queued, try queue.offer(summary(10)));
    try t.expectError(error.Backpressure, queue.drain(10, &sink));
    try t.expectEqual(1, queue.len());
    try t.expectEqual(.dropped, try queue.offer(summary(11)));

    sink.fail_at = 1;
    try t.expectError(error.Backpressure, queue.drain(10, &sink));
    try sink.expectSummary(0, 1, 10);
    try t.expectEqual(0, queue.len());
    try t.expectEqual(.queued, try queue.offer(summary(12)));

    sink.fail_at = null;
    try t.expectEqual(2, try queue.drain(10, &sink));
    try sink.expectLoss(1, 2, 2, 1);
    try sink.expectSummary(2, 3, 12);
    try t.expectEqual(0, try queue.drain(10, &sink));
}

test "zero capacity accounts for a large loss run without allocating slots" {
    var queue = try Queue.init(t.failing_allocator, .{ .max_records = 5, .max_allocated_bytes = slot - 1 });
    defer queue.deinit();
    var sink = Sink{};
    try t.expectEqual(0, queue.allocatedBytes());
    for (0..10_000) |id| try t.expectEqual(.dropped, try queue.offer(summary(id)));
    try t.expectEqual(0, queue.len());
    try t.expectEqual(1, try queue.drain(1, &sink));
    try sink.expectLoss(0, 1, 10_000, 10_000);
    try t.expectEqual(0, try queue.drain(10, &sink));
}

test "allocator failure is returned from initialization" {
    try t.expectError(error.OutOfMemory, Queue.init(t.failing_allocator, .{
        .max_records = 1,
        .max_allocated_bytes = slot,
    }));
}

test "last sequence can be reported as dropped without rollover" {
    var queue = try Queue.init(t.failing_allocator, .{ .max_records = 0, .max_allocated_bytes = slot });
    defer queue.deinit();
    const last = std.math.maxInt(u64);
    queue.attempted_through = last - 1;
    queue.published_through = last - 1;
    try t.expectEqual(.dropped, try queue.offer(summary(10)));
    try t.expectError(error.SequenceExhausted, queue.offer(summary(11)));
    var sink = Sink{};
    try t.expectEqual(1, try queue.drain(10, &sink));
    try sink.expectLoss(0, last, last, 1);
    try t.expectEqual(0, try queue.drain(10, &sink));
}
