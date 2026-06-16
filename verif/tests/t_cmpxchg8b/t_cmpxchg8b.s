# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_cmpxchg8b  --  CMPXCHG8B m64  (0F C7 /1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# CMPXCHG8B m64 (the lock-free 64-bit atomic primitive musl/Quake use):
#   if EDX:EAX == [m64]:  ZF=1;  [m64] <- ECX:EBX        (EDX:EAX unchanged)
#   else:                 ZF=0;  EDX:EAX <- [m64]        ([m64] unchanged)
# ONLY ZF is affected (CF/PF/AF/SF/OF unchanged), so no EFLAGS masking is needed
# and the whole image is differentially checked vs QEMU after every instruction.
#
# Coverage: equal (store happens, ZF=1) + not-equal (EDX:EAX reloaded, ZF=0) +
# a LOCK-prefixed equal case (must be a functional no-op). Memory results are
# reloaded into GPRs so the 64-bit store/no-store folds into the checked state.
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- EQUAL: EDX:EAX == [m64] -> [m64] <- ECX:EBX, ZF=1 -------------
    leal    m64a, %edi
    movl    $0x11111111, %eax           # EDX:EAX = 0x22222222_11111111
    movl    $0x22222222, %edx
    movl    $0x11111111, m64a           # seed [m64a] == EDX:EAX
    movl    $0x22222222, m64a+4
    movl    $0xAAAAAAAA, %ebx           # ECX:EBX = 0xBBBBBBBB_AAAAAAAA (the new value)
    movl    $0xBBBBBBBB, %ecx
    cmpxchg8b (%edi)                    # equal -> [m64a] <- ECX:EBX, ZF=1
    movl    m64a,   %esi                # esi = 0xAAAAAAAA (low stored)
    movl    m64a+4, %ebp                # ebp = 0xBBBBBBBB (high stored)

    # ---- NOT-EQUAL: EDX:EAX != [m64] -> EDX:EAX <- [m64], ZF=0 ---------
    leal    m64b, %edi
    movl    $0x11111111, %eax           # EDX:EAX = 0x22222222_11111111
    movl    $0x22222222, %edx
    movl    $0xDEADBEEF, m64b           # seed [m64b] != EDX:EAX
    movl    $0xCAFEBABE, m64b+4
    movl    $0x99999999, %ebx           # ECX:EBX must NOT be written to memory
    movl    $0x88888888, %ecx
    cmpxchg8b (%edi)                    # not equal -> EAX=0xDEADBEEF, EDX=0xCAFEBABE, ZF=0
    movl    m64b,   %esi                # esi = 0xDEADBEEF ([m64b] unchanged)
    movl    m64b+4, %ebp                # ebp = 0xCAFEBABE

    # ---- LOCK-prefixed EQUAL case (functional no-op) ------------------
    leal    m64c, %edi
    movl    $0x0BADF00D, %eax
    movl    $0xFEEDFACE, %edx
    movl    $0x0BADF00D, m64c
    movl    $0xFEEDFACE, m64c+4
    movl    $0x12345678, %ebx
    movl    $0x9ABCDEF0, %ecx
    lock cmpxchg8b (%edi)              # equal -> [m64c] <- ECX:EBX, ZF=1
    movl    m64c,   %esi                # esi = 0x12345678
    movl    m64c+4, %ebp                # ebp = 0x9ABCDEF0

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 8
m64a:  .quad 0
m64b:  .quad 0
m64c:  .quad 0
