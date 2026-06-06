# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M4 cycle microbench: mb_indepadd
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (ported from ventium-refs/.../tools/microbench.c "indepadd"):
#   Interleave `add $1,%eax` and `add $1,%ebx`. The two destinations are
#   INDEPENDENT, so the pairing checker (can_pair) finds no RAW/WAW between the U
#   member (add eax) and the V candidate (add ebx): both are UV-pairable, no
#   disp+imm, no prefixes. The V slot fills every clock => two adds retire per core
#   clock. Result: CPI ~ 0.5, pairing > 40% (about half of all insns issue into V).
#   Each add carries an 8-bit immediate and NO displacement (has_disp_imm false),
#   so pairing is allowed.
#
# STRUCTURE — hot loop (see mb_depadd.s for the I-cache rationale): a SMALL unrolled
#   body (100 eax/ebx pairs = 200 adds) run 16 times keeps the body resident in the
#   8 KB L1 I-cache so the model's one-time cold-miss cost amortises away and CPI
#   converges to the true paired value ~0.5. The two xors reset the (independent)
#   accumulators each pass; the counted back-edge is predictable.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $16, %ecx               # ecx = outer iteration count
.Lrep:
    xorl    %eax, %eax              # eax = 0
    xorl    %ebx, %ebx              # ebx = 0
    .rept   100
    addl    $1, %eax                # U pipe: eax += 1
    addl    $1, %ebx                # V pipe: ebx += 1 (independent of eax => pairs)
    .endr
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lrep
    # ~3200 adds executed as ~1600 U+V pairs; I-cache warm; CPI ~ 0.5

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
