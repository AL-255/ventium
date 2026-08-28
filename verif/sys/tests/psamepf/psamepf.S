/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug4 A4-H06 — same-privilege delivery PARTIAL FRAME: an interrupt
 * delivery has NO frame pre-probe, so a same-privilege frame that straddles
 * into a non-present (or read-only) page faults MID-FRAME with the landed
 * dwords visible. QEMU shares the incremental-push model exactly
 * (do_interrupt_protected PUSHL one dword at a time, SET_ESP only after the
 * last push -- env->regs[R_ESP] is UNCHANGED when a push faults), so this is
 * fully differential.
 *
 * THE STACK GEOMETRY (why the pieces fit):
 *   * A shared flat stack means the #PF's own frame starts at the SAME ESP
 *     the aborted delivery had (QEMU does not charge ESP for landed pushes),
 *     so the #PF handler must have a SMALLER frame than the trigger or it
 *     re-faults on the same page. The trigger is a 16-byte #GP frame
 *     (EFLAGS,CS,EIP,err); the #PF goes through a 16-BIT GATE (type 0x6,
 *     pint16f machinery) whose 8-byte word frame (FLAGS,CS,IP,err) stays on
 *     the present page. A 32-bit #PF frame (16 bytes) would re-fault, and an
 *     IDT task gate is not available (the RTL deliberately #GPs those --
 *     core_int_deliver.svh A4-H05 note).
 *   * ESP = page1_top + 0xC: the trigger's EFLAGS/CS/EIP dwords land on the
 *     present page, the ERR push is the first one on the missing page and
 *     faults. CR2 = that err-push address ("the first push's address on the
 *     missing page"), err = W/R=1 (+P for the read-only case).
 *   * The 16-bit #PF frame (8 bytes at ESP-8..ESP-1) OVERWRITES the landed
 *     EFLAGS/CS dwords, but the landed EIP dword at ESP-12 SURVIVES below it
 *     -- the observable "partial frame bytes that DID land" witness, read by
 *     the #PF handler.
 *   * All code segments are BASED at 0xF0000 (offsets 16-bit clean) so the
 *     16-bit #PF frame's word IP slots are exact. The #PF handler rewrites
 *     its saved IP word to a 32-bit FIXUP stub (IRETW pops a word; a 0xF0xxx
 *     absolute EIP would truncate), which maps the page, proves the poison
 *     dword at the fault address survived (the err push never landed), and
 *     RE-FIRES the trigger. The delivery restarts and completes; the #GP
 *     handler records the full 4-dword frame.
 *
 * Case A (page 2 NOT PRESENT): trigger stack ESP = 0x800C (page 0x8000
 *   present, page 0x7000 NOT PRESENT, poison 0xDEAD7000 pre-written at
 *   0x7FFC). ljmp to the limit-0x100 segment 0x50 at offset 0x101 -> #GP(0)
 *   (the A4-C02 fault class; re-fires cleanly). EFLAGS@0x8008, CS@0x8004,
 *   EIP@0x8000 land; the err push @0x7FFC #PFs: CR2 = 0x00007FFC, err =
 *   0x002 (P=0,W=1), ESP at the fault = 0x800C (unchanged). The 16-bit #PF
 *   frame fits at 0x8004..0x800B. Fixup maps page 0x7000, proves the poison
 *   at 0x7FFC is intact, re-fires -> the completed #GP frame lands all four
 *   dwords (handler ESP = 0x7FFC).
 * Case B (page 2 present but READ-ONLY, CR0.WP=1): ESP = 0x600C (page
 *   0x6000 present, page 0x5000 read-only, poison 0xDEAD5000 at 0x5FFC).
 *   Same shape: #PF with CR2 = 0x00005FFC, err = 0x003 (P=1,W=1 -- the
 *   probe-class fault), the poison at 0x5FFC is READABLE while RO and must
 *   be intact; fixup makes the page RW and re-fires (handler ESP = 0x5FFC).
 *
 * Memory plan (paging ON, WP ON; identity map 0..0xFFFFF):
 *   GDT @ 0x500: null; 0x08 code32 DPL0 base 0xF0000; 0x10 data32 flat;
 *                0x18 code16 DPL0 base 0xF0000 (D=0, the 16-bit #PF handler);
 *                0x50 code32 DPL0 base 0xF0000 limit 0x100 (#GP trigger)
 *   IDT @ 0x1000: 13 (#GP) -> gpgp_handler (32-bit int gate, sel 0x08);
 *                14 (#PF) -> pf16_handler (16-BIT int gate, sel 0x18)
 *   markers @ 0x2000, PD @ 0x11000, PT0 @ 0x12000 (identity, then toggled)
 *   mainline stack 0x15000; case-A stack 0x800C (page 8 present / 7 NP);
 *   case-B stack 0x600C (page 6 present / 5 RO)
 *
 * WITNESSES (marker page; folded into exit GPRs -- memory is not traced):
 *   0x2000  case-A #PF err word == 0x0002 (P=0,W=1)          (composite)
 *   0x2004  case-A CR2 == 0x00007FFC                          edi at exit
 *   0x2008  case-A ESP at the fault == 0x0000800C (composite)
 *   0x200C  case-A SURVIVING EIP dword @ 0x8000 == the ljmp   esi at exit
 *   0x2010  case-A poison @ 0x7FFC intact post-remap (1)      (composite)
 *   0x2014  case-A completed #GP handler ESP == 0x7FFC        (composite)
 *   0x2018  case-A completed frame's err dword == 0           (composite)
 *   0x2020  case-B #PF err word == 0x0003 (P=1,W=1)          (composite)
 *   0x2024  case-B CR2 == 0x00005FFC                          ebp at exit
 *   0x2028  case-B ESP at the fault == 0x0000600C (composite)
 *   0x202C  case-B SURVIVING EIP dword @ 0x6000 == the ljmp   ecx at exit
 *   0x2030  case-B poison @ 0x5FFC intact (1)                 (composite)
 *   0x2034  case-B completed #GP handler ESP == 0x5FFC        (composite)
 *   0x2038  case-B completed frame's err dword == 0           (composite)
 *   0x2044  CUR: the current case index (1 = A, 2 = B)
 *   exit ebx = 0xA406A406 iff every composite check passes.
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    /* GDT at 0x0500 (limit 0x57). Code segments are BASED at 0xF0000 so all
     * offsets are 16-bit clean (the 16-bit #PF frame pushes WORD IPs).      */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 base 0xF0000 lim 0xFFFF */
    movl    $0x00409a0f, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 flat */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code16 DPL0 base 0xF0000 (D=0) */
    movl    $0x00009a0f, 0x051c
    movl    $0x00000100, 0x0550        /* 0x50 code32 DPL0 base 0xF0000 lim 0x100 */
    movl    $0x00409a0f, 0x0554

    movw    $0x0057, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   _pm32_off
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00015000, %esp

    /* ---- zero the marker area 0x2000..0x2048 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $18, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: 13 #GP -> gpgp_handler (32-bit gate 0x8E, sel 0x08);
     * 14 #PF -> pf16_handler (16-BIT gate attr 0x86, sel 0x18, offset 16).  -- */
    movl    $_hgp_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1068               /* 0x1000 + 13*8 */
    movl    $_hgp_off, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax
    movl    %eax, 0x106c
    movl    $_hpf_off, %eax            /* 16-bit gate: lo = (sel<<16)|off16 */
    orl     $0x00180000, %eax
    movl    %eax, 0x1070               /* 0x1000 + 14*8 */
    movl    $0x00008600, 0x1074        /* attr 0x86: P, DPL0, 16-bit int gate */
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- page tables: PT0 @ 0x12000 identity-maps pages 0..0xFF P|RW;
     * PD @ 0x11000. Then paging + WP on. ---------------------------------- */
    movl    $0x00012000, %edi
    movl    $0x00000003, %eax          /* P|RW, supervisor */
    movl    $256, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00012003, 0x00011000    /* PD[0] -> PT0 */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80010000, %eax          /* PG | WP */
    movl    %eax, %cr0

    /* ======================= case A: page 2 NOT PRESENT =================== */
    movl    $0xDEAD7000, 0x00007FFC    /* poison the err-push slot (page 7 RW) */
    movl    $0x00000000, 0x0001201C    /* PTE[7] = NOT PRESENT */
    invlpg  0x7000                     /* drop the cached present translation */
    movl    $1, 0x00002044             /* CUR = case A */
    movl    $0x0000800C, %esp          /* frame: EFLAGS@0x8008 CS@0x8004
                                        * EIP@0x8000 land, err@0x7FFC faults */
    .byte   0xEA                       /* T1: -> #GP(0), partial frame, #PF, */
    .long   0x00000101                 /*      fixupA, re-fire T2, complete   */
    .word   0x0050
    .global cont_a
cont_a:

    /* ======================= case B: page 2 READ-ONLY ===================== */
    movl    $0x00015000, %esp          /* back on the mainline stack */
    movl    $0xDEAD5000, 0x00005FFC    /* poison (page 5 currently RW) */
    movl    $0x00005001, 0x00012014    /* PTE[5] = PRESENT but READ-ONLY */
    invlpg  0x5000                     /* drop the cached RW translation */
    movl    $2, 0x00002044             /* CUR = case B */
    movl    $0x0000600C, %esp          /* frame: EFLAGS@0x6008 CS@0x6004
                                        * EIP@0x6000 land, err@0x5FFC faults */
    .byte   0xEA                       /* T3: -> #GP(0), partial frame, #PF, */
    .long   0x00000101                 /*      fixupB, re-fire T4, complete   */
    .word   0x0050
    .global cont_b
cont_b:

    /* ---- exit: fold the memory witnesses into the GPRs -------------------- */
    movl    $0x00015000, %esp
    xorl    %ebx, %ebx
    cmpl    $0x00000002, 0x00002000    /* case-A #PF err == 0x002 */
    jne     1f
    cmpl    $0x0000800C, 0x00002008    /* case-A ESP at fault */
    jne     1f
    cmpl    $1, 0x00002010             /* case-A poison intact post-remap */
    jne     1f
    cmpl    $0x00007FFC, 0x00002014    /* case-A completed handler ESP */
    jne     1f
    cmpl    $0, 0x00002018             /* case-A completed err dword */
    jne     1f
    cmpl    $0x00000003, 0x00002020    /* case-B #PF err == 0x003 */
    jne     1f
    cmpl    $0x0000600C, 0x00002028    /* case-B ESP at fault */
    jne     1f
    cmpl    $1, 0x00002030             /* case-B poison intact */
    jne     1f
    cmpl    $0x00005FFC, 0x00002034    /* case-B completed handler ESP */
    jne     1f
    cmpl    $0, 0x00002038             /* case-B completed err dword */
    jne     1f
    movl    $0xA406A406, %ebx
1:
    movl    0x00002004, %edi           /* case-A CR2 (0x00007FFC) */
    movl    0x0000200C, %esi           /* case-A surviving EIP dword */
    movl    0x00002024, %ebp           /* case-B CR2 (0x00005FFC) */
    movl    0x0000202C, %ecx           /* case-B surviving EIP dword */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    /* ================= 32-bit fixup stubs (re-fire arms) ===================
     * Reached by the 16-bit #PF handler's rewritten saved IP (IRETW pops a
     * word, so these offsets must be 16-bit clean -- they are, the segment
     * is based at 0xF0000). Map the page, prove the poison at the fault
     * address survived (the err push never landed), re-fire the trigger:
     * the delivery restarts and this time completes.                         */
    .global fixup_a
fixup_a:
    movl    $0x00007003, 0x0001201C    /* PTE[7] = P|RW */
    invlpg  0x7000
    movl    $1, %eax
    cmpl    $0xDEAD7000, 0x00007FFC    /* the err push never landed */
    je      1f
    xorl    %eax, %eax
1:  movl    %eax, 0x00002010
    .byte   0xEA                       /* T2: re-fire -> completed delivery */
    .long   0x00000101
    .word   0x0050
    jmp     cont_a

    .global fixup_b
fixup_b:
    movl    $0x00005003, 0x00012014    /* PTE[5] = P|RW */
    invlpg  0x5000                     /* drop the cached RO translation */
    movl    $1, %eax
    cmpl    $0xDEAD5000, 0x00005FFC    /* the err push never landed */
    je      1f
    xorl    %eax, %eax
1:  movl    %eax, 0x00002030
    .byte   0xEA                       /* T4: re-fire -> completed delivery */
    .long   0x00000101
    .word   0x0050
    jmp     cont_b

    /* ==================== 32-bit #GP handler (completed) ====================
     * Runs only for the COMPLETED (re-fired) deliveries. Frame dwords:
     * 0(%esp)=err 4=EIP 8=CS 12=EFLAGS. ESP == 0x7FFC (A) / 0x5FFC (B).    */
    .global gpgp_handler
gpgp_handler:
    cmpl    $1, 0x00002044
    jne     gpgp_b
    movl    %esp, 0x00002014           /* completed ESP (0x7FFC) */
    movl    (%esp), %eax
    movl    %eax, 0x00002018           /* completed err (0) */
    addl    $7, 4(%esp)                /* resume past the 7-byte ljmp */
    addl    $4, %esp                   /* pop the error code */
    iretl
gpgp_b:
    movl    %esp, 0x00002034           /* completed ESP (0x5FFC) */
    movl    (%esp), %eax
    movl    %eax, 0x00002038           /* completed err (0) */
    addl    $7, 4(%esp)
    addl    $4, %esp
    iretl

    /* ==================== 16-bit #PF handler (partial) =====================
     * Runs in the 16-bit code segment 0x18 (D=0): its 8-byte word frame
     * (FLAGS,CS,IP,err) fits on the present page where the trigger's 16-byte
     * frame could not. Frame words: [SP]=err [+2]=IP [+4]=CS [+6]=FLAGS;
     * ESP at the fault = SP+8 (the aborted delivery did NOT charge ESP).
     * Records the witnesses, points the saved IP at the 32-bit fixup stub,
     * pops the err word, IRETW.                                             */
    .code16
    .section .text16pm,"ax"
    .global pf16_handler
pf16_handler:
    movw    %sp, %bp
    cmpl    $1, 0x00002044
    jne     pf16_b
    /* ---- case A: page 2 not present ---- */
    movw    0(%bp), %ax
    movw    %ax, 0x2000                /* #PF err (0x0002) */
    movl    %cr2, %eax
    movl    %eax, 0x2004               /* CR2 (0x00007FFC) */
    movzwl  %bp, %eax
    addl    $8, %eax
    movl    %eax, 0x2008               /* ESP at the fault (0x0000800C) */
    movl    0x8000, %eax               /* the SURVIVING partial-frame dword: */
    movl    %eax, 0x200C               /* the landed EIP (== the ljmp's EIP) */
    movw    $_fixa_off, %ax
    movw    %ax, 2(%bp)                /* saved IP <- fixup_a */
    addw    $2, %sp                    /* pop the err word */
    iretw
pf16_b:
    /* ---- case B: page 2 read-only ---- */
    movw    0(%bp), %ax
    movw    %ax, 0x2020                /* #PF err (0x0003) */
    movl    %cr2, %eax
    movl    %eax, 0x2024               /* CR2 (0x00005FFC) */
    movzwl  %bp, %eax
    addl    $8, %eax
    movl    %eax, 0x2028               /* ESP at the fault (0x0000600C) */
    movl    0x6000, %eax               /* the SURVIVING landed EIP dword */
    movl    %eax, 0x202C
    movw    $_fixb_off, %ax
    movw    %ax, 2(%bp)                /* saved IP <- fixup_b */
    addw    $2, %sp
    iretw

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
