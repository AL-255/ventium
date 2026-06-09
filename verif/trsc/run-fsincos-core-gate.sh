#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/trsc/run-fsincos-core-gate.sh — the IN-CORE FSIN/FCOS gate (#11).
# qemu computes FSIN/FCOS at DOUBLE precision (floatx80->double->sin->floatx80),
# so it is NOT the silicon oracle and canNOT func-gate these. The oracle is the
# shared-poly model (qref qfsin/qfcos, ~1.8 ulp vs quad). This gate runs tx_fsin/
# tx_fcos through the +VEN_TRANSCENDENTAL core and asserts the core's st0 equals
# the MODEL bit-for-bit (proving decode -> fpu_fsincos -> commit), and REPORTS the
# core-vs-qemu spread (large, by design: the model beats qemu's double precision).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
export QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export QREF="$ROOT/tools/p5xtrans/qref"
export TB_BIN="$ROOT/verif/tb/obj_dir_trsc/tb_ventium"
export CC="${CC:-gcc}"
W="$ROOT/build/trsc/core"; mkdir -p "$W"; export W

echo "=== FSIN/FCOS core gate: build cosim TB (+VEN_TRANSCENDENTAL) + qref ==="
make -C verif/tb VL_EXTRA_DEFINES="+define+VEN_TRANSCENDENTAL" OBJDIR=obj_dir_trsc >/dev/null 2>&1
make -C tools/p5xtrans qref >/dev/null
[ -x "$TB_BIN" ] || { echo "FAIL: $TB_BIN not built"; exit 1; }

python3 verif/trsc/fsincos_core_check.py
