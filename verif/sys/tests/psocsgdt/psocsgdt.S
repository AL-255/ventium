/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9.5 — real-mode SGDT/SIDT firmware (psocsgdt.bin).
 *
 * LGDT/LIDT a known 6-byte pseudo-descriptor, SGDT/SIDT it back to a different RAM
 * location, then READ the stored bytes into GPRs so the per-record differential (which
 * compares GPRs, not arbitrary memory) sees the stored values. Base[31:24]=0 keeps the
 * 16-bit (24-bit base) and 32-bit forms identical, so the gate is unambiguous. cr0
 * stays the reset 0x60000010 (pure 16-bit real mode, no paging).
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* GDT pseudo-descriptor at 0x600: limit=0x0123, base=0x00456789 */
    movw    $0x0123, 0x0600
    movw    $0x6789, 0x0602
    movw    $0x0045, 0x0604
    lgdt    0x0600

    /* IDT pseudo-descriptor at 0x610: limit=0x07FF, base=0x00001000 */
    movw    $0x07FF, 0x0610
    movw    $0x1000, 0x0612
    movw    $0x0000, 0x0614
    lidt    0x0610

    /* store GDTR -> 0x620, IDTR -> 0x628 */
    sgdt    0x0620
    sidt    0x0628

    /* read the stored bytes into GPRs (differential-visible) */
    movw    0x0620, %ax              /* gdt limit  = 0x0123 */
    movw    0x0622, %bx              /* gdt base15:0 = 0x6789 */
    movw    0x0624, %cx              /* gdt base31:16 = 0x0045 */
    movw    0x0628, %di              /* idt limit  = 0x07FF */
    movw    0x062A, %si              /* idt base15:0 = 0x1000 */
    movw    0x062C, %bp              /* idt base31:16 = 0x0000 */

    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
