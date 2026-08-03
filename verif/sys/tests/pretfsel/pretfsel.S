/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 H-07: a far RETF must bound its POPPED CS selector against the
 * descriptor table BEFORE issuing the descriptor read.
 *
 * The dispatch arm prechecked SYS_LJMP only. Far CALL and RETF reach S_LJMP after
 * stack activity, so their selectors -- and the popped CS is the least trustworthy
 * selector in the machine, it comes straight off the stack -- indexed the GDT with no
 * bounds test. A selector past the table end read arbitrary memory AS a descriptor.
 *
 * HOW THIS DISCRIMINATES -- MEASURED, and not what was predicted when this test was
 * written. The guess was that the broken core would read the zeroed descriptor at
 * gdt_base + 0x0F00 = 0x1700, find it not-present, and deliver #NP instead of #GP --
 * i.e. the right kind of fault with the wrong vector. What actually happens:
 *
 *   with the fix     the selector is rejected before the read -> exactly ONE fault,
 *                    [FAULT] vec=13 err=00000f00 at the LRET
 *                    -> gp_handler, ebp = 0x0D000F00
 *   without the fix  NO FAULT IS RAISED AT ALL. The run retires 1105 instructions
 *                    instead of 1113 and goes quiescent AT the LRET -- it stalls
 *                    rather than mis-classifying. ebp is never written.
 *
 * The witness is therefore "#GP(0x0F00) was delivered", and an ABSENT witness is a
 * failure, not an inconclusive result. np_handler stays installed anyway: if some
 * future build does deliver #NP here, the gate should say so distinctly rather than
 * lump it in with the stall.
 *
 * Zeroing 0x1000..0x2000 keeps the negative case deterministic rather than dependent
 * on whatever happened to be in RAM at the out-of-table descriptor address.
 *
 * SEEN TO FAIL: measured against a build with the four far_sel_bad() guards removed.
 *
 * Exit: isa-debug-exit with 0x42 -> status 133, ebp = 0x0D000F00.
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

    movw    $0x0017, 0x0480            /* GDT limit = 3*8-1 */
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

    xorl    %ebp, %ebp                 /* witness: 0 = never faulted */

    /* THE FINDING: far-return to an out-of-table selector. lret pops EIP then CS,
     * so push CS first. 0x0F00 is index 480 against a 3-entry GDT. */
    pushl   $0x00000F00                /* CS  */
    pushl   $retf_target               /* EIP */
    lret

retf_target:
    /* Reached only if the RETF SUCCEEDED with an out-of-table selector. */
    movl    $0xBADBAD00, %ebp
    jmp     exit

    .global gp_handler
gp_handler:
    /* No iret: the fault's saved EIP is the LRET itself, so returning would loop.
     * 0(%esp) = error code. */
    movl    0(%esp), %eax
    andl    $0x0000ffff, %eax
    orl     $0x0D000000, %eax          /* 0x0D = vector 13, #GP */
    movl    %eax, %ebp
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
