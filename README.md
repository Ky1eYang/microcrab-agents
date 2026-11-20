# MicroCrab Agents

This workspace contains the Zig 0.13.0 Coding ABI and its verification fixtures.
It does **not** select a Zig Coding agent. Core still supplies the existing Rust
Coding and Universal components by default. Existing Sessions retain their exact
component pins. Nothing here stages or publishes runtime artifacts.

## Local verification

Use **Zig 0.13.0**. Formatting, native tests and core Wasm smoke tests:

```sh
zig fmt --check build.zig build.zig.zon shared coding_abi tests
zig build test                                    # Native memory/layout tests; default
zig build test-wasm                               # Core Wasm allocator smoke (Node.js)
zig build check-wit -Dcore=/path/to/microcrab-core  # bash + wasm-tools
zig build test-coding-abi -Dcore=/path/to/microcrab-core # Node.js + wasm-tools
```

The [Coding world](wit/world.wit), [Agent ABI 0.8](wit/deps/agent/agent.wit) and
[Host ABI](wit/deps/host/host.wit) are byte-for-byte mirrors, not new contract
sources. The [drift check](tools/check-wit.sh) never rewrites either repository.
`test-coding-abi` compiles a [test-only probe](tests/abi_probe.zig), checks wire
values and ownership in a [Node.js witness](tools/test-coding-abi.mjs), and links
and validates a real component against the Coding world. Test outputs remain in
Zig's build cache and are not installable products. The Node fixture is not a
substitute for Runtime/Host parity tests.

For a real Core ABI smoke test, run the [isolated probe script](tools/test-core-abi.sh)
with an initialized superproject, a Core checkout, and the pinned Zig executable:

```sh
bash tools/test-core-abi.sh /path/to/microcrab /path/to/microcrab-core /path/to/zig
```

It archives the selected committed Core source into the Agents build cache,
uses a separate Rust target directory, and runs a locked/offline Core test
through the root `xtask`. It exercises typed discovery/init, a constrained
LocalHost read, rejection of an out-of-root path, owned buffered output transfer,
and borrowed `drive` through completion. It does not change Core or stage any
runtime bytes.

## Supplying a real guest

See the [port handoff](docs/zig-coding-abi.md) for the `coding_abi` module,
callback signatures and ownership rules. An explicit guest can be built with:

```sh
zig build component -Dcore=/path/to/microcrab-core -Dcoding-guest=path/to/guest.zig
```

The [build](build.zig) compiles an entryless `wasm32-freestanding` core module
in `ReleaseSmall`. `wasm-tools` embeds the Coding world with UTF-8 strings,
composes it, validates it, extracts its WIT, and checks world conformance before
copying it to `zig-out/coding.component.wasm` (or the explicit Zig build prefix).
This is a build output, not runtime selection, installation or staging.

Before promotion, verify the real guest in Core with constrained Host adapters,
then compare it against Rust Coding through actual Server catalog selection and
fixture-driven turns. Include cancellation, uncertain/partial mutations,
attachment and buffer cleanup, pinned historical component resolution, and Rust
Universal as a control. Default promotion requires a separate decision.
