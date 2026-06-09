#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/trsc/run-fyl2x-core-gate.sh — the IN-CORE FYL2X/FYL2XP1 gate (#11). Builds
# the cosim TB with +VEN_TRANSCENDENTAL and func-diffs tx_fyl2x + tx_fyl2xp1
# (st0..st7/fctrl/fstat/ftag, exact) vs the qemu-i386 gdbstub golden — proving the
# engine is bit-exact THROUGH the core (decode D9 F1/F9 -> S_TRSC_BUSY -> we_sti(1)+pop).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness/build"
QEMU="$REFS/qemu/build/qemu-i386"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
CC="${CC:-gcc}"; CFLAGS="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
W="$ROOT/build/trsc/core"; mkdir -p "$W"
TB_BIN="$ROOT/verif/tb/obj_dir_trsc/tb_ventium"
LOAD=0x08048000

echo "=== FYL2X core gate: build cosim TB (+VEN_TRANSCENDENTAL) ==="
make -C verif/tb VL_EXTRA_DEFINES="+define+VEN_TRANSCENDENTAL" OBJDIR=obj_dir_trsc >/dev/null 2>&1
[ -x "$TB_BIN" ] || { echo "FAIL: $TB_BIN not built"; exit 1; }

run_one () {  # $1=test name  $2=max_insn
  local T="$1" MAX="$2"
  $CC $CFLAGS -Wl,-Ttext="$LOAD" -o "$W/$T.elf" "verif/trsc/tests/$T/$T.s"
  python3 "$ELF2FLAT" "$W/$T.elf" --out "$W/$T.flat" --base "$LOAD" >/dev/null
  python3 "$GEN_TRACE" --qemu "$QEMU" --elf "$W/$T.elf" --out "$W/$T.gold" --max-insn "$MAX" --x87 >/dev/null 2>&1
  local ESP; ESP="$(python3 - "$W/$T.gold" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    f.readline(); print(json.loads(f.readline())["esp"])
PY
)"
  "$TB_BIN" --image "$W/$T.flat" --load "$LOAD" --entry "$LOAD" \
            --init-esp "$ESP" --out "$W/$T.rtl" --max-insn "$MAX" --x87 >/dev/null 2>&1
  if python3 "$COMPARE" --mode func "$W/$T.gold" "$W/$T.rtl" > "$W/$T.cmp" 2>&1; then
    echo "  $T: func-exact vs qemu-i386 OK"
  else
    echo "  $T: FAIL"; grep -m3 -E "^n=|MISMATCH|LENGTH" "$W/$T.cmp" || tail -8 "$W/$T.cmp"; return 1
  fi
}

echo "=== FYL2X core gate: tx_fyl2x + tx_fyl2xp1 ==="
run_one tx_fyl2x 50
run_one tx_fyl2xp1 40
echo "FYL2X-CORE-GATE-OK  (FYL2X + FYL2XP1 func-exact vs qemu-i386)"
echo "FYL2X-CORE-GATE: PASS"
