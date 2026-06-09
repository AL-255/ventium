#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/trsc/run-fpatan-core-gate.sh — the IN-CORE FPATAN gate (#11). Builds the
# cosim TB with +VEN_TRANSCENDENTAL and func-diffs tx_fpatan (st0..st7/fctrl/fstat/
# ftag, exact) vs the qemu-i386 gdbstub golden — proving the engine is bit-exact
# THROUGH the core (decode D9 F3 -> S_TRSC_BUSY -> we_sti(1)+pop commit). Quake's
# only transcendental, so this unblocks F4 (first Quake frame).
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

T=verif/trsc/tests/tx_fpatan
LOAD=0x08048000; ENTRY=0x08048000; MAX=80

echo "=== FPATAN core gate: build cosim TB (+VEN_TRANSCENDENTAL) ==="
make -C verif/tb VL_EXTRA_DEFINES="+define+VEN_TRANSCENDENTAL" OBJDIR=obj_dir_trsc >/dev/null 2>&1
[ -x "$TB_BIN" ] || { echo "FAIL: $TB_BIN not built"; exit 1; }

echo "=== FPATAN core gate: assemble tx_fpatan + golden + RTL + compare ==="
$CC $CFLAGS -Wl,-Ttext="$LOAD" -o "$W/tx_fpatan.elf" "$T/tx_fpatan.s"
python3 "$ELF2FLAT" "$W/tx_fpatan.elf" --out "$W/tx_fpatan.flat" --base "$LOAD" >/dev/null
python3 "$GEN_TRACE" --qemu "$QEMU" --elf "$W/tx_fpatan.elf" \
        --out "$W/golden_fa.vtrace" --max-insn "$MAX" --x87 >/dev/null 2>&1
INIT_ESP="$(python3 - "$W/golden_fa.vtrace" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    f.readline(); print(json.loads(f.readline())["esp"])
PY
)"
"$TB_BIN" --image "$W/tx_fpatan.flat" --load "$LOAD" --entry "$ENTRY" \
          --init-esp "$INIT_ESP" --out "$W/rtl_fa.vtrace" --max-insn "$MAX" --x87 >/dev/null 2>&1

if python3 "$COMPARE" --mode func "$W/golden_fa.vtrace" "$W/rtl_fa.vtrace" > "$W/cmp_fa.txt" 2>&1; then
  echo "FPATAN-CORE-GATE-OK  (tx_fpatan func-exact vs qemu-i386: st0..st7/fctrl/fstat/ftag)"
  echo "FPATAN-CORE-GATE: PASS"
else
  echo "FPATAN-CORE-GATE: FAIL"
  grep -m4 -E "^n=|MISMATCH|LENGTH" "$W/cmp_fa.txt" || tail -10 "$W/cmp_fa.txt"
  exit 1
fi
