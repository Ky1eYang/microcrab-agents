# MicroCrab Agents

This independent workspace contains the opt-in Zig 0.13.0 Coding Component and
its verification fixtures. It does **not** select Zig by default: Core still
supplies the existing Rust Coding and Universal components. Existing Sessions
retain their exact component and discovery pins. Nothing here stages or publishes
runtime artifacts.

## Local verification

Use **Zig 0.13.0**. Formatting, native tests and core Wasm smoke tests:

```sh
zig fmt --check build.zig build.zig.zon shared coding coding_abi tests
zig build test                                    # Native tool, catalog and ABI tests; default
zig build test-wasm                               # Core Wasm allocator smoke (Node.js)
zig build check-wit -Dcore=/path/to/microcrab-core  # bash + wasm-tools
zig build test-coding-abi -Dcore=/path/to/microcrab-core # Node.js + wasm-tools
```

The [Coding world](wit/world.wit) selects imports from byte-for-byte mirrors of
[Agent ABI 0.8](wit/deps/agent/agent.wit), [Host ABI](wit/deps/host/host.wit) and
[Session Variables 0.2](wit/deps/session-scoped/scoped-variables.wit). The
[drift check](tools/check-wit.sh) never rewrites either repository.
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

## Building the explicit candidate

See the [ABI contract](docs/zig-coding-abi.md) for kernel boundaries, callback
signatures and buffer ownership. Build the included Zig guest explicitly:

```sh
zig build component -Dcore=/path/to/microcrab-core
```

In plan mode, `write` may atomically create a missing lowercase `.md` without
`expected_version`. The guest derives the title and description from the body,
and uses the exact admitted Session ID and UTC Unix milliseconds in its YAML
frontmatter. `edit` accepts the generated header only for the same Session,
changes the body with the normal version check, and refreshes the edit time.
Frontmatter is not a cryptographic provenance signature. The actual linked shell
and single-file `patch` default to Ask, and `apply_patch` remains Deny. Build
mode and Host restrictions are unchanged. Typed Session Variables 0.2 supplies
read-only `tool-call-facts`; the admitted mode is distinct from the latest State
mode. Build and use this Component with a matching Server. Enable it in a
disposable Server catalog with an explicit path
and select its exact Component digest when creating a new Session. Where historical
Rust Coding Sessions must remain usable, retain their original bytes in the catalog
and use `restore_only` as appropriate. Never write Zig bytes over a pinned Rust file.

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
