#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Production PIO IRQ contract. Known RED is not a correctness PASS.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/verif/ide/obj_dir_pio_irq_scratch"
mkdir -p "$SCRATCH/build-tmp"
[[ "$(readlink -f "$SCRATCH")" == "$SCRATCH" ]] || exit 2
export TMPDIR="$SCRATCH/build-tmp"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    export VENTIUM_BUILD_SCOPE_UNIT="ventium-ide-pio-irq-${UID}-$$"
    exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 120s bash "$0" "$@"
fi
[[ "${EXPECT_RED:-0}" == 0 || "${EXPECT_RED:-0}" == 1 ]] || exit 2
# Tighten only this verified own scope. The shared guard still requires the
# actual lock FD; one compiler is below the approved four-worker maximum.
[[ "${VENTIUM_BUILD_SCOPE_UNIT:-}" == ventium-ide-pio-irq-* ]] || {
    echo 'Run this leaf in its own bounded scope, not a preexisting gate scope' >&2;exit 2;
}
systemctl --user set-property --runtime "${VENTIUM_BUILD_SCOPE_UNIT}.scope" \
    MemoryMax=2G MemorySwapMax=0 TasksMax=64
"$ROOT/tools/build_scope.sh" --is-active
OUT="$(mktemp -d "$SCRATCH/ide-pio-irq.XXXXXX")"
echo "Artifacts: $OUT"
sources=(3rd-party/ao486_MiSTer/rtl/soc/ide.v ao486-sim/stubs/sim_prims.sv
    verif/ide/tb_ide_pio_irq.sv)
frozen=()
for relative in "${sources[@]}"; do
    mkdir -p "$OUT/src/$(dirname "$relative")"
    cp -p "$ROOT/$relative" "$OUT/src/$relative"
    frozen+=("$OUT/src/$relative")
done
cp -p "$0" "$OUT/src/verif/ide/run-pio-irq-gate.sh"
sha256sum "${frozen[@]}" "$OUT/src/verif/ide/run-pio-irq-gate.sh" > "$OUT/sources.sha256"
systemctl --user show "${VENTIUM_BUILD_SCOPE_UNIT}.scope" \
    --property=MemoryMax --property=MemorySwapMax --property=TasksMax > "$OUT/resource-limits.txt"
"$ROOT/tools/verilator_serial.sh" -j1 --binary --timing --assert -sv -Wall \
    -Wno-UNUSED -Wno-fatal -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
    -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    --top-module tb_ide_pio_irq -Mdir "$OUT/model" -o test "${frozen[@]}" \
    > "$OUT/build.log" 2>&1 || { tail -50 "$OUT/build.log";exit 1; }
rc=0
timeout --kill-after=2s 20s "$OUT/model/test" > "$OUT/run.log" 2>&1 || rc=$?
sha256sum -c "$OUT/sources.sha256" > "$OUT/source-stability.log"
sha256sum "$OUT/model/test" > "$OUT/binary.sha256"
rg 'IDE-PIO-IRQ-RESULT|IDE-READ-EXTRA-IRQ' "$OUT/run.log" || true
if [[ "${EXPECT_RED:-0}" == 1 ]]; then
    [[ "$rc" != 0 && "$rc" != 124 && "$rc" != 137 ]] || exit 1
    rg -qxF 'IDE-PIO-IRQ-RESULT checks=2623 irq_errors=4 control_errors=0' "$OUT/run.log"
    [[ "$(rg -c '^IDE-READ-EXTRA-IRQ ' "$OUT/run.log")" == 4 ]] || exit 1
    # Only these precise extra-completion IRQs qualify as the known RED.
    # Missing IRQs or different status/data ownership must remain failures.
    for signature in \
        'single-read-no-second-completion-irq irq=1 edges=2' \
        'multi-read-one-irq-per-block irq=1 edges=3' \
        'read-multiple-no-second-final-irq irq=1 edges=3' \
        'identify-no-second-final-irq irq=1 edges=2'; do
        rg -qxF "IDE-READ-EXTRA-IRQ $signature status=50 count=256 request=0" "$OUT/run.log"
    done
    rg -q 'IDE-PIO-IRQ-READ-RED' "$OUT/run.log"
    if rg -q 'IDE-PIO-IRQ-CONTROL-FAIL|IDE-CONTROL-FAIL' "$OUT/run.log"; then
        exit 1
    fi
    echo "IDE-PIO-IRQ-EXPECTED-RED $OUT"
else
    [[ "$rc" == 0 ]] || { tail -25 "$OUT/run.log";exit 1; }
    rg -qxF 'IDE-PIO-IRQ-RESULT checks=2623 irq_errors=0 control_errors=0' "$OUT/run.log"
    rg -q 'IDE-PIO-IRQ-GATE-OK' "$OUT/run.log"
fi
