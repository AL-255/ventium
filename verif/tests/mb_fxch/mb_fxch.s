# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium cycle microbench: mb_fxch   (GATED — VEN_FXCH_FREE / GAP2 demo)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# THE FREE-FXCH MECHANISM (gaps doc GAP2, "Quake, Floating Point, and the Intel
# Pentium" + Front-End Part 1): the P5 executes FXCH as a stack-pointer/tag RENAME
# in parallel with an adjacent FP op (~0 added cycles), giving x87 the flexibility
# of a flat register file. Quake leans on this to ~double effective FP throughput.
#
# BANDS — seven throughput-bound FLD1/FXCH producers per iteration, followed
# by seven pops. The legacy cycle oracle charges each ordinary FXCH one clock;
# fxchfree=1 folds it into the preceding producer. The CPI <= 1.10 band is
# unchanged. This test is not a measurement of gameplay or asynchronous FP IPC.
#
# The persistent initial entry is essential: without it the FIRST exchange
# reads empty ST(1), raises stack underflow, and makes the old throughput test
# exercise exceptional behavior. Depth is now 1..8 inside the loop, then zero
# after teardown. Invalid FXCH remains covered by px87stk and the shared-FP TB.
# =============================================================================

    .text
    .globl  _start
_start:
    fld1                            # persistent, valid exchange partner
    movl    $40, %ecx               # outer iteration count (I-cache warm after pass 1)
.Lrep:
    # THROUGHPUT-bound: 7 independent `fld1` PRODUCERS (fp_role 1 -> no RAW wait,
    # 1/clock), each immediately followed by an FXCH. DEFAULT charges each FXCH a
    # full clock (it can't hide — the flds are back-to-back); +VEN_FXCH_FREE folds
    # each FXCH into its preceding fld's commit clock (occ 0). Seven pushes on
    # the persistent entry reach depth 8; seven pops restore depth 1 each pass.
    .rept   7
    fld1                            # push 1.0 (throughput-bound producer)
    fxch    %st(1)                  # swap st(0)/st(1) ; FREE under VEN_FXCH_FREE (occ 0)
    .endr
    .rept   7
    fstp    %st(0)                  # restore stack depth
    .endr
    decl    %ecx                    # predictable back-edge (BTB-warm; negligible)
    jnz     .Lrep
    fstp    %st(0)                  # remove the persistent entry; depth zero

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
