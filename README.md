# MicroCrab Agents

Zig-based WebAssembly Component agents for MicroCrab, with independently
buildable Agent packages and shared ABI tooling.

The [Coding Agent](<agents/coding/>) provides Host-scoped coding tools,
PLAN/BUILD policies, and buffered shell execution. The opt-in
[Browser Agent](<agents/browser/README.md>) observes an explicitly supplied
browser over the selected native Bridge, without controlling its lifecycle.
Building this repository does not select or install an Agent in MicroCrab.
[MicroCrab Core](https://github.com/Ky1eYang/microcrab-core) owns the Runtime and
still supplies its Rust Coding and Universal implementations.

## Build and test

Use **Zig 0.13.0** exactly. Wasm smoke and wire tests use Node.js; component
checks use **wasm-tools 1.263.0**; Core drift scripts also use Bash. From the
repository root:

```sh
zig fmt --check build.zig build.zig.zon agents shared
zig build test
zig build test-wasm
zig build check-vendored-component
```

Or invoke the same Coding package directly from a full clone:

```sh
cd agents/coding
zig build test
zig build check-vendored-component
```

Each Agent owns its `build.zig.zon`, guest code, tests and WIT world. The
repository root aggregates builds; `shared/` contains common ABI memory code.
Package-directory builds intentionally use local dependencies in the same
checkout; a detached Agent subdirectory is not a self-contained distribution.
The unsuffixed root steps above remain Coding-only. See the
[Browser verification commands](<agents/browser/README.md#L9-L24>) for the
explicit Browser test, check, and component steps.

## Verify against Core and produce a Component

Use a Core checkout matching the target Server. At the repository root or in
`agents/coding`, with an absolute Core path:

```sh
zig build check-wit -Dcore=/path/to/microcrab-core
zig build test-coding-abi -Dcore=/path/to/microcrab-core
zig build check-component -Dcore=/path/to/microcrab-core
zig build component -Dcore=/path/to/microcrab-core
```

The resulting `zig-out/coding.component.wasm` (or the file under `--prefix`)
is an entryless `wasm32-freestanding` component built with `ReleaseSmall`.
Component verification includes validation and WIT world conformance. The
vendored-WIT check requires no Core checkout but does not certify compatibility
with Core; neither a WIT check nor a Node.js witness replaces a Runtime test.
The [isolated Core probe](agents/coding/tools/test-core-abi.sh) additionally
exercises discovery, Host confinement and buffered lifecycle through the real
Runtime. See [ABI notes](docs/zig-coding-abi.md) for ownership and test guidance.

## Runtime selection

Select the Zig Component explicitly in a compatible Server catalog. Existing
Sessions retain their exact Component and discovery pins; keep original bytes
where historical restores are required. Do not overwrite a pinned Rust Agent
with this file. In PLAN, `write` can create a missing lowercase `.md` without
an `expected_version`; it derives the title and description from the body and
sets the admitted Session ID and UTC edit time. `edit` checks that header and
the same Session ID, changes the body under the normal version check, and
refreshes the edit time. The header is not a provenance signature. The linked
shell and single-file `patch` default to Ask in PLAN; `apply_patch` is denied.
BUILD and Host restrictions are unchanged. Default promotion requires separate
Runtime/Server acceptance.

## Contributing and license

See [Contributing](CONTRIBUTING.md) and the [security policy](SECURITY.md).
This repository is distributed under the [MIT license](LICENSE). The WIT
mirrors and Rust-derived catalog fixtures retain MicroCrab Core provenance.
