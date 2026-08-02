#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-l1axi-callret-gate.sh — regression gate for the L1/AXI byte-lane write fix.
#
# Runs real-mode CALL/RET + a sub-word-stack test through the EXACT deployed memory
# config (L1AXI + KV260 REMAP, all fetch/cache features) with a FAITHFUL (word-aligned)
# DDR BFM. This is the path that escaped verification: a sub-word write to a non-word-
# aligned byte address (a 16-bit stack push to 0x..FE) clobbered the adjacent half-word
# on silicon, breaking CALL's return-addr push -> RET, IVT delivery, and any stack use.
# The fix (ven_axi_master byte-lane align/shift) makes both pass. PASS proves the
# deployed config executes CALL/RET + sub-word stack writes correctly through L1/AXI.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/mabench"
LD="$T/mabench.ld"
say(){ printf '\n== %s ==\n' "$*"; }

say "0. build the real-mode test images (gcc -m32 -bios)"
for n in calltest stacktest; do
  gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -c "$T/$n.S" -o "$T/$n.o"
  gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -static -no-pie -Wl,-T,"$LD" \
      -Wl,--build-id=none "$T/$n.o" -o "$T/$n.elf" 2>/dev/null
  objcopy -O binary "$T/$n.elf" "$T/$n.bin"; truncate -s 65536 "$T/$n.bin"
done

say "1. build the deployed-config tb (L1AXI + KV260 REMAP + all features)"
make -C "$TB" l1axi_kv_full >/dev/null
BIN="$TB/obj_dir_l1axi_kvf/tb_ventium"

# run <image> [max-insn] -> prints the tb console, sets RC, and ALWAYS returns 0.
#
# The tb exits through the QEMU isa-debug-exit convention: a guest OUT to port 0xf4
# with value v makes the process exit (v<<1)|1, which is ALWAYS odd and nonzero even
# on a clean run. These images write 0x42, so a fully successful run exits 133.
# `set -eu` is in force, so `OUT=$(run ...)` used to abort the whole script at the
# assignment -- before a single functional check could look at the output. This gate
# therefore could NOT pass, in any tree state, no matter how correct the RTL was; it
# had been failing on a SUCCESSFUL run. (Found while adding the L1 gates to
# verify-all: 11 of 12 passed, this one "failed" with 133.)
#
# So: swallow the exit status here, keep it in RC, and let the functional assertions
# below decide -- they are the real checks (P=1234 read back, isa-debug-exit actually
# reached, retire count sane). RC is still inspected for the failure modes an exit
# code genuinely carries: 124 = `timeout` fired (hang), and 128+N = killed by a
# signal (crash), neither of which can be confused with an isa-debug-exit value.
RC=0
run(){
  local o
  o=$(timeout 120 "$BIN" --system --l1-axi --cosim --image "$1" --out /dev/null \
      --max-insn "${2:-4000}" --quiesce 8000 2>&1) && RC=0 || RC=$?
  printf '%s' "$o"
  return 0
}

# check_rc <what> -- fail on a hang or a crash; tolerate isa-debug-exit's odd codes.
check_rc(){
  [ "$RC" != 124 ] || { echo "  $1 FAIL (timeout — the run HUNG)"; exit 1; }
  case "$RC" in
    0|*[13579]) : ;;   # 0, or an odd (v<<1)|1 isa-debug-exit status
    *) echo "  $1 FAIL (tb died with status $RC — not an isa-debug-exit value)"; exit 1;;
  esac
}

say "2. stacktest: sub-word stack write/read-back through L1/AXI (expect P=1234)"
OUT=$(run "$T/stacktest.bin" 3000)
check_rc stacktest
CK=$(printf '%s' "$OUT" | grep -av '^tb:' | tr -d '\n' | tr -d '\r')
echo "  console: $CK"
case "$CK" in *P*=*1*2*3*4*) echo "  stacktest PASS";; *)
  echo "  stacktest FAIL (sub-word stack write clobbered — the L1/AXI lane bug)"; exit 1;; esac

say "3. calltest: near CALL/RET (+nested) through L1/AXI (expect clean exit ~67 retired)"
OUT=$(run "$T/calltest.bin" 4000)
check_rc calltest
R=$(printf '%s' "$OUT" | grep -oiE "retired [0-9]+ inst" | grep -oE "[0-9]+" | head -1)
echo "  retired=$R (low ~67 = completed; ~max = looped/broken)"
printf '%s' "$OUT" | grep -qi "isa-debug-exit" || { echo "  calltest FAIL (no isa-debug-exit — RET looped)"; exit 1; }
[ "${R:-9999}" -lt 500 ] || { echo "  calltest FAIL (ran to max-insn — RET mis-returned)"; exit 1; }
echo "  calltest PASS"

echo
echo "L1AXI-CALLRET-OK  (sub-word stack write + CALL/RET correct through L1/AXI+REMAP)"
