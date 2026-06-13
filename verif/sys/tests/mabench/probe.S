/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */
/* Instruction-support probe: prints a marker char after each suspect op; whichever
 * marker is the LAST one seen identifies the instruction that hangs on hardware. */
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

    movw    $0x03F8, %dx; movb $'1', %al; outb %al, %dx   /* past COM1 init (8/16-bit) */

    /* finit removed — it hangs on the deployed bitstream (x87 unavailable) */

    movl    $0x12345678, %ebx                              /* 32-bit immediate load (66 prefix) */
    movw    $0x03F8, %dx; movb $'3', %al; outb %al, %dx

    movl    %ebx, %ecx                                     /* 32-bit reg-reg */
    addl    %ecx, %ebx
    movw    $0x03F8, %dx; movb $'4', %al; outb %al, %dx    /* past 32-bit add */

    imull   $0x6D2B79F5, %ebx, %eax                        /* 3-operand IMUL */
    movw    $0x03F8, %dx; movb $'5', %al; outb %al, %dx    /* past imul */

    roll    $11, %eax                                      /* 32-bit rotate */
    movw    $0x03F8, %dx; movb $'6', %al; outb %al, %dx

    movl    %eax, %ebx
    xorl    %edx, %edx
    movl    $7, %esi
    divl    %esi                                           /* 32-bit DIV (iterative) */
    movw    $0x03F8, %dx; movb $'7', %al; outb %al, %dx    /* past div */

    movl    %ebx, 0x600                                    /* 32-bit ModRM store, DS=0 */
    movl    0x600, %edi                                    /* 32-bit ModRM load */
    movw    $0x03F8, %dx; movb $'8', %al; outb %al, %dx    /* past 32-bit mem */

    movb    $0x42, %al; movw $0xF4, %dx; outb %al, %dx     /* isa-debug-exit */
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
