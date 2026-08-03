/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-06 PREREQUISITE: a POSITIVE far CALL/RETF test, with source.
 *
 * C-06's remaining half is a "validate, then push, then commit" reorder of the
 * far-transfer path. Measured while deciding whether to attempt it:
 *
 *   - verify-sys's golden list contains NO far-CALL test.
 *   - psocfarcall / psoccallfmem / psocpmretf are referenced by ZERO gates, and their
 *     directories hold only .bin/.elf/.o -- no .S, no Makefile, no linker script. They
 *     are unrebuildable artifacts (the M-04/M-05 missing-source problem, task #64), so
 *     they cannot be registered as they stand.
 *   - pcallsel, written in this review, covers the far CALL REJECT path only.
 *
 * So a far CALL that SUCCEEDS was exercised by nothing any gate runs, and reordering
 * that path would have shipped unregressed. This is the missing positive case.
 *
 * WHAT IT DOES: a protected-mode far CALL to a second, valid code segment, then a far
 * RETF back. ebp accumulates both halves, so the witness distinguishes "never called"
 * from "called but never returned":
 *
 *   0x00000000  the far CALL never transferred
 *   0xFA000001  reached the target but the RETF did not come back
 *   0xFA000003  both the call and the return completed   <- correct
 */

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

    /* GDT at 0x0500, THREE entries only -- limit 0x17. Selector 0x0F00 is far past
     * the end, which is the whole point. */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 flat DPL0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 flat DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code32 flat DPL0 -- the CALL target */
    movl    $0x00cf9a00, 0x051c

    movw    $0x001f, 0x0480            /* GDT limit = 4*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x7000, %esp

    /* Zero 0x1000..0x1FFF so the descriptor the BROKEN core would read at
     * gdt_base + 0x0F00 = 0x1700 is deterministically not-present. Without this the
     * negative case depends on RAM contents and the test proves nothing. */
    movl    $0x00001000, %edi
    movl    $1024, %ecx
    xorl    %eax, %eax
    rep stosl

    /* IDT at 0x0600, vectors 0..13 zeroed, then #GP(13) and #NP(11) each to their
     * OWN handler so the witness identifies WHICH exception was delivered. */
    movl    $0x00000600, %edi
    movl    $28, %ecx                  /* 14 gates * 8 bytes / 4 */
    xorl    %eax, %eax
    rep stosl

    movl    $gp_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0600 + 13*8
    movl    $gp_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax
    movl    %eax, 0x0600 + 13*8 + 4

    movl    $np_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0600 + 11*8
    movl    $np_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax
    movl    %eax, 0x0600 + 11*8 + 4

    movw    $0x006F, 0x0490            /* IDT limit covers vector 13 */
    movl    $0x00000600, 0x0492
    lidt    0x0490

    xorl    %ebp, %ebp                 /* 0 = the far CALL never transferred */

    /* far CALL to selector 0x18, which the GDT above defines as a VALID flat code32
     * segment. Hand-encoded ptr16:32 (9A off32 sel16); the offset is a .code32
     * absolute, so no R_386_16 truncation is involved. */
    .byte   0x9A
    .long   far_target
    .word   0x0018
    /* control returns HERE from the RETF */
    orl     $0x00000002, %ebp          /* -> 0xFA000003 */
    jmp     exit

far_target:
    movl    $0xFA000001, %ebp          /* reached the far target */
    lret                               /* far return to the caller */

    .global gp_handler
gp_handler:
    /* Same-privilege #GP frame WITH an error code: err, eip, cs, eflags = 16 bytes.
     * So the ESP at the moment of the fault is handler_esp + 16. Comparing that with
     * the value saved before the far CALL is the whole assertion:
     *   equal      the stack was untouched -> the selector was rejected at dispatch
     *   8 lower    CS and next_eip were already pushed before the rejection
     * The witness carries the DIFFERENCE so a wrong answer reports how far off it was
     * rather than just failing. */
    leal    16(%esp), %eax             /* ESP at the fault */
    subl    %eax, %ebx                 /* saved - at_fault: 0 if untouched, 8 if pushed */
    andl    $0x000000ff, %ebx
    movl    $0x0CA10000, %eax
    orl     %ebx, %eax
    movl    %eax, %ebp                 /* 0x0CA10000 = clean, 0x0CA10008 = pushed */
    jmp     exit

    .global np_handler
np_handler:
    movl    0(%esp), %eax
    andl    $0x0000ffff, %eax
    orl     $0x0B000000, %eax          /* 0x0B = vector 11, #NP */
    movl    %eax, %ebp

exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
