# =============================================================================
# Ventium M3 x87 test: tx_const -- constant loads + sign/abs (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
# Built like the rest of the corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md Tier 1 "Constants" + "Sign/abs"): load every x87 ROM
# constant and verify the EXACT 80-bit floatx80 QEMU produces, then exercise
# FABS / FCHS on positive, negative and signed-zero operands.
#
# Ops covered:
#   FLDZ FLD1 FLDPI FLDL2E FLDL2T FLDLG2 FLDLN2  (D9 /5 group, ROM constants)
#   FABS (D9 E1), FCHS (D9 E0)
#   FSTP st(i) used only to tear the stack down between phases (Tier 1 move op)
#
# Golden constants QEMU emits (verified via gen_trace --x87):
#   FLD1   = 0x3fff8000000000000000   (+1.0)
#   FLDPI  = 0x4000c90fdaa22168c235   (pi)
#   FLDZ   = 0x00000000000000000000   (+0.0)
#   FLDL2E = 0x3fffb8aa3b295c17f0bc   (log2(e))
#   FLDL2T = 0x4000d49a784bcd1b8afe   (log2(10))
#   FLDLG2 = 0x3ffd9a209a84fbcff799   (log10(2))
#   FLDLN2 = 0x3ffeb17217f7d1cf79ac   (ln(2))
#
# No arithmetic, no transcendentals. fctrl stays 0x037f throughout; fstat only
# tracks TOP; QEMU reports ftag = 0x0000 for all of these (abridged g-packet).
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- ROM constants: push all seven, check 80-bit st regs ----------------
    fld1                    # st0 = +1.0
    fldpi                   # st0 = pi      (st1 = 1.0)
    fldl2e                  # st0 = log2(e)
    fldl2t                  # st0 = log2(10)
    fldlg2                  # st0 = log10(2)
    fldln2                  # st0 = ln(2)   -- 6 deep
    fldz                    # st0 = +0.0    -- 7 deep (TOP wraps to 001)

    # tear the stack back down to empty (FSTP st(0) discards top, pops)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)          # stack empty again, TOP back to 000

    # ---- FABS / FCHS on +1.0 ------------------------------------------------
    fld1                    # st0 = +1.0
    fchs                    # st0 = -1.0  (0xbfff8000000000000000)
    fabs                    # st0 = +1.0  (abs of negative)
    fchs                    # st0 = -1.0
    fchs                    # st0 = +1.0  (double negate -> positive)
    fabs                    # st0 = +1.0  (abs of positive, idempotent)
    fstp    %st(0)          # pop

    # ---- FABS / FCHS on signed zero -----------------------------------------
    fldz                    # st0 = +0.0
    fchs                    # st0 = -0.0  (0x80000000000000000000) sign bit only
    fabs                    # st0 = +0.0  (abs clears sign even on zero)
    fchs                    # st0 = -0.0
    fstp    %st(0)          # pop

    # ---- FABS / FCHS on pi --------------------------------------------------
    fldpi                   # st0 = +pi
    fchs                    # st0 = -pi   (0xc000c90fdaa22168c235)
    fabs                    # st0 = +pi
    fstp    %st(0)          # pop -> empty

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax        # __NR_exit
    xorl    %ebx, %ebx      # status 0
    int     $0x80           # halt
