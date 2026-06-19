#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-sys-cov.sh — SYSTEM-MODE coverage lane.
#
# The user-mode ISA suite (run-cov.sh) structurally cannot reach the core's
# privileged paths — interrupt/fault delivery, IRET, segmentation/far transfers,
# TSS + task switch, SMM, the page-table walk, port I/O, the TLB. Those show as
# 0 %-line includes in the core report. This lane runs the project's bare-metal
# system-mode images (verif/sys/tests/*) through the SAME coverage TB in
# --system mode so those paths light up, and merges the coverage into a system
# pool. (Correctness of these images is gated separately by `make verify-sys`;
# here we only need them to EXECUTE to collect coverage.)
#
# Usage:  bash verif/cov/run-sys-cov.sh            # default RTL-supported set
#         bash verif/cov/run-sys-cov.sh pmode pintr
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_cov/tb_ventium"
SYS="$ROOT/verif/sys/tests"
OUT="$ROOT/build/cov/sys"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
COV_SUM="$SCRIPT_DIR/cov_summary.py"
COV_DEFS="${COV_DEFS:-}"
MAX_CYCLES="${MAX_CYCLES:-4000000}"
MAX_INSN="${MAX_INSN:-300000}"

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# Default set = the system-mode demonstrators the RTL core supports (the
# RTL_SYS_TESTS family from run-sys-golden.sh) — each exercises a distinct
# privileged path: segmentation, paging, interrupts, faults, CPL/TSS, task
# switch, V86, debug, SMM, descriptor errors.
DEFAULT_TESTS="pseg pmode ppage pintr pfault pde pcpl ptask pv86 pdebug psmm \
  psocfarcall psoclseg psocrmint psocrmexc psocsgdt psoccallfmem psocsregmem"
TESTS=("$@"); [ "${#TESTS[@]}" -eq 0 ] && read -r -a TESTS <<<"$DEFAULT_TESTS"

mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

# ---- ensure the coverage TB exists -----------------------------------------
if [ ! -x "$TB_BIN" ]; then
    say "build coverage TB (verif/tb make cov)"
    make -C "$TB_DIR" cov COV_DEFS="$COV_DEFS" || { echo "cov TB build failed"; exit 1; }
fi

declare -a RESULTS; ALL_RAN=1
for T in "${TESTS[@]}"; do
    say "SYS: $T"
    TDIR="$SYS/$T"
    if [ ! -d "$TDIR" ]; then info "no such test dir: $TDIR"; RESULTS+=("$T NO-DIR"); ALL_RAN=0; continue; fi
    if ! make -C "$TDIR" >/dev/null 2>"$OUT/${T}_build.log"; then
        info "image build failed (see $OUT/${T}_build.log)"; RESULTS+=("$T BUILD-FAIL"); ALL_RAN=0; continue; fi
    IMGREL="$(grep -oP '"image":\s*"\K[^"]+' "$TDIR/manifest.json" 2>/dev/null || echo "$T.bin")"
    IMG="$TDIR/$IMGREL"
    [ -f "$IMG" ] || { info "image not found: $IMG"; RESULTS+=("$T NO-IMG"); ALL_RAN=0; continue; }
    if VEN_COV_DAT="$DAT/${T}.dat" "$TB_BIN" --image "$IMG" --system \
            --out "$OUT/${T}.vtrace" --max-cycles "$MAX_CYCLES" --max-insn "$MAX_INSN" \
            > "$OUT/${T}_run.log" 2>&1; then
        R="$(grep -oE 'retired [0-9]+ instructions' "$OUT/${T}_run.log" | head -1)"
        info "ran: $R"
        [ -f "$DAT/${T}.dat" ] && RESULTS+=("$T OK ($R)") || { RESULTS+=("$T NO-COV"); ALL_RAN=0; }
    else
        info "TB run failed (see $OUT/${T}_run.log)"; tail -4 "$OUT/${T}_run.log" | sed 's/^/      /'
        RESULTS+=("$T RUN-FAIL"); ALL_RAN=0
    fi
done

say "MERGE + SYSTEM-MODE COVERAGE SUMMARY"
DAT_FILES=$(ls "$DAT"/*.dat 2>/dev/null || true)
[ -n "$DAT_FILES" ] || { echo "no system coverage produced"; exit 1; }
MERGED="$OUT/merged.dat"
if command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$MERGED" $DAT_FILES > "$OUT/merge.log" 2>&1 || cat $DAT_FILES > "$MERGED"
else
    cat $DAT_FILES > "$MERGED"
fi
"$PYTHON" "$COV_SUM" "$MERGED" --root "$ROOT" --worst 20 \
    --out "$OUT/cov_summary.txt" --json "$OUT/cov_summary.json" | \
    sed -n '1,8p'

say "SYSTEM-MODE RESULTS"
for r in "${RESULTS[@]}"; do printf '    %s\n' "$r"; done
info "full per-file table: $OUT/cov_summary.txt"
[ "$ALL_RAN" -eq 1 ] && { echo; echo "SYS COVERAGE: all images ran + emitted coverage (exit 0)."; exit 0; }
echo; echo "SYS COVERAGE: some images did not run (see results)."; exit 0
