# Contributing

Use Zig 0.13.0. Each Agent owns its package manifest, entry point, native tests,
and guest-specific WIT world. Put genuinely reusable code in `shared/` and use
local package dependencies rather than relative imports across package roots.
Both build entry points must use the same build graph and produce the same
component interface. See the [README](README.md) for verification commands.

Changes to canonical Agent, Host, or Session interfaces start in
[MicroCrab Core](https://github.com/Ky1eYang/microcrab-core). Mirror those files
byte for byte and record the Core revision used for any integration test. CI
against vendored WIT alone is not proof of compatibility with a live Runtime.

Guest code uses explicit allocators, bounded inputs and outputs, and scoped
resource ownership. Preserve WASM import permissions, cleanup, and feature
selection when refactoring. Keep generated binaries, caches, credentials and
real session transcripts out of commits. Use synthetic inputs for fixtures.
