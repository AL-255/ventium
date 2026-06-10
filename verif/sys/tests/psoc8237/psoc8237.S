/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.7 — bare-metal 8237A DMA controller (ctrl 0) differential test.
 *
 * Exercises the primary DMA controller (channels 0-3) + AT page registers that
 * M8.7 wires into ventium_soc at I/O 0x00-0x0F + 0x81/0x82/0x83/0x87. Same
 * per-record-differential shape as psocdev/psocuart: NO interrupts, NO DMA
 * transfer (the request register 0x09 is never WRITTEN and no channel is left
 * unmasked-with-a-request), so every interaction is a synchronous IN/OUT and
 * qemu's gdbstub single-step (gen_trace.py --system) is a valid per-record oracle.
 *
 * WHAT IT PROVES byte-identical to qemu-system over every retired instruction:
 *   * reset: status(0x08)=0x00, mask(0x09)=0xFF.
 *   * channel 0 base ADDRESS round-trip via the flip-flop: write 0x1234 (LSB then
 *     MSB), read back 0x34/0x12 (the MSB write runs init_chan so now[ADDR]=base).
 *   * channel 0 base COUNT round-trip: write 0x5678, read back 0x78/0x56.
 *   * flip-flop clear (0x0C) re-bases the LSB/MSB sequencing.
 *   * mask: clear-all (0x0E)->0x00, single-mask set ch1 (0x0A=0x05)->0x02,
 *     write-all (0x0F=0x0A)->0x0A, each observed via the mask read (0x09).
 *   * page registers: 0x81->ch2, 0x83->ch1, 0x87->ch0 round-trip.
 * The actual DMA transfer / DREQ / TC / mode+command effects are the oracle
 * boundary (no transfer is ever triggered).
 *
 * Memory plan (-m 32, NO paging): GDT @ 0x0500, results @ 0x2000, stack @ 0x90000.
 */

    .equ RES_STAT,  0x00002000  /* status reset       = 0x00 */
    .equ RES_MASK0, 0x00002004  /* mask reset         = 0xFF */
    .equ RES_ADRL,  0x00002008  /* ch0 addr LSB       = 0x34 */
    .equ RES_ADRH,  0x0000200C  /* ch0 addr MSB       = 0x12 */
    .equ RES_CNTL,  0x00002010  /* ch0 count LSB      = 0x78 */
    .equ RES_CNTH,  0x00002014  /* ch0 count MSB      = 0x56 */
    .equ RES_MASK1, 0x00002018  /* mask clear-all     = 0x00 */
    .equ RES_MASK2, 0x0000201C  /* mask single ch1    = 0x02 */
    .equ RES_MASK3, 0x00002020  /* mask write-all     = 0x0A */
    .equ RES_PG2,   0x00002024  /* page 0x81 (ch2)    = 0xAB */
    .equ RES_PG1,   0x00002028  /* page 0x83 (ch1)    = 0xCD */
    .equ RES_PG0,   0x0000202C  /* page 0x87 (ch0)    = 0xEF */

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

    /* ============ master reset (0x0D), then read reset state ============== */
    xorb    %al, %al
    outb    %al, $0x0D                  /* master reset: ff=0,mask=0xFF,status=0,cmd=0 */
    inb     $0x08, %al                  /* status -> 0x00 */
    andl    $0xFF, %eax
    movl    %eax, RES_STAT
    inb     $0x09, %al                  /* mask -> 0xFF */
    andl    $0xFF, %eax
    movl    %eax, RES_MASK0

    /* ============ channel-0 base ADDRESS round-trip (flip-flop) =========== */
    outb    %al, $0x0C                  /* clear flip-flop */
    movb    $0x34, %al
    outb    %al, $0x00                  /* ch0 addr LSB */
    movb    $0x12, %al
    outb    %al, $0x00                  /* ch0 addr MSB (init_chan: now=base) */
    outb    %al, $0x0C                  /* clear flip-flop */
    inb     $0x00, %al                  /* -> 0x34 */
    andl    $0xFF, %eax
    movl    %eax, RES_ADRL
    inb     $0x00, %al                  /* -> 0x12 */
    andl    $0xFF, %eax
    movl    %eax, RES_ADRH

    /* ============ channel-0 base COUNT round-trip ========================= */
    outb    %al, $0x0C
    movb    $0x78, %al
    outb    %al, $0x01                  /* ch0 count LSB */
    movb    $0x56, %al
    outb    %al, $0x01                  /* ch0 count MSB */
    outb    %al, $0x0C
    inb     $0x01, %al                  /* -> 0x78 */
    andl    $0xFF, %eax
    movl    %eax, RES_CNTL
    inb     $0x01, %al                  /* -> 0x56 */
    andl    $0xFF, %eax
    movl    %eax, RES_CNTH

    /* ============ mode write (inert, no read-back) ======================== */
    movb    $0x45, %al
    outb    %al, $0x0B                  /* ch1 mode (exercises decode; not read) */

    /* ============ mask register via clear-all / single / write-all ======== */
    xorb    %al, %al
    outb    %al, $0x0E                  /* clear mask (all) -> 0x00 */
    inb     $0x09, %al
    andl    $0xFF, %eax
    movl    %eax, RES_MASK1
    movb    $0x05, %al                  /* single mask: set ch1 (data[2]=1, ch=1) */
    outb    %al, $0x0A
    inb     $0x09, %al                  /* -> 0x02 */
    andl    $0xFF, %eax
    movl    %eax, RES_MASK2
    movb    $0x0A, %al
    outb    %al, $0x0F                  /* write mask (all) -> 0x0A */
    inb     $0x09, %al
    andl    $0xFF, %eax
    movl    %eax, RES_MASK3

    /* ============ page registers (0x81->ch2, 0x83->ch1, 0x87->ch0) ======== */
    movb    $0xAB, %al
    outb    %al, $0x81
    inb     $0x81, %al
    andl    $0xFF, %eax
    movl    %eax, RES_PG2
    movb    $0xCD, %al
    outb    %al, $0x83
    inb     $0x83, %al
    andl    $0xFF, %eax
    movl    %eax, RES_PG1
    movb    $0xEF, %al
    outb    %al, $0x87
    inb     $0x87, %al
    andl    $0xFF, %eax
    movl    %eax, RES_PG0

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
