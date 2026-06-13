#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-l1axi-xline-gate.sh — regression gate for the L1/AXI CROSS-CACHE-LINE store fix.
#
# A 4-byte store whose bytes straddle the 32-byte L1 line end spills its HIGH bytes into
# the NEXT line. ven_l1d invalidates the cached line(s) so a re-read refills correct data
# from the backing — but the invalidate originally fired only when the ADDRESSED line was
# resident. When the addressed line MISSED but the NEXT line was RESIDENT (hit==0,
# hit_n==1), the next line's STALE copy survived and a later cross-line read served the
# stale HIGH bytes. On the deployed KV260 bitstream this corrupted SeaBIOS's __call16 iret
# frame (a `pushl` of the return {cs:ip} to a ...x7E stack slot spilled CS into a resident-
# but-stale next line) -> the iret popped CS=0 -> FreeDOS derailed into the IVT and HALTed.
#
#   xlinetest : seed+cache the NEXT line, leave the addressed line non-resident, do the
#               cross-line store, then read back the cross-line dword AND the next line
#               (XLOK/XLBAD). Reproduces the exact (hit==0, hit_n==1) shape.
#
# PASS proves cross-cache-line stores are byte-correct through L1/AXI+REMAP. Companion to
# run-l1axi-xword-gate.sh (cross-WORD, within-line) and run-l1axi-callret-gate.sh.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/mabench"
LD="$T/mabench.ld"
say(){ printf '\n== %s ==\n' "$*"; }

say "0. build the real-mode test image (gcc -m32 -bios)"
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -c "$T/xlinetest.S" -o "$T/xlinetest.o"
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -static -no-pie -Wl,-T,"$LD" \
    -Wl,--build-id=none "$T/xlinetest.o" -o "$T/xlinetest.elf" 2>/dev/null
objcopy -O binary "$T/xlinetest.elf" "$T/xlinetest.bin"; truncate -s 65536 "$T/xlinetest.bin"

say "1. build the deployed-config tb (L1AXI + KV260 REMAP + all features)"
make -C "$TB" l1axi_kv_full >/dev/null
BIN="$TB/obj_dir_l1axi_kvf/tb_ventium"
[ -x "$BIN" ] || { echo "FATAL: deployed-config tb not built"; exit 1; }

run(){ timeout 180 "$BIN" --system --l1-axi --cosim --image "$1" --out /dev/null \
       --max-insn "${2:-400000}" --quiesce 8000 2>&1 \
     | grep -av '^tb:' | tr -d '\r\n' | sed 's/\(.\)\1\{2,\}/\1/g'; }

say "2. xlinetest: cross-CACHE-LINE store (addressed line miss, next line resident) (expect XLOK)"
OUT=$(run "$T/xlinetest.bin" 400000); echo "  console: $OUT"
case "$OUT" in *XLOK*) echo "  xlinetest PASS";;
  *) echo "  xlinetest FAIL ($OUT) — cross-line store left a stale next line (the FreeDOS iret-frame bug)"; exit 1;; esac

echo
echo "L1AXI-XLINE-OK  (cross-cache-line stores byte-correct through L1/AXI+REMAP)"
