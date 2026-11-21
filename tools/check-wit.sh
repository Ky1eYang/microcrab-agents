#!/usr/bin/env bash
# Compare the standalone Zig input with the canonical Core checkout. Never rewrite either.
set -euo pipefail
if [[ $# -ne 1 ]]; then
    printf 'Usage: bash tools/check-wit.sh PATH_TO_MICROCRAB_CORE\n' >&2
    exit 2
fi
root=$(dirname -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")")
core=$(realpath -- "$1")
check() {
    if ! cmp -- "$core/$1" "$root/$2"; then
        printf 'Coding WIT differs from Core: %s -> %s\n' "$1" "$2" >&2
        return 1
    fi
}
# The independent Zig world adds Session services to the Rust Coding base.
# Compare the shared interfaces without treating guest-owned world selection as canonical.
check crates/session/wit/scoped-variables.wit wit/deps/session-scoped/scoped-variables.wit
check crates/agent/wit/wit/agent.wit wit/deps/agent/agent.wit
check crates/host/wit/host.wit wit/deps/host/host.wit
wasm-tools component wit "$root/wit" >/dev/null
printf 'Coding world resolves; Agent, Host, and Session WIT mirrors match Core.\n'
