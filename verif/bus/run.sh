#!/usr/bin/env bash
# ============================================================================
# run.sh -- standalone build+run for the Ventium M5B Bus Interface Unit (biu_p5)
#
# Verifies biu_p5.sv structurally (no differential oracle / M2S pattern):
#   1. verilator --lint-only   -- the DUT lints clean as a standalone module
#   2. verilator --binary      -- builds the SV testbench WITH SVA concurrent
#      assertions (--assert) and the directed self-consistency scenarios, runs it.
#
# Fully isolated: touches ONLY verif/bus/. Never invokes any rtl/ or verif/tb
# build. iverilog 12 on this host does NOT parse SVA `property`, so Verilator
# (which does support SVA concurrent assertions in --binary mode) is used.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBJ="$HERE/obj"
VTB="$OBJ/vtb"
mkdir -p "$OBJ" "$VTB"

VERILATOR="${VERILATOR:-verilator}"

# warnings that are stylistic-only for the *testbench* (DUT is lint-clean under -Wall)
TB_WAIVERS=(-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ
            -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD)

echo "=== [1/2] lint biu_p5 (standalone, -Wall) ==="
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME --top-module biu_p5 "$HERE/biu_p5.sv"
echo "    lint OK"

echo "=== [2/2] build + run SVA / self-consistency testbench ==="
"$VERILATOR" --binary --assert --timing -Wall "${TB_WAIVERS[@]}" \
  --top-module tb_biu_p5 --Mdir "$VTB" \
  "$HERE/biu_p5.sv" "$HERE/tb_biu_p5.sv" -o tb_biu_p5 >/dev/null

"$VTB/tb_biu_p5"
echo "=== run.sh: DONE ==="
