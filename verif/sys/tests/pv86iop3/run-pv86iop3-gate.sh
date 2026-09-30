#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Existing frozen model only. Global bounded guard; never rebuilds the core.
set -euo pipefail
ulimit -c 0
# Validate the selected matrix before taking the guard or creating artifacts.
EXPECT_RED="${EXPECT_RED:-0}"
[[ "$EXPECT_RED" == 0 || "$EXPECT_RED" == 1 ]] || exit 2
CASES="${CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}"
[[ "$CASES" =~ ^([1-9]|1[0-5])(\ ([1-9]|1[0-5]))*$ ]] || exit 2
declare -A seen_cases=()
has_denied=0
for case_id in $CASES; do
    [[ -z "${seen_cases[$case_id]+present}" ]] || {
        echo "Duplicate CASES entry: $case_id" >&2
        exit 2
    }
    seen_cases[$case_id]=1
    if ((case_id <= 12)); then has_denied=1; fi
done
if [[ "$EXPECT_RED" == 1 && "$has_denied" == 0 ]]; then
    echo 'EXPECT_RED requires at least one denied case (1..12)' >&2
    exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HERE="$ROOT/verif/sys/tests/pv86iop3"
SCRATCH="$HERE/obj_dir_artifacts"
mkdir -p "$SCRATCH/build-tmp"
[[ "$(realpath "$SCRATCH")" == "$SCRATCH" ]] || exit 2
export TMPDIR="$SCRATCH/build-tmp"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    export VENTIUM_BUILD_SCOPE_UNIT="ventium-pv86iop3-${UID}-$$"
    exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi
[[ "${VENTIUM_BUILD_SCOPE_UNIT:-}" == ventium-pv86iop3-* ]] || exit 2
systemctl --user set-property --runtime "${VENTIUM_BUILD_SCOPE_UNIT}.scope" \
    MemoryMax=2G MemorySwapMax=0 TasksMax=64
"$ROOT/tools/build_scope.sh" --is-active
: "${TB_BIN:?Provide approved frozen tb_ventium}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
[[ -x "$TB" && -x "$QEMU" ]] || exit 2
PORT="${QEMU_PORT:-41439}"
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && ((10#$PORT >= 1024 && 10#$PORT + 14 <= 65535)) || exit 2
JOBS="${JOBS:-4}"
[[ "$JOBS" =~ ^[1-4]$ ]] || exit 2
OUT="$(mktemp -d "$SCRATCH/pv86iop3.XXXXXX")"
printf 'Artifacts: %s\n' "$OUT"
sha256sum "$TB" "$QEMU" "$HERE/pv86iop3.S" "$HERE/Makefile" \
    "$HERE/check_trace.py" "$HERE/run-pv86iop3-gate.sh" \
    "$ROOT/verif/sys/tests/pv86/pv86.ld" > "$OUT/input.sha256"
systemctl --user show "${VENTIUM_BUILD_SCOPE_UNIT}.scope" \
    --property=MemoryMax --property=MemorySwapMax --property=TasksMax > "$OUT/limits.txt"
START=$SECONDS
run_bounded() {
    local cap="$1" remaining
    shift
    remaining=$((520 - (SECONDS - START)))
    ((remaining > 0)) || return 124
    ((cap <= remaining)) || cap="$remaining"
    timeout --kill-after=3s "${cap}s" "$@"
}
run_case() {
    local case_id="$1" image rc diff_rc
    image="$OUT/pv86iop3_$case_id"
    run_bounded 30 make -C "$HERE" OUTDIR="$OUT" CASE="$case_id" > "$image.build.log" 2>&1
    nm -n "$image.elf" > "$image.sym"
    sha256sum "$image.elf" "$image.bin" > "$image.sha256"
    run_bounded 60 python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
        --system --image "$image.bin" --image-mode bios --cpu pentium \
        --max-insn 5000 --port "$((10#$PORT + case_id - 1))" \
        --out "$image.qemu.vtrace" > "$image.qemu.log" 2>&1
    run_bounded 10 python3 "$HERE/check_trace.py" --case "$case_id" \
        --symbols "$image.sym" "$image.qemu.vtrace" > "$image.qemu.check.log" 2>&1
    rc=0
    run_bounded 20 "$TB" --system --cosim --image "$image.bin" \
        --max-insn 5000 --max-cycles 2000000 --quiesce 400 \
        --out "$image.rtl.vtrace" +ven_faultlog > "$image.rtl.log" 2>&1 || rc=$?
    if [[ "${EXPECT_RED:-0}" == 1 && "$case_id" -le 12 ]]; then
        [[ "$rc" == 135 ]] || { echo "Unexpected RED exit $rc case $case_id"; exit 1; }
        run_bounded 10 python3 "$HERE/check_trace.py" --case "$case_id" \
            --symbols "$image.sym" --rtl-log "$image.rtl.log" --expect-red \
            "$image.rtl.vtrace" > "$image.rtl.check.log" 2>&1
        diff_rc=0
        run_bounded 10 python3 "$ROOT/verif/diff/compare.py" --mode func \
            "$image.qemu.vtrace" "$image.rtl.vtrace" > "$image.diff.log" 2>&1 || diff_rc=$?
        [[ "$diff_rc" == 1 ]] || exit 1
        printf 'PV86-IOP3-EXPECTED-RED case=%s\n' "$case_id"
    else
        [[ "$rc" == 133 ]] || { echo "Unexpected exit $rc case $case_id"; exit 1; }
        run_bounded 10 python3 "$HERE/check_trace.py" --case "$case_id" \
            --symbols "$image.sym" --rtl-log "$image.rtl.log" \
            "$image.rtl.vtrace" > "$image.rtl.check.log" 2>&1
        run_bounded 10 python3 "$ROOT/verif/diff/compare.py" --mode func --all \
            "$image.qemu.vtrace" "$image.rtl.vtrace" > "$image.diff.log" 2>&1
        printf 'PV86-IOP3-PASS case=%s\n' "$case_id"
    fi
}
pids=()
wait_wave() {
    local pid failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    pids=()
    ((failed == 0))
}
for case_id in $CASES; do
    run_case "$case_id" &
    pids+=("$!")
    if ((${#pids[@]} == JOBS)); then wait_wave; fi
done
if ((${#pids[@]})); then wait_wave; fi
sha256sum -c "$OUT/input.sha256" > "$OUT/input-stability.log"
if [[ "${EXPECT_RED:-0}" == 1 ]]; then
    echo 'PV86-IOP3-EXPECTED-RED-OK: negative witnesses are not correctness passes'
else
    echo 'PV86-IOP3-GATE-OK: scalar I/O only; no string-I/O or full-PC qualification'
fi
