# MicroCrab Agents

This independent workspace is being prepared for the Zig Coding Component. The
current default Coding and Universal components remain in Core until a Zig
replacement has passed parity and integration checks. This repository is not yet
registered in the superproject and does not publish runtime artifacts.

The existing Core Agent 0.8 and Host WIT packages define the ABI. Use Zig 0.13.0
and the freestanding target; retain Core as the source of truth for imports,
Agent lifecycle, permissions, and immutable Session component identities.

The `wit/` tree mirrors the existing Coding world and its two imported packages.
Run `bash tools/check-wit.sh /path/to/microcrab-core` with `wasm-tools` on PATH
before changing the Zig bindings or packaging a guest. The check fails on byte
drift or an invalid WIT graph; it does not rewrite either checkout. The actual
Coding world exports `init`, `describe`, `invoke`, and `drive`.
