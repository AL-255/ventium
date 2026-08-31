/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/*
 * Common-base protected-mode fast-load regression.
 *
 * DPMI-style clients commonly use one non-zero base for CS, DS, SS and ES.
 * This image copies a 32-bit client to physical 0x00080000 for pre-paging
 * execution and to physical 0x00090000 for paged execution, maps its non-zero
 * linear address 0x00080000 to that *different* physical page, enters four
 * conventional 4 GiB segments with the 0x80000 base, enables paging, and
 * repeatedly executes the
 * deliberately narrow load form admitted by VEN_SYS_FASTLOAD_FLAT:
 *
 *     movl (%esi), %edi               (ModR/M base form)
 *     movl (%esi,%edx,4), %edi        (DS-default SIB form)
 *     movl 4(%esi,%edx,4), %edi       (DS-default SIB+disp8 form)
 *
 * The datum and ESI are client-relative, so the access is only correct when
 * the DS base is applied.  The loop folds every observed value into EAX;
 * QEMU-vs-RTL trace comparison therefore proves non-zero-base addressing,
 * D-TLB/page-walk handling, and the architectural result.  It has no Quake
 * dependency and restores no guest state.
 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld

    /* Copy the 32-bit client body from the BIOS alias twice.  The pre-paging
     * far jump executes the copy at physical 0x80000; after CR0.PG=1, the
     * same linear address maps to the distinct physical 0x90000 copy.  Both
     * locations stay below 1 MiB and therefore need no A20 assumption. */
    movw    $0xf000, %ax
    movw    %ax, %ds
    movw    $0x9000, %ax
    movw    %ax, %es
    movw    $_pm32_payload_off, %si
    xorw    %di, %di
    movw    $(pm32_payload_end - pm32_payload), %cx
    rep movsb

    movw    $0xf000, %ax
    movw    %ax, %ds
    movw    $0x8000, %ax
    movw    %ax, %es
    movw    $_pm32_payload_off, %si
    xorw    %di, %di
    movw    $(pm32_payload_end - pm32_payload), %cx
    rep movsb

    /* Make the translated physical copy observably distinct.  If a fast load
     * or fetch bypasses paging it reads the 0x80000 copy's original sentinel;
     * QEMU's paged reference reads this replacement at 0x90000 instead. */
    movw    $0x9000, %ax
    movw    %ax, %es
    movw    $(pm32_data - pm32_payload), %di
    movl    $0x1badb002, %es:(%di)

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

    /* A minimal genuinely non-identity 4 KiB page hierarchy.  The protected-
     * mode client fetches and loads at linear 0x00080000 + client_offset,
     * while this PTE maps that linear page to physical 0x90000.
     * Only PDE[0] and PT[128] are touched, so no implicit RAM-reset assumption
     * is needed for unwalked entries. */
    movl    $0x00002003, 0x1000   /* PD[0] -> PT @ phys 0x2000, P|RW */
    movl    $0x00090003, 0x2200   /* PT[128] -> client @ phys 0x90000, P|RW */

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

    /* Enable 4 KiB paging only after all bootstrap accesses to low physical
     * RAM are complete.  The following instruction fetch and every DS:[ESI]
     * load must pass through the mapping above. */
    movl    $0x00001000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ESI is an offset within the relocated client.  With paging enabled the
     * load's linear address is 0x80000+ESI and must translate via PT[128] to
     * physical 0x90000+ESI.
     * The loop also covers DS-default SIB forms with ESI as the concrete base
     * and EDX as the scaled index. */
    movl    $(pm32_data - pm32_payload), %esi
    movl    $1, %edx
    xorl    %eax, %eax
    movl    $128, %ecx
1:
    movl    (%esi), %edi
    addl    %edi, %eax
    movl    4(%esi), %edi
    xorl    %edi, %eax
    movl    0x100(%esi), %edi
    addl    %edi, %eax
    movl    (%esi,%edx,4), %edi
    xorl    %edi, %eax
    movl    4(%esi,%edx,4), %edi
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
    .long   0x3e7a19c5
    .long   0x4a9bf216
    .long   0xc3817d5e
    .zero   0x100 - (.-pm32_data)
pm32_disp32_data:
    .long   0x52c0ffee
pm32_payload_end:

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xea
    .word   _start16_off
    .word   0xf000
