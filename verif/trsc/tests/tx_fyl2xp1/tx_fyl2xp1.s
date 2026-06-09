# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Ventium #11 x87 test: tx_fyl2xp1 — FYL2XP1 = ST1*log2(ST0+1), D9 F9.
# ST0 must have |value| < 1-sqrt(2)/2 = 0.292. Driven by run-fyl2x-core-gate.sh.
    .text
    .globl  _start
_start:
.macro YL2XP1 ylab, xlab
    fldt    \ylab
    fldt    \xlab
    fyl2xp1
    fstp    %st(0)
.endm
    YL2XP1 v_1,  v_p1        # log2(1.1)
    YL2XP1 v_2,  v_m2        # 2*log2(0.8)
    YL2XP1 v_1,  v_p25       # log2(1.25)
    YL2XP1 v_5,  v_m1        # 5*log2(0.9)
    YL2XP1 v_1,  v_tiny      # tiny ln-path
    YL2XP1 v_3,  v_p15       # 3*log2(1.15)
    YL2XP1 v_m1, v_m05       # log2(0.95)*(-0.1)
    YL2XP1 v_1,  v_0         # x=0 -> 0 (passthrough)
    YL2XP1 v_1,  v_oor       # x out of range (0.5) -> #IA / default NaN
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
    .data
    .align 16
v_1:    .tfloat  1.0
v_2:    .tfloat  2.0
v_3:    .tfloat  3.0
v_5:    .tfloat  5.0
v_m1:   .tfloat -0.1
v_p1:   .tfloat  0.1
v_m2:   .tfloat -0.2
v_p25:  .tfloat  0.25
v_p15:  .tfloat  0.15
v_m05:  .tfloat -0.05
v_0:    .tfloat  0.0
v_tiny: .tfloat  1e-25
v_oor:  .tfloat  0.5
