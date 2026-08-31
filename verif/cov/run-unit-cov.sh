#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-unit-cov.sh — coverage for the OPTIONAL arithmetic engines.
#
# The faithful default core build (`make verify`, and verif/cov/run-cov.sh) does
# NOT instantiate the FPGA-synthesizable iterative engines — ven_idiv,
# fpu_srt_div, fpu_sqrt_iter, ven_bcd, ven_bcd_to_fp — so they show 0 % in the
# core coverage pool (Verilator never instruments an uninstantiated module).
# Each one HAS a proven, bit-exact standalone gate; this runner re-runs those
# gates with --coverage so the engines' own line/toggle coverage is captured and
# reported, extending total RTL coverage toward 100 %.
#
# Each engine TB is self-checking (asserts its <ENGINE>-GATE-OK token) and runs
# from the repo root (so the SRT vector file path resolves), auto-writing
# coverage.dat which we collect into build/cov/unit/.
#
# Usage:  bash verif/cov/run-unit-cov.sh
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/cov/unit"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
COV_SUM="$SCRIPT_DIR/cov_summary.py"
VFLAGS="--binary --timing --assert --coverage --coverage-line --coverage-toggle --quiet \
        -Wall -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-UNUSEDSIGNAL \
        -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-TIMESCALEMOD \
        -Wno-DECLFILENAME -Wno-IMPLICITSTATIC -Wno-UNOPTFLAT"

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

# name | top | OK-token | define | sources
build_run() {  # <name> <top> <tok> <define> <sources...>
    local name="$1" top="$2" tok="$3" def="$4"; shift 4
    local bdir="$OUT/obj_$name"
    say "UNIT: $name"
    rm -rf "$bdir"; mkdir -p "$bdir"; rm -f "$ROOT/coverage.dat"
    # shellcheck disable=SC2086
    if ! $VERILATOR -j "$VL_J" $VFLAGS $def -Mdir "$bdir" --top-module "$top" -o "V$top" \
            "$@" > "$bdir/build.log" 2>&1; then
        info "BUILD FAIL (see $bdir/build.log)"; tail -12 "$bdir/build.log" | sed 's/^/      /'
        RESULTS+=("$name BUILD-FAIL"); ALL_OK=0; return
    fi
    local output rc; output="$(cd "$ROOT" && "$bdir/V$top" 2>&1)"; rc=$?
    echo "$output" | tail -3 | sed 's/^/    /'
    # Empty token => the TB has no print token; passing == exited 0 with no SVA
    # failure (--assert aborts on a fired assertion). Otherwise require the token.
    if [ -n "$tok" ]; then
        if ! grep -q "$tok" <<<"$output"; then
            info "SELF-CHECK FAIL (want $tok)"; RESULTS+=("$name CHECK-FAIL"); ALL_OK=0; return
        fi
    elif [ "$rc" -ne 0 ]; then
        info "SELF-CHECK FAIL (exit $rc / assertion)"; RESULTS+=("$name CHECK-FAIL"); ALL_OK=0; return
    fi
    if [ -f "$ROOT/coverage.dat" ]; then
        mv "$ROOT/coverage.dat" "$DAT/${name}.dat"; RESULTS+=("$name OK")
    else
        info "no coverage.dat"; RESULTS+=("$name NO-COV")
    fi
}

declare -a RESULTS; ALL_OK=1

build_run idiv      tb_idiv       IDIV-GATE-OK      "+define+IDIV_N=4000" \
    rtl/core/ven_idiv.sv verif/idiv/tb_idiv.sv
# biu_p5: the pin-level 64-bit P5 bus FSM (uninstantiated by the default core
# unless bus_mode!=0). Its standalone SVA testbench aborts on any protocol
# violation, so a clean exit IS the pass (empty token).
build_run bus_p5    tb_biu_p5     ""                "" \
    rtl/bus/biu_p5.sv verif/bus/tb_biu_p5.sv
build_run bcd       tb_bcd        BCD-GATE-OK       "+define+BCD_N=2000" \
    rtl/fpu/fpu_x87_pkg.sv rtl/fpu/ven_bcd.sv verif/bcd/tb_bcd.sv
build_run fbld      tb_bcd_to_fp  FBLD-GATE-OK      "+define+FBLD_N=2000" \
    rtl/fpu/fpu_x87_pkg.sv rtl/fpu/ven_bcd_to_fp.sv verif/fbld/tb_bcd_to_fp.sv
build_run sqrt_iter tb_sqrt_iter  SQRT-ITER-GATE-OK "+define+SQRT_N=2000" \
    rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_sqrt_iter.sv verif/srt/tb_sqrt_iter.sv

# SRT iterative FDIV needs golden vectors generated first; N comes from the model.
say "UNIT: srt_iter (generate vectors first)"
if SRT_N="$("$PYTHON" verif/srt/gen_vectors.py "$ROOT/build/srt" 2>/dev/null)"; then
    build_run srt_iter tb_srt_iter SRT-ITER-GATE-OK "+define+SRT_N=$SRT_N" \
        rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_srt_div.sv verif/srt/tb_srt_iter.sv
else
    info "gen_vectors.py failed — skipping srt_iter"; RESULTS+=("srt_iter SKIP")
fi

say "MERGE + UNIT-ENGINE COVERAGE SUMMARY"
DAT_FILES=$(ls "$DAT"/*.dat 2>/dev/null || true)
[ -n "$DAT_FILES" ] || { echo "no unit coverage produced"; exit 1; }
MERGED="$OUT/merged.dat"
if command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$MERGED" $DAT_FILES > "$OUT/merge.log" 2>&1 || cat $DAT_FILES > "$MERGED"
    "$VERILATOR_COVERAGE" --annotate "$OUT/annotated" --annotate-min 1 "$MERGED" > "$OUT/annotate.log" 2>&1 || true
else
    cat $DAT_FILES > "$MERGED"
fi
# Only the rtl/ engines matter; the tb_* files inflate the table, so filter the
# report to rtl/ by stripping the root and letting cov_summary list everything.
"$PYTHON" "$COV_SUM" "$MERGED" --root "$ROOT" --worst 12 \
    --out "$OUT/cov_summary.txt" --json "$OUT/cov_summary.json"

say "UNIT-ENGINE RESULTS"
for r in "${RESULTS[@]}"; do printf '    %s\n' "$r"; done
[ "$ALL_OK" -eq 1 ] && { echo; echo "UNIT COVERAGE: all engines OK (exit 0)."; exit 0; }
echo; echo "UNIT COVERAGE: at least one engine failed."; exit 1
