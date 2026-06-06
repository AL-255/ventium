# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_op8  --  8-bit operand forms / partial-register coverage
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
#       -o t_op8.elf t_op8.s
#
# Goal: exercise the 8-bit operand forms (B0+r mov imm8, /r byte ALU, byte
# shifts) and prove the partial-register write rules from docs/m2-isa-spec.md:
#   * writing AL/CL/DL/BL updates [7:0] and PRESERVES [31:8].
#   * writing AH/CH/DH/BH updates [15:8] and PRESERVES the rest.
#   * flags are computed on the 8-bit result (SF = bit7, ZF on low8,
#     CF/OF on the byte boundary, PF computed over the low byte).
#
# Each byte register is pre-seeded with a known surrounding context
# (0x1122334455-style is impossible in 32 bits, so 0x11223344) so a bug that
# zero/sign-extends a byte result into the wider register, or that writes AL
# when AH was intended (or vice-versa), corrupts a checked GPR and the gate
# catches it.
#
# Uses 8-bit forms of: mov (B0+r imm8, 88/8A reg), add, adc, sub, sbb, and,
#   or, xor, cmp, test, inc, dec (FE /0,/1), neg, not (F6 /3,/2), shl/shr/sar
#   (D0/D2/C0 byte group), rol by 1. No div/idiv. No undefined-DEST ops.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- seed full 32-bit regs with known surrounding bytes -----------------
    movl    $0x11223344, %eax       # AL=0x44 AH=0x33 ; hi=0x1122
    movl    $0x55667788, %ecx       # CL=0x88 CH=0x77 ; hi=0x5566
    movl    $0x99AABBCC, %edx       # DL=0xCC DH=0xBB ; hi=0x99AA
    movl    $0xDEADBEEF, %ebx       # BL=0xEF BH=0xBE ; hi=0xDEAD

    # ---- 8-bit MOV imm (B0+r): write AL/AH, preserve everything else --------
    movb    $0x01, %al              # AL=0x01 ; eax = 0x11223301
    movb    $0x02, %ah              # AH=0x02 ; eax = 0x11220201
    movb    $0xFF, %cl              # CL=0xff ; ecx = 0x556677ff
    movb    $0x10, %ch              # CH=0x10 ; ecx = 0x556610ff

    # ---- 8-bit reg->reg MOV (88/8A): move AL into BL, CH into DL ------------
    movb    %al, %bl                # BL = AL = 0x01 ; ebx = 0xDEAD BE01
    movb    %ch, %dl                # DL = CH = 0x10 ; edx = 0x99AABB10

    # ---- 8-bit ADD reg,reg: flags on byte, hi preserved ---------------------
    movb    $0x7F, %al              # AL = 0x7f ; eax = 0x1122027f
    movb    $0x01, %bl              # BL = 0x01 ; ebx = 0xDEADBE01
    addb    %bl, %al                # AL = 0x80 (OF=1 signed overflow, SF=1) ; eax=0x11220280

    # ---- 8-bit ADD that carries out of bit7 (CF set, wraps byte) ------------
    movb    $0xFF, %al              # AL = 0xff
    addb    $0x02, %al              # AL = 0x01 (CF=1) ; eax = 0x11220201

    # ---- 8-bit ADC / SBB (carry chain on byte) ------------------------------
    movb    $0x00, %dl              # DL = 0 ; edx = 0x99AABB00
    adcb    $0x10, %dl              # DL = 0x10 + CF(1) = 0x11 ; edx = 0x99AABB11
    sbbb    $0x01, %dl              # DL = 0x11 - 0x01 - CF(0) = 0x10

    # ---- 8-bit SUB producing zero (ZF=1, PF=1 over the byte) ----------------
    movb    $0x42, %al              # AL = 0x42
    subb    $0x42, %al              # AL = 0 (ZF=1, PF=1) ; eax = 0x11220200

    # ---- 8-bit logicals: AND/OR/XOR (CF=OF=0, PF over byte) -----------------
    movb    $0x3C, %al              # AL = 0x3c ; eax = 0x1122023c
    andb    $0x0F, %al              # AL = 0x0c (PF over 0x0c) ; eax = 0x1122020c
    orb     $0xF0, %al              # AL = 0xfc ; eax = 0x112202fc
    xorb    $0xFF, %al              # AL = 0x03 ; eax = 0x11220203

    # ---- 8-bit CMP / TEST (flags only, no dest write) -----------------------
    cmpb    $0x03, %al              # AL==3 -> ZF=1
    testb   %al, %al                # SF from bit7 (0x03 -> SF=0), CF=OF=0, PF set

    # ---- 8-bit INC / DEC (CF preserved; OF/SF/ZF/AF/PF on byte) -------------
    movb    $0x7F, %dl              # DL = 0x7f ; edx = 0x99AABB7f
    incb    %dl                     # DL = 0x80 (OF=1, SF=1) ; edx = 0x99AABB80
    decb    %dl                     # DL = 0x7f (OF=1) ; edx = 0x99AABB7f

    # ---- 8-bit NEG / NOT -----------------------------------------------------
    movb    $0x01, %dl              # DL = 1 ; edx = 0x99AABB01
    negb    %dl                     # DL = 0xff (CF=1) ; edx = 0x99AABBff
    notb    %dl                     # DL = 0x00 ; edx = 0x99AABB00

    # ---- 8-bit shifts: by 1 (D0), by imm8 (C0), by CL (D2), count masked ----
    movb    $0x81, %al              # AL = 0x81 ; eax = 0x11220281
    shlb    $1, %al                 # AL = 0x02 (CF=1 from bit7) ; eax=0x11220202
    movb    $0x80, %al              # AL = 0x80
    shrb    $1, %al                 # AL = 0x40 (CF=0) ; eax = 0x11220240
    movb    $0x80, %al              # AL = 0x80
    sarb    $1, %al                 # AL = 0xc0 (arith) ; eax = 0x112202c0
    movb    $0x01, %al              # AL = 1
    shlb    $3, %al                 # AL = 0x08, by imm (OF undefined for cnt!=1)
    # shift by CL: set CL = 2, shift AH by CL (exercises AH as dest + CL count)
    movb    $0x02, %cl              # CL = 2 ; ecx = 0x556610 02
    movb    $0x05, %ah              # AH = 0x05 ; eax = 0x11220508
    shlb    %cl, %ah                # AH = 0x14 ; eax = 0x11221408
    # shift by CL count==0 => NO flag change (must match QEMU exactly)
    xorb    %cl, %cl                # CL = 0
    movb    $0x33, %al              # AL = 0x33
    shrb    %cl, %al                # count 0: AL unchanged, flags unchanged

    # ---- 8-bit ROL by 1 (affects only CF/OF) --------------------------------
    movb    $0x81, %bl              # BL = 0x81 ; ebx = 0xDEADBE81
    rolb    $1, %bl                 # BL = 0x03 (CF=1, OF defined) ; ebx=0xDEADBE03

    # ---- final fold: write BH and confirm independence from BL --------------
    movb    $0x77, %bh              # BH = 0x77 ; ebx = 0xDEAD7703

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
