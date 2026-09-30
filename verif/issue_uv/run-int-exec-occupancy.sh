#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-int-exec-occupancy.XXXXXX)}"
mkdir -p "$OUT"
for profile in reference native iterative native-chain; do
  defines=()
  if [[ "$profile" != reference ]]; then defines+=(+define+VEN_P54_INT_EXEC_OCC); fi
  if [[ "$profile" == iterative ]]; then defines+=(+define+VEN_IDIV_ITER); fi
  if [[ "$profile" == native-chain ]]; then defines+=(+define+VEN_P54_PREFIX_EX_CHAIN); fi
  "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -j 1 -sv -Wall \
    -Wno-UNUSED -Wno-fatal -Wno-TIMESCALEMOD -Werror-IMPLICIT -Werror-PINMISSING \
    -Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    "${defines[@]}" +incdir+"$ROOT/rtl/core" --top-module tb_int_exec_occupancy \
    -Mdir "$OUT/$profile" "$ROOT/rtl/core/ventium_decode_pkg.sv" \
    "$ROOT/rtl/core/ven_idiv.sv" "$ROOT/verif/issue_uv/tb_int_exec_occupancy.sv" \
    > "$OUT/$profile.build.log" 2>&1 || { tail -n 50 "$OUT/$profile.build.log"; exit 1; }
  "$OUT/$profile/Vtb_int_exec_occupancy" > "$OUT/$profile.run.log" 2>&1 || {
    tail -n 50 "$OUT/$profile.run.log"; exit 1;
  }
  rg 'INT-EXEC-OCCUPANCY-OK' "$OUT/$profile.run.log"
done
for profile in reference native; do
  defines=(+define+VTM_NO_DPI)
  [[ "$profile" == reference ]] || defines+=(+define+VEN_P54_INT_EXEC_OCC)
  "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -j 1 -sv -Wall \
    -Wno-UNUSED -Wno-fatal -Wno-TIMESCALEMOD -Werror-IMPLICIT -Werror-PINMISSING \
    -Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    "${defines[@]}" --top-module tb_cl_shift_decode -Mdir "$OUT/$profile-cl" \
    "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
    "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/decode.sv" \
    "$ROOT/verif/issue_uv/tb_cl_shift_decode.sv" \
    > "$OUT/$profile-cl.build.log" 2>&1 || { tail -n 50 "$OUT/$profile-cl.build.log"; exit 1; }
  "$OUT/$profile-cl/Vtb_cl_shift_decode" > "$OUT/$profile-cl.run.log" 2>&1 || {
    tail -n 50 "$OUT/$profile-cl.run.log"; exit 1;
  }
  rg 'CL-SHIFT-DECODE-OK' "$OUT/$profile-cl.run.log"
done
printf 'INT-EXEC-OCCUPANCY-GATE-OK artifacts=%s\n' "$OUT"
