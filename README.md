# MicroCrab Agents

A1 is the independent Zig build foundation, **not a working Zig Coding agent**.
Core still builds and supplies the existing Rust Coding and Universal components.
This repository is not registered in the superproject and does not stage or
publish runtime artifacts. Existing Sessions retain their exact component pins.

## Local verification

Use **Zig 0.13.0**. `zig build` defaults to the native memory tests; the additional
checks require Node.js or `wasm-tools` on `PATH` as noted below.

```sh
zig build test                                  # native allocator tests
zig build test-wasm                             # core Wasm allocator smoke test (Node.js)
zig build check-wit -Dcore=/path/to/microcrab-core # byte drift + WIT parsing (bash, wasm-tools)
```

The [Coding world](wit/world.wit), [Agent ABI 0.8](wit/deps/agent/agent.wit) and
[Host ABI](wit/deps/host/host.wit) are byte-for-byte mirrors, not new contract
sources. [The drift check](tools/check-wit.sh) compares them with the supplied
Core checkout and never rewrites either repository.

The [allocator helper](shared/abi_memory.zig) tests owned-memory allocation,
reallocation, and release independently of Wasm. The [Wasm boundary](shared/wasm_abi.zig)
exports `cabi_realloc`, traps on failure, and uses the freestanding allocator.
The Wasm test instantiates a core module with no imports and exactly `memory`
and `cabi_realloc` exported. It does not exercise the Agent ABI or produce a
Coding Component.

## Component pipeline and parity gates

Once a real guest exists, it can be passed to the explicit packaging target:

```sh
zig build component -Dcore=/path/to/microcrab-core -Dcoding-guest=path/to/guest.zig
```

The [build](build.zig) compiles an entryless `wasm32-freestanding` core module
in `ReleaseSmall`. A guest can import `wasm_abi` (for example,
`comptime { _ = @import("wasm_abi"); }`) and must implement the actual Agent 0.8
exports: `init`, `describe`, `invoke`, and `drive`. After a passing drift check,
`wasm-tools` embeds the `coding` world with UTF-8 strings, composes the component,
then validates and extracts its WIT before copying the build output to
`zig-out/coding.component.wasm` (or the explicit Zig build prefix). This is not
runtime installation. A1 supplies no guest source, substitute exports, or fake
worker. Without a guest, `component` fails explicitly.

1. **Bindings and lifecycle:** implement and exercise all four canonical entry
   points in Core's runtime. Verify layout, result lifting, post-return frees,
   and owned/borrowed handles separately from guest behavior.
2. **Sandbox adapter parity:** compare capability-shaped catalogs and modes,
   empty-capability behavior, typed attachments and failures, buffered output
   and continuation/cancellation/cleanup with Rust Coding in controlled Host
   fixtures. Core and the Host remain the authorization and lifecycle owners;
   the Zig guest must not add new authority or behavior.
3. **Integration after parity (A2):** separately verify explicit catalog
   selection in the actual Host, a representative tool-driven turn and failure,
   Rust Universal as a control, and pinned historical component resolution
   (including concrete failure for missing bytes). Only then consider default
   build dispatch changes. Component validation alone does not establish parity.
