#!/usr/bin/env bash
# Directed pair-class microtest; no full verification or system build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR="${OUTDIR:-$(mktemp -d "$ROOT/tmp/regmem-prime-pair.XXXXXX")}"
mkdir -p "$OUTDIR"
timeout 180s verilator --binary --timing -j 2 -sv -Wno-fatal \
  --top-module tb_regmem_prime_pair \
  +define+VEN_P54_DUAL_LOAD_PAIR +define+VEN_P54_REGMEM_PRIME \
  --Mdir "$OUTDIR/obj" \
  "$ROOT/rtl/core/ventium_decode_pkg.sv" \
  "$ROOT/rtl/core/issue_uv.sv" \
  "$ROOT/verif/issue_uv/tb_regmem_prime_pair.sv" \
  > "$OUTDIR/build.log" 2>&1
timeout 60s "$OUTDIR/obj/Vtb_regmem_prime_pair" > "$OUTDIR/run.log" 2>&1
rg -q 'REGMEM-PAIR-CLASS-OK' "$OUTDIR/run.log"
echo "REGMEM-PRIME-PAIR-GATE-OK ($OUTDIR)"
