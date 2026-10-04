#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Response-owner unit regression, not a full-core or FPGA acceptance gate.
# Set TMPDIR explicitly to an existing scratch volume. Preserve all receipts.
# L1D_EARLY_RETARGET_SOURCE selects a diagnostic cache source; such a run never
# prints the canonical correctness-pass marker, even if the override passes.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TMPDIR:?set TMPDIR explicitly to an existing writable scratch directory}"
[[ "$TMPDIR" = /* && -d "$TMPDIR" && -w "$TMPDIR" ]] || {
  echo "L1D-EARLY-RETARGET-GATE-FAIL (invalid TMPDIR)" >&2; exit 2;
}
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec env VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel \
    "$ROOT/tools/build_scope.sh" -- timeout --signal=TERM --kill-after=10s 600s bash "$0" "$@"
fi
OBJ="$(mktemp -d "$TMPDIR/ventium-l1d-early-retarget-gate.XXXXXX")"
SOURCE="${L1D_EARLY_RETARGET_SOURCE:-$ROOT/rtl/mem/ven_l1d.sv}"
[[ -f "$SOURCE" ]] || { echo "missing cache source: $SOURCE" >&2; exit 2; }
printf 'L1D-EARLY-RETARGET-OUTPUT %s\n' "$OBJ"
printf 'CACHE_SOURCE %s\n' "$SOURCE"
INPUTS=("$SOURCE" "$ROOT/rtl/mem/ven_p54_bank_arb.sv" "$ROOT/rtl/mem/ven_p54_hit_return.sv"
        "$ROOT/verif/l1/tb_l1d_early_retarget.sv" "$ROOT/verif/l1/run-l1d-early-retarget-gate.sh"
        "$ROOT/tools/build_scope.sh" "$ROOT/tools/verilator_serial.sh")
sha256sum "${INPUTS[@]}" > "$OBJ/inputs.before.sha256"
OVERALL=0
PROFILE_COUNT=0
CASE_COUNT=0
run_one() {
  local label="$1"; shift
  local dir="$OBJ/$label" build_status sim_status scenario
  local has_code=0
  local -a arguments scenarios=(hold retarget)
  for define in "$@"; do [[ "$define" != -DVEN_L1D_CODE_BUFFER ]] || has_code=1; done
  (( has_code == 0 )) || scenarios+=(retarget-code)
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/defines.txt"
  set +e
  "$ROOT/tools/verilator_serial.sh" -j 4 --binary --timing -sv \
    -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD "$@" \
    --top-module tb_l1d_early_retarget -Mdir "$dir/obj" -o tb_l1d_early_retarget \
    "$ROOT/rtl/mem/ven_p54_bank_arb.sv" "$ROOT/rtl/mem/ven_p54_hit_return.sv" \
    "$SOURCE" "$ROOT/verif/l1/tb_l1d_early_retarget.sv" > "$dir/build.log" 2>&1
  build_status=$?
  set -e
  printf '%s\n' "$build_status" > "$dir/build.exit.txt"
  printf 'BUILD profile=%s actual_exit=%s\n' "$label" "$build_status"
  PROFILE_COUNT=$((PROFILE_COUNT + 1))
  if (( build_status != 0 )); then OVERALL=1; tail -20 "$dir/build.log"; return; fi
  sha256sum "$dir/obj/tb_l1d_early_retarget" > "$dir/binary.sha256"
  for scenario in "${scenarios[@]}"; do
    arguments=()
    [[ "$scenario" != hold ]] || arguments=(+HOLD_B)
    [[ "$scenario" != retarget-code ]] || arguments=(+CODE_A)
    set +e
    timeout --signal=TERM --kill-after=5s 30s "$dir/obj/tb_l1d_early_retarget" \
      "${arguments[@]}" > "$dir/$scenario.log" 2>&1
    sim_status=$?
    set -e
    printf '%s\n' "$sim_status" > "$dir/$scenario.exit.txt"
    printf 'RUN profile=%s scenario=%s actual_exit=%s\n' "$label" "$scenario" "$sim_status"
    CASE_COUNT=$((CASE_COUNT + 1))
    if (( sim_status != 0 )) || ! rg -q 'L1D-EARLY-RETARGET-OK' "$dir/$scenario.log"; then OVERALL=1; fi
  done
}

# Both storage implementations, with/without saved windows and code-buffer
# policies. HUF is the feature whose simultaneous capture is under test.
BASE=(-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD)
WINDOW=(-DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE -DVEN_L1D_TAG_INVALIDATE
        -DVEN_L1D_TWO_WINDOW_REUSE -DVEN_L1D_TWO_WINDOW_KEEP_STORE)
CODE=(-DVEN_L1D_CODE_BUFFER -DVEN_L1D_CODE_STREAM -DVEN_L1D_CODE_TAG_INVALIDATE)
for storage in packed banked; do
  STORAGE=()
  [[ "$storage" != banked ]] || STORAGE=(-DVEN_L1D_BANKED_DATA -DVEN_L1D_BANK0_SHARED_XLINE)
  run_one "$storage-huf-only" -DVEN_L1D_HIT_UNDER_FILL "${STORAGE[@]}"
  for window in off on; do
    WIN=()
    [[ "$window" != on ]] || WIN=("${WINDOW[@]}")
    for code in off on; do
      COD=()
      [[ "$code" != on ]] || COD=("${CODE[@]}")
      run_one "$storage-window-$window-code-$code" "${BASE[@]}" "${STORAGE[@]}" "${WIN[@]}" "${COD[@]}"
    done
  done
done
# Complete active frozen-payload cache option conjunction. Core/FPU execution
# defines are irrelevant to this unit; all optional pair producer inputs are
# tied inactive, so this checks the legacy cache response path only.
run_one full-cache-policy "${BASE[@]}" "${WINDOW[@]}" "${CODE[@]}" \
  -DVEN_L1D_BANKED_DATA -DVEN_L1D_BANK0_SHARED_XLINE -DVEN_L1D_STORE_POLICY -DVEN_L1D_PERF \
  -DVEN_L1_HONOR_CD -DVEN_FP_LOAD64 -DVEN_P54_DUAL_HIT -DVEN_P54_DUAL_HIT_LEGACY_CAPTURE \
  -DVEN_P54_DUAL_LOAD_PAIR -DVEN_P54_DUAL_BYTE_LOAD_PAIR -DVEN_P54_DUAL_READ_ALU_PAIR \
  -DVEN_P54_DUAL_STORE_PAIR -DVEN_P54_LOAD_STORE_PAIR -DSYNTHESIS
sha256sum "${INPUTS[@]}" > "$OBJ/inputs.after.sha256"
cmp "$OBJ/inputs.before.sha256" "$OBJ/inputs.after.sha256" || OVERALL=1
printf '%s\n' "$OVERALL" > "$OBJ/gate.exit.txt"
if (( OVERALL != 0 )); then
  printf 'L1D-EARLY-RETARGET-GATE-FAIL profiles=%s cases=%s output=%s\n' "$PROFILE_COUNT" "$CASE_COUNT" "$OBJ"
elif [[ -n "${L1D_EARLY_RETARGET_SOURCE:-}" ]]; then
  printf 'L1D-EARLY-RETARGET-DIAGNOSTIC-OK profiles=%s cases=%s output=%s (not canonical correctness)\n' "$PROFILE_COUNT" "$CASE_COUNT" "$OBJ"
else
  printf 'L1D-EARLY-RETARGET-GATE-OK profiles=%s cases=%s output=%s\n' "$PROFILE_COUNT" "$CASE_COUNT" "$OBJ"
fi
exit "$OVERALL"
