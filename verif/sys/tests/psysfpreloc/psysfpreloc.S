/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/*
 * General common-base protected-mode fast-path regression.
 *
 * DPMI hosts commonly give a client one non-zero base for CS, DS, SS and ES.
 * That is still a flat address space relative to the client, but it differs
 * from the base-zero flat model assumed by the original system fast-path
 * guard.  This image copies a small 32-bit body to physical 0x00080000,
 * creates four conventional 4 GiB segments all with that base, enters the
 * code segment, and executes register/immediate/relative-control operations.
 *
 * The program deliberately contains no protected-mode data memory operands:
 * it proves the precisely safe subset admitted by VEN_SYS_FASTPATH_RELOC,
 * rather than widening the fast path to segment-relative loads or stores.
 * It is a generic segmentation test, not a Quake or save-state fixture.
 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld

    /* Copy the 32-bit client body from the BIOS alias to physical 0x80000.
     * This stays below 1 MiB and therefore needs no A20 assumption. */
    movw    $0xf000, %ax
    movw    %ax, %ds
    movw    $0x8000, %ax
    movw    %ax, %es
    movw    $_pm32_payload_off, %si
    xorw    %di, %di
    movw    $(pm32_payload_end - pm32_payload), %cx
    rep movsb

    /* Build GDT @ 0x500 and its pseudo-descriptor @ 0x480 in low RAM.
     * base=0x00080000, limit=4 GiB-1, G=1, D/B=1. */
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    movl    $0x00000500, %ebx
    movl    $0x00000000,  (%ebx)
    movl    $0x00000000, 4(%ebx)
    /* code32: base=0x00080000, type=exec/read */
    movl    $0x0000ffff,  8(%ebx)
    movl    $0x00cf9a08, 12(%ebx)
    /* data32: same common base, type=read/write */
    movl    $0x0000ffff, 16(%ebx)
    movl    $0x00cf9208, 20(%ebx)

    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* CS base is 0x80000, so the far offset is deliberately client-relative,
     * not the BIOS image VMA. */
    .byte   0x66, 0xea
    .long   pm32_entry - pm32_payload
    .word   0x08

    .code32
    .section .client32, "ax"
    .global pm32_payload
pm32_payload:
pm32_entry:
    /* All conventional data segments share the code segment's non-zero base. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss

    /* A deterministic register-only loop and relative branch.  No memory
     * operands follow the segment setup: this is the safe relocated subset. */
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    movl    $0x33333333, %edx
    movl    $128, %ecx
1:
    addl    $3, %eax
    xorl    %eax, %ebx
    roll    $1, %edx
    decl    %ecx
    jnz     1b

    /* isa-debug-exit: intentionally leaves the fast path after the loop. */
    movl    $0x42, %eax
    movw    $0xf4, %dx
    outb    %al, %dx
2:
    hlt
    jmp     2b
pm32_payload_end:

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xea
    .word   _start16_off
    .word   0xf000
