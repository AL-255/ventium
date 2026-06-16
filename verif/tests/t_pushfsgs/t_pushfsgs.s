# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_pushfsgs  --  PUSH FS (0F A0) / PUSH GS (0F A8)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# PUSH FS / PUSH GS push the 16-bit segment selector, zero-extended to the
# operand size (32 by default, 16 under a 0x66 prefix), and decrement ESP by
# that width. They touch no flags. The pushed selectors are popped back into
# GPRs so the value enters the differentially-checked architectural state.
#
# At linux-user entry QEMU reports FS=0x0000 and GS=0x002b (the core resets to
# the same selectors), so PUSH FS pushes 0x00000000 and PUSH GS pushes
# 0x0000002b. ESP must return to its start after the matched push/pop pairs.
# (POP FS/GS — 0F A1/A9 — need the protected-mode descriptor reload and are a
# separate batch, so they are not exercised here.)
# =============================================================================

    .text
    .globl  _start
_start:

    movl    %esp, %esi              # esi = loader ESP (stable marker)

    # ---- 32-bit PUSH FS / PUSH GS, popped into GPRs --------------------
    push    %fs                     # [ESP-4] <- 0x00000000 ; ESP-=4
    pop     %eax                    # eax = FS selector = 0x00000000
    push    %gs                     # [ESP-4] <- 0x0000002b ; ESP-=4
    pop     %ecx                    # ecx = GS selector = 0x0000002b

    # ---- interleaved: push both, pop in reverse order ------------------
    push    %fs                     # ESP-=4 ; value 0x00000000
    push    %gs                     # ESP-=4 ; value 0x0000002b
    pop     %edx                    # edx = GS = 0x0000002b (last pushed)
    pop     %ebx                    # ebx = FS = 0x00000000
    movl    %esp, %edi              # edi = ESP (must equal esi again)

    # ---- 16-bit (0x66) PUSH GS into the low half of a seeded reg -------
    movl    $0xCAFE0000, %eax       # seed upper half of EAX
    pushw   %gs                     # ESP-=2 ; 16-bit selector 0x002b
    popw    %ax                     # AX <- 0x002b -> eax = 0xCAFE002B

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
