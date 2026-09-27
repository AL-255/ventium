#!/usr/bin/env bash
# Check the normal tag-selective policy and its optional read-window combinations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-tag-policy.XXXXXX")"
echo "Artifacts: $OUT"
for profile in default tag tag_window tag_window_huf tag_window_ff tag_window_both; do
  flags=()
  if [[ "$profile" == tag* ]]; then flags+=(+define+VEN_L1D_TAG_INVALIDATE); fi
  if [[ "$profile" == tag_window* ]]; then flags+=(+define+VEN_L1D_WINDOW_REUSE); fi
  if [[ "$profile" == *_huf || "$profile" == *_both ]]; then flags+=(+define+VEN_L1D_HIT_UNDER_FILL); fi
  if [[ "$profile" == *_ff || "$profile" == *_both ]]; then flags+=(+define+VEN_L1D_FILL_FORWARD); fi
  for top in tb_l1d_store_pollution tb_l1d_coherence tb_l1d; do
    "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
      -Werror-LATCH -Werror-UNOPTFLAT "${flags[@]}" \
      --top-module "$top" -Mdir "$OUT/${profile}_${top}" -o test \
      "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/$top.sv" \
      >"$OUT/${profile}_${top}.build.log" 2>&1 || { tail -60 "$OUT/${profile}_${top}.build.log"; exit 1; }
    "$OUT/${profile}_${top}/test" | tee "$OUT/${profile}_${top}.run.log"
  done
done
echo L1D-TAG-POLICY-GATE-OK
