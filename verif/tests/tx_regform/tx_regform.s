# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# tx_regform -- x87 REGISTER-FORM fast-decode + writeback coverage:
#   FLD constants (D9 E8..ED : FK_FLDC), FLD ST(i) (D9 C0+i : FK_FLDSTI),
#   FXCH (D9 C8+i : FK_FXCH), ST0 op ST(i) (D8 C0+i.. : FK_ARITH),
#   FSTP ST(i) (DD D8+i : FK_FSTP0), FRNDINT (D9 FC), FSCALE (D9 FD),
#   FCOM mem32/mem64 (FX_FCOM_M32/M64), FWAIT (9B). Deterministic, x87-compared.
    .text
    .globl _start
_start:
    finit
    fld1                    # D9 E8  st0=1.0
    fldl2t                  # D9 E9
    fldl2e                  # D9 EA
    fldpi                   # D9 EB
    fldlg2                  # D9 EC
    fldln2                  # D9 ED
    fldz                    # D9 EE
    fld   %st(1)            # D9 C0+i  push copy of st(1)
    fxch  %st(2)            # D9 C8+i  swap st0,st2
    fadd  %st(1), %st       # D8 C0+i  st0 += st1
    fmul  %st(2), %st       # D8 C8+i  st0 *= st2
    fsub  %st(1), %st       # D8 E0+i
    fdiv  %st(3), %st       # D8 F0+i
    frndint                 # D9 FC
    fld1
    fldl2e
    fscale                  # D9 FD  st0 = st0 * 2**trunc(st1)
    fstp  %st(0)            # DD D8   pop/discard
    fcoml dbl               # FX_FCOM_M64
    fcoms flt               # FX_FCOM_M32
    fwait                   # 9B
    fstp  %st(0)
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
    .data
    .align 8
dbl: .double 3.5
flt: .float  2.5
