# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_xchg  --  XCHG r/m, r  (0x86 byte / 0x87 word|dword / 0x90+r)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# XCHG swaps the two operands. The hard corner — and a real Ventium bug this test
# was added to lock down — is XCHG between two byte halves of the SAME 16-bit
# register (e.g. `xchg %ch,%cl`). The register-file writeback merged BOTH byte
# writes from the original register value, so the second write discarded the
# first: only one half swapped. `xchg %ch,%cl` on CX=0x0025 produced 0x2525
# (ch<-cl only) instead of 0x2500. FreeDOS's INT 13h cylinder packing uses
# exactly `xchg %ch,%cl; ror; ror`, so every cylinder>=1 disk read was corrupted.
#
# Coverage: 32/16/8-bit reg<->reg, the same-register byte-half swaps for all of
# CX/AX/BX/DX (the bug), high8<->low8 across registers, the 0x90+r accumulator
# form, `xchg %eax,%eax` NOP, and a memory exchange (folded into a GPR). Every
# committed instruction's full state is differentially checked against QEMU.
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- 32-bit reg <-> reg (basic) ------------------------------------
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    xchg    %ebx, %eax              # eax<-0x22222222, ebx<-0x11111111

    # ---- 16-bit (0x66): low halves swap, upper halves preserved --------
    movl    $0xAAAA1234, %eax       # ax=0x1234
    movl    $0xBBBB5678, %ecx       # cx=0x5678
    xchgw   %cx, %ax                # ax<-0x5678, cx<-0x1234; tops 0xAAAA/0xBBBB

    # ---- 8-bit low <-> low across registers ----------------------------
    movl    $0x000000AA, %eax       # al=0xAA
    movl    $0x000000BB, %ebx       # bl=0xBB
    xchgb   %bl, %al                # al<-0xBB, bl<-0xAA

    # ====================================================================
    # THE BUG: xchg two byte-halves of the SAME 16-bit register.
    # ====================================================================
    movl    $0x00000025, %ecx       # cx=0x0025 (ch=0x00, cl=0x25)
    xchg    %ch, %cl                # MUST be cx=0x2500 (Ventium bug gave 0x2525)

    movl    $0x12345678, %eax       # ax=0x5678 (ah=0x56, al=0x78)
    xchg    %al, %ah                # MUST be ax=0x7856; top 0x1234 preserved

    movl    $0x0000ABCD, %ebx       # bx=0xABCD (bh=0xAB, bl=0xCD)
    xchg    %bl, %bh                # MUST be bx=0xCDAB

    movl    $0xFFFF0F00, %edx       # dx=0x0F00 (dh=0x0F, dl=0x00)
    xchg    %dl, %dh                # MUST be dx=0x000F; top 0xFFFF preserved

    # ---- high8 <-> low8 across DIFFERENT registers ---------------------
    movl    $0x0000AA00, %eax       # ah=0xAA
    movl    $0x000000BB, %ebx       # bl=0xBB
    xchg    %bl, %ah                # ah<-0xBB, bl<-0xAA

    # ---- 0x90+r accumulator form: xchg %ebx,%eax -----------------------
    movl    $0xDEADBEEF, %eax
    movl    $0xCAFEBABE, %ebx
    xchg    %ebx, %eax              # eax<-0xCAFEBABE, ebx<-0xDEADBEEF

    # ---- xchg %eax,%eax == NOP -----------------------------------------
    movl    $0x13572468, %eax
    xchg    %eax, %eax              # unchanged

    # ---- memory exchange (32-bit), result folded into a GPR ------------
    leal    dword_a, %edi
    movl    $0xAABBCCDD, dword_a    # seed [edi]
    movl    $0x99887766, %esi
    xchg    %esi, (%edi)            # [edi]<-0x99887766, esi<-0xAABBCCDD
    movl    dword_a, %ebp           # ebp=0x99887766 (fold the store into state)

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 4
dword_a:  .long 0x00000000
