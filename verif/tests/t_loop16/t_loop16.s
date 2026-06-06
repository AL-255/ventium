# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_loop16  --  0x67 (address-size-16) LOOP / LOOPE / JCXZ
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the adversarial-review finding that the 0x67 address-size
# prefix on LOOP/LOOPE/LOOPNE and JCXZ/JECXZ was recognized by the prefix
# machine but never affected the counter width: JECXZ always tested the full
# 32-bit ECX and LOOP always decremented the full 32-bit ECX. With 0x67 they
# must use CX (the low 16 bits), preserving ECX[31:16].
#
#   67 E2 cb (loopw)  : CX -= 1 (preserve [31:16]); branch while CX != 0.
#   67 E1 cb (loopew) : same + ZF == 1.
#   67 E3 cb (jcxz)   : branch iff CX == 0.
#
# The rel8 target is added to the full EIP (no truncation), so a flat program
# loops correctly. Each counter register is pre-seeded with a nonzero high half
# so a full-32 decrement (the bug) corrupts a checked GPR. LOOP/JCXZ touch no
# flags; LOOPE reads ZF. All architecturally defined.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- 0x67 LOOP: CX counts 3 -> 0, preserve ECX[31:16] -------------------
    movl    $0xAAAA0003, %ecx       # CX = 3, hi witness = 0xAAAA
    movl    $0, %eax
loop1:
    incl    %eax                    # count iterations
    .byte   0x67
    loop    loop1                   # 67 E2: dec CX, branch while CX != 0
    # after: eax = 3, ecx = 0xAAAA0000
    movl    %eax, %esi              # ESI = 3 (iteration count witness)

    # ---- 0x67 JCXZ taken (CX == 0) ------------------------------------------
    movl    $0xBBBB0000, %ecx       # CX = 0
    .byte   0x67
    jecxz   skip1                   # 67 E3: taken (CX==0)
    movl    $0xDEAD, %edx           # must be SKIPPED
skip1:
    movl    $0x1111, %ebp           # ebp = 0x1111 (reached)

    # ---- 0x67 JCXZ not taken (CX != 0, but ECX[31:16] != 0) -----------------
    movl    $0xCCCC0005, %ecx       # CX = 5 (low16 nonzero) -> not taken
    .byte   0x67
    jecxz   skip2                   # not taken
    movl    $0x2222, %edi           # EXECUTED
skip2:
    movl    $0x3333, %edx           # edx = 0x3333 (reached either way)

    # ---- 0x67 JCXZ where ECX low16 == 0 but high16 != 0: must take ----------
    movl    $0xEEEE0000, %ecx       # CX = 0 (high half nonzero) -> 16-bit test sees 0
    .byte   0x67
    jecxz   skip3                   # taken (CX==0 even though ECX != 0)
    movl    $0xBEEF, %esi           # must be SKIPPED (would clobber ESI=3)
skip3:

    # ---- 0x67 LOOPE: branch while CX != 0 AND ZF == 1 -----------------------
    movl    $0x99990004, %ecx       # CX = 4
    movl    $0, %ebx
    xorl    %eax, %eax              # set ZF = 1 (eax=0)
loope1:
    incl    %ebx                    # body
    cmpl    %eax, %eax              # ZF = 1 (equal)
    .byte   0x67
    loope   loope1                  # 67 E1: dec CX, branch while CX!=0 && ZF=1
    # ZF stays 1 each time, so it loops until CX hits 0 -> ebx = 4
    movl    %ebx, %ebp              # EBP = 4

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
