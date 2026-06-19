#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-flags-cov.sh — BUILD-FLAGS coverage lane.
#
# The core is riddled with `ifdef VEN_*` feature gates whose code (and whole
# modules: uopcache.sv, fpu_f2xm1/fpatan/fyl2x/fsincos.sv, the FP-pipe commit
# paths, the fetch pipeline) is NOT instantiated in the default build, so it is
# 0% in every other lane. This lane builds a FEATURE-RICH ventium_top coverage
# variant and re-runs the whole corpus (func + cycle, COVERAGE-ONLY — these are
# verified-equivalent features, separately gated by make verify/m4/m5) so those
# gated paths light up. Same ventium_top hierarchy => merges into the CORE pool.
#
# Flags exercised (the safe, combinable, non-L1AXI set the deployed build uses):
#   VEN_FE_PIPE VEN_UOPCACHE VEN_BTB_PIPE VEN_FP_PIPE VEN_FP_PIPE2 VEN_FP_OVERLAP
#   VEN_FXCH_FREE VEN_TRANSCENDENTAL VEN_FPREM VEN_SRT_ITER VEN_IDIV_ITER
#   VEN_BCD_ITER VEN_FPTRAP VEN_FP_PC_RELAX VEN_DIV_EXACT
# (VEN_IC_BRAM/VEN_CACHE_HALF/VEN_KV260_SOC need L1AXI; VEN_PS_PROXY/VEN_DBG_CORE
#  need their own run modes — out of this lane's scope, noted in the README.)
#
# Usage:  bash verif/cov/run-flags-cov.sh
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_cov_feat/tb_ventium"
TESTS_DIR="$ROOT/verif/tests"; COV_TESTS="$ROOT/verif/cov/tests"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
OUT="$ROOT/build/cov/flags"; DAT="$OUT/dat"; WORK="$ROOT/build/cov/work"
PYTHON="${PYTHON:-python3}"; CC="${CC:-gcc}"
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
FEAT_DEFS="${FEAT_DEFS:-+define+VEN_FE_PIPE +define+VEN_UOPCACHE +define+VEN_BTB_PIPE \
  +define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_FP_OVERLAP +define+VEN_FXCH_FREE \
  +define+VEN_TRANSCENDENTAL +define+VEN_FPREM +define+VEN_SRT_ITER +define+VEN_IDIV_ITER \
  +define+VEN_BCD_ITER +define+VEN_FPTRAP +define+VEN_FP_PC_RELAX}"
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

say "build feature-rich coverage TB (obj_dir_cov_feat)"
make -C "$TB_DIR" cov COV_OBJ=obj_dir_cov_feat COV_DEFS="$FEAT_DEFS" \
    || { echo "feature build FAILED — try trimming FEAT_DEFS"; exit 1; }
[ -x "$TB_BIN" ] || { echo "feature TB not built"; exit 1; }
mkdir -p "$DAT" "$WORK"; rm -f "$DAT"/*.dat 2>/dev/null || true

manifest_get() { "$PYTHON" - "$1" "$2" <<'PY'
import sys,json; m=json.load(open(sys.argv[1])); v=m.get(sys.argv[2])
sys.exit(1) if v is None else print(v)
PY
}

RAN=0
for MANIFEST in $(find "$TESTS_DIR" "$COV_TESTS" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | sort); do
    NAME="$(manifest_get "$MANIFEST" name)" || continue
    SRC_REL="$(manifest_get "$MANIFEST" src)" || continue
    LOAD="$(manifest_get "$MANIFEST" load_addr)" || continue
    ENTRY="$(manifest_get "$MANIFEST" entry)" || continue
    MAX="$(manifest_get "$MANIFEST" max_insn)" || MAX=200000
    X87="$(manifest_get "$MANIFEST" x87)" || X87="false"
    X87_FLAG=""; { [ "$X87" = "True" ] || [ "$X87" = "true" ]; } && X87_FLAG="--x87"
    FLAT="$WORK/${NAME}.flat"
    if [ ! -f "$FLAT" ]; then
        ELF="$WORK/${NAME}.elf"
        "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$(dirname "$MANIFEST")/$(basename "$SRC_REL")" 2>/dev/null || continue
        "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" >/dev/null 2>&1 || continue
    fi
    # func + cycle, coverage-only (two dats per test -> both modes' paths)
    VEN_COV_DAT="$DAT/${NAME}_f.dat" "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp 0x40c34910 $X87_FLAG --out "$OUT/${NAME}_f.vtrace" --max-insn "$MAX" \
        > "$OUT/${NAME}_f.log" 2>&1 || true
    VEN_COV_DAT="$DAT/${NAME}_c.dat" "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp 0x40c34910 --cycle $X87_FLAG --out "$OUT/${NAME}_c.vtrace" --max-insn "$MAX" \
        > "$OUT/${NAME}_c.log" 2>&1 || true
    [ -f "$DAT/${NAME}_f.dat" ] && RAN=$((RAN+1))
done

say "BUILD-FLAGS coverage: ran $RAN test(s) through the feature-rich build"
ls "$DAT"/*.dat >/dev/null 2>&1 && echo "OK (dats merge into the combined CORE pool)" \
    || { echo "no coverage produced"; exit 1; }
