//! Bounded, connection-local storage for details of already matched responses.
//! The caller owns capture filters, protocol correlation and tool admission.
//! Drive may insert metadata but must not fetch a body. No I/O or publication
//! occurs here; the summary queue must receive only the opaque record ID.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PageRef = [32]u8;
pub const RecordId = u64;
pub const max_protocol_id_bytes = 256;

pub const Limits = struct {
    max_records: usize = 128,
    // Bounds requested allocation bytes, including empty slots and all stored
    // payloads and correlation IDs. Does not change any transport wire limit.
    max_allocated_bytes: usize = 256 * 1024,
    max_url_bytes: usize = 16 * 1024,
    max_body_bytes: usize = 16 * 1024,
    ttl_ms: u64 = 60_000,
};

/// Only supply a candidate when the response is complete, still live, and
/// matched an explicit body filter. These identifiers never leave the Guest.
pub const Correlation = struct {
    session_id: []const u8,
    request_id: []const u8,
};

pub const Body = union(enum) {
    not_requested,
    fetchable,
    fetching,
    unavailable,
    too_large,
    text: []const u8,
};

pub const Detail = struct { url: []const u8, body: Body };

/// Untrusted protocol output must be classified by the admitted caller. A
/// base64 payload must not be treated as text just because its encoding is ASCII.
pub const BodyResult = union(enum) { unavailable, too_large, binary, text: []const u8 };

pub const Fetch = struct {
    ticket: Ticket,
    // Copies survive cache mutation while the admitted call waits for a reply.
    session: ProtocolId,
    request: ProtocolId,

    pub fn correlation(self: *const Fetch) Correlation {
        return .{ .session_id = self.session.bytes[0..self.session.len], .request_id = self.request.bytes[0..self.request.len] };
    }
};

pub const Ticket = struct { generation: u64, page: PageRef, record: RecordId };
const ProtocolId = struct {
    bytes: [max_protocol_id_bytes]u8,
    len: usize,

    fn copy(bytes: []const u8) ProtocolId {
        var result: ProtocolId = .{ .bytes = undefined, .len = bytes.len };
        @memcpy(result.bytes[0..bytes.len], bytes);
        return result;
    }
};

const Record = struct {
    id: RecordId,
    page: PageRef,
    inserted_at_ms: u64,
    url: []u8,
    body: StoredBody,
};
const StoredBody = union(enum) {
    not_requested,
    fetchable: []u8, // Concatenated session and request IDs, split by Slot.session_len.
    fetching,
    unavailable,
    too_large,
    text: []u8,
};
const Slot = struct {
    record: ?Record = null,
    session_len: usize = 0,
};

/// Single owner; use a reclaiming allocator that outlives the connection, not
/// an arena. Keep one Cache per connection generation, after checking the
/// caller's exact `connect_id`. Generation must not be reused across caches.
pub const Cache = struct {
    allocator: Allocator,
    limits: Limits,
    generation: u64,
    slots: []Slot,
    payload_bytes: usize = 0,
    live_records: usize = 0,
    last_record: RecordId = 0,
    now_ms: u64 = 0,

    pub fn init(allocator: Allocator, limits: Limits, generation: u64) Allocator.Error!Cache {
        // An occupied slot needs at least one payload byte for a nonempty URL.
        const capacity = @min(limits.max_records, limits.max_allocated_bytes / (@sizeOf(Slot) + 1));
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .allocator = allocator, .limits = limits, .generation = generation, .slots = slots };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: *const Cache) usize {
        return self.slots.len * @sizeOf(Slot) + self.payload_bytes;
    }

    pub fn len(self: *const Cache) usize {
        return self.live_records;
    }

    pub fn clear(self: *Cache) void {
        for (self.slots) |*slot| self.remove(slot);
        // Never reset last_record while the connection generation is live.
    }

    pub fn removePage(self: *Cache, page: PageRef) void {
        for (self.slots) |*slot| {
            if (slot.record) |record| if (samePage(record.page, page)) self.remove(slot);
        }
    }

    /// Advances the cache's monotonic time floor, reclaiming expired entries.
    pub fn expire(self: *Cache, now_ms: u64) void {
        self.now_ms = @max(self.now_ms, now_ms);
        for (self.slots) |*slot| {
            if (slot.record) |record| {
                if (self.now_ms - record.inserted_at_ms >= self.limits.ttl_ms) self.remove(slot);
            }
        }
    }

    /// Insert a whole URL or return a typed error; no clipped value is kept.
    /// FIFO eviction is independent of the Job summary queue. Do not pass
    /// slices borrowed from this cache back to any mutating method.
    pub fn insert(self: *Cache, page: PageRef, url: []const u8, candidate: ?Correlation, now_ms: u64) error{ UrlTooLarge, InvalidUrl, RecordIdsExhausted, InvalidCorrelation, DetailCapacity, OutOfMemory }!RecordId {
        if (url.len > self.limits.max_url_bytes) return error.UrlTooLarge;
        if (url.len == 0 or !std.unicode.utf8ValidateSlice(url)) return error.InvalidUrl;
        if (self.last_record == std.math.maxInt(RecordId)) return error.RecordIdsExhausted;
        const correlation_bytes = if (candidate) |key| blk: {
            if (!validProtocolId(key.session_id) or !validProtocolId(key.request_id)) return error.InvalidCorrelation;
            break :blk key.session_id.len + key.request_id.len;
        } else 0;
        const required = std.math.add(usize, url.len, correlation_bytes) catch return error.DetailCapacity;
        if (self.slots.len == 0 or self.limits.ttl_ms == 0 or required > self.limits.max_allocated_bytes - self.slots.len * @sizeOf(Slot)) return error.DetailCapacity;
        self.expire(now_ms);
        while (self.live_records == self.slots.len or required > self.freeBytes()) self.remove(self.oldest());
        const slot = for (self.slots) |*slot| {
            if (slot.record == null) break slot;
        } else unreachable; // Eviction above guarantees space for one record.
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const body: StoredBody = if (candidate) |key| .{
            .fetchable = try std.mem.concat(self.allocator, u8, &.{ key.session_id, key.request_id }),
        } else .not_requested;
        self.last_record += 1;
        self.live_records += 1;
        self.payload_bytes += required;
        slot.* = .{
            .record = .{ .page = page, .id = self.last_record, .inserted_at_ms = self.now_ms, .url = owned_url, .body = body },
            .session_len = if (candidate) |key| key.session_id.len else 0,
        };
        return self.last_record;
    }

    /// The returned data is untrusted and borrowed only until the next cache
    /// mutation. Wrong-page, nonexistent and expired records are indistinguishable.
    pub fn get(self: *Cache, page: PageRef, id: RecordId, now_ms: u64) error{RecordExpired}!Detail {
        self.expire(now_ms);
        const slot = self.lookup(page, id) orelse return error.RecordExpired;
        const record = &slot.record.?;
        const body: Body = switch (record.body) {
            .not_requested => .not_requested,
            .fetchable => .fetchable,
            .fetching => .fetching,
            .unavailable => .unavailable,
            .too_large => .too_large,
            .text => |text| .{ .text = text },
        };
        return .{ .url = record.url, .body = body };
    }

    /// Called only by a separately admitted detail invocation, after verifying
    /// the page/session correlation remains live. Only one fetch is started.
    pub fn beginBodyFetch(self: *Cache, page: PageRef, id: RecordId, now_ms: u64) error{ RecordExpired, BodyNotFetchable }!Fetch {
        self.expire(now_ms);
        const slot = self.lookup(page, id) orelse return error.RecordExpired;
        const record = &slot.record.?;
        const key = switch (record.body) {
            .fetchable => |key| key,
            else => return error.BodyNotFetchable,
        };
        const result: Fetch = .{
            .ticket = .{ .generation = self.generation, .page = page, .record = id },
            .session = ProtocolId.copy(key[0..slot.session_len]),
            .request = ProtocolId.copy(key[slot.session_len..]),
        };
        self.dropBody(slot);
        record.body = .fetching;
        return result;
    }

    /// Retire a response's body correlation (for example on a detach or a
    /// replaced request ID) without discarding its complete retained URL.
    pub fn invalidateBody(self: *Cache, page: PageRef, id: RecordId, now_ms: u64) error{RecordExpired}!void {
        self.expire(now_ms);
        const slot = self.lookup(page, id) orelse return error.RecordExpired;
        switch (slot.record.?.body) {
            .fetchable, .fetching => self.dropBody(slot),
            else => {},
        }
    }

    /// Complete exactly the active fetch. On failure, store a terminal state
    /// rather than implicitly retrying or retaining incomplete/binary data.
    /// A body never evicts another retained URL to make room.
    pub fn finishBodyFetch(self: *Cache, ticket: Ticket, body: BodyResult, now_ms: u64) error{ RecordExpired, BodyNotFetching, OutOfMemory }!void {
        if (ticket.generation != self.generation) return error.RecordExpired;
        self.expire(now_ms);
        const slot = self.lookup(ticket.page, ticket.record) orelse return error.RecordExpired;
        const record = &slot.record.?;
        if (record.body != .fetching) return error.BodyNotFetching;
        record.body = .unavailable;
        switch (body) {
            .unavailable, .binary => {},
            .too_large => record.body = .too_large,
            .text => |text| {
                if (text.len > self.limits.max_body_bytes) {
                    record.body = .too_large;
                } else if (text.len <= self.freeBytes() and std.unicode.utf8ValidateSlice(text)) {
                    record.body = .{ .text = try self.allocator.dupe(u8, text) };
                    self.payload_bytes += text.len;
                }
            },
        }
    }

    fn freeBytes(self: *const Cache) usize {
        return self.limits.max_allocated_bytes - self.allocatedBytes();
    }

    fn lookup(self: *Cache, page: PageRef, id: RecordId) ?*Slot {
        for (self.slots) |*slot| {
            if (slot.record) |record| if (record.id == id and samePage(record.page, page)) return slot;
        }
        return null;
    }

    fn oldest(self: *Cache) *Slot {
        var first: ?*Slot = null;
        for (self.slots) |*slot| {
            if (slot.record) |record| {
                if (first == null or record.id < first.?.record.?.id) first = slot;
            }
        }
        // Called only when a fit is possible after freeing space and at least
        // one occupied slot is preventing it.
        return first.?;
    }

    fn dropBody(self: *Cache, slot: *Slot) void {
        const record = &slot.record.?;
        switch (record.body) {
            .fetchable, .text => |bytes| self.freePayload(bytes),
            else => {},
        }
        slot.session_len = 0;
        record.body = .unavailable;
    }

    fn remove(self: *Cache, slot: *Slot) void {
        if (slot.record == null) return;
        self.dropBody(slot);
        self.freePayload(slot.record.?.url);
        slot.record = null;
        self.live_records -= 1;
    }

    fn freePayload(self: *Cache, bytes: []u8) void {
        self.payload_bytes -= bytes.len;
        self.allocator.free(bytes);
    }
};

fn validProtocolId(id: []const u8) bool {
    return id.len > 0 and id.len <= max_protocol_id_bytes and std.unicode.utf8ValidateSlice(id);
}

fn samePage(a: PageRef, b: PageRef) bool {
    return std.mem.eql(u8, &a, &b);
}

const t = std.testing;
const page_a = "a" ** 32;
const page_b = "b" ** 32;
const test_key = Correlation{ .session_id = "session-a", .request_id = "response-42" };

test "complete URLs and separately admitted body fetch are exact-page and exact-generation" {
    var cache = try Cache.init(t.allocator, .{}, 5);
    defer cache.deinit();
    var successor = try Cache.init(t.allocator, .{}, 6);
    defer successor.deinit();
    const url = "https://example.test/path?q=entire%20value#fragment";
    const id = try cache.insert(page_a.*, url, test_key, 11);
    try t.expectError(error.RecordExpired, cache.get(page_b.*, id, 12));
    try t.expectError(error.RecordExpired, cache.beginBodyFetch(page_b.*, id, 12));
    const detail = try cache.get(page_a.*, id, 12);
    try t.expectEqualStrings(url, detail.url);
    try t.expectEqual(Body.fetchable, detail.body);
    const fetch = try cache.beginBodyFetch(page_a.*, id, 13);
    try t.expectEqualStrings(test_key.session_id, fetch.correlation().session_id);
    try t.expectEqualStrings(test_key.request_id, fetch.correlation().request_id);
    try t.expectError(error.BodyNotFetchable, cache.beginBodyFetch(page_a.*, id, 13));
    var wrong_page = fetch.ticket;
    wrong_page.page = page_b.*;
    try t.expectError(error.RecordExpired, cache.finishBodyFetch(wrong_page, .{ .text = "wrong" }, 13));
    const next = try successor.insert(page_a.*, url, test_key, 13);
    try t.expectEqual(id, next);
    _ = try successor.beginBodyFetch(page_a.*, next, 13);
    try t.expectError(error.RecordExpired, successor.finishBodyFetch(fetch.ticket, .{ .text = "wrong" }, 13));
    try cache.finishBodyFetch(fetch.ticket, .{ .text = "complete body" }, 14);
    try t.expectEqualStrings("complete body", (try cache.get(page_a.*, id, 15)).body.text);
    try t.expectError(error.BodyNotFetching, cache.finishBodyFetch(fetch.ticket, .unavailable, 15));
}

test "FIFO eviction, expiry, invalidation and clearance fence late replies" {
    var cache = try Cache.init(t.allocator, .{ .max_records = 2, .ttl_ms = 10 }, 1);
    defer cache.deinit();
    const a = try cache.insert(page_a.*, "url-a", test_key, 10);
    const fetch = try cache.beginBodyFetch(page_a.*, a, 11);
    const b = try cache.insert(page_b.*, "url-b", test_key, 12);
    _ = try cache.get(page_a.*, a, 13); // Detail reads do not extend retention.
    const c = try cache.insert(page_a.*, "url-c", test_key, 14);
    try t.expectError(error.RecordExpired, cache.finishBodyFetch(fetch.ticket, .{ .text = "late" }, 15));
    try t.expectEqual(@as(usize, 2), cache.len());
    try cache.invalidateBody(page_b.*, b, 16);
    try t.expectEqual(Body.unavailable, (try cache.get(page_b.*, b, 16)).body);
    try t.expectError(error.BodyNotFetchable, cache.beginBodyFetch(page_b.*, b, 16));
    cache.removePage(page_b.*);
    try t.expectError(error.RecordExpired, cache.get(page_b.*, b, 16));
    try t.expectEqualStrings("url-c", (try cache.get(page_a.*, c, 23)).url);
    try t.expectError(error.RecordExpired, cache.get(page_a.*, c, 24));
    cache.clear();
    const d = try cache.insert(page_a.*, "url-d", null, 25);
    try t.expect(d > c);
    try t.expectEqual(Body.not_requested, (try cache.get(page_a.*, d, 25)).body);
}

test "limits count slots, whole URLs, live correlation and retained text bytes" {
    const budget = 2 * @sizeOf(Slot) + 8;
    var cache = try Cache.init(t.allocator, .{ .max_records = 2, .max_allocated_bytes = budget, .max_url_bytes = 8, .max_body_bytes = 5 }, 0);
    defer cache.deinit();
    const base = cache.allocatedBytes();
    const small_key = Correlation{ .session_id = "s", .request_id = "rr" };
    try t.expectError(error.UrlTooLarge, cache.insert(page_a.*, "123456789", small_key, 0));
    try t.expectError(error.InvalidCorrelation, cache.insert(page_a.*, "abc", .{ .session_id = "s", .request_id = "" }, 0));
    const a = try cache.insert(page_a.*, "12345", small_key, 0);
    try t.expectEqual(budget, cache.allocatedBytes());
    const af = try cache.beginBodyFetch(page_a.*, a, 0);
    try t.expectEqual(budget - 3, cache.allocatedBytes());
    try cache.finishBodyFetch(af.ticket, .{ .text = "four" }, 0);
    try t.expectEqual(Body.unavailable, (try cache.get(page_a.*, a, 0)).body);
    const b = try cache.insert(page_b.*, "abc", small_key, 0);
    try t.expectError(error.RecordExpired, cache.get(page_a.*, a, 0));
    const bf = try cache.beginBodyFetch(page_b.*, b, 0);
    try cache.finishBodyFetch(bf.ticket, .{ .text = "123456" }, 0);
    try t.expectEqual(Body.too_large, (try cache.get(page_b.*, b, 0)).body);
    const c = try cache.insert(page_b.*, "ab", small_key, 0);
    const cf = try cache.beginBodyFetch(page_b.*, c, 0);
    try cache.finishBodyFetch(cf.ticket, .binary, 0);
    try t.expectEqual(Body.unavailable, (try cache.get(page_b.*, c, 0)).body);
    const d = try cache.insert(page_b.*, "u", small_key, 0);
    const df = try cache.beginBodyFetch(page_b.*, d, 0);
    try cache.finishBodyFetch(df.ticket, .{ .text = "bad\xff" }, 0);
    try t.expectEqual(Body.unavailable, (try cache.get(page_b.*, d, 0)).body);
    cache.clear();
    try t.expectEqual(base, cache.allocatedBytes());
}

test "in-flight correlation retirement and expiry never attach a late body" {
    var cache = try Cache.init(t.allocator, .{ .ttl_ms = 10 }, 1);
    defer cache.deinit();
    const a = try cache.insert(page_a.*, "url-a", test_key, 10);
    const first = try cache.beginBodyFetch(page_a.*, a, 11);
    try cache.invalidateBody(page_a.*, a, 12);
    try t.expectError(error.BodyNotFetching, cache.finishBodyFetch(first.ticket, .{ .text = "late" }, 13));
    const b = try cache.insert(page_a.*, "url-b", test_key, 13);
    const second = try cache.beginBodyFetch(page_a.*, b, 14);
    cache.expire(23);
    try t.expectError(error.RecordExpired, cache.finishBodyFetch(second.ticket, .{ .text = "late" }, 15));
    try t.expectEqual(@as(usize, 0), cache.len());
}
