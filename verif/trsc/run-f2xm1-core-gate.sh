#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/trsc/run-f2xm1-core-gate.sh — the IN-CORE F2XM1 gate (#11). Builds the
# cosim TB with +VEN_TRANSCENDENTAL (the F2XM1 engine wired into core.sv), then
# func-diffs tx_f2xm1 (st0..st7 / fctrl / fstat / ftag, exact) vs the qemu-i386
# gdbstub golden — the SAME oracle + comparator `make verify` uses. This proves
# the engine is bit-exact THROUGH the core (decode -> S_TRSC_BUSY -> commit), not
# just in isolation (verif/trsc/run-f2xm1-gate.sh does the standalone leg).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness/build"
QEMU="$REFS/qemu/build/qemu-i386"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
CC="${CC:-gcc}"
CFLAGS="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
W="$ROOT/build/trsc/core"; mkdir -p "$W"
TB_BIN="$ROOT/verif/tb/obj_dir_trsc/tb_ventium"

T=verif/trsc/tests/tx_f2xm1
LOAD=0x08048000; ENTRY=0x08048000; MAX=60

echo "=== F2XM1 core gate: build cosim TB (+VEN_TRANSCENDENTAL) ==="
make -C verif/tb VL_EXTRA_DEFINES="+define+VEN_TRANSCENDENTAL" OBJDIR=obj_dir_trsc >/dev/null 2>&1
[ -x "$TB_BIN" ] || { echo "FAIL: $TB_BIN not built"; exit 1; }

echo "=== F2XM1 core gate: assemble tx_f2xm1 + golden + RTL + compare ==="
$CC $CFLAGS -Wl,-Ttext="$LOAD" -o "$W/tx_f2xm1.elf" "$T/tx_f2xm1.s"
python3 "$ELF2FLAT" "$W/tx_f2xm1.elf" --out "$W/tx_f2xm1.flat" --base "$LOAD" >/dev/null
python3 "$GEN_TRACE" --qemu "$QEMU" --elf "$W/tx_f2xm1.elf" \
        --out "$W/golden.vtrace" --max-insn "$MAX" --x87 >/dev/null 2>&1
INIT_ESP="$(python3 - "$W/golden.vtrace" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    f.readline(); print(json.loads(f.readline())["esp"])
PY
)"
"$TB_BIN" --image "$W/tx_f2xm1.flat" --load "$LOAD" --entry "$ENTRY" \
          --init-esp "$INIT_ESP" --out "$W/rtl.vtrace" --max-insn "$MAX" --x87 >/dev/null 2>&1

if python3 "$COMPARE" --mode func "$W/golden.vtrace" "$W/rtl.vtrace" > "$W/cmp.txt" 2>&1; then
  echo "F2XM1-CORE-GATE-OK  (tx_f2xm1 func-exact vs qemu-i386: st0..st7/fctrl/fstat/ftag)"
  echo "F2XM1-CORE-GATE: PASS"
else
  echo "F2XM1-CORE-GATE: FAIL"
  grep -m3 -E "^n=|MISMATCH|LENGTH" "$W/cmp.txt" || tail -8 "$W/cmp.txt"
  exit 1
fi
