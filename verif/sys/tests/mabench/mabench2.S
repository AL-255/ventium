/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — U/V/FP pipeline stress benchmark (mabench2.bin).
 *
 * A heavier sibling of mabench that deliberately exercises the dual-issue and FP
 * pipeline datapaths, to be run in cycle_mode (ven_bench --cycle):
 *   Block A — integer U/V pairing + cross-pipe forwarding: dense pairable ALU/LEA
 *             sequences alternating independent (pair in U+V) and dependent (forward)
 *             ops, plus IMUL and iterative IDIV.
 *   Block B — the x87 FADD/FMUL/FSUB pipeline (latency-3, ~1/clk) woven with FXCH
 *             (free-paired on P5) and dependent chains that exercise FP forwarding.
 *   Block C — long-latency non-pipelined FDIV/FSQRT overlapped with integer work
 *             (the P5 FP/integer-overlap path).
 * Every block folds into a djb2 hash (acc = acc*33 + mix); the final CK=xxxxxxxx is
 * deterministic, so any datapath corruption (single- or dual-issue) changes it.
 *
 * HW constraints (see the mabench README): FNINIT not FINIT (FWAIT 0x9B hangs); no
 * MOV-moffs (A0-A3) — non-EAX regs force ModRM; no CALL/RET; DS=0, FP scratch 0:0x600.
 * AT&T x87: "fadd %st(N),%st" = st0 += st(N); faddp/fmulp pop into st1.
 */
    .equ COM1, 0x03F8
    .equ ITERS, 30000
    .equ V1,  0x0600
    .equ V2,  0x0604
    .equ V3,  0x0608
    .equ R0,  0x0610

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %ds
    movw    $0x7000, %sp
    movw    $0x03FB, %dx; movb $0x83, %al; outb %al, %dx
    movw    $0x03F8, %dx; movb $0x01, %al; outb %al, %dx
    movw    $0x03F9, %dx; movb $0x00, %al; outb %al, %dx
    movw    $0x03FB, %dx; movb $0x03, %al; outb %al, %dx
    movw    $0x03FC, %dx; movb $0x03, %al; outb %al, %dx

#ifndef NOFP
    fninit
#endif
    movl    $0x811C9DC5, %ebp           /* djb2 hash */
    movl    $ITERS, %ecx
.loop:
    /* ============ Block A: integer U/V pairing + forwarding ============ */
    movl    %ecx, %eax
    movl    %ebp, %ebx
    addl    $0x9E3779B9, %eax           /* U  \  independent pair          */
    xorl    $0x6D2B79F5, %ebx           /* V  /                            */
    roll    $5, %eax                     /* U  \  independent pair          */
    roll    $11, %ebx                    /* V  /                            */
    addl    %eax, %ebx                   /* dep: forward eax -> V           */
    xorl    %ebx, %eax                   /* dep: forward ebx -> U           */
    leal    3(%eax), %esi                /* U  \  LEA pair (AGU)            */
    leal    7(%ebx), %edi                /* V  /                            */
    subl    %edi, %esi                   /* dep forward                     */
    addl    %esi, %eax                   /* dep forward                     */
    imull   $0x85EBCA77, %eax, %eax      /* IMUL                            */
    movl    %ecx, %esi; orl $0x00010001, %esi
    xorl    %edx, %edx
    movl    %eax, %ebx
    movl    %ebx, %eax
    divl    %esi                         /* iterative DIV                   */
    addl    %edx, %eax                   /* + remainder                     */
    /* eax = Block-A mix */

#ifndef NOFP
    /* ============ Block B: FP add/mul/sub pipeline + FXCH ============ */
    movl    %ecx, %edi; andl $0x0000FFFF, %edi; orl $1, %edi; movl %edi, V1
    movl    %ebp, %edi; andl $0x000000FF, %edi; orl $1, %edi; movl %edi, V2
    movl    %eax, %edi; andl $0x0000007F, %edi; orl $1, %edi; movl %edi, V3
    fildl   V1                           /* st0=v1                          */
    fildl   V2                           /* st0=v2 st1=v1                   */
    fildl   V3                           /* st0=v3 st1=v2 st2=v1            */
    fadd    %st(2), %st                  /* st0 = v3+v1   (FADD)            */
    fmul    %st(1), %st                  /* st0 *= v2     (FMUL)            */
    fxch    %st(2)                        /* swap st0,st2  (free pair)       */
    fsub    %st(1), %st                  /* st0 -= st1    (FSUB)            */
    fadd    %st(2), %st                  /* dependent FADD (forwarding)     */
    fmul    %st(1), %st                  /* dependent FMUL                  */
    faddp   %st, %st(1)                  /* pop                             */
    fmulp   %st, %st(1)                  /* pop -> st0 = result             */
    fistpl  R0
    movl    R0, %edi
    xorl    %edi, %eax                   /* fold Block-B into mix           */

    /* ============ Block C: long-latency FDIV/FSQRT + int overlap ====== */
    movl    %ecx, %edi; andl $0x0000FFFF, %edi; orl $0x0100, %edi; movl %edi, V1
    movl    %ebp, %edi; andl $0x0000003F, %edi; orl $3, %edi;      movl %edi, V2
    fildl   V1                           /* st0=v                           */
    fildl   V2                           /* st0=d st1=v                    */
    fdivr   %st, %st(1)                  /* st1 = v/d   (FDIV, st1/=...)... */
    fxch    %st(1)                        /* st0 = v/d                       */
    fsqrt                                 /* sqrt(v/d)   (FSQRT)            */
    /* integer work overlapping the long-latency FP unit */
    imull   $0x27D4EB2F, %eax, %ebx
    roll    $13, %ebx
    xorl    %ebx, %eax
    fmulp   %st, %st(1)                  /* * d, pop                        */
    fistpl  R0
    movl    R0, %edi
    xorl    %edi, %eax                   /* fold Block-C into mix           */
#endif

    /* ============ absorb into djb2 hash ============ */
    imull   $33, %ebp, %ebp
    addl    %eax, %ebp

    decl    %ecx
    jnz     .loop

    /* ---- print "CK=" + hex(EBP) + CRLF (inlined) ---- */
    movw    $COM1, %dx
    movb    $'C', %al; outb %al, %dx
    movb    $'K', %al; outb %al, %dx
    movb    $'=', %al; outb %al, %dx
    movl    %ebp, %eax
    movw    $8, %cx
.phex:
    roll    $4, %eax
    movb    %al, %bl
    andb    $0x0F, %bl
    cmpb    $10, %bl
    jb      1f
    addb    $87, %bl
    jmp     2f
1:  addb    $48, %bl
2:  pushw   %ax
    movb    %bl, %al
    movw    $COM1, %dx
    outb    %al, %dx
    popw    %ax
    decw    %cx
    jnz     .phex
    movw    $COM1, %dx
    movb    $13, %al; outb %al, %dx
    movb    $10, %al; outb %al, %dx
    movb    $0x42, %al; movw $0xF4, %dx; outb %al, %dx
3:  hlt
    jmp     3b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
