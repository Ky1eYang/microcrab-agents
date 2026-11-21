# Zig Coding ABI handoff

The [Coding world](../agents/coding/wit/world.wit) imports byte-for-byte mirrors
of the canonical Core interfaces. Zig tool ports use
`const abi = @import("coding_abi");` and [Zig-native DTOs](../agents/coding/abi/types.zig):
WIT names use `snake_case`, options use Zig `?T`, lists use slices, and replies
use tagged `.ok` / `.err`. Neither a Host error nor a mutation receipt is
converted into a Zig error set or interpreted by the binding.

Use `abi.host.<interface>.<method>(scratch, ...)`. Z2 uses `text_read.read`,
`glob.glob`, `grep.grep`, `text_write.write`, and `cache_points.capture`. Z3
uses `file_mutation.preflight` and `.mutate`. Z4 uses `filesystem.stat`,
`.openRead`, `.read`, `.close`, `shell.launch`, `.read`, `.drain`, `.write`,
`process.status`, `.waitForState`, `.release`, `.killTree`, and `abi.execution`.
Host discovery uses `abi.host.hostInfo(scratch)`. Arguments after the allocator
match WIT, with `openRead` fixing the read-only flag. No adapter selects a shell
or grants a Host operation. Results including
error messages are copied into `scratch`; pass an arena scoped to the callback.
For native tool tests, inject a mock at the tool's adapter boundary instead of
introducing native effects into the guest binding.

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

`execution.create` gives the callback an `OwnedBuffer`. Borrow it with
`buffer.borrow()` for operations. Use `buffer.take()` exactly once to transfer
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
The default Rust Coding and Universal are unchanged.
