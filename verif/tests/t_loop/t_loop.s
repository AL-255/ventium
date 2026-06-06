# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M1 test: t_loop  --  counted loops, back-edges, taken/not-taken Jcc
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like smoke:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal: exercise back-edge control flow and the loop idioms in
# docs/m1-core-spec.md: dec/inc + cmp/test + jne/jge, with the SAME branch both
# taken (each iteration) and finally not-taken (loop exit). Two nested-ish
# phases compute a known closed-form result so a miscounted iteration or a wrong
# branch condition corrupts a checked GPR.
#
# Uses only the M1-implemented subset: mov r32,imm32, add/sub/cmp (reg & imm8),
# inc/dec, test r/m32,r32, Jcc rel8 (jne/je/jge/jg), unconditional jmp rel8.
# NO undefined-EFLAGS ops (no mul/div/shift).
#
# Phase 1: sum = 1+2+...+10 = 55 (0x37) via a count-DOWN loop using dec + jne.
# Phase 2: count taken iterations with inc and stop with cmp + jge (signed).
# Phase 3: a test-based loop (test reg,reg; jne) draining a counter to 0.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- Phase 1: sum 1..10 with a count-down loop (dec + jne back-edge) -----
    movl    $0, %eax                # eax = running sum = 0
    movl    $10, %ecx               # ecx = loop counter i = 10
.Lsum:
    addl    %ecx, %eax              # sum += i
    decl    %ecx                    # i-- (sets ZF when i reaches 0; CF preserved)
    jne     .Lsum                   # back-edge taken while i != 0; falls through at 0
    # here eax = 55 = 0x37

    # ---- Phase 2: count up to a limit with inc + cmp + jge (signed exit) -----
    movl    $0, %edx                # edx = i = 0
    movl    $0, %ebx                # ebx = accumulator
.Lcount:
    addl    %edx, %ebx              # acc += i
    incl    %edx                    # i++
    cmpl    $5, %edx                # compare i with 5  (83 /7 ib)
    jl      .Lcount                 # signed: while i < 5, take back-edge
    # i ran 0,1,2,3,4 ; acc = 0+0+1+2+3+4 = 10 = 0x0a ; edx = 5

    # ---- Phase 3: drain a counter to zero with test + jne -------------------
    movl    $4, %esi                # esi = 4
    movl    $0, %edi                # edi = 0 (count of iterations actually run)
.Ldrain:
    incl    %edi                    # edi++
    decl    %esi                    # esi--
    testl   %esi, %esi              # ZF = (esi == 0)
    jnz     .Ldrain                 # while esi != 0, loop
    # esi = 0 ; edi = 4

    # ---- A never-taken sentinel after a known-not-taken branch --------------
    cmpl    %eax, %eax              # eax == eax -> ZF=1
    jne     .Lbad                   # NOT taken (ZF=1)
    jmp     .Ldone                  # unconditional jump over the sentinel
.Lbad:
    movl    $0xbadbad00, %eax       # (must never execute) sentinel
.Ldone:
    # eax=0x37 ebx=0x0a ecx=0 edx=5 esi=0 edi=4

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall
