#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-all-cov.sh — run every coverage lane and produce the combined
# headline. Four complementary lanes (Verilator only instruments INSTANTIATED
# modules, so no single build can cover everything):
#
#   1. ISA      user-mode ISA suite through the --coverage core build (run-cov)
#   2. SYS      bare-metal system-mode images through the same core (run-sys-cov)
#   3. MEM      faithful standalone cache/bus TBs (run-mem-cov)
#   4. UNIT     optional arithmetic engines + biu_p5 standalone gates (run-unit-cov)
#
# The ISA + SYS pools share the ventium_top hierarchy, so they MERGE into the
# authoritative CORE coverage number. MEM/UNIT cover leaf modules under their
# own tops and are reported separately.
#
# Usage:  bash verif/cov/run-all-cov.sh   (or: make coverage-all)
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COV="$ROOT/build/cov"; COMB="$COV/combined"
PYTHON="${PYTHON:-python3}"
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
COV_SUM="$SCRIPT_DIR/cov_summary.py"
say() { printf '\n########## %s ##########\n' "$*"; }

mkdir -p "$COMB"

say "LANE 1/4 — user-mode ISA suite"
bash "$SCRIPT_DIR/run-cov.sh" || true
say "LANE 2/4 — system-mode images"
bash "$SCRIPT_DIR/run-sys-cov.sh" || true
say "LANE 3/4 — memory subsystem"
bash "$SCRIPT_DIR/run-mem-cov.sh" || true
say "LANE 4/4 — optional arithmetic engines + biu_p5"
bash "$SCRIPT_DIR/run-unit-cov.sh" || true

# ---- combined CORE coverage (ISA + SYS, same top) --------------------------
say "COMBINED CORE COVERAGE (ISA + system-mode)"
CORE_DATS=$(ls "$COV"/dat/*.dat "$COV"/sys/dat/*.dat 2>/dev/null || true)
if [ -n "$CORE_DATS" ]; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$COMB/core.dat" $CORE_DATS > "$COMB/merge.log" 2>&1 \
        || cat $CORE_DATS > "$COMB/core.dat"
    "$PYTHON" "$COV_SUM" "$COMB/core.dat" --root "$ROOT" --worst 20 \
        --out "$COMB/cov_summary.txt" --json "$COMB/cov_summary.json" | sed -n '1,8p'
else
    echo "  (no core dats — did the ISA/SYS lanes run?)"
fi

say "SUMMARY — all lanes"
hdr() { sed -n '4,6p' "$1" 2>/dev/null | sed 's/^/    /'; }
echo "CORE (ISA+SYS)   build/cov/combined/cov_summary.txt"; hdr "$COMB/cov_summary.txt"
echo "MEMORY subsystem build/cov/mem/cov_summary.txt";       hdr "$COV/mem/cov_summary.txt"
echo "UNIT engines     build/cov/unit/cov_summary.txt";      hdr "$COV/unit/cov_summary.txt"
echo ""
echo "ISA execution report (unimplemented/diverging): build/cov/isa.txt"
sed -n '/tests analyzed/,/diverged/p' "$COV/isa.txt" 2>/dev/null | sed 's/^/    /'
sed -n '/UNIMPLEMENTED/,/EXECUTED opcode-map/p' "$COV/isa.txt" 2>/dev/null | grep -E '^\s*\[' | sed 's/^/    /'
echo ""
echo "coverage-all: done. Annotated sources under build/cov/**/annotated/."
