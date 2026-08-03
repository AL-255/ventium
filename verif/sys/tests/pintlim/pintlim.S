/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-03 (fourth bullet): an IDT gate whose OFFSET lies beyond the
 * destination CS limit must raise #GP(0) DURING delivery -- before the handler
 * context is installed and before any fetch is issued outside the segment.
 *
 * Ventium previously never compared the two. A gate naming a valid, present,
 * correctly-privileged code segment but an out-of-range offset installed CS/CPL and
 * then began fetching past the segment end; the fault, if it came at all, came from
 * the handler's own first fetch with the control context already switched.
 *
 * WHY THIS DISCRIMINATES IN THE DEFAULT BUILD -- which is the whole point, since
 * VEN_SEG_ENFORCE ships OFF and therefore nothing DOWNSTREAM catches the overrun
 * either. Both builds take a #GP; what differs is WHERE:
 *
 *   with the fix     delivery rejects the gate before CS is installed. The #GP frame
 *                    saves CS = 0x08, EIP = the `int $0x40` instruction.
 *   without the fix  delivery ACCEPTS it: CS=0x18 installs, eip=0x000F0000, and the
 *                    core fetches this image's own .code16 bytes as 32-bit code. That
 *                    garbage faults almost immediately, so the #GP frame saves
 *                    CS = 0x18 and an EIP inside the image.
 *
 * So the witness is the SAVED CS, not "a #GP happened" -- see the note in gp_handler.
 * An instruction count would not work either (the TB reports "quiescent (core idle)"
 * for a normal exit as well, and the two builds differ by only 4 instructions).
 *
 * SEEN TO FAIL -- and the first version of this test did NOT fail, which is the whole
 * reason the witness has its present shape. Measured, same image, both builds:
 *
 *   fixed     ebp=0x0C030008  esi=0x000F00F5   (saved CS 0x08, the INT instruction)
 *   reverted  ebp=0x0C030018  esi=0x000F0004   (saved CS 0x18, garbage in the image)
 *
 * A test written alongside its fix proves nothing until reversion has been observed
 * to change its verdict: REVIEW2_aug2 C-08 and C-09 both agreed with the code for the
 * wrong reason, and this test's own first draft made it three.
 *
 * Exit: isa-debug-exit with 0x42 -> status 133, with ebp = 0x0C030008 (the saved CS).
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

    /* GDT in LOW RAM at 0x0500, lgdt'd from an ABSOLUTE address -- a `lgdt label`
     * from .code16 emits R_386_16 against a label linked at 0x000F0000 and truncates.
     *
     *   0x0500  null
     *   0x0508  0x08  code32 flat            (0x00cf9a00_0000ffff)
     *   0x0510  0x10  data  flat             (0x00cf9200_0000ffff)
     *   0x0518  0x18  code32 LIMIT 0x0fff    (0x00409a00_00000fff)  <- the small CS
     *
     * 0x18 is byte-granular (G=0) with limit19:16 = 0, so its limit is exactly 0x0fff.
     * The gate below names it with offset 0x000F0000, which is far outside.
     */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510
    movl    $0x00cf9200, 0x0514
    movl    $0x00000fff, 0x0518
    movl    $0x00409a00, 0x051c        /* G=0 D=1 P=1 DPL=0 code, limit = 0x0fff */

    movw    $31,     0x0480            /* pseudo-descriptor: limit */
    movl    $0x0500, 0x0482            /*                    base  */
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    /* hand-encoded far jump: `ljmpl $0x08,$pm_entry` from .code16 against a .text32
     * label truncates for the same R_386_16 reason. */
    .byte   0x66, 0xEA          /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry            /* 32-bit offset (flat, base 0) */
    .word   0x08                /* 32-bit code selector */

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x7000, %esp

    /* ---- build the IDT at 0x0600 (in .code32: the gates need 32-bit offsets) ----
     * Zero vectors 0..0x40 first so a stray vector cannot land on a garbage gate and
     * make the result ambiguous. 0x41 entries * 8 bytes = 0x208.
     */
    movl    $0x0600, %edi
    movl    $0x82, %ecx                 /* 0x208 bytes / 4 = 0x82 dwords */
    xorl    %eax, %eax
    rep stosl

    /* IDT entry layout, per core_int_deliver.svh S_INT_GATE:
     *   word0 = {selector[15:0], offset[15:0]}
     *   word1 = {offset[31:16], attr[7:0], 8'b0}      (attr sits at bits [15:8])
     * attr 0x8E = P=1 DPL=0 type=0xE (32-bit interrupt gate).
     */

    /* vector 13 (#GP) -> selector 0x08 (FLAT), offset gp_handler. This one must be
     * reachable, or the test cannot report anything. */
    movl    $gp_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax           /* selector 0x08 in the high half */
    movl    %eax, 0x0600 + 13*8
    movl    $gp_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax           /* attr 0x8E at bits [15:8] */
    movl    %eax, 0x0600 + 13*8 + 4

    /* vector 0x40 -> selector 0x18 (limit 0x0fff), offset 0x000F0000. THE FINDING:
     * a perfectly well-formed gate and a perfectly valid code segment, with an offset
     * that is not inside it. */
    movl    $0x00180000, 0x0600 + 0x40*8         /* sel 0x18, offset[15:0] = 0x0000 */
    movl    $0x000f8e00, 0x0600 + 0x40*8 + 4     /* offset[31:16] = 0x000f, attr 0x8E */

    movw    $0x0207, 0x0490             /* IDT pseudo-descriptor: limit (covers 0x40) */
    movl    $0x0600, 0x0492             /*                        base  */
    lidt    0x0490

    /* ebp is the witness and is untouched by everything above. 0 = "never faulted". */
    xorl    %ebp, %ebp

    int     $0x40                       /* must #GP(0) during DELIVERY */

    /* Falling through means delivery ACCEPTED an out-of-limit handler offset and
     * somehow returned. Leave ebp at 0 so the gate reports failure. */
    jmp     exit

    .global gp_handler
gp_handler:
    /* Deliberately NO iret. For a fault raised DURING delivery the saved EIP is the
     * INT instruction itself, so an iret would re-execute `int $0x40` forever -- the
     * exact infinite loop that the pioperm attempt hit. One fault is all this test
     * needs, so the handler records the witness and exits.
     *
     * THE WITNESS MUST CARRY THE SAVED CS, NOT MERELY "a #GP happened".
     *
     * The first version of this test set a constant here and PASSED WITH THE FIX
     * REVERTED -- 182 instructions vs 178, same witness. The reason is that without
     * the limit check delivery SUCCEEDS: CS=0x18 installs, eip=0x000F0000, and the
     * core fetches this image's own .code16 bytes as 32-bit code. That garbage
     * promptly faults, lands in THIS handler, and sets the same constant. "A #GP was
     * delivered" is true in both builds and therefore discriminates nothing.
     *
     * The saved CS on the fault frame does discriminate, because it names WHERE the
     * fault was taken:
     *   fixed     delivery rejects the gate BEFORE installing CS -> saved CS = 0x08
     *   reverted  CS was installed, the overrun fetch faulted    -> saved CS = 0x18
     *
     * Same-privilege #GP frame, error code present:
     *   0(%esp) = error code   4(%esp) = eip   8(%esp) = cs   12(%esp) = eflags
     */
    movl    8(%esp), %eax               /* saved CS */
    movl    4(%esp), %esi               /* saved EIP -- the INT insn when correct */
    andl    $0x0000ffff, %eax
    orl     $0x0C030000, %eax           /* witness = 0x0C03_00<saved cs> */
    movl    %eax, %ebp

exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* isa-debug-exit -> status 133 */
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
