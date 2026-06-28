#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# FP-PIPELINE coverage lane. The standard transc/flags lanes run on cov-feat (which
# carries VEN_FPTRAP, so FPATAN takes the PS-trap/non-pipe path and the split FP
# pipeline fpp2_s1 + the fpu_fpatan CORDIC stay dark). This lane builds the
# +VEN_FP_PIPE/+VEN_FP_PIPE2 variant WITHOUT FPTRAP and runs the transcendental +
# FP-arith input sweeps on it, so the split-pipeline datapaths reproduce in the
# combined headline (fpu_fpatan 42.6%->77.4%, fpp2_s1, etc.). Coverage-only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TBDIR="$ROOT/verif/tb"; OBJ="obj_dir_fppipe"; TB="$TBDIR/$OBJ/tb_ventium"
DAT="$ROOT/build/cov/fppipe/dat"; W="$ROOT/build/cov/fppipe/work"
PY="${PYTHON:-python3}"; CC="${CC:-gcc}"; LOAD=0x08048000
E2F="$ROOT/verif/tests/elf2flat.py"
mkdir -p "$DAT" "$W"; rm -f "$DAT"/*.dat 2>/dev/null || true

DEFS="+define+VEN_TRANSCENDENTAL +define+VEN_FPREM +define+VEN_SRT_ITER +define+VEN_FP_PIPE +define+VEN_FP_PIPE2"
[ -x "$TB" ] || make -C "$TBDIR" cov COV_OBJ="$OBJ" COV_DEFS="$DEFS" >"$W/build.log" 2>&1 \
    || { echo "fppipe TB build FAILED — see $W/build.log"; exit 1; }

"$PY" "$ROOT/verif/cov/opgen/gen_transc_sweep.py"  >/dev/null
"$PY" "$ROOT/verif/cov/opgen/gen_fparith_sweep.py" >/dev/null
ran=0
for sw in transc_sweep fparith_sweep; do
    src="$ROOT/verif/cov/tests/$sw/$sw.s"
    [ -f "$src" ] || src="$ROOT/verif/cov/opgen/tests/$sw/$sw.s"
    [ -f "$src" ] || continue
    "$CC" -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext="$LOAD" \
        -o "$W/$sw.elf" "$src" 2>/dev/null || continue
    "$PY" "$E2F" "$W/$sw.elf" --out "$W/$sw.flat" --base "$LOAD" >/dev/null 2>&1 || continue
    VEN_COV_DAT="$DAT/$sw.dat" "$TB" --image "$W/$sw.flat" --load "$LOAD" --entry "$LOAD" \
        --init-esp 0x40c34910 --x87 --out /dev/null --max-insn 8000 >/dev/null 2>&1 || true
    [ -f "$DAT/$sw.dat" ] && ran=$((ran+1))
done
echo "fppipe lane: $ran/2 sweeps -> dats in build/cov/fppipe/dat/ (+VEN_FP_PIPE, no FPTRAP)"
