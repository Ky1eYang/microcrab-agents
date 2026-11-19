# MicroCrab Agents

This independent workspace is being prepared for the Zig Coding Component. The
current default Coding and Universal components remain in Core until a Zig
replacement has passed parity and integration checks. This repository is not yet
registered in the superproject and does not publish runtime artifacts.

The existing Core Agent 0.8 and Host WIT packages define the ABI. Use Zig 0.13.0
and the freestanding target; retain Core as the source of truth for imports,
Agent lifecycle, permissions, and immutable Session component identities.
