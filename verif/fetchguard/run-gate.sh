#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" != --out || $# != 2 ]]; then
  echo "usage: bash verif/fetchguard/run-gate.sh --out EXISTING_OWNED_OUTPUT" >&2
  exit 2
fi
out="$(realpath -- "$2")"
[[ -d "$out" && ! -e "$out/source-link.json" && ! -e "$out/obj" ]] || {
  echo "output must exist and be a fresh caller-owned directory" >&2; exit 2;
}
case "$out" in
  "$repo"/verif/tb/obj_dir_*/fetchguard-*) ;;
  /tmp/ventium-fetchguard.*) ;;
  *) echo "output must be /tmp/ventium-fetchguard.* or under an owned verif/tb/obj_dir_*" >&2; exit 2 ;;
esac
export TMPDIR="$out/compiler-tmp"
mkdir -m 700 "$TMPDIR"
export VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32
export VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32
cd "$repo"
sha256sum rtl/core/core.sv verif/fetchguard/extract_predicates.py \
  verif/fetchguard/tb_fetchguard.sv verif/fetchguard/run-gate.sh \
  verif/fetchguard/record_resources.py \
  tools/build_scope.sh > "$out/inputs.before.sha256"
python3 verif/fetchguard/extract_predicates.py --core rtl/core/core.sv --out "$out"
sha256sum "$out/production_predicates.svh" "$out/source-link.json" \
  > "$out/extraction.sha256"
timeout --signal=TERM --kill-after=10s 540s tools/build_scope.sh -- \
  bash -c 'set -euo pipefail; repo="$1"; out="$2";
    export CCACHE_DISABLE=1;
    "$repo/tools/build_scope.sh" --is-active;
    python3 "$repo/verif/fetchguard/record_resources.py" \
      --phase before --out "$out/resources.before.json";
    verilator --binary --assert -j 32 -sv -Wall -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
      -Werror-LATCH -Werror-UNOPTFLAT --top-module tb_fetchguard \
      -I"$out" -Mdir "$out/obj" -o tb_fetchguard \
      "$repo/verif/fetchguard/tb_fetchguard.sv" > "$out/build.log" 2>&1;
    "$out/obj/tb_fetchguard" > "$out/run.log" 2>&1;
    rg -q "^FETCHGUARD-LEAF-OK checks=" "$out/run.log";
    python3 "$repo/verif/fetchguard/record_resources.py" \
      --phase after --out "$out/resources.after.json"' bash "$repo" "$out"
sha256sum --check "$out/inputs.before.sha256" > "$out/input-check.after.log"
sha256sum --check "$out/extraction.sha256" > "$out/extraction-check.after.log"
sha256sum "$out/obj/tb_fetchguard" "$out/build.log" "$out/run.log" \
  "$out/resources.before.json" "$out/resources.after.json" \
  > "$out/outputs.sha256"
printf '%s\n' FETCHGUARD-SOURCE-LINKED-LEAF-GATE-OK
