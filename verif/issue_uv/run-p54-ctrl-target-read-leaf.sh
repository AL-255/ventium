#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-ctrl-target-read-leaf.XXXXXX)}"
mkdir -p "$OUT"
timeout 120s "$ROOT/tools/verilator_serial.sh" --binary --timing -sv \
  -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
  -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module tb_p54_ctrl_target_read -I"$ROOT/rtl/core" \
  --Mdir "$OUT/obj" "$ROOT/verif/issue_uv/tb_p54_ctrl_target_read.sv" \
  > "$OUT/build.log" 2>&1
timeout 15s "$OUT/obj/Vtb_p54_ctrl_target_read" > "$OUT/run.log" 2>&1
rg -q 'P54-CTRL-TARGET-READ-LEAF-OK' "$OUT/run.log"
printf 'P54-CTRL-TARGET-READ-LEAF-OK artifacts=%s\n' "$OUT"
