# Zig Coding ABI handoff

The [Coding world](../agents/coding/wit/world.wit) imports byte-for-byte mirrors
of the canonical Core interfaces. Zig tool ports use
`const abi = @import("coding_abi");` and [Zig-native DTOs](../agents/coding/abi/types.zig):
WIT names use `snake_case`, options use Zig `?T`, lists use slices, and replies
use tagged `.ok` / `.err`. Neither a Host error nor a mutation receipt is
converted into a Zig error set or interpreted by the binding.

Use `abi.host.<interface>.<method>(scratch, ...)`. Production Coding 0.5.0
uses `file_versions.read`, `.write`, `.preflight`, and `.mutate` through the
[Session file versions adapter](../agents/coding/wit/deps/session-scoped/file-versions.wit).
Read returns both its internal exact version and the model-facing reference.
Writes and committed patches project a scoped reference only after acknowledgment;
exact Host operations and cache points do not change. The detached compatibility
probe keeps the old exact `text-read` import in its separate test WIT world.
Production Coding also uses `glob_ignore.globWithIgnoredPaths`, `grep.grep`, and
`cache_points.capture`. The shell uses `shell.launch`, `.read`, `.drain`, `.write`,
`process.status`, `.waitForState`, `.release`, `.killTree`, and `abi.execution`.
The guest does not offer `read_image` or import the raw Host filesystem interface.
Host discovery uses `abi.host.hostInfo(scratch)`. Arguments after the allocator
match WIT. No adapter selects a shell or grants a Host operation. Results including
error messages are copied into `scratch`; pass an arena scoped to the callback.
For native tool tests, inject a mock at the tool's adapter boundary instead of
introducing native effects into the guest binding.

Coding 0.5.0 uses the additive resolved-path operations of Core's
`glob-ignore@0.1.0` service. Init gets a complete bounded list of concrete
workspace-relative paths, marking ignored directory subtrees with trailing `/`,
and publishes it as Agent-owned, visible, persisted `glob_ignored`, with Client
as an authorized editor. It does not publish ignore rule text. A Host `limit`
becomes an `incomplete` status; any other resolution failure becomes
`unavailable`. These are status objects, not empty lists, and contain a safe
reason code, not a Host error message. A rejected State write fails init.

Omitting `ignored_list` selects the current visible `glob_ignored` through
Core's dispatch-time variable substitution. An explicit list replaces the
default; `[]` disables filtering; missing, malformed or incomplete resolved
values do not become `[]`. It neither collects rules again nor calls legacy glob.
New nodes are not automatically added to the list, though newly created
nodes beneath an excluded directory remain excluded. `truncated` reports
only omitted matching output. An optional `scan_incomplete` reports scan
ceilings and how to narrow the query. Earlier pinned Coding guests keep their
original rule-based contract, and grep's import and behavior do not change.

The catalog advertises these version-bearing operations only when Runtime exposes
`file_versions_v1` and the corresponding Host capability. A compatible Session
Journal owns the durable reference mapping; the guest never creates or resolves
aliases. Model inputs use `fv_` plus 16, 20, or 24 lowercase hex digits, or an
explicit full SHA-256 compatibility input. A reference binds to the Session, Host,
canonical path and lineage/epoch; it is not proof of write authority. Same-authority
reopen can reuse references. Fork, rollback, a changed Host or a new epoch require
a new read. Never replay a mutation after uncertain acknowledgment.

The catalog/entry integrator supplies four public callbacks and wires them with
`comptime { abi.exportAgent(@This()); }`. Their signatures are:

```zig
pub fn init(scratch: std.mem.Allocator) abi.types.InitResult
pub fn describe(scratch: std.mem.Allocator, host_info: []const u8) abi.types.DescribeResult
pub fn invoke(scratch: std.mem.Allocator, host_info: []const u8, name: []const u8,
    arguments: []const u8) abi.types.InvokeResult
pub fn drive(scratch: std.mem.Allocator, output: abi.types.BorrowedBuffer, state: []const u8,
    cancelled: bool) abi.types.DriveResult
```

Treat callback parameters as call-scoped. Input copies must not be stored across
calls; use the WIT continuation state for data that survives. Returned strings
and lists may borrow call inputs, use `scratch`, or refer to constants; the
binding copies return data before reclaiming the call arena. Do not return
slices backed by a local array or a runtime-built array literal; that stack
storage is gone before lowering begins.

`execution.create` takes Agent 0.9 `output-channel` records and gives the
callback an `OwnedBuffer`. Coding declares only text channels and retains
shell processes with the `shell-text` source. It does not import the private
shell launch operation. Borrow the buffer with `buffer.borrow()` for operations. Use `buffer.take()` exactly once to transfer
ownership in `.ok = .{ .buffered = ... }`; defer `abi.execution.drop(&buffer)`
to close an untransferred buffer on early exits. Zig structs are copyable; do
not duplicate owners. A `drive` callback receives only a borrow. The ABI
closes its scoped canonical table entry when the callback returns; the
underlying Runtime buffer remains owned by Runtime. Host process
and file handles are scoped identities, not WIT resources: their lifecycle is
explicitly controlled by the existing Host/Runtime operations.

This binding does not implement tool arguments or policy. The
[catalog](../agents/coding/src/catalog.zig) defines the actual tool permissions,
including PLAN's Session-bound Markdown exceptions and Ask for the linked shell.
The independently built Coding guest does not set the Runtime's default Agent.

## Coding 0.2.0 Component verification

Built on Linux x86_64 with Zig 0.13.0 and wasm-tools 1.263.0 against
Core `e4f69e1940f2941f6cbe0bd0b13b04bddaeb3938` in a temporary prefix outside
Runtime. The root and package entry points produced byte-identical ReleaseSmall
Components (249,151 bytes, SHA-256
`bde3df9276f97c0e87f61717b21b6d91d020a9bcacf1e4e75e372072a801cdfb`).

Formatting, all 41 native tests at each entry point, the freestanding WASM
smoke test, the Node ABI wire probe, and vendored and canonical WIT/Component
verification passed. The generated Component imports Agent 0.9 and does not
import raw Host filesystem or private shell launch. This hash records a
verified build, not a published or installed Runtime pin.
