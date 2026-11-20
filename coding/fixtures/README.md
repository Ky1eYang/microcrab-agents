# Rust Coding catalog witness

`rust-v0_1_20.json` was captured from Core `c87cec4d1e51686904a0ed1efe5197efacc40114`
by passing each synthetic `host` object to `microcrab_agent_coding::describe`.
No live Host or product Session is represented. Keep this witness independent of
Zig implementation changes. The differential test permits only the approved
plan-mode Ask for the actual shell; if the predecessor changes, capture a new
witness through the Rust entry point and review every delta.

The compact production `catalog-baseline.json` contains static schemas and
wording, derived from the full Unix case plus the two platform shell descriptions.
Tool availability, per-mode rules, Host description and mode roles are checked by
the differential test across full and degraded configurations. Actual Core linkage
and Session enforcement require separate Component gates.
