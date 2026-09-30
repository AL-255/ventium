#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-mov-ack-leaf.XXXXXX)}"
mkdir -p "$OUT"
timeout 300s "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -j 1 -sv -Wall \
  -Wno-UNUSED -Wno-fatal -Wno-TIMESCALEMOD -Werror-IMPLICIT -Werror-PINMISSING \
  -Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
  +incdir+"$ROOT/rtl/core" --top-module tb_p54_mov_ack_retire \
  -Mdir "$OUT/obj" "$ROOT/rtl/core/ventium_decode_pkg.sv" \
  "$ROOT/rtl/core/ventium_alu_pkg.sv" "$ROOT/verif/issue_uv/tb_p54_mov_ack_retire.sv" \
  > "$OUT/build.log" 2>&1 || { tail -n 60 "$OUT/build.log"; exit 1; }
timeout 30s "$OUT/obj/Vtb_p54_mov_ack_retire" > "$OUT/run.log" 2>&1 || {
  tail -n 60 "$OUT/run.log"; exit 1;
}
rg 'P54-MOV-ACK-RETIRE-LEAF-OK' "$OUT/run.log"
printf 'Artifacts: %s\n' "$OUT"
