#!/usr/bin/env bash
# verif/l1/run-cachemap-gate.sh — standalone unit gate for ven_cachemap (the 430FX
# TSC cacheability decoder, rtl/northbridge/ven_cachemap.sv). Builds the self-checking
# tb_cachemap with Verilator --binary and asserts CACHEMAP-GATE-OK: the golden
# address→{to_dram,l1_cacheable,l2_cacheable} table from the TSC datasheet §3.2.14/15
# (fixed DRAM/PCI windows, PAM ROM windows incl. read-only/code-only/disabled, the
# FLCE/SCFMI/SCS global gates, the DRAMC.HEN holes, and the SMRAM aperture).
# Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator -j "${VL_J:-1}" --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD --top-module tb_cachemap -Mdir "$OBJ" -o tb_cachemap \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/verif/l1/tb_cachemap.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "CACHEMAP-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_cachemap" 2>&1)"
echo "$OUT"
grep -q "CACHEMAP-GATE-OK" <<<"$OUT" || { echo "CACHEMAP-GATE-FAIL"; exit 1; }
echo "== cachemap gate PASS =="
