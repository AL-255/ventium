#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fenv-gate.sh — REVIEW2 M-01 self-check: FNSTENV must MASK ALL x87 exceptions.
#
# SDM Vol.2 (FSTENV/FNSTENV): "After saving the FPU environment, the FPU exception
# masks are set" -- FCW[5:0] <- 6'b111111. Ventium did not do this.
#
# WHY A SELF-CHECK AND NOT A DIFFERENTIAL TEST -- both reasons are load-bearing:
#
#  1. The DEFAULT control word 0x037F ALREADY has bits[5:0] = 0x3F, so on every
#     existing x87 program `fctrl | 0x3F` is a NO-OP. `make verify` passed 98/98 with
#     the fix in place and would have passed without it: the behaviour is never
#     reached. The test therefore FIRST clears the mask bits (CW = 0x0340).
#
#  2. QEMU DOES NOT IMPLEMENT IT. do_fstenv() in target/i386/tcg/fpu_helper.c stores
#     the environment and returns; there is no `fpuc |= 0x3f` anywhere in the QEMU
#     tree (verified by grep, and translate.c adds nothing around the helper). The
#     ORACLE IS WRONG HERE, so a differential test would fail exactly when Ventium is
#     architecturally CORRECT. That is why this asserts against the SDM directly.
#
# Expected: CW=037f   (0x0340 with all six mask bits set again)
# Without the fix the core prints CW=0340 -- verified by removing the masking and
# re-running, which is what makes this gate meaningful rather than decorative.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/mabench"
BIN="${TB_BIN:-$TB/obj_dir/tb_ventium}"

echo "== x87 env gate (REVIEW2 M-01): FNSTENV masks all exceptions =="
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -c "$T/fenvtest.S" -o "$T/fenvtest.o"
gcc -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -static -no-pie \
    -Wl,-T,"$T/mabench.ld" -Wl,--build-id=none "$T/fenvtest.o" -o "$T/fenvtest.elf" 2>/dev/null
objcopy -O binary "$T/fenvtest.elf" "$T/fenvtest.bin"
truncate -s 65536 "$T/fenvtest.bin"
make -C "$TB" OBJDIR=obj_dir >/dev/null

# The tb exits via isa-debug-exit ((0x42<<1)|1 = 133) even on success, so the OUTPUT
# decides; only a timeout (124) is treated as a failure of the run itself.
set +e
OUT=$(timeout 180 "$BIN" --system --cosim --image "$T/fenvtest.bin" --out /dev/null \
      --max-insn 4000 --quiesce 8000 2>&1)
RC=$?
set -e
[ "$RC" != 124 ] || { echo "FENV-GATE-FAIL (timeout — the run HUNG)"; exit 1; }

CW=$(printf '%s' "$OUT" | grep -oE "CW=[0-9a-f]+" | head -1 | cut -d= -f2)
SW=$(printf '%s' "$OUT" | grep -oE "SW=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  CW after FNSTENV = ${CW:-<none>}  (loaded 0340 with ALL masks clear)"
echo "  FSW IE|ES|B      = ${SW:-<none>}  (0.0/0.0 with IM clear)"

# REVIEW1_Aug2 H-12: FSW.ES is the error summary -- set when a flag is raised AND that
# exception is unmasked. Nothing derived it, so ES read 0 in all 10165 fstat records the
# previous round measured, which ALSO made the B:=ES mirror inert. 0.0/0.0 with IM clear
# must set IE (0x0001), ES (0x0080) and B (0x8000) => 0x8081. A core that does not derive
# ES prints 0001 here.
fenv_fail=0
if [ "$CW" != "037f" ]; then
  [ "$CW" = "0340" ] && echo "  FAIL FNSTENV left FCW untouched — the mask-after-store is missing"
  [ "$CW" != "0340" ] && [ -n "${CW:-}" ] && echo "  FAIL unexpected FCW '$CW' (want 037f)"
  [ -z "${CW:-}" ] && echo "  FAIL no CW= line in the output"
  fenv_fail=1
else
  echo "  PASS FNSTENV set FCW[5:0] (all x87 exceptions masked, per SDM Vol.2)"
fi
if [ "$SW" != "8081" ]; then
  [ "$SW" = "0001" ] && echo "  FAIL IE was raised but ES/B were NOT derived (H-12)"
  [ "$SW" != "0001" ] && [ -n "${SW:-}" ] && echo "  FAIL unexpected FSW '$SW' (want 8081 = IE|ES|B)"
  [ -z "${SW:-}" ] && echo "  FAIL no SW= line in the output"
  fenv_fail=1
else
  echo "  PASS an UNMASKED exception sets FSW.ES and mirrors it to FSW.B"
fi
# REVIEW1_Aug2 M-04: the 14-byte (16-bit operand-size) FNSTENV/FLDENV forms. The
# sequencer wrote the 28-byte image for these too, so 14 bytes PAST the guest's object
# were destroyed on every 16-bit FNSTENV -- and 16-bit code takes that form by DEFAULT,
# with no prefix. All three witnesses below were graded against the harness QEMU, which
# prints exactly `E1=ffff E2=eeee E3=037f`.
E1=$(printf '%s' "$OUT" | grep -oE "E1=[0-9a-f]+" | head -1 | cut -d= -f2)
E2=$(printf '%s' "$OUT" | grep -oE "E2=[0-9a-f]+" | head -1 | cut -d= -f2)
E3=$(printf '%s' "$OUT" | grep -oE "E3=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  14-byte env: layout=[+4]=${E1:-<none>} past-end=${E2:-<none>} reload=${E3:-<none>}"
if [ "$E1" != "ffff" ]; then
  [ "$E1" = "0000" ] && echo "  FAIL [+4] holds SW, not TW — the 28-BYTE layout was written to a 14-byte object"
  [ "$E1" != "0000" ] && [ -n "${E1:-}" ] && echo "  FAIL unexpected [+4] '$E1' (want ffff = TW)"
  [ -z "${E1:-}" ] && echo "  FAIL no E1= line — the 14-byte form did not execute (decoder #UD?)"
  fenv_fail=1
else
  echo "  PASS 14-byte FNSTENV wrote the 14-byte LAYOUT (TW at +4, not SW)"
fi
if [ "$E2" != "eeee" ]; then
  echo "  FAIL the word PAST the 14-byte object reads '$E2', not the eeee poison —"
  echo "       FNSTENV overran the guest's object. This is the finding itself."
  fenv_fail=1
else
  echo "  PASS 14-byte FNSTENV wrote exactly 14 bytes (nothing past the object)"
fi
if [ "$E3" != "037f" ]; then
  echo "  FAIL 14-byte FLDENV round trip gave CW='$E3' (want 037f) — the load half"
  echo "       does not read back the layout the store half wrote."
  fenv_fail=1
else
  echo "  PASS 14-byte FLDENV read back what 14-byte FNSTENV wrote"
fi

if [ "$fenv_fail" = 0 ]; then
  echo "FENV-GATE-OK"
  exit 0
fi
echo "FENV-GATE-FAIL"
exit 1
