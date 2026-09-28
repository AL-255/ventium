#!/usr/bin/env bash
# Bounded independent V translation-port test, direct and four-way DTLBs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$root/tools/build_scope.sh" --is-active; then
  exec "$root/tools/build_scope.sh" -- bash "$0" "$@"
fi
for variant in direct assoc; do
  out="$(mktemp -d "${TMPDIR:-/tmp}/ventium-p54-pair-dtlb.${variant}.XXXXXX")"
  echo "Artifacts: $out"
  extra=()
  if [[ "$variant" == assoc ]]; then extra=(+define+TB_ASSOC); fi
  timeout --signal=TERM --kill-after=10s 240s "$root/tools/verilator_serial.sh" \
    --binary --timing --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT \
    +define+VEN_P54_DUAL_HIT +define+VEN_PIPE_MEM_CHAIN "${extra[@]}" \
    --top-module tb_p54_pair_dtlb -Mdir "$out" \
    "$root/rtl/mem/tlb.sv" "$root/rtl/mem/tlb_assoc.sv" \
    "$root/verif/bench/tb_p54_pair_dtlb.sv" > "$out/build.log" 2>&1 || {
      tail -50 "$out/build.log"
      exit 1
    }
  timeout --signal=TERM --kill-after=10s 20s "$out/Vtb_p54_pair_dtlb"
done
