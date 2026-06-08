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
# BANDS — one kernel, two timelines: a dependent `fadd %st(1),%st` chain (each fadd
# RAW-depends on the running sum through the 3-cycle fadd latency) with an FXCH
# after EACH fadd:
#   * DEFAULT (no VEN_FXCH_FREE): each FXCH costs occ=1, so a fadd+fxch PAIR is
#     ~3(fadd lat) + 1(fxch) -> CPI ~2.0.
#   * +VEN_FXCH_FREE: each FXCH is free (occ=0, folds onto the adjacent fadd) ->
#     the pair is ~3 + 0 -> CPI ~1.5. The FXCH cost vanishes.
#
# Every FXCH immediately FOLLOWS an fadd (the realistic Quake pattern — never
# consecutive/lone), so it co-retires with the preceding FP op. Hot LOOP so the
# L1 I-cache is warm after pass 1. This is x87 FP -> P5 ISA.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $40, %ecx               # outer iteration count (I-cache warm after pass 1)
.Lrep:
    # THROUGHPUT-bound: 7 independent `fld1` PRODUCERS (fp_role 1 -> no RAW wait,
    # 1/clock), each immediately followed by an FXCH. DEFAULT charges each FXCH a
    # full clock (it can't hide — the flds are back-to-back); +VEN_FXCH_FREE folds
    # each FXCH into its preceding fld's commit clock (occ 0). 7 pushes keep the
    # x87 stack within its 8 slots; the 7 pops below restore depth each pass.
    .rept   7
    fld1                            # push 1.0 (throughput-bound producer)
    fxch    %st(1)                  # swap st(0)/st(1) ; FREE under VEN_FXCH_FREE (occ 0)
    .endr
    .rept   7
    fstp    %st(0)                  # restore stack depth
    .endr
    decl    %ecx                    # predictable back-edge (BTB-warm; negligible)
    jnz     .Lrep

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
