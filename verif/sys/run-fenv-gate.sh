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

# REVIEW1_Aug2 M-04, second half: the 94-byte FNSAVE/FRSTOR forms. Same 640 bits of ST
# register data as the 108-byte form, delivered as 40 WORD beats instead of 20 dword
# beats (47 total). Oracle prints E4=3fff E5=eeee E6=eeee E7=0003.
E4=$(printf '%s' "$OUT" | grep -oE "E4=[0-9a-f]+" | head -1 | cut -d= -f2)
E5=$(printf '%s' "$OUT" | grep -oE "E5=[0-9a-f]+" | head -1 | cut -d= -f2)
E6=$(printf '%s' "$OUT" | grep -oE "E6=[0-9a-f]+" | head -1 | cut -d= -f2)
E7=$(printf '%s' "$OUT" | grep -oE "E7=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  94-byte state: layout=[+4]=${E4:-<none>} below=${E5:-<none>} past-end=${E6:-<none>} ST0=${E7:-<none>}"
if [ "$E4" != "3fff" ]; then
  [ "$E4" = "3800" ] && echo "  FAIL [+4] holds SW, not TW — the 108-BYTE layout went to a 94-byte object"
  [ "$E4" != "3800" ] && [ -n "${E4:-}" ] && echo "  FAIL unexpected [+4] '$E4' (want 3fff = TW with ST0 valid)"
  [ -z "${E4:-}" ] && echo "  FAIL no E4= line — the 94-byte form did not execute (decoder #UD?)"
  fenv_fail=1
else
  echo "  PASS 94-byte FNSAVE wrote the 94-byte LAYOUT (TW at +4)"
fi
if [ "$E5" != "eeee" ] || [ "$E6" != "eeee" ]; then
  echo "  FAIL FNSAVE wrote OUTSIDE its 94-byte object (below='$E5' past-end='$E6', both"
  echo "       want eeee). The 108-byte image overruns the end by 14 bytes."
  fenv_fail=1
else
  echo "  PASS 94-byte FNSAVE wrote exactly 94 bytes (clean above and below)"
fi
if [ "$E7" != "0003" ]; then
  echo "  FAIL 94-byte FRSTOR did not restore ST0: (int)ST0='$E7', want 0003 (pi)."
  echo "       FNSAVE reinitializes the FPU, so FRSTOR is the ONLY way pi comes back —"
  echo "       this is the 40-word REGISTER reassembly, not just the env header."
  fenv_fail=1
else
  echo "  PASS 94-byte FRSTOR restored the ST registers (pi survived the round trip)"
fi

# REVIEW1_Aug2 H-11: x87 STACK FAULTS. These three are a SELF-CHECK against the SDM,
# not a differential, because the oracle does not implement the feature at all:
#
#   target/i386/tcg/fpu_helper.c
#     static inline void fpush(CPUX86State *env)
#     { env->fpstt = (env->fpstt - 1) & 7; env->fptags[env->fpstt] = 0; }
#
#   no tag check. And `#define FPUS_SF (1 << 6)` at line 59 of that file is the ONLY
#   occurrence of the symbol in the entire i386 target -- defined, never used.
#
# Measured: the harness QEMU prints S1=3800 S2=3fff S3=0800, i.e. TOP moved and nothing
# else happened. So a CORRECT Ventium diverges here and a diff would fail exactly when
# the core is right -- the same situation as pseglim/segment limits.
#
# Expected per SDM Vol.1 8.5.1 + Table 8-4, with IM MASKED (the state FNINIT leaves):
#   S1 = 3a41  TOP=7 (nine pushes from 0), C1=1 (overflow), SF, IE
#   S2 = ffff  ST0's sign||exponent word: the masked response is the QNaN INDEFINITE,
#              not the pushed value. This is the response half, not just the flag.
#   S3 = 0841  TOP=1, C1=0 (underflow), SF, IE
# Enforcement is NOT in the default build (see fpu_writeback.sv for why), so build a
# separate object directory with +define+VEN_X87_STKFLT and re-run the SAME image.
STKOBJ=obj_dir_stk
STKTB="$ROOT/verif/tb/$STKOBJ/tb_ventium"
make -s -C "$TB" rtl OBJDIR="$STKOBJ" VL_EXTRA_DEFINES="+define+VEN_X87_STKFLT" >/dev/null
[ -x "$STKTB" ] || { echo "FENV-GATE-FAIL (stack-fault TB not built)"; exit 1; }
SOUT=$(timeout 180 "$STKTB" --system --cosim --image "$T/fenvtest.bin" --out /dev/null \
       --max-insn 12000 --quiesce 8000 2>&1 || true)
S1=$(printf '%s' "$SOUT" | grep -oE "S1=[0-9a-f]+" | head -1 | cut -d= -f2)
S2=$(printf '%s' "$SOUT" | grep -oE "S2=[0-9a-f]+" | head -1 | cut -d= -f2)
S3=$(printf '%s' "$SOUT" | grep -oE "S3=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  stack faults: overflow FSW=${S1:-<none>} ST0=${S2:-<none>} underflow FSW=${S3:-<none>}"
if [ "$S1" != "3a41" ]; then
  [ "$S1" = "3800" ] && echo "  FAIL a 9th push raised NOTHING — the push overwrote a live register silently"
  [ "$S1" != "3800" ] && [ -n "${S1:-}" ] && echo "  FAIL overflow FSW '$S1' (want 3a41 = TOP7|C1|SF|IE)"
  [ -z "${S1:-}" ] && echo "  FAIL no S1= line in the output"
  fenv_fail=1
else
  echo "  PASS stack OVERFLOW sets IE+SF with C1=1"
fi
if [ "$S2" != "ffff" ]; then
  [ "$S2" = "3fff" ] && echo "  FAIL ST0 holds the pushed 1.0, not the indefinite — flag set, RESPONSE missing"
  [ "$S2" != "3fff" ] && [ -n "${S2:-}" ] && echo "  FAIL ST0 sign/exp '$S2' (want ffff = QNaN indefinite)"
  [ -z "${S2:-}" ] && echo "  FAIL no S2= line in the output"
  fenv_fail=1
else
  echo "  PASS masked overflow delivered the QNaN indefinite to the destination"
fi
if [ "$S3" != "0841" ]; then
  [ "$S3" = "0800" ] && echo "  FAIL popping an empty stack raised NOTHING"
  [ "$S3" = "0a41" ] && echo "  FAIL C1 is SET on an underflow — C1 must distinguish the direction"
  [ "$S3" != "0800" ] && [ "$S3" != "0a41" ] && [ -n "${S3:-}" ] && echo "  FAIL underflow FSW '$S3' (want 0841)"
  [ -z "${S3:-}" ] && echo "  FAIL no S3= line in the output"
  fenv_fail=1
else
  echo "  PASS stack UNDERFLOW sets IE+SF with C1=0"
fi

# REVIEW1_Aug2 H-12 (remainder): a pending UNMASKED x87 exception must be delivered as
# #MF (vector 16) before the next waiting FP instruction. FSW.ES was derived but never
# consumed, so an unmasked exception was raised and then ignored forever.
#
# Unlike the stack faults above, the ORACLE IMPLEMENTS THIS -- QEMU emits
# gen_helper_fwait at translate.c:5538 (FWAIT) and :4608 (FNOP) -- so this one is graded
# DIFFERENTIALLY. The harness QEMU prints M1=0001, and so must Ventium.
#
# M1 counts handler entries. It must be exactly 1, which checks both directions at once:
#   0  -> ES was set but never consumed (the finding)
#   2+ -> the handler's FNCLEX did not clear ES, so the second FWAIT faulted again;
#         that would be an unrecoverable loop in real software.
M1=$(printf '%s' "$OUT" | grep -oE "M1=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  pending unmasked exception -> #MF deliveries: ${M1:-<none>} (want 0001)"
if [ "$M1" != "0001" ]; then
  [ "$M1" = "0000" ] && echo "  FAIL FWAIT did not trap on a pending unmasked exception — ES is still inert"
  [ "$M1" != "0000" ] && [ -n "${M1:-}" ] && echo "  FAIL #MF fired $M1 times; the handler's FNCLEX must clear ES (want 1)"
  [ -z "${M1:-}" ] && echo "  FAIL no M1= line in the output"
  fenv_fail=1
else
  echo "  PASS #MF delivered once on FWAIT, and FNCLEX cleared it (matches QEMU)"
fi

# REVIEW2_aug2 H-17: FWAIT is the ONE x87 instruction whose #NM rule is not "EM or TS".
# It traps only when CR0.MP=1 AND CR0.TS=1, so a lazy-FPU OS with MP=0 expects WAIT to
# pass even with TS set. The code NAMED this rule in a comment and never implemented it.
# Graded DIFFERENTIALLY -- the harness QEMU prints N1=0000 N2=0001.
N1=$(printf '%s' "$OUT" | grep -oE "N1=[0-9a-f]+" | head -1 | cut -d= -f2)
N2=$(printf '%s' "$OUT" | grep -oE "N2=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  FWAIT #NM: TS=1/MP=0 -> ${N1:-<none>} (want 0000)   TS=1/MP=1 -> ${N2:-<none>} (want 0001)"
if [ "$N1" != "0000" ]; then
  echo "  FAIL FWAIT trapped with MP=0 — a blanket TS->#NM breaks lazy-FPU switching"
  fenv_fail=1
elif [ "$N2" != "0001" ]; then
  [ "$N2" = "0000" ] && echo "  FAIL FWAIT did NOT trap with TS=1 and MP=1 (the rule is unimplemented)"
  [ "$N2" != "0000" ] && echo "  FAIL FWAIT trapped $N2 times, want 1"
  fenv_fail=1
else
  echo "  PASS FWAIT #NM only when CR0.MP and CR0.TS are BOTH set"
fi

# REVIEW2_aug2 H-16: FCOMPP/FUCOMPP retire TWO registers, and the detection checked only
# ST(0). A pop2 with a LIVE ST(0) over an EMPTY ST(1) went undetected -- the common shape
# after a single FLD. Read from the VEN_X87_STKFLT build (the response is gated there).
# Measured: pre-fix 0000, post-fix 0041 (IE|SF, C1=0).
S4=$(printf '%s' "$SOUT" | grep -oE "S4=[0-9a-f]+" | head -1 | cut -d= -f2)
echo "  pop2 over one live register: FSW(IE|SF|C1) = ${S4:-<none>} (want 0041)"
if [ "$S4" != "0041" ]; then
  [ "$S4" = "0000" ] && echo "  FAIL pop2 raised nothing — only ST(0)'s tag is being checked"
  [ "$S4" = "0241" ] && echo "  FAIL C1 is SET; an underflow must report C1=0"
  [ "$S4" != "0000" ] && [ "$S4" != "0241" ] && [ -n "${S4:-}" ] && echo "  FAIL unexpected '$S4'"
  fenv_fail=1
else
  echo "  PASS pop2 checks BOTH retired registers (IE+SF, C1=0)"
fi

if [ "$fenv_fail" = 0 ]; then
  echo "FENV-GATE-OK"
  exit 0
fi
echo "FENV-GATE-FAIL"
exit 1
