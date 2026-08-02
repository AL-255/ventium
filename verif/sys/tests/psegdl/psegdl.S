/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-01: a segment violation must not DEADLOCK the DEFAULT build.
 *
 * seg_access_fault was computed unconditionally while its DELIVERY lived under
 * `ifdef VEN_SEG_ENFORCE and the bus-driver SQUASH was likewise unconditional. In the
 * default build that gave: fault asserts -> request suppressed -> no #GP started ->
 * the FSM waits forever for an acknowledgement that can never arrive.
 *
 * Measured on pseglim before the fix: 95 instructions then "quiescent (core idle)",
 * against 154 for the enforcement build.
 *
 * pseglim cannot be this test: it INSTALLS a #GP handler, so its instruction count
 * depends on whether faults are delivered, and "fewer instructions" is ambiguous
 * between a deadlock and a legitimately different path. This test instead does the
 * violating accesses and then UNCONDITIONALLY signals completion, so the only two
 * outcomes are "exited" and "hung". It is a liveness check, not a semantics check --
 * what the violating access DOES in the default build is a separate question (H-05).
 *
 * Exit: isa-debug-exit with 0x42 -> status 133. Reaching it at all is the assertion.
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

    /* Build the GDT in LOW RAM at 0x0500 and lgdt an ABSOLUTE address, exactly as
     * pseglim.S does (`lgdt 0x0480`). A `lgdt gdt_desc` against a linked label emits
     * an R_386_16 relocation from .code16 and truncates -- the image is linked at
     * 0x000F0000, which no 16-bit offset can name.
     *
     *   0x0500  null
     *   0x0508  0x08  code32 flat        (0x00cf9a00_0000ffff)
     *   0x0510  0x10  data, limit 0xffff (0x00409200_0000ffff)  <- the violator
     *   0x0518  0x18  data flat          (0x00cf9200_0000ffff)
     */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510
    movl    $0x00409200, 0x0514        /* G=0 D=1 limit19:16=0 -> limit is 0xffff */
    movl    $0x0000ffff, 0x0518
    movl    $0x00cf9200, 0x051c

    movw    $31,     0x0480            /* pseudo-descriptor: limit */
    movl    $0x0500, 0x0482            /*                    base  */
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    /* hand-encoded far jump: a plain `ljmpl $0x08,$pm_entry` emits an R_386_16
     * relocation against .text32 in .code16 and truncates (same reason pseglim.S
     * encodes it by hand at its own transition). */
    .byte   0x66, 0xEA          /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry            /* 32-bit offset (flat, base 0) */
    .word   0x08                /* 32-bit code selector */

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax          /* DS = the 64 KiB data segment (limit 0xffff) */
    movw    %ax, %ds
    movw    $0x18, %ax          /* SS = flat, so the stack is never the violator */
    movw    %ax, %ss
    movl    $0x7000, %esp

    /* THE VIOLATING ACCESSES: offset 0x10000 is one byte past a 0xffff limit.
     * Each must either fault (enforcement) or complete (default) -- but must NOT
     * leave the core waiting on an acknowledgement forever. */
    movl    $0x00010000, %ebx
    movl    (%ebx), %eax        /* violating LOAD  */
    movl    $0xcafebabe, (%ebx) /* violating STORE */

    /* If we get here the core is still live. Signal completion.
     *
     * NO SERIAL: plain --system mode does not wire the 16550, so an OUT to 0x3F8
     * stalls waiting for an I/O acknowledgement (task #73). That bit me writing this
     * test -- the run stopped at the OUT, three instructions PAST the violating
     * accesses, which for a moment looked like the very deadlock being tested.
     * isa-debug-exit (0xF4) is implemented, so the exit status alone is the signal.
     */
    /* LIVENESS WITNESS: the TB reports "quiescent (core idle)" for a NORMAL exit
     * too (pseglim does the same), so an instruction count cannot distinguish
     * "completed" from "hung". A register witness in the final trace record can.
     * ebp is untouched by everything above. */
    movl    $0x5EED11FE, %ebp

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx            /* isa-debug-exit -> status 133 */
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
