//! Connection-local FIFO for lossy network summaries, not replies or lifecycle
//! events. The caller owns capture admission, correlation and separately bounded
//! detail retention. No wire data or free-form strings enter this queue.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Summary = struct {
    // Guest-generated opaque IDs only, never CDP IDs or page/network strings.
    page_ref: [32]u8,
    record_id: u64,
    outcome: enum { request_started, response_received, request_finished, request_failed },
    http_status: ?u16 = null,
};

pub const Loss = struct {
    first_sequence: u64,
    last_sequence: u64,

    pub fn count(self: Loss) u64 {
        return self.last_sequence - self.first_sequence + 1;
    }
};

pub const Record = struct { sequence: u64, summary: Summary };
pub const Publication = union(enum) { summary: Record, loss: Loss };
pub const OfferResult = enum { queued, dropped };

pub const Limits = struct {
    max_records: usize,
    // Maximum bytes requested from the allocator by the queue's backing ring,
    // including unused slots. Queue bookkeeping is fixed-size inline state.
    max_allocated_bytes: usize,
};

/// Single owner, serialized by the Browser Guest. Keep one instance per
/// connection generation, using an allocator that outlives the connection.
pub const Queue = struct {
    pub const slot_bytes = @sizeOf(Record);

    allocator: Allocator,
    slots: []Record,
    head: usize = 0,
    pending: usize = 0,
    attempted_through: u64 = 0,
    published_through: u64 = 0,

    pub fn init(allocator: Allocator, limits: Limits) Allocator.Error!Queue {
        const capacity = @min(limits.max_records, limits.max_allocated_bytes / slot_bytes);
        return .{ .allocator = allocator, .slots = try allocator.alloc(Record, capacity) };
    }

    pub fn deinit(self: *Queue) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: *const Queue) usize {
        return self.slots.len * slot_bytes;
    }

    /// Counts queued summaries, excluding loss markers (which need no slots).
    pub fn len(self: *const Queue) usize {
        return self.pending;
    }

    /// Assigns a sequence even to a dropped attempt. Never overwrites a queued
    /// summary, allocates, or waits for space. Exhaustion is explicit rather
    /// than reusing a sequence within a connection generation.
    pub fn isFull(self: *const Queue) bool {
        return self.pending == self.slots.len;
    }

    pub fn noteDrop(self: *Queue) error{SequenceExhausted}!void {
        if (self.attempted_through == std.math.maxInt(u64)) return error.SequenceExhausted;
        self.attempted_through += 1;
    }

    pub fn offer(self: *Queue, summary: Summary) error{SequenceExhausted}!OfferResult {
        try self.noteDrop();
        if (self.isFull()) return .dropped;

        const tail = (self.head + self.pending) % self.slots.len;
        self.slots[tail] = .{ .sequence = self.attempted_through, .summary = summary };
        self.pending += 1;
        return .queued;
    }

    /// Producer-side drain. `sink.publish(Publication)` must be non-reentrant
    /// and return success only when accepted by the output layer. On an error,
    /// the failing publication remains pending (earlier successes stay drained).
    /// `limit` counts both summaries and coalesced loss markers. Job reads must
    /// not drive this drain; Job output history/eviction belongs to Runtime.
    pub fn drain(self: *Queue, limit: usize, sink: anytype) !usize {
        var published: usize = 0;
        while (published < limit) : (published += 1) {
            const item = self.nextPublication() orelse break;
            try sink.publish(item);
            switch (item) {
                .summary => |record| {
                    self.published_through = record.sequence;
                    self.head = (self.head + 1) % self.slots.len;
                    self.pending -= 1;
                },
                .loss => |loss| self.published_through = loss.last_sequence,
            }
        }
        return published;
    }

    fn nextPublication(self: *const Queue) ?Publication {
        if (self.published_through == self.attempted_through) return null;
        const next_sequence = self.published_through + 1;
        // Gaps between survivors (or a final run of drops) determine exactly
        // what was lost without allocating a second queue or overwriting data.
        const last_lost = if (self.pending == 0) self.attempted_through else blk: {
            const head = self.slots[self.head];
            if (head.sequence == next_sequence) return .{ .summary = head };
            break :blk head.sequence - 1;
        };
        return .{ .loss = .{ .first_sequence = next_sequence, .last_sequence = last_lost } };
    }
};
