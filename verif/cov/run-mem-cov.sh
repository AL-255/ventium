#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-mem-cov.sh — dedicated MEMORY-subsystem coverage.
#
# The cache/bus leaf modules (ven_l1d, ven_axi_master, ventium_l1_axi)
# are exercised only thinly by the user-mode ISA suite, and the icache/TLB
# arrays are driven by core-internal fill protocols that are awkward to reach
# from the ISA suite alone. So this runner coverage-instruments the project's
# FAITHFUL, self-checking standalone memory testbenches (verif/l1/*) — plus a
# new breadth sweep that drives ven_l1d across all 128 sets x 2 ways — and
# reports per-module line/toggle coverage for the memory subsystem.
#
# Each TB is verilated with --coverage (--binary auto-writes coverage.dat at
# $finish); we run it from a private dir, assert its self-check OK token, and
# collect its coverage.dat into build/cov/mem/. Then merge + cov_summary.
#
# Usage:  bash verif/cov/run-mem-cov.sh
# Exit:   0 iff every memory TB built, self-checked OK, and emitted coverage.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL="$ROOT/rtl"; L1="$ROOT/verif/l1"
OUT="$ROOT/build/cov/mem"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
COV_SUM="$SCRIPT_DIR/cov_summary.py"

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

# name | OK-token | timing? | sources (space-separated, relative to repo root)
TBS=(
  "l1d|L1D-GATE-OK|0|rtl/mem/ven_l1d.sv verif/l1/tb_l1d.sv"
  "l1d_sweep|L1DSWEEP-OK|1|rtl/mem/ven_l1d.sv verif/cov/tb_cov_l1d_sweep.sv"
  "l1axi|L1AXI-GATE-OK|0|rtl/mem/ven_l1d.sv rtl/mem/ven_axi_master.sv rtl/mem/ventium_l1_axi.sv verif/l1/axi_slave_bfm.sv verif/l1/tb_l1_axi.sv"
)

ALL_OK=1
declare -a NAMES VERDICTS
for entry in "${TBS[@]}"; do
    IFS='|' read -r NAME TOK TIMING SRCS <<<"$entry"
    say "MEM TB: $NAME"
    BDIR="$OUT/obj_$NAME"; rm -rf "$BDIR"; mkdir -p "$BDIR"
    TOP="tb_${NAME}"; [ "$NAME" = "l1d_sweep" ] && TOP="tb_cov_l1d_sweep"
    [ "$NAME" = "l1axi" ] && TOP="tb_l1_axi"
    TIMING_FLAG=""; [ "$TIMING" = "1" ] && TIMING_FLAG="--timing"

    # resolve sources to absolute paths
    ABS=""; for s in $SRCS; do ABS="$ABS $ROOT/$s"; done
    # shellcheck disable=SC2086
    if ! "$VERILATOR" -j "$VL_J" --binary --assert --coverage --coverage-line --coverage-toggle \
            $TIMING_FLAG -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
            -Wno-IMPLICITSTATIC -Wno-UNOPTFLAT -Wno-PINMISSING --top-module "$TOP" -Mdir "$BDIR" -o "$TOP" \
            $ABS > "$BDIR/build.log" 2>&1; then
        info "BUILD FAIL (see $BDIR/build.log)"; tail -15 "$BDIR/build.log" | sed 's/^/      /'
        ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("BUILD-FAIL"); continue
    fi
    # run from the build dir so the auto-written coverage.dat lands there
    OUTPUT="$(cd "$BDIR" && "./$TOP" 2>&1)"; echo "$OUTPUT" | sed 's/^/    /' | head -8
    if ! grep -q "$TOK" <<<"$OUTPUT"; then
        info "SELF-CHECK FAIL (expected token $TOK)"; ALL_OK=0
        NAMES+=("$NAME"); VERDICTS+=("CHECK-FAIL"); continue
    fi
    if [ -f "$BDIR/coverage.dat" ]; then
        cp "$BDIR/coverage.dat" "$DAT/${NAME}.dat"
        NAMES+=("$NAME"); VERDICTS+=("OK")
    else
        info "WARNING: no coverage.dat produced"; NAMES+=("$NAME"); VERDICTS+=("NO-COV")
    fi
done

say "MERGE + MEMORY COVERAGE SUMMARY"
DAT_FILES=$(ls "$DAT"/*.dat 2>/dev/null || true)
if [ -z "$DAT_FILES" ]; then echo "no memory coverage produced"; exit 1; fi
MERGED="$OUT/merged.dat"
if command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$MERGED" $DAT_FILES > "$OUT/merge.log" 2>&1 \
        || cat $DAT_FILES > "$MERGED"
    "$VERILATOR_COVERAGE" --annotate "$OUT/annotated" --annotate-min 1 "$MERGED" \
        > "$OUT/annotate.log" 2>&1 || true
else
    cat $DAT_FILES > "$MERGED"
fi
"$PYTHON" "$COV_SUM" "$MERGED" --root "$ROOT" --worst 12 \
    --out "$OUT/cov_summary.txt" --json "$OUT/cov_summary.json"

say "MEMORY TB RESULTS"
for ((i=0; i<${#NAMES[@]}; i++)); do printf '    %-12s %s\n' "${NAMES[$i]}" "${VERDICTS[$i]}"; done
[ "$ALL_OK" -eq 1 ] && { echo; echo "MEM COVERAGE: all TBs OK (exit 0)."; exit 0; }
echo; echo "MEM COVERAGE: at least one TB failed."; exit 1
