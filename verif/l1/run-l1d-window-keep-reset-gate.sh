#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---draft}"
[[ "$MODE" == --draft || "$MODE" == --live ]] || { echo 'usage: --draft|--live'; exit 2; }
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-window-keep-reset.XXXXXX")"
echo "Artifacts: $OUT"
sha256sum "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/window-keep-store.patch" \
    "$ROOT/verif/l1/tb_l1d_window_keep_reset.sv" "$0" > "$OUT/source-before.sha256"
mkdir -p "$OUT/source/rtl/mem"
cp "$ROOT/rtl/mem/ven_l1d.sv" "$OUT/source/rtl/mem/ven_l1d.sv"
if [[ "$MODE" == --draft ]]; then
    patch --batch --fuzz=0 -p1 -d "$OUT/source" < "$ROOT/verif/l1/window-keep-store.patch" > "$OUT/patch.log"
else
    grep -q 'ifdef VEN_L1D_WINDOW_KEEP_STORE' "$OUT/source/rtl/mem/ven_l1d.sv"
fi
for tag in 0 1; do for keep in 0 1; do
    extra=()
    [[ "$tag" == 0 ]] || extra+=(+define+VEN_L1D_TAG_INVALIDATE)
    [[ "$keep" == 0 ]] || extra+=(+define+VEN_L1D_WINDOW_KEEP_STORE)
    label="tag${tag}_keep${keep}"
    (
        set -x
        "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
            -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
            -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_L1D_WINDOW_REUSE \
            +define+VEN_FP_LOAD64 +define+VEN_L1D_HIT_STREAM +define+VEN_PIPE_MEM_CHAIN \
            "${extra[@]}" --top-module tb_l1d_window_keep_reset -Mdir "$OUT/$label" \
            "$OUT/source/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_window_keep_reset.sv"
    ) > "$OUT/$label.build.log" 2>&1 || { tail -50 "$OUT/$label.build.log"; exit 1; }
    "$OUT/$label/Vtb_l1d_window_keep_reset" > "$OUT/$label.run.log" 2>&1 || {
        tail -10 "$OUT/$label.run.log"; exit 1;
    }
    grep '^L1D-WINDOW-KEEP-RESET-OK' "$OUT/$label.run.log"
done; done
sha256sum -c "$OUT/source-before.sha256" > "$OUT/source-stability.log"
sha256sum "$OUT"/*/Vtb_l1d_window_keep_reset > "$OUT/binaries.sha256"
echo "L1D-WINDOW-KEEP-RESET-GATE-OK $OUT"
