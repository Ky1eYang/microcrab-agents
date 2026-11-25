const std = @import("std");

pub const max_bytes = 4096;
pub const Error = error{ InvalidEndpoint, EndpointTooLong, DiscoveryAuthorityMismatch, DiscoveryTlsDowngrade };
const Scheme = enum {
    bare,
    http,
    https,
    ws,
    wss,

    fn secure(self: Scheme) bool {
        return self == .https or self == .wss;
    }
};

const Host = union(enum) {
    name: []const u8,
    ipv6: [16]u8,

    fn eql(self: Host, other: Host) bool {
        return switch (self) {
            .name => |name| other == .name and std.ascii.eqlIgnoreCase(name, other.name),
            .ipv6 => |addr| other == .ipv6 and std.mem.eql(u8, &addr, &other.ipv6),
        };
    }
};

pub const Endpoint = struct {
    raw: []const u8,
    scheme: Scheme,
    host: Host,
    port: u16,

    pub fn websocket(self: Endpoint) bool {
        return self.scheme == .ws or self.scheme == .wss;
    }

    pub fn discoveryUrl(self: Endpoint, buf: *[max_bytes]u8) Error![]const u8 {
        if (self.websocket()) return error.InvalidEndpoint;
        if (self.scheme == .bare) {
            return std.fmt.bufPrint(buf, "http://{s}/json/version", .{self.raw}) catch error.EndpointTooLong;
        }
        const rest = self.raw[(std.mem.indexOf(u8, self.raw, "://") orelse return error.InvalidEndpoint) + 3 ..];
        const suffix = rest[std.mem.indexOfAny(u8, rest, "/?") orelse rest.len ..];
        if (suffix.len == 0 or std.mem.eql(u8, suffix, "/")) {
            const origin = if (suffix.len == 0) self.raw else self.raw[0 .. self.raw.len - 1];
            return std.fmt.bufPrint(buf, "{s}/json/version", .{origin}) catch error.EndpointTooLong;
        }
        return self.raw;
    }

    // The Host independently enforces this check against the admitted invocation.
    // Do not rewrite a discovered URL or try a fallback target.
    pub fn checkDiscovered(self: Endpoint, raw: []const u8) Error!void {
        const target = try parse(raw);
        if (!target.websocket()) return error.InvalidEndpoint;
        if (!self.host.eql(target.host) or self.port != target.port) return error.DiscoveryAuthorityMismatch;
        if (self.scheme.secure() and !target.scheme.secure()) return error.DiscoveryTlsDowngrade;
    }
};

pub fn parse(raw: []const u8) Error!Endpoint {
    if (raw.len > max_bytes) return error.EndpointTooLong;
    if (raw.len == 0 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidEndpoint;
    for (raw) |c| switch (c) {
        0...32, 127, '#', '\\' => return error.InvalidEndpoint,
        else => {},
    };

    var scheme: Scheme = .bare;
    var remainder = raw;
    if (std.mem.indexOf(u8, raw, "://")) |separator| {
        const name = raw[0..separator];
        const forms = .{ "http", "https", "ws", "wss" };
        inline for (forms) |form| {
            if (std.ascii.eqlIgnoreCase(name, form)) scheme = @field(Scheme, form);
        }
        if (scheme == .bare) return error.InvalidEndpoint;
        remainder = raw[separator + 3 ..];
    }

    const authority_end = std.mem.indexOfAny(u8, remainder, "/?") orelse remainder.len;
    const authority = remainder[0..authority_end];
    const suffix = remainder[authority_end..];
    if (authority.len == 0 or (scheme == .bare and suffix.len != 0)) return error.InvalidEndpoint;
    var port_text: ?[]const u8 = null;
    const host: Host = if (authority[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidEndpoint;
        const literal = authority[1..close];
        if (std.mem.indexOfScalar(u8, literal, '%') != null) return error.InvalidEndpoint;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.InvalidEndpoint;
            port_text = authority[close + 2 ..];
        }
        break :blk .{ .ipv6 = try parseIpv6(literal) };
    } else blk: {
        const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        if (colon < authority.len) port_text = authority[colon + 1 ..];
        const name = authority[0..colon];
        if (name.len == 0 or name.len > 253) return error.InvalidEndpoint;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return error.InvalidEndpoint;
        }
        break :blk .{ .name = name };
    };
    const port = if (port_text) |text| blk: {
        if (text.len == 0) return error.InvalidEndpoint;
        for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidEndpoint;
        const number = std.fmt.parseInt(u16, text, 10) catch return error.InvalidEndpoint;
        if (number == 0) return error.InvalidEndpoint;
        break :blk number;
    } else switch (scheme) {
        .bare => return error.InvalidEndpoint,
        .http, .ws => @as(u16, 80),
        .https, .wss => @as(u16, 443),
    };
    return .{ .raw = raw, .scheme = scheme, .host = host, .port = port };
}

// std.net.Ip6Address depends on the target's socket type layout. This guest
// needs only address comparison; no socket interfaces are linked.
fn parseIpv6(literal: []const u8) Error![16]u8 {
    var groups = [_]u16{0} ** 8;
    var count: usize = 0;
    if (std.mem.indexOf(u8, literal, "::")) |split| {
        try parseGroups(literal[0..split], false, &groups, &count);
        const left_count = count;
        try parseGroups(literal[split + 2 ..], true, &groups, &count);
        if (count >= groups.len) return error.InvalidEndpoint;
        const missing = groups.len - count;
        std.mem.copyBackwards(u16, groups[left_count + missing ..], groups[left_count..count]);
        @memset(groups[left_count .. left_count + missing], 0);
    } else {
        try parseGroups(literal, true, &groups, &count);
        if (count != groups.len) return error.InvalidEndpoint;
    }
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |group, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], group, .big);
    return bytes;
}

test "standard discovery path derives only from HTTP origins and bare authorities" {
    var scratch: [max_bytes]u8 = undefined;
    const cases = .{
        .{ "127.0.0.1:9222", "http://127.0.0.1:9222/json/version" },
        .{ "http://127.0.0.1:9222", "http://127.0.0.1:9222/json/version" },
        .{ "https://[::1]:9222/", "https://[::1]:9222/json/version" },
        .{ "https://browser.example/discover?key=example", "https://browser.example/discover?key=example" },
        .{ "https://browser.example/?key=example", "https://browser.example/?key=example" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try (try parse(case[0])).discoveryUrl(&scratch));
    try std.testing.expectError(error.InvalidEndpoint, (try parse("wss://browser.example/devtools/browser/mock")).discoveryUrl(&scratch));
}

fn parseGroups(text: []const u8, allow_ipv4_tail: bool, groups: *[8]u16, count: *usize) Error!void {
    if (text.len == 0) return;
    var pieces = std.mem.splitScalar(u8, text, ':');
    while (pieces.next()) |piece| {
        if (piece.len == 0 or count.* >= groups.len) return error.InvalidEndpoint;
        if (std.mem.indexOfScalar(u8, piece, '.') != null) {
            if (!allow_ipv4_tail or pieces.next() != null or count.* > groups.len - 2) return error.InvalidEndpoint;
            var octets = std.mem.splitScalar(u8, piece, '.');
            var parsed: [4]u8 = undefined;
            for (&parsed) |*byte| {
                const part = octets.next() orelse return error.InvalidEndpoint;
                if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return error.InvalidEndpoint;
                for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidEndpoint;
                byte.* = std.fmt.parseInt(u8, part, 10) catch return error.InvalidEndpoint;
            }
            if (octets.next() != null) return error.InvalidEndpoint;
            groups[count.*] = std.mem.readInt(u16, parsed[0..2], .big);
            groups[count.* + 1] = std.mem.readInt(u16, parsed[2..4], .big);
            count.* += 2;
        } else {
            if (piece.len > 4) return error.InvalidEndpoint;
            for (piece) |c| if (!std.ascii.isHex(c)) return error.InvalidEndpoint;
            groups[count.*] = std.fmt.parseInt(u16, piece, 16) catch return error.InvalidEndpoint;
            count.* += 1;
        }
    }
}
