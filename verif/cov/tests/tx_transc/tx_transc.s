# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# tx_transc -- x87 TRANSCENDENTALS over MULTIPLE operands to walk the iterative
# engines (fpu_f2xm1/fpu_fyl2x/fpu_fsincos/fpu_fpatan), enabled only under
# +VEN_TRANSCENDENTAL (default build defers->HALT, so KNOWN_FAIL / FLAGS-lane).
    .text
    .globl _start
_start:
    finit
    # F2XM1 over several x in [-1,1]
    flds  c_p50
    f2xm1
    finit
    flds  c_n50
    f2xm1
    finit
    flds  c_p25
    f2xm1
    finit
    fld1
    f2xm1
    finit
    # FYL2X / FYL2XP1 over several x>0
    fldl2e
    flds  c_3
    fyl2x
    finit
    fldl2t
    flds  c_10
    fyl2x
    finit
    fld1
    flds  c_p50
    fyl2xp1
    finit
    # FSIN/FCOS/FSINCOS over several angles
    fldpi
    fsin
    finit
    flds  c_p50
    fcos
    finit
    fld1
    fsincos
    finit
    fldz
    fsin
    finit
    # FPTAN / FPATAN
    flds  c_p50
    fptan
    finit
    flds  c_3
    flds  c_10
    fpatan
    finit
    fld1
    fld1
    fpatan
    finit
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
    .data
    .align 4
c_p50: .float  0.5
c_n50: .float -0.5
c_p25: .float  0.25
c_3:   .float  3.0
c_10:  .float  10.0
