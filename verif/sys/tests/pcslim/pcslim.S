/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 H-05: INSTRUCTION FETCH must be checked against the CS limit.
 *
 * The per-access segment check is qualified on cur_is_d -- deliberately, because a
 * fetch address measured against the DS limit is the spurious #GP that got this
 * finding's delivery reverted in an earlier round. The consequence was that fetches
 * were checked by nothing at all: EIP could walk out of the code segment and the core
 * kept fetching and executing.
 *
 * This test runs inside a code segment with limit 0x0F -- sixteen valid bytes. Sixteen
 * NOPs fill offsets 0..15 exactly; the instruction after them starts at offset 16,
 * which is outside. Fetching it must #GP(0).
 *
 *   with the fix     #GP at the fetch of offset 16   -> ebp = 0x0C510010
 *   without the fix  the fetch proceeds and the code past the limit EXECUTES,
 *                    setting the poison witness      -> ebp = 0xBADBAD00
 *
 * The poison instruction past the limit is what makes this discriminate. A test that
 * only asked "did a #GP happen" would be satisfied by a fault from anywhere.
 *
 * Requires +define+VEN_SEG_ENFORCE. In the DEFAULT build no segment check runs at all,
 * so the poison witness is the correct expected outcome there -- the gate asserts the
 * #GP only against the enforcing build, and asserts the poison against the default one,
 * which also proves the test is really reaching the out-of-limit fetch.
 *
 * Exit: isa-debug-exit with 0x42 -> status 133, ebp = 0x0C510010 (enforcing build).
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

    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 flat DPL0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 flat DPL0 */
    movl    $0x00cf9200, 0x0514
    /* 0x18 is built at runtime in pm_entry: its base is a .text32 label, which a
     * 16-bit section cannot name without an R_386_16 truncation. */

    movw    $0x001f, 0x0480            /* GDT limit = 4*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA
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

    /* GDT[3] = 0x18: code32, base = cs_stub, LIMIT 0x0F (G=0, so it is exact),
     * access 0x9A, flags nibble 0x4 (G=0, D/B=1).
     *   low  = (base[15:0] << 16) | 0x000F
     *   high = base[31:24] | 0x4<<20 | limit[19:16]<<16 | 0x9A<<8 | base[23:16] */
    movl    $cs_stub, %ebx
    movl    %ebx, %eax
    shll    $16, %eax
    orl     $0x0000000F, %eax
    movl    %eax, 0x0518
    movl    %ebx, %eax
    andl    $0xFF000000, %eax          /* base[31:24] already in place */
    movl    %ebx, %ecx
    shrl    $16, %ecx
    andl    $0x000000FF, %ecx          /* base[23:16] */
    orl     %ecx, %eax
    orl     $0x00409A00, %eax          /* flags 0x4, limit19:16 = 0, access 0x9A */
    movl    %eax, 0x051C

    /* IDT at 0x0600: vector 13 -> gp_handler through the FLAT selector 0x08, so the
     * handler is reachable even though CS is about to become a 16-byte segment. */
    movl    $0x00000600, %edi
    movl    $28, %ecx
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
    movw    $0x006F, 0x0490
    movl    $0x00000600, 0x0492
    lidt    0x0490

    xorl    %ebp, %ebp

    /* Far jump into the 16-byte segment at offset 0. Offset 0 needs no relocation, so
     * hand-encoding keeps this safe from .code32 as well. */
    .byte   0xEA
    .long   0
    .word   0x18

    /* ---- the 16-byte code segment -----------------------------------------------
     * Offsets 0..15 are valid; the instruction at offset 16 is not. */
    .align  16
    .global cs_stub
cs_stub:
    .rept   16
    nop
    .endr
    /* offset 16: OUTSIDE the limit. Fetching this must #GP. If it executes instead,
     * the poison witness records that the fetch went unchecked. */
    movl    $0xBADBAD00, %ebp
    jmp     escape

    .global gp_handler
gp_handler:
    /* Entered with CS = 0x08 (flat) because the gate names the flat selector.
     * 0(%esp) = error code, 4(%esp) = the faulting EIP = 16, the offset that lay
     * outside the segment. Encoding it into the witness is what distinguishes this
     * #GP from any other one the test could have taken. */
    movl    4(%esp), %eax
    andl    $0x0000ffff, %eax
    orl     $0x0C510000, %eax          /* witness = 0x0C51_00<faulting offset> */
    movl    %eax, %ebp
escape:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
