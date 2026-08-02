#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-a20-gate.sh — REVIEW2 M-03 regression gate for the A20 gate.
#
# A20 was ABSENT from the design: no masking anywhere in the core and no top-level
# control, so accesses that must ALIAS at 1 MiB stayed distinct in memory and in the
# caches. This gate exercises the classic HMA wrap the way real BIOS/DOS code does,
# through a real-mode seg:off whose linear sum exceeds 1 MiB:
#
#     ES = 0xFFFF, offset 0x0510  ->  linear 0xFFFF0 + 0x0510 = 0x0010_0500
#
# The test image prints three values:
#   A = [0x0500] after a write through the HIGH alias with A20 ENABLED
#   B = [0x0500] after a write through the HIGH alias with A20 DISABLED (port 0x92)
#   C = [0x0510] read through DS, no override
#
# Expected: A=1111 B=3333 C=0000
#
# All three matter, and each rules out a different way of being wrong:
#   A=1111  CONTROL. With A20 enabled the two addresses must stay DISTINCT. A build
#           that masks unconditionally fails here -- so a passing B cannot be an
#           artifact of always-on masking.
#   B=3333  THE FIX. With A20 disabled the high write must WRAP onto the low dword.
#           A build with no A20 support fails here (B stays 1111).
#   C=0000  Proves the ES override really is producing a >1 MiB address. If the
#           override were being dropped, both writes would have landed at linear
#           0x0510 and A/B would be explainable without A20 being involved at all.
#           This check exists because that was a live hypothesis during bring-up.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/mabench"
BIN="${TB_BIN:-$TB/obj_dir/tb_ventium}"

echo "== A20 gate (REVIEW2 M-03): 1 MiB alias wrap via port 0x92 =="

echo "-- build the test image --"
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -c "$T/a20test.S" -o "$T/a20test.o"
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -static -no-pie \
    -Wl,-T,"$T/mabench.ld" -Wl,--build-id=none "$T/a20test.o" -o "$T/a20test.elf" 2>/dev/null
objcopy -O binary "$T/a20test.elf" "$T/a20test.bin"
truncate -s 65536 "$T/a20test.bin"

echo "-- build the tb (if needed) --"
make -C "$TB" OBJDIR=obj_dir >/dev/null

echo "-- run --"
# The tb exits through isa-debug-exit ((0x42<<1)|1 = 133) even on success, so the
# status is captured and the OUTPUT is what decides. A hang (124) still fails.
set +e
OUT=$(timeout 180 "$BIN" --system --cosim --image "$T/a20test.bin" --out /dev/null \
      --max-insn 4000 --quiesce 8000 2>&1)
RC=$?
set -e
[ "$RC" != 124 ] || { echo "A20-GATE-FAIL (timeout — the run HUNG)"; exit 1; }

RES=$(printf '%s' "$OUT" | grep -oE "A=[0-9a-f]+ B=[0-9a-f]+ C=[0-9a-f]+" | head -1 || true)
echo "  result: ${RES:-<no result line>}"

fails=0
chk() {  # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"
  else echo "  FAIL $1: got '$2' want '$3'"; fails=$((fails+1)); fi
}
A=$(printf '%s' "$RES" | sed -n 's/.*A=\([0-9a-f]*\).*/\1/p')
B=$(printf '%s' "$RES" | sed -n 's/.*B=\([0-9a-f]*\).*/\1/p')
C=$(printf '%s' "$RES" | sed -n 's/.*C=\([0-9a-f]*\).*/\1/p')
chk "CONTROL: A20 ENABLED keeps 0x100500 and 0x000500 DISTINCT" "$A" "1111"
chk "FIX:     A20 DISABLED wraps the 1 MiB alias onto 0x000500" "$B" "3333"
chk "SANITY:  the ES override really addresses above 1 MiB"     "$C" "0000"

if [ "$fails" -ne 0 ]; then
  echo "A20-GATE-FAIL ($fails check(s) failed)"
  exit 1
fi
echo "A20-GATE-OK  (A20 masking correct in real mode, and inert when A20 is enabled)"
