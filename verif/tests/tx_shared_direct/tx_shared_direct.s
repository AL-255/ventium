# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Cycle-mode shared-FP direct-handoff regression.  The initial x87 sequence
# consists of register-only decoder forms that may bypass S_FETCH / S_DECODE,
# but every one must still commit via S_FEXEC.  FNSTENV then exposes the
# preceding direct instruction's saved FIP through EDX, exercising the q_pc/
# q_len handoff in addition to the x87 stack and arithmetic state.

    .text
    .globl _start
_start:
    fld1                    # FK_FLDC: push 1.0
    fld1                    # FK_FLDC: push 1.0
    fadd    %st(1), %st     # FK_ARITH: ST0 = 2.0
    fxch    %st(1)          # FK_FXCH:  ST0 = 1.0, ST1 = 2.0
    fld     %st(0)          # FK_FLDSTI: duplicate ST0
    fstp    %st(0)          # FK_FSTP0: discard the duplicate
    fmul    %st(1), %st     # FK_ARITH: ST0 = 2.0
    fsub    %st(1), %st     # FK_ARITH: ST0 = 0.0
    fsubr   %st(1), %st     # FK_ARITH: ST0 = 2.0

    # FNSTENV must preserve the FIP of the preceding FSUBr rather than its own
    # address.  The differential trace observes EDX after this load.
    fnstenv env
    movl    env+12, %edx

    fstp    %st(0)
    fstp    %st(0)
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 16
env:
    .space 28
