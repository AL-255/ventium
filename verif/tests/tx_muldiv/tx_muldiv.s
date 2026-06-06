# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 test: tx_muldiv -- x87 multiply/divide family (Tier-2 arithmetic)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m3-fpu-spec.md Tier 2, default control word 0x037f =
# round-nearest-even, 64-bit precision), on NORMAL non-exceptional operands:
#   FMUL  st(i),st / st,st(i)   (D8/DC C8+i)
#   FMUL  m32 / m64             (D8 /1 , DC /1)
#   FMULP st(i),st              (DE C8+i)        gas: fmulp %st,%st(i)
#   FDIV  st(i),st / st,st(i)   (D8/DC F0/F8+i)  ST0 = ST0 / ST(i)
#   FDIVR st(i),st              (D8 F8+i)        ST0 = ST(i) / ST0
#   FDIV  m32 / m64 ; FDIVR m32
#   FDIVP / FDIVRP st(i),st     (DE F8/F0+i)
#   FIMUL m32 ; FIDIV m32       (DA /1 , DA /6 integer-memory mul/div)
#
# Direction was probed against QEMU:
#   fdiv  %st(1),%st(0)  =>  ST0 = ST0 / ST1   (3/10 = 0.3 -> rounds)
#   fdivr %st(1),%st(0)  =>  ST0 = ST1 / ST0   (10/3      -> rounds)
#
# Operand mix (EXACT vs ROUNDING verified per-op vs QEMU's PE/precision bit):
#   EXACT (product/quotient fits the 64-bit significand):
#     3*8=24, 8*24=192, 2.5*4=10, 10*0.5=5, 5*0.1f=0.5, 0.1f*0.1f, 24/8=3,
#     100/4=25, 25/2=12.5, 10/2=5, 8/2=4, 3/2=1.5, 6*7=42, 42/2=21.
#     (single (.float) operands carry only 24 mantissa bits, so their products
#      stay exact in 80-bit -> PE stays 0; verified.)
#   ROUNDING (non-terminating quotient -> round-near-even, PE latches):
#     10.0/3.0, 1.0/3.0, 1.0/3.0(m32), 1.0/10.0, 10/3 (integer-memory FIDIV).
#   The diff just has to MATCH QEMU's rounded floatx80; not hand-predicted.
#
# No inf/nan/denormal, no zero divide, exceptions masked (default cw).
# Deterministic. Ends with Linux i386 _exit(0) (int 0x80 = HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---------------------------------------------------------------------
    # (1) FMUL register forms -- EXACT
    #     load 8.0 then 3.0 -> st0=3 st1=8
    # ---------------------------------------------------------------------
    flds    f_eight                 # st0=8
    flds    f_three                 # st0=3 st1=8
    fmul    %st(1), %st(0)          # st0 = 3*8 = 24.0          EXACT
    fmul    %st(0), %st(1)          # st1 = 8*24 = 192.0        EXACT (st,st(i))
    fstp    %st(0)                  # drop st0(24)
    fstp    %st(0)                  # drop st0(192) -> empty

    # ---------------------------------------------------------------------
    # (2) FMUL m32 / m64 -- all EXACT here.
    #     NOTE (verified vs QEMU, PE=0): products of single (.float) operands
    #     stay within the 64-bit significand (a single carries only 24 mantissa
    #     bits, so 5.0*0.1f and 0.1f*0.1f are EXACT in 80-bit extended). The
    #     genuine multiply/divide ROUNDING cases live in the divisions below,
    #     where 10/3, 1/3, 1/10 are non-terminating and latch PE.
    # ---------------------------------------------------------------------
    flds    f_2p5                   # st0 = 2.5
    fmuls   f_four                  # st0 = 2.5 * 4 = 10.0      EXACT (m32)
    fmull   d_half                  # st0 = 10 * 0.5 = 5.0      EXACT (m64)
    fmuls   f_tenth                 # st0 = 5.0 * 0.1f = 0.5    EXACT (m32, verified)
    fstp    %st(0)

    flds    f_tenth                 # st0 = 0.1f
    fmuls   f_tenth                 # st0 = 0.1f * 0.1f         EXACT (verified)
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (3) FMULP -- EXACT product chain of powers of two
    # ---------------------------------------------------------------------
    flds    f_two                   # st0=2
    flds    f_four                  # st0=4 st1=2
    fmulp   %st, %st(1)             # st1 = 2*4 = 8, pop -> st0=8   EXACT
    flds    f_eight                 # st0=8 st1=8
    fmulp   %st, %st(1)             # st0 = 64                       EXACT
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (4) FDIV / FDIVR register forms
    #     EXACT : 24/8 = 3.0     (fdiv  %st(1),%st(0) = st0/st1)
    #     ROUND : 10/3           (fdiv  %st(1),%st(0))
    #     ROUND : 1/3            (fdivr %st(1),%st(0) = st1/st0, st0=3 st1=1)
    # ---------------------------------------------------------------------
    flds    f_eight                 # st0=8
    flds    f_24                    # st0=24 st1=8
    fdiv    %st(1), %st(0)          # st0 = 24/8 = 3.0          EXACT
    fstp    %st(0)
    fstp    %st(0)                  # -> empty

    flds    f_three                 # st0=3
    flds    f_ten                   # st0=10 st1=3
    fdiv    %st(1), %st(0)          # st0 = 10/3                ROUNDING
    fstp    %st(0)
    fstp    %st(0)                  # -> empty

    flds    f_one                   # st0=1
    flds    f_three                 # st0=3 st1=1
    fdivr   %st(1), %st(0)          # st0 = st1/st0 = 1/3       ROUNDING
    fstp    %st(0)
    fstp    %st(0)                  # -> empty

    # ---------------------------------------------------------------------
    # (5) FDIV / FDIVR m32 / m64
    #     EXACT: 100/4=25, 5/2=2.5
    #     ROUND: 1.0/3.0 (m32 divisor 3), 1.0/10.0
    # ---------------------------------------------------------------------
    flds    f_hundred               # st0 = 100
    fdivs   f_four                  # st0 = 100/4 = 25.0        EXACT (m32)
    fdivl   d_two                   # st0 = 25/2 = 12.5         EXACT (m64)
    fstp    %st(0)

    flds    f_one                   # st0 = 1.0
    fdivs   f_three                 # st0 = 1.0/3.0             ROUNDING (m32)
    fstp    %st(0)

    flds    f_one                   # st0 = 1.0
    fdivs   f_ten                   # st0 = 1.0/10.0 (0.1 not dyadic) ROUNDING
    fstp    %st(0)

    # FDIVR memory: ST0 = mem / ST0  -- gas fdivrs computes mem/st0
    flds    f_two                   # st0 = 2.0
    fdivrs  f_ten                   # st0 = 10.0/2.0 = 5.0      EXACT (m32)
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (6) FDIVP / FDIVRP  (gas/QEMU-verified results below) -- both EXACT
    # ---------------------------------------------------------------------
    flds    f_two                   # st0=2
    flds    f_eight                 # st0=8 st1=2
    fdivp   %st, %st(1)             # DE F1: pop -> st0 = 8/2 = 4.0       EXACT
    fstp    %st(0)

    flds    f_three                 # st0=3
    flds    f_two                   # st0=2 st1=3
    fdivrp  %st, %st(1)             # DE F9: pop -> st0 = 3/2 = 1.5       EXACT
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (7) FIMUL m32 / FIDIV m32 -- integer-memory mul/div
    #     EXACT: 6*7=42, 100/4=25 ; ROUND: 10/3
    # ---------------------------------------------------------------------
    flds    f_six                   # st0 = 6.0
    fimull  i_seven                 # st0 = 6*7 = 42.0          EXACT
    fidivl  i_two                   # st0 = 42/2 = 21.0         EXACT
    fstp    %st(0)

    fildl   i_ten                   # st0 = 10.0
    fidivl  i_three                 # st0 = 10/3               ROUNDING
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # clean exit: Linux i386 _exit(0)
    # ---------------------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 8
f_one:      .float  1.0
f_two:      .float  2.0
f_three:    .float  3.0
f_four:     .float  4.0
f_six:      .float  6.0
f_eight:    .float  8.0
f_ten:      .float  10.0
f_24:       .float  24.0
f_2p5:      .float  2.5
f_half:     .float  0.5
f_tenth:    .float  0.1
f_hundred:  .float  100.0
d_half:     .double 0.5
d_two:      .double 2.0
i_two:      .long   2
i_three:    .long   3
i_seven:    .long   7
i_ten:      .long   10
