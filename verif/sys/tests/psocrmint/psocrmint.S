/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F3 — real-mode IVT INT n / IRET firmware (psocrmint.bin).
 *
 * The smallest exerciser of real-mode interrupt delivery (the BIOS/DOS service
 * mechanism). Installs an IVT entry for vector 0x40 (at 0:0x100 = {offset=handler,
 * segment=0xF000}), does INT $0x40 -> the handler runs in segment F000 and IRETs
 * back, then isa-debug-exits. The per-record differential checks the pushed FLAGS:CS:IP
 * frame + the CS:IP load + the IRET restore vs qemu-system. cr0 stays 0x60000010
 * (pure 16-bit real mode); the IVT is at 0:0 (reset IDTR base=0, limit=0x3FF).
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds                    /* DS=0 -> the IVT (segment 0) is addressable */
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* install IVT[0x40] @ 0:0x100 = { offset=handler, segment=0xF000 } */
    movw    $handler_off, 0x0100        /* IVT[0x40].offset */
    movw    $0xF000,       0x0102       /* IVT[0x40].segment */

    movw    $0x1111, %bx                /* pre-INT marker */
    int     $0x40                       /* -> real-mode IVT delivery into the handler */
    movw    $0x3333, %cx                /* post-IRET marker (control returned here) */

    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    /* the INT 0x40 handler (runs at CS=0xF000) */
    .global handler
handler:
    movw    $0x2222, %bx                /* observable: the handler ran */
    iret                                /* pop IP:CS:FLAGS -> back to the post-INT marker */

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
