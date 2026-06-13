#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-l1axi-xword-gate.sh — regression gate for the L1/AXI CROSS-WORD store fix (P2b).
#
# A store whose bytes straddle a 32-bit word (an UNALIGNED 16/32-bit store) must be
# issued to DDR as TWO AXI word-beats. The original ven_axi_master collapsed it into
# one beat and dropped the spilled bytes, silently corrupting DDR — which on the
# deployed KV260 bitstream cascaded into the SeaBIOS memset(0xc0000) POST infinite
# loop (the C:\ boot never reached). The byte-addressed sim BFM masked it; only the
# deployed config (L1AXI + KV260 REMAP, FAITHFUL word-aligned DDR BFM) exposes it.
#
#   xwordtest : unaligned 32-bit stores across a 60 KiB region (>> the ~8 KiB L1),
#               forcing dirty-line write-backs, then read back from DDR (XOK/XBAD).
#   memtest   : the SeaBIOS pattern — fill, descending byte-memset, read-back (MOK).
#
# PASS proves unaligned/cross-word stores are byte-correct through L1/AXI+REMAP.
# Companion to run-l1axi-callret-gate.sh (the within-word P2 sub-word-write fix).
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/mabench"
LD="$T/mabench.ld"
say(){ printf '\n== %s ==\n' "$*"; }

say "0. build the real-mode test images (gcc -m32 -bios)"
for n in xwordtest memtest; do
  gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -c "$T/$n.S" -o "$T/$n.o"
  gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -static -no-pie -Wl,-T,"$LD" \
      -Wl,--build-id=none "$T/$n.o" -o "$T/$n.elf" 2>/dev/null
  objcopy -O binary "$T/$n.elf" "$T/$n.bin"; truncate -s 65536 "$T/$n.bin"
done

say "1. build the deployed-config tb (L1AXI + KV260 REMAP + all features)"
make -C "$TB" l1axi_kv_full >/dev/null
BIN="$TB/obj_dir_l1axi_kvf/tb_ventium"
[ -x "$BIN" ] || { echo "FATAL: deployed-config tb not built"; exit 1; }

# strip the tb's per-OUT character spam (each console byte echoes a few times).
run(){ timeout 180 "$BIN" --system --l1-axi --cosim --image "$1" --out /dev/null \
       --max-insn "${2:-2000000}" --quiesce 8000 2>&1 \
     | grep -av '^tb:' | tr -d '\r\n' | sed 's/\(.\)\1\{2,\}/\1/g'; }

say "2. xwordtest: unaligned (cross-word) 32-bit stores through L1/AXI (expect XOK)"
OUT=$(run "$T/xwordtest.bin" 600000); echo "  console: $OUT"
case "$OUT" in *XOK*) echo "  xwordtest PASS";;
  *) echo "  xwordtest FAIL ($OUT) — cross-word store lost bytes (the 2-beat split bug)"; exit 1;; esac

say "3. memtest: fill + descending byte-memset + read-back through L1/AXI (expect MOK)"
OUT=$(run "$T/memtest.bin" 2000000); echo "  console: $OUT"
case "$OUT" in *MOK*) echo "  memtest PASS";;
  *) echo "  memtest FAIL ($OUT) — byte-memset/read-back mismatch through L1/AXI"; exit 1;; esac

echo
echo "L1AXI-XWORD-OK  (unaligned cross-word stores + byte-memset correct through L1/AXI+REMAP)"
