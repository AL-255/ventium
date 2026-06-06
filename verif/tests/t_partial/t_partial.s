# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_partial  --  partial-register preserved-bits stress
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
#       -o t_partial.elf t_partial.s
#
# Goal: hammer the partial-register write/preserve rules (docs/m2-isa-spec.md
# "Operand sizes & prefixes") by INTERLEAVING 8-/16-/32-bit writes and reads on
# the SAME architectural registers, and by contrasting them with MOVZX/MOVSX
# (which DO write the full 32 bits, zero/sign extending). The classic P5 bug is
# treating AL/AX writes as full-width (clobbering [31:8]/[31:16]) or aliasing
# AH and AL; every step below reads back the full register through ALU so any
# such bug corrupts a checked GPR.
#
#   1. Build a 32-bit value byte-by-byte: AL, then AH, then 16-bit AX-rotate,
#      observing that AL/AH are the SAME 16-bit lane but independent bytes, and
#      that [31:16] is untouched.
#   2. MOVZX / MOVSX from AL/AX into other regs (full 32-bit dest, contrast).
#   3. 16-bit op feeding an 8-bit op feeding a 32-bit op on one register.
#   4. The xchg-eax-nop edge (0x90) and 8-bit xchg of partials.
#
# Uses: mov (8/16/32), movzx/movsx (0F B6/B7/BE/BF), add/and/or (8/16/32),
#   inc (8/16), xchg r/m8,r8 (86), xchg eax,r32 (90+r) incl 0x90 NOP.
# No undefined-flag-only ops other than benign ones; no faulting.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- 1. build a dword byte-by-byte, preserving the rest -----------------
    movl    $0x12340000, %eax       # eax = 0x12340000 (hi half is the "preserve" witness)
    movb    $0xEF, %al              # AL=0xef ; eax = 0x123400ef
    movb    $0xBE, %ah              # AH=0xbe ; eax = 0x1234beef  <- assembled low16
    # AL and AH are independent: prove AH write did not touch AL
    addb    $0x01, %al              # AL = 0xf0 ; eax = 0x1234bef0
    addb    $0x01, %ah              # AH = 0xbf ; eax = 0x1234bff0
    # now write the WHOLE low 16 at once; [31:16] still preserved
    movw    $0x00AA, %ax            # AX = 0x00aa ; eax = 0x123400aa

    # ---- 2. MOVZX / MOVSX: full-32 dest (zero/sign extend) ------------------
    movb    $0x80, %al              # AL = 0x80 (negative byte) ; eax = 0x12340080
    movzbl  %al, %ecx               # ecx = 0x00000080 (zero-extend byte)
    movsbl  %al, %edx               # edx = 0xffffff80 (sign-extend byte)
    movw    $0x8001, %ax            # AX = 0x8001 (negative word) ; eax=0x12348001
    movzwl  %ax, %esi               # esi = 0x00008001 (zero-extend word)
    movswl  %ax, %edi               # edi = 0xffff8001 (sign-extend word)
    # movzx/movsx with a separate source register (BL/BX), full dest
    movl    $0x77777777, %ebx       # ebx = 0x77777777
    movb    $0x7F, %bl              # BL = 0x7f ; ebx = 0x7777777f
    movzbl  %bl, %ebp               # ebp = 0x0000007f

    # ---- 3. chained 16->8->32 writes on one register (edx) ------------------
    movl    $0xCAFE0000, %edx       # edx = 0xcafe0000 (hi witness = 0xcafe)
    movw    $0x1200, %dx            # DX = 0x1200 ; edx = 0xcafe1200
    movb    $0x34, %dl              # DL = 0x34 ; edx = 0xcafe1234
    incw    %dx                     # DX = 0x1235 ; edx = 0xcafe1235 (hi preserved)
    incb    %dl                     # DL = 0x36 ; edx = 0xcafe1236
    orl     $0x000F0000, %edx       # full-32 OR ; edx = 0xcaff1236 (hi now touched)

    # ---- 4. xchg edge cases --------------------------------------------------
    # 0x90 = NOP = xchg %eax,%eax (must be a true no-op, eax unchanged)
    nop                             # 0x90
    # xchg %eax, %ecx (90+r form): swaps full 32-bit values
    movl    $0xAAAA1111, %eax       # eax = 0xaaaa1111
    movl    $0xBBBB2222, %ecx       # ecx = 0xbbbb2222
    xchgl   %eax, %ecx              # eax=0xbbbb2222 ecx=0xaaaa1111
    # xchg %al, %bl (86 /r byte): swaps only the low bytes, preserves [31:8]
    movl    $0x11223344, %eax       # eax = 0x11223344 (AL=0x44)
    movl    $0xAABBCCDD, %ebx       # ebx = 0xaabbccdd (BL=0xdd)
    xchgb   %al, %bl                # AL<->BL : eax=0x112233dd ebx=0xaabbcc44

    # ---- final fold so a partial bug is visible in flags-bearing GPRs -------
    movw    $0x0000, %si            # SI=0 ; esi = 0x00000000 (hi was 0)
    addl    %ecx, %eax              # eax = 0x112233dd + 0xaaaa1111 = 0xbbcc44ee

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
