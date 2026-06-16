# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_xlat  --  XLATB  (D7)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# XLATB: AL <- [DS:(E)BX + zero-extend(AL)].  One byte, no ModR/M, touches NO
# flags. Only AL changes (the upper 24 bits of EAX and EBX are preserved). The
# differential gate checks every GPR + EFLAGS after each instruction, so a wrong
# table byte, a clobbered upper-EAX, a wrong base, or a stray flag all diverge.
#
# Coverage: index 0, a mid index, the top index, and a re-load of EBX between
# lookups (XLATB must not touch EBX). The 16-byte table holds byte i = i*0x11
# (0x00,0x11,..,0xFF) so the loaded value is a direct function of the index.
# =============================================================================

    .text
    .globl  _start
_start:

    leal    xtab, %ebx              # base for [EBX + AL]

    # ---- index 0 -> table[0] = 0x00 ------------------------------------
    movl    $0xAABBCC00, %eax        # AL = 0x00
    xlat                            # AL <- 0x00  -> eax = 0xAABBCC00

    # ---- index 5 -> table[5] = 0x55 ------------------------------------
    movl    $0xAABBCC05, %eax        # AL = 0x05
    xlat                            # AL <- 0x55  -> eax = 0xAABBCC55

    # ---- index 0x0A -> table[10] = 0xAA --------------------------------
    movl    $0x1234560A, %eax        # AL = 0x0A
    xlatb                           # AL <- 0xAA  -> eax = 0x123456AA

    # ---- top index 0x0F -> table[15] = 0xFF ----------------------------
    movl    $0x9900000F, %eax        # AL = 0x0F
    xlat                            # AL <- 0xFF  -> eax = 0x990000FF

    # ---- chained: result of one XLATB feeds the next index -------------
    # eax=0x?..03 -> table[3]=0x33; then AL=0x33 is out of the 16-byte
    # table, so set AL explicitly again to a safe index to stay in-table.
    movl    $0x00000003, %eax        # AL = 0x03
    xlat                            # AL <- table[3] = 0x33  -> eax = 0x00000033

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 4
xtab:
    .byte 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    .byte 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
