/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-06: a protected far RETF whose POPPED CS has RPL > CPL is a return
 * to an OUTER privilege level. IA-32 requires the frame to carry ESP and SS as well,
 * and the CPU must pop and VALIDATE them and switch to the outer stack.
 *
 * Ventium reused far-JMP semantics for RETF: it loaded CS and took CPL from the popped
 * RPL, but never touched SS:ESP. The result is outer-privilege code running on the
 * INNER stack -- a ring-3 routine holding a ring-0 stack pointer, which is a privilege
 * escalation primitive, not merely a wrong register. It failed SILENTLY, which is why
 * it carried a [VEN-RETFOUT] instrument for this whole review.
 *
 * THE WITNESS IS SS, and that is the point. Both builds reach ring 3 and both set ebp;
 * what differs is WHICH STACK the ring-3 code is standing on:
 *
 *   with the fix     SS:ESP are popped and validated -> SS = 0x23 (the ring-3 stack)
 *                    -> ebp = 0x0C060023
 *   without the fix  SS is never touched              -> SS = 0x10 (the RING-0 stack)
 *                    -> ebp = 0x0C060010
 *
 * A test that only asked "did we reach ring 3" would pass in BOTH builds -- CPL does
 * take the popped RPL either way. That is exactly the trap pintlim's first draft fell
 * into, so the witness names the stack, not the privilege level.
 *
 * ESP is checked too (esi), for the same reason: SS could in principle be reloaded
 * without ESP and the segment half alone would look correct.
 *
 * IOPL is set to 3 before the return so the ring-3 tail may drive port 0xF4. With
 * CPL == IOPL == 3 no TSS I/O bitmap consultation is required, so this test does not
 * depend on the C-07/M-02 bitmap path.
 *
 * HOW THIS RUN ENDS: the final `outb %al,(%dx)` to 0xF4 does NOT complete -- the TB
 * services I/O only in cosim mode and the gates run --system without --cosim, so
 * io_ack never asserts and the core stalls ON that OUT. The TB reports "quiescent
 * (core idle)". ebp/esi are set BEFORE the OUT, so they appear in the last RETIRED
 * record, which is what the gate reads with tail -1.
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

    /* GDT at 0x0500:
     *   0x00 null   0x08 code0   0x10 data0   0x18 code3   0x20 data3 */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code32 DPL3 -> selector 0x1B */
    movl    $0x00cffa00, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data32 DPL3 -> selector 0x23 */
    movl    $0x00cff200, 0x0524

    movw    $0x0027, 0x0480            /* GDT limit = 5*8-1 */
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
    movl    $0x00007000, %esp

    /* IOPL = 3, so the ring-3 tail may drive port 0xF4 with CPL == IOPL. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    xorl    %ebp, %ebp                 /* witness: 0 = ring 3 never reached */
    xorl    %esi, %esi

    /* THE FINDING: far-return to an OUTER level. LRET pops EIP, CS, then -- because
     * the popped CS.RPL (3) is greater than CPL (0) -- ESP and SS. Push in reverse. */
    pushl   $0x00000023                /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00008000                /* ESP = the ring-3 stack */
    pushl   $0x0000001B                /* CS  = ring-3 code, RPL 3 */
    pushl   $r3_entry                  /* EIP */
    lret

    /* Reached only if the RETF did not transfer at all. */
    movl    $0xBADBAD00, %ebp
    jmp     r3_exit

    .global r3_entry
r3_entry:
    /* CPL is 3 here in BOTH builds -- CS.RPL is taken either way. The question this
     * test asks is which STACK we are standing on. */
    movl    %ss, %eax
    andl    $0x0000ffff, %eax
    orl     $0x0C060000, %eax          /* witness = 0x0C06_00<ss> */
    movl    %eax, %ebp
    movl    %esp, %esi                 /* 0x00008000 fixed / ~0x00007000 broken */

r3_exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b                          /* NOT hlt: privileged at CPL 3 */

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
