/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-06: a protected far CALL must not modify the stack before the
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
 * HOW THIS RUN ACTUALLY ENDS -- and the header used to state this wrongly. The final
 * `outb %al,(%dx)` to 0xF4 does NOT complete: tb_main.cpp services I/O only in cosim
 * mode (`if (!cosim_mode) { io_ack = 0; return; }`), and the gates run this image with
 * --system and no --cosim, so io_ack never asserts and the core stalls ON that OUT.
 * The TB then reports "quiescent (core idle)".
 *
 * The WITNESS is unaffected and that is why the gate is still valid: ebp is set BEFORE
 * the OUT, so it appears in the last RETIRED record, which is exactly what the gate
 * reads with tail -1. What is not true is "exit status 133" -- nothing exits. Stated
 * accurately here rather than repeating a mechanism this harness does not provide.
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

    /* FPGA BIOS regression: SeaBIOS enters the VGA option ROM with the exact
     * `lcall *0(%bp)` encoding below (FF 5E 00), using C000 as an ordinary
     * real-mode segment.  C-06 once sent this through far_sel_bad(), treated
     * C000 as a GDT selector, and looped forever through #GP before IDE POST.
     * Keep this before LGDT/PE so the protected-only pcallsel witness below can
     * never accidentally cover the regression. */
    movw    $0x0460, %bp
    movw    $(real_call_target - _start16), 0x0460
    movw    $0xF000, 0x0462
    movw    $0x1357, 0x0464
    lcall   *0(%bp)                    /* must encode exactly FF 5E 00 */
    cmpw    $0x2468, 0x0464
    jne     real_call_failed

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

real_call_target:
    movw    $0x2468, 0x0464
    lret

real_call_failed:
    hlt
    jmp     real_call_failed

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
    movl    %esp, %ebx                 /* ESP BEFORE the far CALL */

    /* THE FINDING: a protected far CALL must not modify the stack before the
     * destination is validated. H-07's selector check runs at S_LCALL -> S_LJMP,
     * i.e. AFTER both pushes, so a rejected selector still faults with CS:next_eip
     * on the stack and ESP down 8. The check now runs at dispatch, before any push.
     *
     * lcall ptr16:32, hand-encoded: 9A <off32> <sel16>. Selector 0x0F00 is index 480
     * against a 3-entry GDT. The offset is never used. */
    .byte   0x9A
    .long   0x00000000
    .word   0x0F00

    /* Reached only if the far CALL SUCCEEDED with an out-of-table selector. */
    movl    $0xBADBAD00, %ebp
    jmp     exit

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
