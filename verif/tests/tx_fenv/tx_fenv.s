# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M11b x87 test: tx_fenv -- FNSTENV (28-byte protected-mode env store)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87. gcc -m32 -march=pentium.
#
# FNSTENV (D9 /6) writes the 28-byte env image (CW/SW/FTW/FIP/FCS|FOP/FDP/FDS).
# Memory is NOT gate-compared, so all 7 env dwords are read back into distinct
# GPRs (eax/ecx/edx/ebx/esi/edi/ebp -- all live-graded) so QEMU and the RTL must
# agree byte-exact. A memory-operand FP op (fldl) is the last FP op before
# FNSTENV so FIP = its address and FDP = the operand address (FDS=DS, FCS=CS).
#
# Oracle-pinned shape (exact FIP/FDP are layout-specific -> the gate compares
# RTL-GPR vs QEMU-GPR, not a hardcoded value): CW=0x037F, SW TOP=5 (0x2800),
# FTW=0x43FF (phys5/6 valid, phys7 zero, rest empty), FIP=&fldl, FCS=0x23,
# FDP=&dval, FDS=0x2b, FOP=0.
#
# Exit: Linux i386 _exit(0) -> int 0x80.
# =============================================================================
    .text
    .globl  _start
_start:
    fninit
    fldz                    # st0 = +0.0   (phys7 zero)
    fld1                    # st0 = 1.0    (phys6 valid), st1 = 0
    fldl    dval            # st0 = 3.5 (mem operand -> FDP/FDS), st1=1, st2=0, TOP=5
    fnstenv env28
    movl    env28+0,  %eax  # CW
    movl    env28+4,  %ecx  # SW  (TOP overlaid)
    movl    env28+8,  %edx  # FTW
    movl    env28+12, %ebx  # FIP (= address of fldl)
    movl    env28+16, %esi  # FCS | FOP
    movl    env28+20, %edi  # FDP (= address of dval)
    movl    env28+24, %ebp  # FDS

    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 16
dval:  .double 3.5
env28: .fill 28, 1, 0
