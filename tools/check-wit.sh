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
check crates/agent/coding/wit/world.wit wit/world.wit
check crates/agent/wit/wit/agent.wit wit/deps/agent/agent.wit
check crates/host/wit/host.wit wit/deps/host/host.wit
wasm-tools component wit "$root/wit" >/dev/null
printf 'Coding world, Agent ABI, and Host WIT match Core.\n'
