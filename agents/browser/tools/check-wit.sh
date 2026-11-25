#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || "$1" != /* ]]; then
    printf 'pass -Dcore=/absolute/path/to/microcrab-core for Browser WIT drift checks\n' >&2
    exit 1
fi
core=$1
browser=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cmp -- "$core/crates/agent/wit/wit/agent.wit" "$browser/wit/deps/agent/agent.wit"
cmp -- "$core/crates/host/wit/host.wit" "$browser/wit/deps/host/host.wit"
cmp -- "$core/crates/host/wit/scoped-web-transport.wit" "$browser/wit/deps/host-scoped/scoped-web-transport.wit"
cmp -- "$core/crates/session/wit/scoped-variables.wit" "$browser/wit/deps/session-scoped/scoped-variables.wit"
cmp -- "$core/crates/session/wit/private-bytes.wit" "$browser/wit/deps/session-private/private-bytes.wit"
cmp -- "$core/crates/session/wit/observation.wit" "$browser/wit/deps/session-observation/observation.wit"
cmp -- "$core/crates/session/wit/browser-observation.wit" "$browser/wit/deps/session-browser-observation/browser-observation.wit"
