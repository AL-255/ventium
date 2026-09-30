#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prepared only. Requires explicit authorization plus an existing bounded
# build_scope, and a frozen prebuilt TB. Never launches a model rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HERE="$ROOT/verif/sys/tests/pv86movrestart"
"$ROOT/tools/build_scope.sh" --is-active || {
    echo 'pv86movrestart requires the existing bounded build_scope launcher' >&2
    exit 2
}
: "${TB_BIN:?Provide an explicitly approved frozen prebuilt tb_ventium}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
[[ -x "$TB" && -x "$QEMU" ]] || { echo 'Missing pinned executable' >&2; exit 2; }
PORT="${QEMU_PORT:-41437}"
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )) || {
    echo 'QEMU_PORT must be an available port 1024..65535' >&2; exit 2;
}
[[ "${CASES:-1 2 3 4}" =~ ^[1-4](\ [1-4])*$ ]] || {
    echo 'CASES must be a space-separated list of 1..4' >&2; exit 2;
}
# Unique non-existing output path prevents clobbering receipts/canonical runs.
if [[ -n "${OUTDIR:-}" ]]; then
    [[ "$OUTDIR" == /tmp/* && ! -e "$OUTDIR" && ! -L "$OUTDIR" ]] || {
        echo 'OUTDIR must be a new unique directory under /tmp' >&2; exit 2;
    }
    mkdir -m 700 -- "$OUTDIR"
    OUT="$(realpath "$OUTDIR")"
    [[ "$OUT" == /tmp/* ]] || { echo 'Resolved OUTDIR left /tmp' >&2; exit 2; }
else
    OUT="$(mktemp -d /tmp/ventium-pv86movrestart.XXXXXX)"
fi
printf 'Artifacts: %s\n' "$OUT"
sha256sum "$TB" "$QEMU" "$HERE/pv86movrestart.S" "$HERE/Makefile" \
    "$HERE/check_trace.py" "$HERE/run-pv86movrestart-gate.sh" \
    "$ROOT/verif/sys/tests/pv86/pv86.ld" > "$OUT/input.sha256"
printf 'TB_BIN=%s\nQEMU=%s\nCASES=%s\nQEMU_PORT=%s\nMAX_INSN=5000\nMAX_CYCLES=2000000\nEVENT=software_INT30_not_hardware_IRQ\n' \
    "$TB" "$QEMU" "${CASES:-1 2 3 4}" "$PORT" > "$OUT/arguments.txt"

# Global540s budget, not540s per case. No child starts after the budget. Each
# invocation can add at most5s TERM-to-KILL grace, keeping below600s total.
START=$SECONDS
run_bounded() {
    local cap="$1" remaining duration
    shift
    remaining=$((540 - (SECONDS - START)))
    (( remaining > 0 )) || { echo 'PV86-MOVRESTART deadline exhausted' >&2; return 124; }
    duration="$cap"
    (( duration <= remaining )) || duration="$remaining"
    timeout --kill-after=5s "${duration}s" "$@"
}

for case_id in ${CASES:-1 2 3 4}; do
    image="$OUT/pv86movrestart_$case_id"
    run_bounded 30 make -C "$HERE" OUTDIR="$OUT" CASE="$case_id" > "$image.build.log" 2>&1
    nm -n "$image.elf" > "$image.sym"
    sha256sum "$image.bin" "$image.elf" > "$image.sha256"
    run_bounded 90 python3 "$ROOT/verif/qemu-trace/gen_trace.py" \
        --qemu "$QEMU" --system --image "$image.bin" --image-mode bios \
        --max-insn 5000 --port "$PORT" --out "$image.qemu.vtrace" \
        > "$image.qemu.log" 2>&1
    run_bounded 10 python3 "$HERE/check_trace.py" --case "$case_id" \
        --symbols "$image.sym" "$image.qemu.vtrace" > "$image.qemu.check.log" 2>&1
    for mode in functional cycle; do
        extra=()
        [[ "$mode" != cycle ]] || extra+=(--cycle)
        set +e
        run_bounded 35 "$TB" --system --cosim --image "$image.bin" \
            --max-insn 5000 --max-cycles 2000000 --quiesce 400 \
            --out "$image.$mode.vtrace" "${extra[@]}" +ven_faultlog \
            > "$image.$mode.log" 2>&1
        rtl_status=$?
        set -e
        [[ "$rtl_status" == 133 ]] || {
            printf 'PV86-MOVRESTART-FAIL case=%s mode=%s rtl_exit=%s\n' "$case_id" "$mode" "$rtl_status"
            exit 1
        }
        run_bounded 10 python3 "$HERE/check_trace.py" --case "$case_id" \
            --symbols "$image.sym" "$image.$mode.vtrace" > "$image.$mode.check.log" 2>&1
        run_bounded 10 python3 "$ROOT/verif/diff/compare.py" --mode func --all \
            "$image.qemu.vtrace" "$image.$mode.vtrace" > "$image.$mode.diff.log" 2>&1
        printf 'PV86-MOVRESTART-PASS case=%s mode=%s\n' "$case_id" "$mode"
    done
done
echo 'PV86-MOVRESTART-GATE-OK: byte PF retry/restored ES/AH/BX/CX; software gates only, no hardware IRQ witness'
