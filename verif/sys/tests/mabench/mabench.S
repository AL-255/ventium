/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — heavy bare-metal overclock benchmark (mabench.bin).
 *
 * A real-mode -bios image (reset vector F000:FFF0, like psocfw) that stresses the
 * actual Fmax-critical datapaths the trivial psocfw smoke never touches: the x87
 * FADD/FMUL/FSQRT cone, the FBSTP packed-BCD engine (u_bcd — the half-cache K26
 * critical path), and the integer multiply/divide unit. Every iteration mixes the
 * integer-div + FP/BCD results and absorbs them into a djb2 hash (acc = acc*33 +
 * mix) — a NON-cancelling accumulator, so a single corrupted bit anywhere changes
 * the final "CK=xxxxxxxx" printed to COM1. The checksum is fully deterministic
 * (no RNG / time / input), so a clean run at 40 MHz defines the golden value and
 * any overclock that prints a different CK has corrupted a datapath = FAIL.
 *
 * Hardware-portability constraints (found on the live KV260 bring-up):
 *  - x87 init uses FNINIT, never FINIT — the FWAIT (0x9B) prefix hangs on the
 *    deployed bitstream (the FPU-busy handshake never completes). Bare x87 arith
 *    ops (no implicit wait) work fine.
 *  - no MOV-moffs (A0-A3) direct addressing — the core decodes only ModRM [disp16];
 *    every memory access uses a non-EAX register so GAS emits the 89/8B ModRM form.
 *  - no CALL/RET (the hex printer is inlined) and no interrupts.
 *  - DS=0: FP scratch lives in low RAM at 0:0x600 (no image-relative data).
 */
    .equ COM1, 0x03F8
    .equ ITERS, 50000
    .equ S_INT,  0x0600         /* dword: FILD source            */
    .equ S_FP,   0x0604         /* dword: FISTP result           */
    .equ S_BCD,  0x0610         /* 10 bytes: FBSTP result        */

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %ds                    /* DS = 0 -> FP scratch at 0:0x600 */
    movw    $0x7000, %sp

    /* init COM1 16550 (8N1, 115200) */
    movw    $0x03FB, %dx; movb $0x83, %al; outb %al, %dx
    movw    $0x03F8, %dx; movb $0x01, %al; outb %al, %dx
    movw    $0x03F9, %dx; movb $0x00, %al; outb %al, %dx
    movw    $0x03FB, %dx; movb $0x03, %al; outb %al, %dx
    movw    $0x03FC, %dx; movb $0x03, %al; outb %al, %dx

#ifndef NOFP
    fninit                              /* x87 init (NOT finit — FWAIT hangs) */
#endif

    movl    $0x811C9DC5, %ebp           /* djb2 hash accumulator (non-cancelling) */
    movl    $ITERS, %ecx                /* down-counter */
.loop:
    /* ---- integer multiply + divide -> mix in EAX ---- */
    movl    %ecx, %eax
    imull   $0x6D2B79F5, %eax, %eax     /* eax = ecx * const  (IMUL) */
    movl    %ecx, %esi
    orl     $0x00000101, %esi           /* divisor >= 0x101 (never 1 -> no self-cancel) */
    xorl    %edx, %edx
    divl    %esi                        /* eax=quot, edx=rem  (iterative DIV) */
    roll    $13, %edx
    xorl    %edx, %eax                  /* mix = quot ^ rol(rem,13) */

#ifndef NOFP
    /* ---- x87 FADD/FMUL/FSQRT cone -> fold into mix ---- */
    movl    %ecx, %edi
    andl    $0x000FFFFF, %edi           /* bound < ~1M (valid FBSTP source) */
    movl    %edi, S_INT
    fildl   S_INT                       /* st0 = v */
    fld1
    faddp   %st, %st(1)                 /* v+1   (FADD) */
    fldpi
    fmulp   %st, %st(1)                 /* (v+1)*pi  (FMUL) */
    fsqrt                               /* sqrt((v+1)*pi)  (FSQRT) */
    fistpl  S_FP
    movl    S_FP, %edi
    xorl    %edi, %eax

    /* ---- FBSTP packed-BCD engine (u_bcd) -> fold into mix ---- */
    fildl   S_INT
    fbstp   S_BCD
    movl    S_BCD,   %edi; xorl %edi, %eax
    movl    S_BCD+4, %edi; xorl %edi, %eax
#endif

    /* ---- absorb mix into the djb2 hash: acc = acc*33 + mix ---- */
    imull   $33, %ebp, %ebp
    addl    %eax, %ebp

    decl    %ecx
    jnz     .loop

    /* ---- print "CK=" + 8 hex digits of EBP + CRLF (inlined, no CALL) ---- */
    movw    $COM1, %dx
    movb    $'C', %al; outb %al, %dx
    movb    $'K', %al; outb %al, %dx
    movb    $'=', %al; outb %al, %dx
    movl    %ebp, %eax                  /* hash -> working copy (reg-reg) */
    movw    $8, %cx
.phex:
    roll    $4, %eax
    movb    %al, %bl
    andb    $0x0F, %bl
    cmpb    $10, %bl
    jb      1f
    addb    $87, %bl                    /* 'a'..'f' */
    jmp     2f
1:  addb    $48, %bl                    /* '0'..'9' */
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

    /* isa-debug-exit */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
3:  hlt
    jmp     3b

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
