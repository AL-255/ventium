#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# New leaf only: no full-core/full-PC build, no saved state, no RTL changes.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/verif/l1/obj_dir_load_store_policy_scratch"
mkdir -p "$SCRATCH"
[[ "$(readlink -f "$SCRATCH")" == "$SCRATCH" ]] || exit 2
export TMPDIR="$SCRATCH/build-tmp"
mkdir -p "$TMPDIR"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi
OUT="$(mktemp -d "$SCRATCH/ventium-load-store-policy.XXXXXX")"
echo "Artifacts: $OUT"
mkdir -p "$OUT/src"
cp -p "$ROOT/rtl/mem/ven_l1d.sv" "$OUT/src/ven_l1d.sv"
cp -p "$ROOT/verif/l1/tb_l1d_load_store_policy.sv" "$OUT/src/tb_l1d_load_store_policy.sv"
cp -p "$0" "$OUT/src/run-l1d-load-store-policy-gate.sh"
sha256sum "$OUT/src/"* > "$OUT/source.sha256"
for profile in banked_policy banked_windows_policy banked_windows_no_policy; do
    defs=(+define+VEN_L1D_BANKED_DATA +define+VEN_P54_DUAL_STORE_PAIR
          +define+VEN_P54_LOAD_STORE_PAIR)
    [[ "$profile" == banked_windows_no_policy ]] || defs+=(+define+VEN_L1D_STORE_POLICY)
    if [[ "$profile" != banked_policy ]]; then
        defs+=(+define+VEN_L1D_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE
               +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_TWO_WINDOW_KEEP_STORE
               +define+VEN_L1D_CODE_BUFFER +define+VEN_L1D_CODE_TAG_INVALIDATE)
    fi
    mkdir -p "$OUT/$profile"
    printf '%s\n' "${defs[@]}" > "$OUT/$profile/defines.txt"
    "$ROOT/tools/verilator_serial.sh" -j1 --binary --timing --assert -sv -Wall \
      -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
      -Werror-LATCH -Werror-UNOPTFLAT "${defs[@]}" \
      --top-module tb_l1d_load_store_policy -Mdir "$OUT/$profile" -o test \
      "$OUT/src/ven_l1d.sv" "$OUT/src/tb_l1d_load_store_policy.sv" \
      > "$OUT/$profile/build.log" 2>&1 || { tail -50 "$OUT/$profile/build.log"; exit 1; }
    rc=0
    timeout --kill-after=2s 30s "$OUT/$profile/test" > "$OUT/$profile/run.log" 2>&1 || rc=$?
    cat "$OUT/$profile/run.log"
    if [[ "$profile" == banked_windows_no_policy ]]; then
        [[ "$rc" != 0 && "$rc" != 124 && "$rc" != 137 ]] || exit 1
        grep -q 'LOADSTORE-POLICY-FAIL' "$OUT/$profile/run.log"
        grep -q 'LOADSTORE-DATA-MISMATCH.*a=000[cdef]' "$OUT/$profile/run.log"
        grep -Eq 'LOADSTORE-RESULT .*control_errors=0 rom_errors=[1-9][0-9]* ram_errors=0 ' "$OUT/$profile/run.log"
        echo "LOADSTORE-POLICY-EXPECTED-RED"
    else
        [[ "$rc" == 0 ]] || exit 1
        grep -q 'LOADSTORE-POLICY-OK' "$OUT/$profile/run.log"
    fi
done
sha256sum -c "$OUT/source.sha256" > "$OUT/source-stability.log"
sha256sum "$OUT/"*/test > "$OUT/binaries.sha256"
echo "LOADSTORE-POLICY-GATE-OK $OUT"
