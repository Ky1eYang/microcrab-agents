#!/usr/bin/env bash
# Exercise the real Runtime without changing the selected Core checkout or shared target.
set -euo pipefail
if [[ $# -ne 3 ]]; then
    printf 'Usage: bash tools/test-core-abi.sh ROOT_REPO CORE_REPO ZIG_0_13_0\n' >&2
    exit 2
fi
agents=$(dirname -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")")
root=$(realpath -- "$1")
core=$(realpath -- "$2")
zig=$(realpath -- "$3")
cd -- "$agents"

# Archive the committed source, not the caller's potentially dirty checkout.
# Reuse the isolated target but use a fresh source and output path for this run.
cache="$agents/.zig-cache/core-abi-smoke"
mkdir -p -- "$cache"
work=$(mktemp -d "$cache/run.XXXXXXXX")
mkdir -- "$work/core"
revision=$(git -C "$core" rev-parse HEAD)
git -C "$core" archive "$revision" | tar -x -C "$work/core"
printf 'Core ABI test at %s; isolated run: %s\n' "$revision" "$work"

# Register the fixture in Core's existing explicit suite, only in the archive.
cp -- tests/core_abi_probe.rs "$work/core/crates/session/tests/zig_abi_probe.rs"
printf '\n#[path = "zig_abi_probe.rs"]\nmod zig_abi_probe;\n' >> \
    "$work/core/crates/session/tests/session_wasm.rs"

"$zig" build component -Dcore="$work/core" -Dcoding-guest=tests/core_abi_probe.zig \
    --prefix "$work/component"
export MICROCRAB_Z1_ABI_PROBE="$work/component/coding.component.wasm"
sha256sum -- "$MICROCRAB_Z1_ABI_PROBE"

cargo --config "$root/.cargo/config.toml" run --locked --offline \
    --manifest-path "$root/Cargo.toml" --target-dir "$cache/root-target" --bin xtask -- \
    --core "$work/core" --target-dir "$cache/target" test core -p microcrab-session \
    --test session_wasm --filter canonical_zig_component_uses_runtime_and_constrained_local_host
