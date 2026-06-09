# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Ventium #11 x87 test: tx_fyl2x — FYL2X = ST1*log2(ST0), D9 F1.
# Meaningful only under +VEN_TRANSCENDENTAL; driven by run-fyl2x-core-gate.sh.
# Each case: fld y (->ST1); fld x (->ST0); fyl2x (ST1*log2(ST0), pop); fstp.
    .text
    .globl  _start
_start:
.macro YL2X ylab, xlab
    fldt    \ylab
    fldt    \xlab
    fyl2x
    fstp    %st(0)
.endm
    YL2X v_1,  v_2          # log2(2)=1
    YL2X v_1,  v_8          # 3
    YL2X v_2,  v_8          # 6
    YL2X v_1,  v_10         # log2(10)
    YL2X v_3,  v_p5         # 3*log2(0.5)=-3
    YL2X v_1,  v_p25        # -2
    YL2X v_m2, v_3          # -2*log2(3)
    YL2X v_1,  v_1p5        # log2(1.5)
    YL2X v_p7, v_100        # 0.7*log2(100)
    YL2X v_1,  v_1          # log2(1)=+0
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
    .data
    .align 16
v_1:   .tfloat  1.0
v_2:   .tfloat  2.0
v_8:   .tfloat  8.0
v_10:  .tfloat  10.0
v_3:   .tfloat  3.0
v_m2:  .tfloat -2.0
v_p5:  .tfloat  0.5
v_p25: .tfloat  0.25
v_1p5: .tfloat  1.5
v_p7:  .tfloat  0.7
v_100: .tfloat  100.0
