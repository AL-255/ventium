# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium #11 x87 test: tx_fpatan — FPATAN atan2(ST1,ST0), D9 F3.
# =============================================================================
# Quake's ONLY transcendental. Built like the corpus. Meaningful only under
# +VEN_TRANSCENDENTAL (the fpu_fpatan engine), driven by run-fpatan-core-gate.sh,
# which func-diffs st0..st7/fctrl/fstat/ftag vs the qemu-i386 gdbstub golden.
#
# Each case loads ST1=y then ST0=x (fld y; fld x), runs FPATAN (-> ST0=atan(y/x),
# popped), then fstp to clear. Covers all four quadrants, the axis corners
# (pi/2, -pi/2, pi, +0 passthrough), and the |y|<>|x| boundary.
# =============================================================================
    .text
    .globl  _start
_start:
.macro ATAN ylab, xlab
    fldt    \ylab            # ST0 = y  (becomes ST1)
    fldt    \xlab            # ST0 = x, ST1 = y
    fpatan                   # ST0 = atan(y/x), popped
    fstp    %st(0)
.endm
    ATAN v_p5,  v_p5         # Q1
    ATAN v_1,   v_2          # Q1 |y|<|x|
    ATAN v_p5,  v_m5         # Q2
    ATAN v_1,   v_m2         # Q2
    ATAN v_m5,  v_m5         # Q3
    ATAN v_m1,  v_m2         # Q3
    ATAN v_m5,  v_p5         # Q4
    ATAN v_m1,  v_2          # Q4
    ATAN v_1,   v_0          # +pi/2
    ATAN v_m1,  v_0          # -pi/2
    ATAN v_0,   v_m1         # +pi
    ATAN v_0,   v_1          # +0 passthrough
    ATAN v_3,   v_1          # |y|>|x|
    ATAN v_1,   v_3          # |y|<|x|
    ATAN v_p7,  v_1p3        # irregular (Quake-like)
    ATAN v_m0p3,v_0p9        # irregular

    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 16
v_p5:   .tfloat  0.5
v_m5:   .tfloat -0.5
v_1:    .tfloat  1.0
v_m1:   .tfloat -1.0
v_2:    .tfloat  2.0
v_m2:   .tfloat -2.0
v_3:    .tfloat  3.0
v_0:    .tfloat  0.0
v_p7:   .tfloat  0.7
v_1p3:  .tfloat  1.3
v_m0p3: .tfloat -0.3
v_0p9:  .tfloat  0.9
