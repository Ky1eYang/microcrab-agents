//! Page-scoped capture. Protocol identities and payloads are never Job output.
const std = @import("std");
const details = @import("network_details.zig");
const queue = @import("network_queue.zig");
const Allocator = std.mem.Allocator;
pub const max_filter = 512;
const max_pending = 256;
const max_url = 2048;
const max_id = details.max_protocol_id_bytes;

pub const Pending = struct {
    request: [max_id]u8 = undefined,
    request_len: usize,
    url: [max_url]u8 = undefined,
    url_len: usize,
    status: ?u16,
    body: bool,
};

pub const Capture = struct {
    allocator: Allocator,
    page: details.PageRef,
    session_bytes: [max_id]u8 = undefined,
    session_len: usize,
    target_bytes: [max_id]u8 = undefined,
    target_len: usize,
    prefix: []u8,
    body_prefix: ?[]u8,
    records: details.Cache,
    summaries: queue.Queue,
    pending: []?Pending,
    // Bound retention by FIFO capacity; no wall-clock import is required.
    pub const cache_epoch: u64 = 0;

    pub fn init(a: Allocator, page: details.PageRef, session_id: []const u8, target_id: []const u8, prefix: []const u8, body_prefix: ?[]const u8, generation: u64) !Capture {
        if (session_id.len > max_id or target_id.len > max_id) return error.InvalidRequest;
        const pending = try a.alloc(?Pending, max_pending);
        errdefer a.free(pending);
        @memset(pending, null);
        const owned_prefix = try a.dupe(u8, prefix);
        errdefer a.free(owned_prefix);
        const owned_body = if (body_prefix) |body| try a.dupe(u8, body) else null;
        errdefer if (owned_body) |body| a.free(body);
        var records = try details.Cache.init(a, .{ .ttl_ms = std.math.maxInt(u64) }, generation);
        errdefer records.deinit();
        const summaries = try queue.Queue.init(a, .{ .max_records = 256, .max_allocated_bytes = 32 * 1024 });
        var result: Capture = .{ .allocator = a, .page = page, .session_len = session_id.len, .target_len = target_id.len, .prefix = owned_prefix, .body_prefix = owned_body, .records = records, .summaries = summaries, .pending = pending };
        @memcpy(result.session_bytes[0..session_id.len], session_id);
        @memcpy(result.target_bytes[0..target_id.len], target_id);
        return result;
    }

    pub fn deinit(self: *Capture) void {
        self.records.deinit();
        self.summaries.deinit();
        self.allocator.free(self.pending);
        self.allocator.free(self.prefix);
        if (self.body_prefix) |prefix| self.allocator.free(prefix);
    }

    pub fn session(self: *const Capture) []const u8 {
        return self.session_bytes[0..self.session_len];
    }

    pub fn target(self: *const Capture) []const u8 {
        return self.target_bytes[0..self.target_len];
    }

    fn lookup(self: *Capture, request: []const u8) ?*?Pending {
        for (self.pending) |*slot| {
            if (slot.*) |*value| if (std.mem.eql(u8, request, value.request[0..value.request_len])) return slot;
        }
        return null;
    }

    pub fn response(self: *Capture, request: []const u8, url: []const u8, mime: []const u8, status: ?u16) !void {
        // CDP may reuse a request ID across redirects. A new response must
        // invalidate its predecessor even if the new URL does not match.
        if (self.lookup(request)) |slot| slot.* = null;
        if (!std.mem.startsWith(u8, url, self.prefix)) return;
        if (request.len > max_id or url.len > max_url) return self.summaries.noteDrop();
        for (self.pending) |*slot| {
            if (slot.* != null) continue;
            var entry: Pending = .{ .request_len = request.len, .url_len = url.len, .status = status, .body = if (self.body_prefix) |prefix| std.mem.startsWith(u8, url, prefix) and textMime(mime) else false };
            @memcpy(entry.request[0..request.len], request);
            @memcpy(entry.url[0..url.len], url);
            slot.* = entry;
            return;
        }
        try self.summaries.noteDrop();
    }

    pub fn finish(self: *Capture, request: []const u8, completed: bool) !void {
        const slot = self.lookup(request) orelse return;
        defer slot.* = null;
        const entry = &slot.*.?;
        if (self.summaries.isFull()) return self.summaries.noteDrop();
        const record = self.records.insert(self.page, entry.url[0..entry.url_len], if (entry.body and completed) .{
            .session_id = self.session(),
            .request_id = request,
        } else null, cache_epoch) catch return self.summaries.noteDrop();
        _ = try self.summaries.offer(.{ .page_ref = self.page, .record_id = record, .outcome = if (completed) .request_finished else .request_failed, .http_status = entry.status });
    }
};

fn textMime(mime: []const u8) bool {
    const media = mime[0 .. std.mem.indexOfScalar(u8, mime, ';') orelse mime.len];
    return std.mem.startsWith(u8, media, "text/") or std.mem.eql(u8, media, "application/json") or std.mem.endsWith(u8, media, "+json") or std.mem.eql(u8, media, "application/xml") or std.mem.endsWith(u8, media, "+xml") or std.mem.eql(u8, media, "application/javascript");
}
