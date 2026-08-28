/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * fxprog — the driver program for verif/fxabort/tb_fxabort.sv (the focused
 * fragment-engine abort/reset testbench). NOT a differential test: it only
 * has to run on the core and force each fragment phase. Sequence:
 *
 *   R_OK : lgdt [0x8FFE]  -- pages 8/9 present (read frag1+frag2 complete)
 *   R_F2 : lgdt [0x6FFE]  -- page 7 NOT PRESENT: frag2 faults mid-sequence
 *          (the engine is engaged, frag1 already captured); the #PF handler
 *          maps page 7 and the restarted lgdt completes.
 *   R_F1 : lgdt [0x4FFE]  -- page 4 NOT PRESENT: the initial request faults
 *          BEFORE the engine engages (no fragment state exists to abort);
 *          the handler maps page 4 and the restarted lgdt completes.
 *   W_OK : fnstenv [0xAFFE] -- pages 0xA/0xB present (probe + fragA + fragB);
 *          the start is deliberately 2 mod 4 so the first beat straddles
 *   W_F  : fnstenv [0xCFFE] -- page 0xD NOT PRESENT: the write probe faults
 *          before page 1 is touched; the handler maps page 0xD and the
 *          restarted fnstenv completes.
 *   DONE : write 0xD00DF00D to 0x1F000 (the TB watches the bus for it), halt.
 *
 * All three pseudo-descriptors point at the boot GDT {base 0x500, limit
 * 0x2F}, planted with physical writes before paging is enabled. The TB
 * reboots the image between reset-injection runs, so boot must be fully
 * idempotent (the NP pages are re-denied by the PT0 rebuild).
 *
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    movl    $0x00000000, 0x0500         /* 0x00 null */
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508         /* 0x08 code0 flat */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510         /* 0x10 data0 flat */
    movl    $0x00CF9200, 0x0514
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00090000, %esp

    /* IDT: #PF(14) -> pf_handler (interrupt gate 0x8E, CS=0x08) */
    movl    $pf_handler, %ebx
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x00001070
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 0x00001074
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* plant the pseudo-descriptors (physical writes, paging off): each is
     * {limit 0x2F, base 0x500} = the boot GDT */
    movw    $0x002F, 0x00008FFE
    movl    $0x00000500, 0x00009000
    movw    $0x002F, 0x00006FFE
    movl    $0x00000500, 0x00007000
    movw    $0x002F, 0x00004FFE
    movl    $0x00000500, 0x00005000
    movl    $0, 0x0001F000              /* the DONE slot */

    /* page tables: PD @0x11000, PT0 @0x12000 identity [0,1MiB), except
     * PT0[4], PT0[7], PT0[0xD] NOT PRESENT */
    movl    $0x00012003, 0x00011000
    movl    $0x00012000, %edi
    xorl    %eax, %eax
1:  movl    %eax, %edx
    orl     $0x00000003, %edx
    movl    %edx, (%edi)
    addl    $4, %edi
    addl    $0x1000, %eax
    cmpl    $0x00100000, %eax
    jb      1b
    movl    $0x00000000, 0x00012010     /* PT0[4] NP (R_F1) */
    movl    $0x00000000, 0x0001201C     /* PT0[7] NP (R_F2) */
    movl    $0x00000000, 0x00012034     /* PT0[0xD] NP (W_F) */

    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    fninit

    /* ---- the phase drivers ---- */
    .global r_ok
r_ok:
    lgdt    0x00008FFE                  /* read crossing, both pages present */
    .global r_f2
r_f2:
    lgdt    0x00006FFE                  /* read frag2 faults (page 7 NP) */
    .global r_f1
r_f1:
    lgdt    0x00004FFE                  /* read frag1 faults (page 4 NP) */
    .global w_ok
w_ok:
    fnstenv 0x0000AFFE                  /* write crossing, both pages present:
                                         * the FIRST 4-byte beat straddles
                                         * (0xAFFE..0xB001) -- an aligned start
                                         * would never engage the engine */
    .global w_f
w_f:
    fnstenv 0x0000CFFE                  /* write probe faults (page 0xD NP) */

    movl    $0xD00DF00D, 0x0001F000     /* DONE marker (the TB watches the bus) */
    .global fxprog_hang
fxprog_hang:
    hlt
    jmp     fxprog_hang

/* #PF handler: map the faulting page per CR2, count, restart. Same-priv
 * frame: [esp]=err, +4=EIP, +8=CS, +12=EFLAGS. */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    cmpl    $0x00007000, %eax
    jne     1f
    movl    $0x00007003, 0x0001201C     /* PT0[7] present */
    jmp     9f
1:  cmpl    $0x00004FFE, %eax
    jne     2f
    movl    $0x00004003, 0x00012010     /* PT0[4] present */
    jmp     9f
2:  movl    $0x0000D003, 0x00012034     /* PT0[0xD] present (CR2=0xD000) */
9:  incl    0x0001F004                  /* #PF count */
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp
    iret

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
