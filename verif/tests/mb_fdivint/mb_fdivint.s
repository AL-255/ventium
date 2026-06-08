# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium cycle microbench: mb_fdivint   (GATED — VEN_FP_OVERLAP / GAP1 demo)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# THE QUAKE MECHANISM (gaps doc GAP1, "Quake, Floating Point, and the Intel
# Pentium"): the P5 FPU has early-exception logic so that during an FDIV's long
# execution window (~39c extended) the INTEGER pipe keeps issuing in parallel —
# only a FOLLOWING FP op stalls on the FP unit. This is what let Quake's
# perspective-correct texture mapper overlap the per-span FP divide with the
# fixed-point integer texel addressing.
#
# BANDS — two contrasting timelines from ONE kernel:
#   * DEFAULT (no VEN_FP_OVERLAP): one in-order pipe_free_at = issue + occ, so the
#     FDIV's occ=39 SERIALIZES the 8 integer adds behind it -> high CPI.
#   * +VEN_FP_OVERLAP: the FDIV frees the integer pipe after the short dispatch
#     slot (occ 2) and the 39c exec window lives on fp_busy_until; the 8 adds
#     (alternating regs -> U/V pairs) retire IN the FDIV shadow, and only the
#     trailing `fld1` FP PRODUCER pays the FP-unit-busy wait -> lower CPI.
#
# The 8 adds use alternating eax/ebx/esi/edi so consecutive ones are independent
# and pair U/V (2/clock). The trailing `fld1` is an FP *producer* (fp_role==1, not
# a consumer) so it isolates fp_busy_until: it does NOT depend on the quotient via
# the fp_ready (role>=2) path, yet it must still wait for the FP unit. Hot LOOP so
# the L1 I-cache is warm after pass 1 (cold-miss cycles don't perturb CPI).
# This is x87 FP -> P5 ISA (isa_verify treats x87 as in-scope).
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $40, %ecx               # outer iteration count (I-cache warm after pass 1)
.Lrep:
    fld1                            # st(0) = 1.0   (dividend)
    fld1                            # st(0) = 1.0, st(1) = 1.0 (divisor)
    fdiv    %st(1), %st             # st(0) /= st(1)  -> opens the ~39c FDIV shadow
    addl    $1, %eax                # 16 INDEPENDENT integer adds (alternating regs ->
    addl    $1, %ebx                # pair U/V = 8 pair-cycles, all < the 39c shadow).
    addl    $1, %esi                # DEFAULT: serialized behind occ=39 (+8 cycles/iter).
    addl    $1, %edi                # +VEN_FP_OVERLAP: ALL retire IN the FDIV shadow (free),
    addl    $1, %eax                # mirroring Quake's per-span texel addressing hidden
    addl    $1, %ebx                # under the perspective-divide. Total drops >10%.
    addl    $1, %esi
    addl    $1, %edi
    addl    $1, %eax
    addl    $1, %ebx
    addl    $1, %esi
    addl    $1, %edi
    addl    $1, %eax
    addl    $1, %ebx
    addl    $1, %esi
    addl    $1, %edi
    addl    $1, %eax
    addl    $1, %ebx
    addl    $1, %esi
    addl    $1, %edi
    addl    $1, %eax
    addl    $1, %ebx
    addl    $1, %esi
    addl    $1, %edi
    addl    $1, %eax
    addl    $1, %ebx
    addl    $1, %esi
    addl    $1, %edi
    fld1                            # FOLLOWING FP PRODUCER (role1) -> serializes on the
                                    # FP unit (fp_busy_until), NOT via the quotient dep.
    fstp    %st(0)                  # pop the extra st (stack hygiene)
    fstp    %st(0)                  # pop the quotient
    fstp    %st(0)                  # pop the remaining st
    decl    %ecx                    # predictable back-edge (BTB-warm; negligible)
    jnz     .Lrep

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
