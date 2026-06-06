# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 test: tx_chain -- mixed x87 dependency chain + FXCH (Tier-2)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (docs/m3-fpu-spec.md Tier 2 "tx_chain"): a longer mixed expression that
# builds a real DEPENDENCY CHAIN across the FP stack and interleaves FXCH, to
# stress stack management (TOP rotation), operand-order correctness, and the
# accumulation of round-near-even error -- all bit-exact vs QEMU.
#
# Default control word 0x037f (round-nearest-even, 64-bit precision). NORMAL
# operands only (no inf/nan/denormal/zero-divide). Exceptions stay masked.
#
# Verified gas/QEMU pop-form semantics used below (with st0,st1 the top two):
#   faddp  %st,%st(1) = st0 + st1      fmulp  %st,%st(1) = st0 * st1
#   fsubp  %st,%st(1) = st0 - st1      fsubrp %st,%st(1) = st1 - st0
#   fdivp  %st,%st(1) = st0 / st1      fdivrp %st,%st(1) = st1 / st0
# (probed against QEMU; operand loads are arranged so the stated arithmetic
#  is what actually executes.)
#
# Expression PASS 1 (EXACT):  r = a*b + c/d - e
#   a=3 b=7 c=10 d=4 e=1.5  ->  21 + 2.5 - 1.5 = 22.0
# Expression PASS 2 (ROUNDING):  s = (1/3)*7 + sqrt(2) - (2/3)
#   1/3, sqrt(2), 2/3 are non-terminating -> round-near-even, PE latches; the
#   chain accumulates rounding error and the diff must match QEMU bit-exactly.
# Expression PASS 3 (EXACT, deep TOP rotation):  ((2*2)+(8/2))*2 - 4 = 12.0
#
# Covered ops: FLD/FLDS/FILD, FMULP, FDIVP/FDIVRP, FADDP, FSUBP/FSUBRP, FSQRT,
#              FXCH, FSTP. Deterministic. Ends _exit(0) (int 0x80 = HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # =====================================================================
    # PASS 1 -- EXACT: r = a*b + c/d - e = 3*7 + 10/4 - 1.5 = 22.0
    # =====================================================================
    # --- a*b = 21.0 ---
    flds    a                       # st0=a(3)
    flds    b                       # st0=b(7) st1=a(3)
    fmulp   %st, %st(1)             # st0 = st0*st1 = 7*3 = 21.0 (pop)   EXACT

    # --- c/d = 2.5 : need st0/st1 = 10/4, so load d(4) then c(10) ---
    flds    d                       # st0=d(4) st1=21
    flds    c                       # st0=c(10) st1=4 st2=21
    fdivp   %st, %st(1)             # st1 = st0/st1 = 10/4 = 2.5 (pop)
                                    #   -> st0=2.5 st1=21               EXACT

    # FXCH to reorder the two partials, then swap back (net NOP, exercises FXCH)
    fxch    %st(1)                  # st0=21 st1=2.5
    fxch    %st(1)                  # st0=2.5 st1=21  (back)

    # --- (a*b) + (c/d) = 23.5 ---
    faddp   %st, %st(1)             # st0 = st0+st1 = 2.5+21 = 23.5 (pop) EXACT

    # --- subtract e: r = 23.5 - 1.5 = 22.0 ---
    flds    e                       # st0=e(1.5) st1=23.5
    fsubrp  %st, %st(1)             # st1 = st1-st0 = 23.5-1.5 = 22.0 (pop)
                                    #   -> st0 = 22.0                   EXACT
    fstp    %st(0)                  # drop r -> stack empty

    # =====================================================================
    # PASS 2 -- ROUNDING: s = (1/3)*7 + sqrt(2) - (2/3)
    # =====================================================================
    # --- t1 = 1/3 : fdivrp = st1/st0, load 1 then 3 -> st0=3 st1=1 -> 1/3 ---
    flds    one                     # st0=1
    flds    three                   # st0=3 st1=1
    fdivrp  %st, %st(1)             # st1 = st1/st0 = 1/3 (pop) -> st0=1/3 ROUNDING

    # --- t1 = t1 * 7 = 7/3 ---
    flds    seven                   # st0=7 st1=1/3
    fmulp   %st, %st(1)             # st0 = 7*(1/3) = 7/3 (pop)          ROUNDING

    # --- t2 = sqrt(2), pushed above t1 ---
    flds    two                     # st0=2 st1=7/3
    fsqrt                           # st0 = sqrt(2)                      ROUNDING
    fxch    %st(1)                  # reorder: st0=7/3 st1=sqrt(2)

    # --- t1 + t2 ---
    faddp   %st, %st(1)             # st0 = (7/3)+sqrt(2) (pop)          ROUNDING

    # --- t3 = 2/3 : fdivp = st0/st1, load 2 then... need st0=2 st1=3 -> 2/3 ---
    flds    three                   # st0=3 st1=sum
    flds    two                     # st0=2 st1=3 st2=sum
    fdivp   %st, %st(1)             # st1 = st0/st1 = 2/3 (pop)
                                    #   -> st0=2/3 st1=sum               ROUNDING

    # --- s = (t1+t2) - t3 : fsubrp = st1-st0 = sum - 2/3 ---
    fsubrp  %st, %st(1)             # st1 = st1-st0 = sum - 2/3 (pop)    ROUNDING
    fstp    %st(0)                  # drop s -> stack empty

    # =====================================================================
    # PASS 3 -- EXACT, deep TOP rotation + FXCH:
    #   ((2*2) + (8/2)) * 2 - 4 = (4 + 4)*2 - 4 = 12.0
    # =====================================================================
    flds    two                     # st0=2
    flds    two                     # st0=2 st1=2
    fmulp   %st, %st(1)             # st0 = 2*2 = 4 (pop)               EXACT
    # 8/2 : fdivp = st0/st1, need st0=8 st1=2 -> load 2 then 8
    flds    two                     # st0=2 st1=4
    flds    eight                   # st0=8 st1=2 st2=4
    fdivp   %st, %st(1)             # st1 = st0/st1 = 8/2 = 4 (pop)
                                    #   -> st0=4 st1=4                   EXACT
    faddp   %st, %st(1)             # st0 = 4+4 = 8 (pop)               EXACT
    flds    two                     # st0=2 st1=8
    fmulp   %st, %st(1)             # st0 = 2*8 = 16 (pop)              EXACT
    flds    four                    # st0=4 st1=16
    fxch    %st(1)                  # st0=16 st1=4  (reorder)
    fsubr   %st(1), %st(0)          # st0 = st1-st0 = 4-16 = -12        EXACT
    fstp    %st(0)
    fstp    %st(0)                  # clear stack

    # =====================================================================
    # clean exit
    # =====================================================================
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 8
a:      .float  3.0
b:      .float  7.0
c:      .float  10.0
d:      .float  4.0
e:      .float  1.5
one:    .float  1.0
two:    .float  2.0
three:  .float  3.0
four:   .float  4.0
seven:  .float  7.0
eight:  .float  8.0
