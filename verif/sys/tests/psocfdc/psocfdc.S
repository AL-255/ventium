/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.9 — bare-metal 82077 floppy disk controller (FDC) differential test.
 *
 * Exercises the CPU-visible synchronous register surface of the FDC that M8.9
 * wires into ventium_soc at I/O 0x3F0-0x3F5 + 0x3F7 (NOT 0x3F6 = IDE alt-status).
 * NO disk, NO DMA, NO seek timing, NO interrupts taken (CLI) — every command is
 * a fully synchronous register handshake, so qemu's gdbstub single-step is a
 * valid per-record oracle. The disk/DMA/seek path is the oracle boundary.
 *
 * The FDC command FIFO handshake: MSR (0x3F4) = 0x80 (RQM, ready for command);
 * after a result-producing command the handler runs synchronously and MSR = 0xD0
 * (RQM|DIO|CB, result ready); each FIFO (0x3F5) read returns a result byte until
 * the last, which drops MSR back to 0x80. A no-result command returns to 0x80.
 *
 * Config-INDEPENDENT commands only (no drive/media dependence):
 *   reset via DOR + read-back, the post-reset 4-drive SENSE INTERRUPT polling
 *   (ST0 = 0xC0/0xC1/0xC2/0xC3, PCN=0), VERSION (0x90), PART ID (0x41),
 *   LOCK on/off (0x10 / 0x00), SPECIFY + CONFIGURE + PERPENDICULAR (no result).
 *
 * Memory plan (-m 32, NO paging): GDT @ 0x0500, results @ 0x2000, stack @ 0x90000.
 */

    .equ RES_DOR,  0x00002000  /* DOR read after reset    = 0x0C */
    .equ RES_MSR0, 0x00002004  /* MSR after reset         = 0x80 */
    .equ RES_S0,   0x00002008  /* SENSE INT #1 ST0        = 0xC0 */
    .equ RES_S1,   0x0000200C  /* SENSE INT #2 ST0        = 0xC1 */
    .equ RES_S2,   0x00002010  /* SENSE INT #3 ST0        = 0xC2 */
    .equ RES_S3,   0x00002014  /* SENSE INT #4 ST0        = 0xC3 */
    .equ RES_MSRR, 0x00002018  /* MSR in result phase     = 0xD0 */
    .equ RES_VER,  0x0000201C  /* VERSION                 = 0x90 */
    .equ RES_PID,  0x00002020  /* PART ID                 = 0x41 */
    .equ RES_LKON, 0x00002024  /* LOCK on                 = 0x10 */
    .equ RES_LKOF, 0x00002028  /* LOCK off                = 0x00 */
    .equ RES_MSRE, 0x0000202C  /* MSR after SPECIFY (no result) = 0x80 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp

    /* ============ software reset via DOR (assert then release bit2) ======= */
    xorb    %al, %al
    movw    $0x03F2, %dx
    outb    %al, %dx                    /* DOR = 0x00: reset asserted, motors off */
    movb    $0x0C, %al
    outb    %al, %dx                    /* DOR = 0x0C: DMA-en, drive 0, reset released */
    inb     %dx, %al                    /* read DOR -> 0x0C (dor | cur_drv) */
    andl    $0xFF, %eax
    movl    %eax, RES_DOR

    movw    $0x03F4, %dx
    inb     %dx, %al                    /* MSR -> 0x80 (RQM ready) */
    andl    $0xFF, %eax
    movl    %eax, RES_MSR0

    /* ============ 4x SENSE INTERRUPT STATUS (post-reset drive polling) ===== */
    /* #1: write 0x08, read MSR (0xD0), read ST0, read PCN */
    movw    $0x03F5, %dx
    movb    $0x08, %al
    outb    %al, %dx
    movw    $0x03F4, %dx
    inb     %dx, %al                    /* MSR -> 0xD0 (result ready) */
    andl    $0xFF, %eax
    movl    %eax, RES_MSRR
    movw    $0x03F5, %dx
    inb     %dx, %al                    /* ST0 -> 0xC0 */
    andl    $0xFF, %eax
    movl    %eax, RES_S0
    inb     %dx, %al                    /* PCN -> 0x00 */
    /* #2 */
    movb    $0x08, %al
    outb    %al, %dx
    inb     %dx, %al                    /* ST0 -> 0xC1 */
    andl    $0xFF, %eax
    movl    %eax, RES_S1
    inb     %dx, %al                    /* PCN */
    /* #3 */
    movb    $0x08, %al
    outb    %al, %dx
    inb     %dx, %al                    /* ST0 -> 0xC2 */
    andl    $0xFF, %eax
    movl    %eax, RES_S2
    inb     %dx, %al
    /* #4 */
    movb    $0x08, %al
    outb    %al, %dx
    inb     %dx, %al                    /* ST0 -> 0xC3 */
    andl    $0xFF, %eax
    movl    %eax, RES_S3
    inb     %dx, %al

    /* ============ VERSION (0x10) -> 0x90 =================================== */
    movb    $0x10, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_VER

    /* ============ PART ID (0x18) -> 0x41 =================================== */
    movb    $0x18, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_PID

    /* ============ LOCK on (0x94) -> 0x10, LOCK off (0x14) -> 0x00 ========== */
    movb    $0x94, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_LKON
    movb    $0x14, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_LKOF

    /* ============ SPECIFY (0x03 + 2 params) -> no result, MSR back to 0x80 = */
    movb    $0x03, %al
    outb    %al, %dx
    movb    $0xAF, %al
    outb    %al, %dx
    movb    $0x02, %al
    outb    %al, %dx
    movw    $0x03F4, %dx
    inb     %dx, %al                    /* MSR -> 0x80 (no result) */
    andl    $0xFF, %eax
    movl    %eax, RES_MSRE

    /* ============ CONFIGURE (0x13 + 3 params) + PERPENDICULAR (0x12 + 1) === */
    movw    $0x03F5, %dx
    movb    $0x13, %al
    outb    %al, %dx
    movb    $0x00, %al
    outb    %al, %dx
    movb    $0x40, %al
    outb    %al, %dx
    movb    $0x00, %al
    outb    %al, %dx
    movb    $0x12, %al                  /* PERPENDICULAR */
    outb    %al, %dx
    movb    $0x00, %al
    outb    %al, %dx

    /* ====================== clean exit via isa-debug-exit ================= */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
