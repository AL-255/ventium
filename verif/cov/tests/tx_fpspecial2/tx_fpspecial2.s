# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# tx_fpspecial2 -- x87 EXCEPTION-operand corners: FSCALE huge up/down scale
# (fpu_writeback.sv:744/747/752/755 OE/UE arms) and an SNaN input (:697
# SNaN->QNaN + IE). Deterministic results (Inf / 0 / QNaN), x87-compared.
    .text
    .globl _start
_start:
    finit
    fildl  big
    fld1
    fscale
    fstp   %st(0)
    fildl  neg
    fld1
    fscale
    fstp   %st(0)
    flds   snan
    fld1
    faddp  %st, %st(1)
    fstp   %st(0)
    movl   $1, %eax
    xorl   %ebx, %ebx
    int    $0x80
    .data
    .align 8
big:  .long  40000
neg:  .long  -40000
snan: .long  0x7fa00000
