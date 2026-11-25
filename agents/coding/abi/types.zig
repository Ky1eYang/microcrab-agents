//! Zig-native values for the Core-owned Coding world. These are not wire layouts.
//! Keep record fields and variant cases in WIT order: the canonical encoder
//! uses declaration order, independently of Zig's in-memory representation.

pub fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum) { ok: Ok, err: Err };
}

pub const ToolFailure = struct {
    kind: enum { failed, timeout, cancelled },
    code: []const u8,
    message: []const u8,
    retryable: bool,
};

// A resource-table index is not the same as a Host process identity.
// Keep the two Agent resource transfer modes distinct at the Zig boundary.
pub const BorrowedBuffer = struct { index: u32 };
pub const OwnedBuffer = struct {
    index: ?u32,

    pub fn borrow(self: *const OwnedBuffer) BorrowedBuffer {
        return .{ .index = self.index orelse @trap() };
    }

    pub fn take(self: *OwnedBuffer) OwnedBuffer {
        const index = self.index orelse @trap();
        self.index = null;
        return .{ .index = index };
    }
};

pub const MediaAttachment = struct { media_type: []const u8, data: []const u8 };
pub const FinalOutput = struct {
    content: []const u8,
    failure: ?ToolFailure = null,
    attachments: []const MediaAttachment = &.{},
};
pub const BufferedOutput = struct { output: OwnedBuffer, include_initial: bool };
pub const ToolOutput = union(enum) { final: FinalOutput, buffered: BufferedOutput };
pub const ContentKind = union(enum) { text: void, bytes: []const u8 };
pub const OutputChannel = struct {
    name: []const u8,
    kind: ContentKind,

    pub fn text(name: []const u8) OutputChannel {
        return .{ .name = name, .kind = .{ .text = {} } };
    }
};
pub const ProcessSource = enum { raw_pipes, shell_text };
pub const DriverStep = struct { state: []const u8, wake_after_ms: u64, finished: bool };
pub const InitError = struct { code: []const u8, message: []const u8 };
pub const InitResult = union(enum) { ready: void, failed: InitError };
pub const DescribeResult = Result([]const u8, []const u8);
pub const InvokeResult = Result(ToolOutput, ToolFailure);
pub const DriveResult = Result(DriverStep, ToolFailure);
pub const CommunicationError = struct {
    code: enum { absent, unavailable, rejected, cancelled },
    message: []const u8,
};

pub const Visibility = enum { visible, invisible, secret };
pub const Persistence = enum { persisted, ephemeral };
pub const Role = enum { runtime, client, agent };
pub const VariableEntry = struct { name: []const u8, value_json: []const u8 };
pub const MetadataEntry = struct {
    name: []const u8,
    visibility: Visibility,
    persistence: Persistence,
    owner: Role,
    editors: []const Role,
};
pub const ScopedEntry = struct {
    name: []const u8,
    value_json: []const u8,
    visibility: Visibility,
    persistence: Persistence,
    editors: ?[]const Role,
};
pub const VariableChangeSet = struct {
    set: []const VariableEntry,
    remove: []const []const u8,
    scoped_set: []const ScopedEntry,
};
pub const CallFacts = struct {
    session_id: []const u8,
    admitted_mode: ?[]const u8,
    observed_at_unix_ms: u64,
};

pub const OperationError = struct {
    code: enum { denied, invalid_request, unsupported, conflict, limit, cancelled, timeout, io },
    message: []const u8,
};
pub const HostError = struct {
    category: enum { not_found, permission, timeout, cancelled, conflict, unsupported, io },
    retryable: bool,
    message: []const u8,
};

pub const ReadRequest = struct { path: []const u8, offset_line: u64, max_lines: u64, max_bytes: u64 };
pub const ReadOutput = struct {
    content: []const u8,
    start_line: u64,
    next_line: ?u64,
    truncated: bool,
    version: []const u8,
};
pub const WritePrecondition = union(enum) { missing: void, version: []const u8 };
pub const WriteRequest = struct {
    path: []const u8,
    content: []const u8,
    precondition: WritePrecondition,
};
pub const WriteOutput = struct { version: []const u8, bytes: u64 };
pub const DeleteRequest = struct { path: []const u8, expected_version: []const u8 };
pub const MoveRequest = struct {
    path: []const u8,
    destination: []const u8,
    expected_version: []const u8,
    content: []const u8,
};
pub const FileMutation = union(enum) { write: WriteRequest, delete: DeleteRequest, move: MoveRequest };
pub const MutationOutput = struct {
    version: ?[]const u8,
    bytes: u64,
    source_removed: bool,
    destination_written: bool,
    diagnostic: ?[]const u8,
};
pub const GlobRequest = struct {
    root: []const u8,
    pattern: []const u8,
    include_hidden: bool,
    include_ignored: bool,
    include_directories: bool,
    max_results: u64,
};
pub const GlobEntry = struct { path: []const u8, kind: enum { file, directory, symlink } };
pub const GlobOutput = struct { entries: []const GlobEntry, truncated: bool };
pub const GlobScanReason = enum { entries, depth };
pub const GlobScanIncomplete = struct { reason: GlobScanReason, limit: u32, observed: u32 };
pub const ResolvedGlobOutput = struct {
    entries: []const GlobEntry,
    truncated: bool,
    scan_incomplete: ?GlobScanIncomplete = null,
};
pub const GrepRequest = struct {
    root: []const u8,
    pattern: []const u8,
    include_glob: ?[]const u8,
    case_sensitive: bool,
    literal: bool,
    max_matches: u64,
    max_bytes: u64,
};
pub const GrepMatch = struct { path: []const u8, line: u64, text: []const u8 };
pub const GrepOutput = struct { matches: []const GrepMatch, truncated: bool };

pub const ProcessHandle = struct { id: u64, pid: ?u32 };
pub const ProcessSignal = enum { term, kill, int, hup, usr1, usr2 };
pub const ExitStatus = struct { code: ?i32, signal: ?ProcessSignal };
pub const ProcessState = union(enum) { running: void, exited: ExitStatus, failed: []const u8 };
pub const ProcessStatus = struct { pid: ?u32, state: ProcessState, elapsed_s: f64 };
pub const ShellRequest = struct { command: []const u8, cwd: ?[]const u8 };
pub const ShellOutput = struct { stdout: []const u8, stderr: []const u8, truncated: bool };
