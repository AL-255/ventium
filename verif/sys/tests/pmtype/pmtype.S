/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 H-13: instruction-fetch cacheability must follow the PHYSICAL MEMORY
 * TYPE, not CR0.CD alone.
 *
 * The icache retained any line it fetched, with no notion of what the chipset says
 * about the address. A line in a region the cacheability map marks non-cacheable was
 * cached anyway, so later fetches from it were served from a stale copy.
 *
 * THE REGION THIS USES is 0xA8000 -- inside the 0xA0000-0xBFFFF SMRAM/VGA aperture.
 * With SMRAM closed (NB_SMRAM=0, the default) and the CPU outside SMM, ven_cachemap
 * decodes that aperture as {to_dram=0, l1_cacheable=0, l2_cacheable=0} -- verified
 * independently by run-cachemap-gate.sh's `smram_closed` check. So it is a region that
 * is REACHABLE from a test image and genuinely uncacheable, which is what makes this
 * measurable rather than hypothetical.
 *
 * WHAT IT DOES: copies a small loop into 0xA8000 and runs it many times. The loop body
 * is deliberately reuse-heavy -- the same two cache lines re-fetched every iteration --
 * so "retained" and "not retained" differ by a large, unambiguous number of bus reads.
 *
 *   with H-13     ic_fill_nocache is asserted for these fetches -> the lines are never
 *                 retained -> every iteration refetches -> bus reads climb
 *   without it    the lines are cached -> the loop runs almost entirely out of the
 *                 icache -> far fewer bus reads
 *
 * ebp is the architectural witness and must be IDENTICAL in both builds: honouring the
 * memory type changes only whether a line is kept, never what it computes. A gate that
 * checked only the read count could pass while the fix silently broke execution, so it
 * checks both.
 *
 * The loop body is position-independent (its back-edge is a short relative jump), which
 * is what lets it be assembled here and executed from 0xA8000.
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

    movw    $0x0017, 0x0480
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
    movl    $0x00007000, %esp

    /* CLEAR CR0.CD (bit30) and NW (bit29). Without this the test measures NOTHING:
     * CR0 resets to 0x60000010 with CD SET, no image in this corpus ever clears it,
     * and ic_fill_nocache is therefore already 1 from the CR0.CD term alone -- so the
     * memory-type term ORs into an expression that is already true and the two builds
     * come out byte-identical. (They did, on the first run of this test: 56208 reads
     * both ways.) A real 486/P5 BIOS clears CD/NW after POST, so this is also what
     * hardware actually does. */
    movl    %cr0, %eax
    andl    $0x9FFFFFFF, %eax
    movl    %eax, %cr0

    /* copy the loop body into the uncacheable aperture at 0xA8000 */
    movl    $blob_start, %esi
    movl    $0x000A8000, %edi
    movl    $(blob_end - blob_start), %ecx
    rep movsb

    xorl    %ebp, %ebp
    movl    $200, %ebx                 /* iterations */
    movl    $0x000A8000, %eax
    jmp     *%eax                      /* enter the uncacheable code */

    .global blob_start
blob_start:
    /* Position-independent: the back edge is a SHORT relative jump, so this runs
     * correctly from 0xA8000 despite being assembled at its link address. Padded out
     * to span more than one 32-byte line, so a retained copy really does save fetches. */
1:  addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    addl    $1, %ebp
    decl    %ebx
    jnz     1b
    /* back to the BIOS image by absolute address */
    movl    $blob_done, %eax
    jmp     *%eax
    .global blob_end
blob_end:

    .global blob_done
blob_done:
    /* ebp must be 200*12 = 2400 = 0x960 in BOTH builds. */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
