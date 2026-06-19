# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# tx_regform2 -- x87 forms the first reg-form test misses:
#   FCOMP m32/m64 (D8/DC /3), FADD/.. ST(i),ST0 reverse-arith (DC C0+i:1539),
#   FSTP m64 (DD /3:1550), FUCOMP ST(i) (DD E8+i:1562),
#   FIADD/FICOM/FICOMP m16 (DE /x:1571-1573).
    .text
    .globl _start
_start:
    finit
    flds  flt                   # st0 = 2.5
    fld1                        # st0=1, st1=2.5
    fld1
    fadd  %st(0), %st(2)        # DC C0+i  ST(2) += ST0  (reverse direction)
    fmul  %st(0), %st(1)        # DC C8+i
    fcomps flt                  # D8 /3  FCOMP m32 (pop)
    fcompl dbl                  # DC /3  FCOMP m64 (pop)
    fldl  dbl
    fucomp %st(1)               # DD E8+i FUCOMP (pop)
    fiadds w16                  # DE /0  FIADD m16
    ficoms w16                  # DE /2  FICOM m16
    ficomps w16                 # DE /3  FICOMP m16 (pop)
    fstpl  out8                 # DD /3  FSTP m64
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
    .data
    .align 8
dbl:  .double 3.5
flt:  .float  2.5
w16:  .short  7
out8: .double 0.0
