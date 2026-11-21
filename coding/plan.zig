//! PLAN's fixed Markdown header. This is not an arbitrary YAML reader.
const std = @import("std");
const Allocator = std.mem.Allocator;
const eq = std.mem.eql;
const startsWith = std.mem.startsWith;
const title_bytes = 160;
const description_bytes = 512;
const session_bytes = 256;
const scalar_expansion = 6; // Longest escape of one input byte: \u00XX.
const opening = "---\n";
const closing = "---\n";
const edited_key = "edited_at_unix_ms: ";

pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > session_bytes or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |ch| if (std.ascii.isControl(ch)) return false;
    return true;
}

pub fn markdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md");
}

/// Detect a leading frontmatter lookalike even after a UTF-8 BOM, blank lines,
/// indentation or CRLF. A separator later in normal Markdown is not frontmatter.
pub fn suppliedHeader(body: []const u8) bool {
    var lines: Lines = .{ .rest = body };
    while (lines.next()) |raw| {
        var line = trim(raw);
        if (startsWith(u8, line, "\xef\xbb\xbf")) line = trim(line[3..]);
        if (line.len == 0) continue;
        return startsWith(u8, line, "---") or startsWith(u8, line, "...") or
            startsWith(u8, line, "%YAML") or startsWith(u8, line, "%TAG");
    }
    return false;
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t");
}

const Lines = struct {
    rest: []const u8,

    fn next(self: *Lines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfAny(u8, self.rest, "\r\n") orelse self.rest.len;
        const line = self.rest[0..end];
        self.rest = if (end == self.rest.len) "" else if (startsWith(u8, self.rest[end..], "\r\n")) self.rest[end + 2 ..] else self.rest[end + 1 ..];
        return line;
    }
};

fn bounded(limit: usize, value: []const u8) []const u8 {
    var end = @min(value.len, limit);
    while (end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

fn sameRun(line: []const u8, ch: u8) usize {
    for (line, 0..) |c, i| if (c != ch) return i;
    return line.len;
}

fn indented(raw: []const u8) bool {
    const prefix = raw[0 .. raw.len - std.mem.trimLeft(u8, raw, " \t").len];
    return prefix.len >= 4 or std.mem.indexOfScalar(u8, prefix, '\t') != null;
}

fn marker(line: []const u8, len: usize) bool {
    return len == line.len or line[len] == ' ' or line[len] == '\t';
}

fn thematic(line: []const u8) bool {
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var count: usize = 0;
    for (line) |c| {
        if (c == ch) count += 1 else if (c != ' ' and c != '\t') return false;
    }
    return count >= 3;
}

const Fence = struct { ch: u8, len: usize };

const Metadata = struct {
    title: []const u8,
    description: std.BoundedArray(u8, description_bytes),
};

fn derive(path: []const u8, body: []const u8) Metadata {
    const basename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| path[index + 1 ..] else path;
    var info: Metadata = .{ .title = bounded(title_bytes, if (basename.len > 3) basename[0 .. basename.len - 3] else basename), .description = .{} };
    var lines: Lines = .{ .rest = if (startsWith(u8, body, "\xef\xbb\xbf")) body[3..] else body };
    var heading_found = false;
    var description_done = false;
    var fence: ?Fence = null;
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (fence) |active| {
            const run = sameRun(line, active.ch);
            if (!indented(raw) and run >= active.len and trim(line[run..]).len == 0) fence = null;
            continue;
        }
        var paragraph_line = false;
        if (line.len != 0 and !indented(raw)) {
            const ch = line[0];
            const run = sameRun(line, ch);
            if ((ch == '`' or ch == '~') and run >= 3) {
                fence = .{ .ch = ch, .len = run };
            } else if (ch == '#' and run <= 6 and marker(line, run)) {
                if (!heading_found and run == 1) {
                    const text = trim(line[run..]);
                    const without_hashes = std.mem.trimRight(u8, text, "#");
                    const heading = if (without_hashes.len < text.len and (without_hashes.len == 0 or trim(without_hashes).len < without_hashes.len)) trim(without_hashes) else text;
                    if (heading.len != 0) {
                        info.title = bounded(title_bytes, heading);
                        heading_found = true;
                    }
                }
            } else {
                const digits = std.mem.indexOfNone(u8, line, "0123456789") orelse line.len;
                const list = ((ch == '-' or ch == '*' or ch == '+') and marker(line, 1)) or
                    (digits > 0 and digits <= 9 and digits < line.len and (line[digits] == '.' or line[digits] == ')') and marker(line, digits + 1));
                paragraph_line = ch != '>' and !list and !thematic(line);
                // Recognize the common single-line Setext H1/H2 form too.
                if (paragraph_line) {
                    var lookahead = lines;
                    if (lookahead.next()) |next_raw| {
                        const next = trim(next_raw);
                        if (next.len != 0 and !indented(next_raw) and
                            (next[0] == '=' or next[0] == '-') and sameRun(next, next[0]) == next.len)
                        {
                            if (next[0] == '=' and !heading_found) {
                                info.title = bounded(title_bytes, line);
                                heading_found = true;
                            }
                            paragraph_line = false;
                            lines = lookahead;
                        }
                    }
                }
            }
        }
        if (!description_done) {
            if (paragraph_line) {
                if (info.description.len != 0 and info.description.len < description_bytes) info.description.appendAssumeCapacity(' ');
                const prefix = bounded(description_bytes - info.description.len, line);
                info.description.appendSliceAssumeCapacity(prefix);
                if (prefix.len != line.len) description_done = true;
            } else if (info.description.len != 0) description_done = true;
        }
        if (heading_found and description_done) break;
    }
    return info;
}

// Zig's default JSON string writer escapes C0, quotes and backslashes. Also
// escape DEL/C1 here: literal C1 is not clean YAML, and escaping all Unicode via
// JSON would emit surrogate pairs for non-BMP scalars instead of literal UTF-8.
fn scalar(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch < 0x7f) continue;
        const len = std.unicode.utf8ByteSequenceLength(ch) catch unreachable; // Inputs have been validated as UTF-8.
        const codepoint = std.unicode.utf8Decode(value[i..][0..len]) catch unreachable;
        if ((codepoint >= 0x7f and codepoint <= 0x9f) or codepoint == 0x2028 or codepoint == 0x2029 or
            codepoint == 0xfeff or codepoint == 0xfffe or codepoint == 0xffff)
        {
            try std.json.encodeJsonStringChars(value[start..i], .{}, writer);
            try writer.print("\\u{x:0>4}", .{codepoint});
            start = i + len;
        }
        i += len - 1;
    }
    try std.json.encodeJsonStringChars(value[start..], .{}, writer);
    try writer.writeByte('"');
}

fn field(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.writeAll(key);
    try scalar(writer, value);
    try writer.writeByte('\n');
}

fn edited(writer: anytype, time: u64) !void {
    try writer.print(edited_key ++ "\"{d}\"\n" ++ closing, .{time});
}

pub fn create(scratch: Allocator, path: []const u8, body: []const u8, session_id: []const u8, observed_at_unix_ms: u64) Allocator.Error![]const u8 {
    const info = derive(path, body);
    var out = std.ArrayList(u8).init(scratch);
    errdefer out.deinit();
    try out.appendSlice(opening);
    try field(out.writer(), "title: ", info.title);
    try field(out.writer(), "description: ", info.description.constSlice());
    try field(out.writer(), "session_id: ", session_id);
    try edited(out.writer(), observed_at_unix_ms);
    try out.appendSlice(body);
    return out.toOwnedSlice();
}

const HeaderError = error{ MalformedHeader, OtherSession } || Allocator.Error;

fn takeLine(remaining: *[]const u8, comptime max: usize) error{MalformedHeader}![]const u8 {
    const lf = std.mem.indexOfScalar(u8, remaining.*[0..@min(remaining.len, max + 1)], '\n') orelse return error.MalformedHeader;
    const line = remaining.*[0..lf];
    remaining.* = remaining.*[lf + 1 ..];
    return line;
}

fn parseField(scratch: Allocator, remaining: *[]const u8, comptime name: []const u8, comptime max: usize) HeaderError![]const u8 {
    const key = name ++ ": ";
    const line = try takeLine(remaining, key.len + max * scalar_expansion + 2);
    if (!startsWith(u8, line, key)) return error.MalformedHeader;
    const encoded = line[key.len..];
    if (encoded.len < 2 or encoded[0] != '"' or encoded[encoded.len - 1] != '"') return error.MalformedHeader;
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, encoded, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedHeader,
    };
    if (value != .string or value.string.len > max or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.MalformedHeader;
    var buf: [max * scalar_expansion + 2]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    scalar(stream.writer(), value.string) catch return error.MalformedHeader;
    if (!eq(u8, encoded, stream.getWritten())) return error.MalformedHeader;
    return value.string;
}

pub const Verified = struct {
    prefix: []const u8,
    body: []const u8,

    pub fn refresh(self: Verified, scratch: Allocator, body: []const u8, time: u64) Allocator.Error![]const u8 {
        var out = std.ArrayList(u8).init(scratch);
        errdefer out.deinit();
        try out.appendSlice(self.prefix);
        try edited(out.writer(), time);
        try out.appendSlice(body);
        return out.toOwnedSlice();
    }
};

/// Exact generated format and equality with the admitted Session ID, not a
/// signature against malicious writes by already-authorized external actors.
pub fn verify(scratch: Allocator, file: []const u8, session_id: []const u8) HeaderError!Verified {
    if (!startsWith(u8, file, opening)) return error.MalformedHeader;
    var remaining = file[opening.len..];
    if ((try parseField(scratch, &remaining, "title", title_bytes)).len == 0) return error.MalformedHeader;
    _ = try parseField(scratch, &remaining, "description", description_bytes);
    const owner = try parseField(scratch, &remaining, "session_id", session_bytes);
    const prefix = file[0 .. file.len - remaining.len];
    const time = try parseField(scratch, &remaining, "edited_at_unix_ms", 20);
    if (time.len == 0 or (time.len > 1 and time[0] == '0')) return error.MalformedHeader;
    for (time) |ch| if (!std.ascii.isDigit(ch)) return error.MalformedHeader;
    _ = std.fmt.parseInt(u64, time, 10) catch return error.MalformedHeader;
    if (!startsWith(u8, remaining, closing)) return error.MalformedHeader;
    const body = remaining[closing.len..];
    if (suppliedHeader(body)) return error.MalformedHeader;
    if (!eq(u8, owner, session_id)) return error.OtherSession;
    return .{ .prefix = prefix, .body = body };
}
