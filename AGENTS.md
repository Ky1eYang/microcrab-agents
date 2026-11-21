# AGENTS.md

Use Zig 0.13.0. Follow the package boundaries and verification commands in the
[README](README.md) and [contribution guide](CONTRIBUTING.md).

- Agent-specific code, tests and WIT worlds belong in `agents/<slug>/`. Shared
  code must have a clear cross-package purpose. Keep one build graph for both
  repository-root and package-directory entry points.
- Core owns the Agent, Host and Session interfaces. Local WIT copies are byte
  mirrors; never reformat or change them independently. Guest-owned worlds go
  with the consuming package. Verify against the exact selected Core checkout.
- Keep guest builds entryless and freestanding; enforce existing allocator,
  error and resource-lifetime boundaries. Do not change tool policy or use test
  fixtures as runtime artifacts.
- Run formatting and native tests before handoff, then verify Wasm and Component
  output for build or ABI changes. Distinguish vendored-WIT checks, canonical
  drift checks, and real Runtime compatibility. Never stage or install runtime
  bytes without authorization.
