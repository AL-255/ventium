/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Directed system-mode LAR/LSL oracle. All interesting results and ZF states
 * are captured in retire traces; no guest-side expected-value shortcuts.
 */
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

    /* GDT @ 0x500: null, flat code/data, based data, DPL3 data,
     * conforming code and a not-present data descriptor. The based data
     * limit is 0x12345 (G=0) so LSL is nontrivial. */
    movl    $0,      0x0500
    movl    $0,      0x0504
    movl    $0xffff, 0x0508
    movl    $0x00cf9a00, 0x050c
    movl    $0xffff, 0x0510
    /* A=1 here isolates LAR from the pre-existing segment-load accessed-bit
     * writeback omission. That omission needs its own regression gate/fix. */
    movl    $0x00cf9300, 0x0514
    movl    $0x2345, 0x0518
    movl    $0x00419202, 0x051c
    movl    $0xffff, 0x0520
    movl    $0x00cff200, 0x0524
    movl    $0xffff, 0x0528
    movl    $0x00cf9e00, 0x052c
    movl    $0xffff, 0x0530
    movl    $0x00cf1200, 0x0534
    movl    $0xffff, 0x0538
    movl    $0x00cff200, 0x053c
    movw    $0x003f, 0x0480
    movl    $0x00000500, 0x0482
    movw    $0x0018, 0x0600  /* 16-bit memory selector source */
    movw    $0x0000, 0x0602
    movw    $0x0048, 0x0604  /* out of GDT bounds */
    lgdt    0x0480
    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xea
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x90000, %esp

    /* Win95's exact register-source shape: 0F 02 F1 = LAR ESI,CX. */
    movw    $0x10, %cx
    movl    $0xdeadbeef, %esi
    lar     %cx, %esi
    pushfl
    popl    %edx

    /* LSL from a 16-bit memory selector into a 32-bit register. */
    movl    $0xaaaaaaaa, %ebx
    lsl     0x0600, %ebx
    pushfl
    popl    %ebp

    /* 16-bit LAR destination must retain its upper half. */
    movl    $0x76540000, %edi
    larw    0x0600, %di

    /* RPL=3 cannot inspect nonconforming DPL=0 code; it can inspect a
     * conforming code descriptor. The present bit is not a query filter. */
    movw    $0x000b, %cx
    movl    $0x89abcdef, %ebx
    lar     %cx, %ebx
    pushfl
    popl    %ebp
    movw    $0x002b, %cx
    lar     %cx, %ebx
    pushfl
    popl    %edx
    /* Win95's observed selector is 003b: GDT index 7, RPL 3. */
    movw    $0x003b, %cx
    lar     %cx, %esi
    pushfl
    popl    %edx
    movw    $0x0030, %cx
    lsl     %cx, %ecx
    pushfl
    popl    %edx

    /* NULL and out-of-table selectors clear ZF without changing destination. */
    movl    $0x11223344, %eax
    movw    $0, %cx
    lar     %cx, %eax
    pushfl
    popl    %edx
    movl    $0x55667788, %esi
    lsl     0x0604, %esi
    pushfl
    popl    %ebp

    movw    $0xf4, %dx
    movb    $0x42, %al
    outb    %al, %dx
1:  hlt
    jmp     1b

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xea
    .word   _start16_off
    .word   0xf000
