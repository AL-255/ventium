#!/usr/bin/env bash
# Focused, bounded three-port P54 data-TLB geometry test; not a full gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d "${P54_TLB_OUTBASE:-/tmp}/ventium-p54-large-dtlb.XXXXXX")"
echo "Artifacts: $OUT"
timeout 240s "$ROOT/tools/verilator_serial.sh" --binary --assert -sv \
    -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
    -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    +define+VEN_PIPE_MEM_CHAIN +define+VEN_P54_DUAL_HIT \
    --top-module tb_tlb_p54_large -Mdir "$OUT/model" \
    "$ROOT/rtl/mem/tlb_assoc.sv" \
    "$ROOT/verif/l1/tb_tlb_p54_large.sv" > "$OUT/build.log" 2>&1 || {
      tail -60 "$OUT/build.log"
      exit 1
    }
timeout 30s "$OUT/model/Vtb_tlb_p54_large"
