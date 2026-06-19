# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_mulw -- 8-bit and 16-bit MUL/IMUL (the q_w==1 / q_w==2 multiply widths the
# 32-bit-only t_mul never exercises: core_exec.svh/core_gpr_wb.svh width arms).
    .text
    .globl _start
_start:
    # MUL r8 : AX = AL * r8
    movb  $0x07, %al
    movb  $0x06, %bl
    mulb  %bl                 # AX = 42
    movb  $0xff, %al
    movb  $0xff, %cl
    mulb  %cl                 # AX = 0xFE01, CF/OF=1
    # IMUL r8 : AX = AL * r8 (signed)
    movb  $0xfe, %al          # -2
    movb  $0x03, %bl          # 3
    imulb %bl                 # AX = -6 = 0xFFFA
    movb  $0x40, %al
    movb  $0x40, %cl
    imulb %cl                 # 0x1000, OF/CF=1 (doesn't fit in AL signed)
    # MUL r16 : DX:AX = AX * r16
    movw  $0x1234, %ax
    movw  $0x0010, %bx
    mulw  %bx                 # DX:AX = 0x00012340
    movw  $0x8000, %ax
    movw  $0x0002, %cx
    mulw  %cx                 # DX:AX=0x00010000, CF/OF=1
    # IMUL r16 : DX:AX = AX * r16 (signed), plus 2-op and 3-op 16-bit forms
    movw  $0xfffe, %ax        # -2
    movw  $0x0003, %bx
    imulw %bx                 # DX:AX = -6
    movw  $0x0005, %ax
    imulw $0x0007, %bx, %ax   # 16-bit 3-op imul  (ax = bx*7)
    movw  $0x0003, %cx
    imulw %cx, %ax            # 16-bit 2-op imul  (0F AF, 66 prefix)
    # exit
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
