/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/*
 * Common-base protected-mode fast-load regression.
 *
 * DPMI-style clients commonly use one non-zero base for CS, DS, SS and ES.
 * This image copies a 32-bit client to physical 0x00080000, enters four
 * conventional 4 GiB segments with that base, and repeatedly executes the
 * deliberately narrow load form admitted by VEN_SYS_FASTLOAD_FLAT:
 *
 *     movl (%esi), %edi       (ModR/M mod=00, base=ESI, no SIB/disp)
 *
 * The datum and ESI are client-relative, so the access is only correct when
 * the DS base is applied.  The loop folds every observed value into EAX;
 * QEMU-vs-RTL trace comparison therefore proves both the non-zero-base
 * addressing and the architectural result.  It has no Quake dependency and
 * restores no guest state.
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

    /* CS base is 0x80000, so this far offset is client-relative. */
    .byte   0x66, 0xea
    .long   pm32_entry - pm32_payload
    .word   0x08

    .code32
    .section .client32, "ax"
    .global pm32_payload
pm32_payload:
pm32_entry:
    /* All conventional data segments share the non-zero code base. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss

    /* ESI is an offset within the relocated client.  The load's ModR/M byte
     * is 0x3e: DS:[ESI], with no displacement, SIB, or special base form. */
    movl    $(pm32_data - pm32_payload), %esi
    xorl    %eax, %eax
    movl    $128, %ecx
1:
    movl    (%esi), %edi
    addl    %edi, %eax
    xorl    $0xa5a5a5a5, %eax
    decl    %ecx
    jnz     1b

    /* isa-debug-exit intentionally leaves the narrow fast-load subset. */
    movl    $0x42, %eax
    movw    $0xf4, %dx
    outb    %al, %dx
2:
    hlt
    jmp     2b

    .p2align 2
pm32_data:
    .long   0x6d31c4a7
pm32_payload_end:

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xea
    .word   _start16_off
    .word   0xf000
