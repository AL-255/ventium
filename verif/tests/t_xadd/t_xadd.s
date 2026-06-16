# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_xadd  --  XADD r/m, r  (0F C0 byte / 0F C1 word/dword)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# XADD (Intel "XADD r/m, r"; AT&T `xadd %src_reg, %dst_rm`):
#     TEMP = SRC + DEST;  SRC = DEST;  DEST = TEMP
# i.e. the destination (r/m) receives the SUM and the source register receives
# the OLD destination. ALL SIX arithmetic flags are defined exactly like ADD, so
# nothing is masked — the whole EFLAGS image is differentially checked vs QEMU.
#
# Coverage: 32-bit reg (basic / carry+zero / overflow), the same-register corner
# (`xadd %eax,%eax` must leave the SUM), 16-bit (0x66), 8-bit low + high-8
# registers, a memory destination (the result reloaded into a GPR so the store is
# folded into the checked state), and a LOCK-prefixed memory XADD (must be a
# functional no-op on this in-order single core).
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- 32-bit reg, basic: dst=EAX, src=EBX ---------------------------
    movl    $0x00000005, %eax       # dst
    movl    $0x00000003, %ebx       # src
    xadd    %ebx, %eax              # eax <- 8 (sum); ebx <- 5 (old dst). CF=0,ZF=0

    # ---- 32-bit reg, carry + zero result -------------------------------
    movl    $0xFFFFFFFF, %eax
    movl    $0x00000001, %ebx
    xadd    %ebx, %eax              # eax <- 0 (sum); ebx <- 0xFFFFFFFF. CF=1,ZF=1

    # ---- 32-bit reg, signed overflow -----------------------------------
    movl    $0x7FFFFFFF, %eax
    movl    $0x00000001, %ebx
    xadd    %ebx, %eax              # eax <- 0x80000000; ebx <- 0x7FFFFFFF. OF=1,SF=1

    # ---- same-register corner: dst == src ------------------------------
    movl    $0x00000010, %eax
    xadd    %eax, %eax              # TEMP=0x20; SRC(eax)=0x10; DEST(eax)=0x20 -> 0x20

    # ---- 16-bit (0x66): upper halves of EAX/EBX must be preserved ------
    movl    $0x123400FF, %eax       # AX=0x00FF
    movl    $0x56780001, %ebx       # BX=0x0001
    xaddw   %bx, %ax                # AX <- 0x0100; BX <- 0x00FF; tops 0x1234/0x5678

    # ---- 8-bit low: AL/BL, signed 8-bit overflow -----------------------
    movl    $0xAABBCC7F, %eax       # AL=0x7F
    movl    $0x11223301, %ebx       # BL=0x01
    xaddb   %bl, %al                # AL <- 0x80; BL <- 0x7F; tops preserved. OF=1

    # ---- 8-bit high-8 registers: AH/BH ---------------------------------
    movl    $0x00C300DD, %eax       # AH=0xC3
    movl    $0x00910022, %ebx       # BH=0x91
    xaddb   %bh, %ah                # AH <- 0xC3+0x91=0x54 (CF=1); BH <- 0xC3

    # ---- memory destination (32-bit): [EDI] += ECX ---------------------
    leal    dword_a, %edi
    movl    $0x00000100, dword_a    # seed [edi]
    movl    $0x00000023, %ecx       # src
    xadd    %ecx, (%edi)            # [edi] <- 0x123; ecx <- 0x100 (old mem)
    movl    dword_a, %esi           # esi = 0x123 (fold the store into checked state)

    # ---- LOCK-prefixed memory XADD (functional no-op) ------------------
    movl    $0x0000DEAD, dword_b
    leal    dword_b, %edi
    movl    $0x00001111, %edx
    lock xadd %edx, (%edi)          # [edi] <- 0xEFBE; edx <- 0xDEAD
    movl    dword_b, %esi           # esi = 0xEFBE

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 4
dword_a:  .long 0x00000000
dword_b:  .long 0x00000000
