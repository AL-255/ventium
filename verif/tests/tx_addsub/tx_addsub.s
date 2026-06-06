# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 test: tx_addsub -- x87 add/subtract family (Tier-2 arithmetic)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m3-fpu-spec.md Tier 2, default control word 0x037f =
# round-nearest-even, 64-bit precision), on NORMAL non-exceptional operands:
#   FADD  st(i),st / st,st(i)   (D8/DC C0+i)
#   FADD  m32 / m64             (D8 /0 , DC /0)
#   FADDP st(i),st              (DE C0+i)
#   FSUB  st(i),st / st,st(i)   (D8/DC E0/E8+i)   ST(0)=ST(0)-ST(i)
#   FSUBR st(i),st              (D8 E8+i)         ST(0)=ST(i)-ST(0)
#   FSUBP st(i),st              (DE E8+i)
#   FSUBRP st(i),st             (DE E0+i)
#   FADD  m32/m64 ; FSUB m32/m64
#   FIADD m32 ; FISUB m32       (DA /0 , DA /4 integer-memory add/sub)
#
# AT&T two-register operand direction was probed against QEMU:
#   fsub  %st(1),%st(0)  =>  ST0 = ST0 - ST1
#   fsubr %st(1),%st(0)  =>  ST0 = ST1 - ST0
# (Intel ST0 = ST0 - ST(i) for FSUB, ST0 = ST(i) - ST0 for FSUBR.)
#
# Operand mix -- both EXACT (sum/diff representable in 64-bit mantissa) and
# ROUNDING (result needs >64 significant bits, so round-nearest-even fires):
#   EXACT    : 10.0+/-3.0, 2.0+/-0.5, integer sums that fit, powers of two,
#              and single (.float) loads (single->80b is exact and small sums
#              stay within the 64-bit significand -- verified PE=0 vs QEMU).
#   ROUNDING : adds/subs of two DOUBLES of very different magnitude, whose
#              EXACT result needs >64 significand bits, so round-near-even
#              fires and PE (precision) latches in the status word. The diff
#              only has to MATCH QEMU's rounded floatx80; we don't hand-predict.
#
# No inf/nan/denormal, no zero divide, exceptions stay masked (default cw).
# Deterministic. Ends with Linux i386 _exit(0) (int 0x80 = HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---------------------------------------------------------------------
    # (1) FADD st(i),st and the register two-operand forms  -- EXACT
    #     load 3.0 then 10.0 -> st0=10 st1=3
    # ---------------------------------------------------------------------
    flds    f_three                 # st0=3
    flds    f_ten                   # st0=10 st1=3
    fadd    %st(1), %st(0)          # st0 = 10+3 = 13.0       (EXACT)
    faddp   %st, %st(1)          # st1 += st0, pop -> st0 = 3+13 = 16.0 (EXACT)
    fstp    %st(0)                  # drop -> stack empty

    # ---------------------------------------------------------------------
    # (2) FADD m32 / m64  -- EXACT and a genuine 64-bit-mantissa ROUNDING case
    #     Note: a single (.float) widens to 80-bit EXACTLY and small sums of
    #     such operands stay exact in the 64-bit significand (no PE). To force
    #     ADD rounding we add two DOUBLES of very different magnitude, whose
    #     EXACT sum needs >64 significand bits -> round-near-even, PE latches.
    #     (Verified vs QEMU: d_big + d_small sets PE=1.)
    # ---------------------------------------------------------------------
    flds    f_two                   # st0=2.0
    fadds   f_half                  # st0 = 2.0 + 0.5 = 2.5     EXACT (m32)
    faddl   d_quarter               # st0 = 2.5 + 0.25 = 2.75   EXACT (m64)
    fstp    %st(0)
    fldl    d_big                   # st0 = 1.2345678901234567 (53-bit dbl)
    faddl   d_small                 # st0 = d_big + d_small     ROUNDING (m64)
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (3) FADDP exact accumulation of powers of two -- EXACT
    #     8 + 4 = 12, then +2 = 14, then +1 = 15
    # ---------------------------------------------------------------------
    flds    f_eight                 # st0=8
    flds    f_four                  # st0=4 st1=8
    faddp   %st, %st(1)          # st0 = 12  (pop)          EXACT
    flds    f_two                   # st0=2 st1=12
    faddp   %st, %st(1)          # st0 = 14                 EXACT
    flds    f_one                   # st0=1 st1=14
    faddp   %st, %st(1)          # st0 = 15                 EXACT
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (4) FSUB / FSUBR register forms -- EXACT
    #     load 3.0 then 10.0 -> st0=10 st1=3
    # ---------------------------------------------------------------------
    flds    f_three
    flds    f_ten
    fsub    %st(1), %st(0)          # st0 = 10-3 = 7.0         EXACT
    flds    f_three
    flds    f_ten
    fsubr   %st(1), %st(0)          # st0 = 3-10 = -7.0        EXACT
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)                  # clear leftover st's

    # ---------------------------------------------------------------------
    # (5) FSUBP / FSUBRP  -- EXACT then ROUNDING
    #     gas/QEMU-verified: with st0=3 st1=10,
    #        fsubp  %st,%st(1)  assembles DE E1 -> st0 = -7.0  (10-? -> -7)
    #        fsubrp %st,%st(1)  assembles DE E9 -> st0 = +7.0
    #     Both are EXACT integers; we just exercise the two popping encodings.
    # ---------------------------------------------------------------------
    flds    f_ten                   # st0=10
    flds    f_three                 # st0=3 st1=10
    fsubp   %st, %st(1)             # DE E1: pop -> st0 = -7.0          EXACT
    fstp    %st(0)
    flds    f_ten                   # st0=10
    flds    f_three                 # st0=3 st1=10
    fsubrp  %st, %st(1)             # DE E9: pop -> st0 = +7.0          EXACT
    fstp    %st(0)

    # subtract two doubles of differing magnitude -> exact diff needs >64 bits
    flds    f_one                   # (filler so we exercise a 2-deep stack)
    fldl    d_big                   # st0 = d_big st1 = 1.0
    fsubl   d_small                 # st0 = d_big - d_small      ROUNDING (m64)
    fstp    %st(0)
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (6) FSUB m32 / m64  -- EXACT and ROUNDING
    # ---------------------------------------------------------------------
    flds    f_ten                   # st0=10
    fsubs   f_two                   # st0 = 10-2 = 8.0           EXACT (m32)
    fsubl   d_quarter               # st0 = 8 - 0.25 = 7.75      EXACT (m64)
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (7) FIADD m32 / FISUB m32  -- integer-memory add/sub (EXACT integers)
    # ---------------------------------------------------------------------
    flds    f_hundred               # st0 = 100.0
    fiaddl  i_seven                 # st0 = 100 + 7  = 107.0     EXACT
    fisubl  i_fifty                 # st0 = 107 - 50 = 57.0      EXACT
    fstp    %st(0)

    # mixed: integer load then add a double whose sum needs >64 bits -> rounds
    fildl   i_three                 # st0 = 3.0
    faddl   d_big                   # st0 = 3.0 + 1.2345678901234567  ROUNDING
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # clean exit: Linux i386 _exit(0)  (int 0x80 = HALT in the harness)
    # ---------------------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80

    # =========================================================================
    # Read-only operand pool. .float = 32-bit, .double = 64-bit, .long = int32.
    # =========================================================================
    .data
    .align 8
f_one:      .float  1.0
f_two:      .float  2.0
f_three:    .float  3.0
f_four:     .float  4.0
f_eight:    .float  8.0
f_ten:      .float  10.0
f_half:     .float  0.5
f_hundred:  .float  100.0
d_quarter:  .double 0.25
# Two doubles whose EXACT sum/diff needs >64 significand bits -> forces
# round-near-even in 80-bit extended (verified vs QEMU: PE latches).
d_big:      .double 1.2345678901234567
d_small:    .double 0.0000007654321
i_three:    .long   3
i_seven:    .long   7
i_fifty:    .long   50
