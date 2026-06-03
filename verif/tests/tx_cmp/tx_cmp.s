# =============================================================================
# Ventium M3 x87 test: tx_cmp -- compares / classify, condition codes (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md Tier 1 "Compare"): set the status-word condition codes
# C0/C2/C3 (and C1) for the <, >, == cases of every compare op, plus a QNaN-
# unordered case for FUCOM, and the classify (FXAM) / integer-compare (FICOM)
# forms. Each compare is followed by FNSTSW AX so the codes also surface in AX.
#
# Ops covered:
#   FCOM/FCOMP/FCOMPP  (D8 /2, D8 /3, DE D9)
#   FUCOM/FUCOMP/FUCOMPP (DD E0+i, DD E8+i, DA E9)
#   FTST  (D9 E4), FXAM (D9 E5)
#   FICOM/FICOMP m32 (DA /2, DA /3)
#   FNSTSW AX (DF E0)
#
# Verified condition-code encodings (C3 C2 C0 in fstat bits 14/10/8; C1 bit 9):
#   greater : 000 ;  less : 001 (C0) ;  equal : 100 (C3) ;  unordered : 111
#   FXAM: +0.0 -> C3C2C1C0=1000 (Zero, +) ; -finite -> 0110 (Normal, -sign C1=1)
#         empty -> 1001 (Empty)
# All operands are exactly representable (1.0 / 2.0 / 0.0 / integers); the QNaN
# case uses a quiet NaN so FUCOM does NOT raise #IA (stays masked, no fault).
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ===== FCOM: greater (st0=2.0 > st1=1.0) =================================
    fld1                    # st1-to-be = 1.0
    flds    f2_0            # st0 = 2.0
    fcom    %st(1)          # 2.0 ? 1.0 -> greater : C3C2C0 = 000
    fnstsw  %ax
    fcompp                  # pop both (DE D9), clears stack

    # ===== FCOMP: equal (st0=1.0 == st1=1.0), pops st0 ======================
    fld1
    fld1
    fcomp   %st(1)          # 1.0 ? 1.0 -> equal : C3=1, pop st0
    fnstsw  %ax
    fstp    %st(0)          # pop the remaining 1.0 -> empty

    # ===== FCOM: less (st0=1.0 < st1=2.0) ===================================
    flds    f2_0            # st1-to-be = 2.0
    fld1                    # st0 = 1.0
    fcom    %st(1)          # 1.0 ? 2.0 -> less : C0=1
    fnstsw  %ax
    fcompp                  # pop both -> empty

    # ===== FTST: st0 (1.0) vs +0.0 -> greater (C3C2C0=000) ==================
    fld1
    ftst                    # 1.0 ? 0.0 -> greater
    fnstsw  %ax
    fstp    %st(0)          # pop -> empty

    # ===== FUCOM: QNaN unordered (no #IA, quiet) ============================
    fld1                    # st1-to-be = 1.0
    fldl    qnan            # st0 = QNaN
    fucom   %st(1)          # QNaN ? 1.0 -> unordered : C3C2C0 = 111
    fnstsw  %ax
    fucompp                 # pop both (DA E9) -> empty

    # ===== FICOM / FICOMP: integer-memory compare ===========================
    flds    f2_0            # st0 = 2.0
    ficoml  ten             # 2.0 ? 10 -> less : C0=1
    fnstsw  %ax
    ficompl one_i           # 2.0 ? 1 -> greater : 000, pop
    fnstsw  %ax
    # stack empty

    # ===== FXAM classify: +0.0, then -2.0, then empty =======================
    fldz                    # st0 = +0.0
    fxam                    # Zero, + : C3C2C1C0 = 1000
    fnstsw  %ax
    flds    f2_0
    fchs                    # st0 = -2.0
    fxam                    # Normal, - : C3C2C1C0 = 0110 (C2=1, C1=sign=1)
    fnstsw  %ax
    fstp    %st(0)          # pop -2.0
    fstp    %st(0)          # pop +0.0 -> st0 EMPTY
    fxam                    # Empty : C3C2C1C0 = 1001
    fnstsw  %ax

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax        # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80           # halt

    # =========================================================================
    .data
    .align 8
f2_0:   .float  2.0
qnan:   .quad   0x7FF8000000000000      # double-precision quiet NaN
ten:    .long   10
one_i:  .long   1
