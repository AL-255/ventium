/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug4 A4-H03 — 16-bit protected-mode interrupt/trap gate FRAMES.
 *
 * The defect: the RTL built 32-BIT frames for cross-privilege 16-bit gates,
 * charged 6 bytes even WITH an error code same-privilege, and never wrapped
 * SP for a B=0 stack. The fix makes 16-bit interrupt/trap gates (IDT types
 * 0x6/0x7) push WORD frames everywhere:
 *   same-priv  : FLAGS,CS,IP [,err]            -- 6/8 bytes, SP wraps in the
 *                low 16 when SS.B=0 with ESP[31:16] preserved
 *   cross-priv : SS,SP,FLAGS,CS,IP [,err]      -- 10/12 bytes, wrapped per the
 *                NEW stack's B; ESP[31:16] = the OLD ESP's upper half
 *
 * QEMU is an exact oracle (do_interrupt_protected, shift = type>>3; PUSHW
 * stores at ssp + (sp & sp_mask); SET_ESP keeps the old register's upper half
 * for a 16-bit stack), so every case is differentially graded.
 *
 * Architecture: ALL code segments are BASED at 0xF0000 (offsets stay 16-bit
 * clean) so the WORD IP slots of the 16-bit frames are exact and IRETW
 * returns land correctly. 16-bit gate targets live in a 16-bit code segment
 * 0x18 (D=0); the 32-bit mainline/ring-3/32-bit-handler code lives in 32-bit
 * segments 0x08 (DPL0) / 0x20 (DPL3), all based at 0xF0000. The pintr16
 * sibling covers the plain same-priv software-INT round-trip; this test adds
 * the frame-CONTENT readback, the error-code frame, the trap-gate IF
 * semantics, ALL the cross-priv shapes, the B=0 wrap stack, and the 32-bit
 * controls.
 *
 * Cases (witness slots on the marker page 0x2000; the discriminating ones are
 * folded into the exit GPRs -- memory is not traced):
 *
 *   (1) CPL0, 16-bit INTERRUPT gate 0x40, software INT (no errcode):
 *       SP drops exactly 6 (0x7000 -> 0x6FFA); handler reads back the three
 *       pushed WORDS (IP, CS=0x0008, FLAGS) via SS:BP; its own PUSHF shows
 *       IF CLEARED (interrupt gate; mainline runs STI). IRETW back.
 *   (2) CPL0, #GP(0) from an ljmp to a SMALL-LIMIT code segment 0x50 with
 *       offset 0x101 > limit 0x100 (the A4-C02 fault class -- a null-
 *       selector trigger is unusable here: the RTL's S_LJMP descriptor path
 *       reads GDT[0] and raises #NP(0) where QEMU/SDM raise #GP(0); see
 *       manifest.json oracle_notes), delivered through the 16-bit TRAP gate
 *       at IDT VECTOR 13 (faults deliver through their exception vector, not
 *       a chosen INT vector): SP drops exactly 8 (0x7000 -> 0x6FF8); four
 *       words read back (err=0, IP=the ljmp, CS, FLAGS); handler PUSHF shows
 *       IF PRESERVED. Handler skips the 7-byte ljmp via the saved IP, pops
 *       the err word, IRETW.
 *   (3) CPL3 -> CPL0, 16-bit INTERRUPT gate 0x42 (DPL3), software INT: TSS
 *       SS0:ESP0 = 0x10:0x6000; handler ESP == 0x6000-10 == 0x5FF6; the five
 *       word slots IP,CS=0x23,FLAGS,SP=0x5000,SS=0x2B read back. Cross-priv
 *       IRETW restores ring 3 (DS re-nulled, reloaded by the mainline).
 *   (4) CPL3 -> CPL0, #NP(0x48) from an ljmp to a NOT-PRESENT DPL3 code
 *       descriptor 0x48 (WITH errcode, so it differs from case (2)'s vector
 *       13), delivered through the 16-bit TRAP gate at IDT VECTOR 11:
 *       handler ESP == 0x6000-12 == 0x5FF4; six slots read back, the error
 *       word == 0x0048 (a NONZERO code proving the word errcode content).
 *   (5) CPL3 -> CPL0, 16-bit INTERRUPT gate 0x44 (DPL3) onto a B=0 STACK:
 *       ring-3 code rewrites TSS.SS0:ESP0 = 0x30:0x00010004 (16-bit data
 *       descriptor 0x30) and sets its own ESP = 0x00025000, then INTs.
 *       The five PUSHW stores wrap in the LOW 16: SS@0002, SP@0000,
 *       FLAGS@FFFE, CS@FFFC, IP@FFFA. Handler ESP == 0x0002FFFA: the upper
 *       half 0x0002 is the OLD (ring-3) ESP's upper -- preserved, NOT taken
 *       from esp0's 0x0001 and NOT zeroed (QEMU SET_ESP semantics; the
 *       ring-3 ESP upper 0x0002 != esp0's 0x0001 makes the rule exact). The
 *       handler's BP-relative slot reads wrap through 0x0000/0x0002 and find
 *       the SP/SS words -- proving the STORES wrapped. The 16-bit IRETW
 *       restores ESP = 0x00005000 (the frame only saved the SP WORD; the
 *       upper half is architecturally lost -- identical in both oracles).
 *   (7) CONTROLS: 32-bit interrupt gate 0x45 same-priv (ESP 0x7000 ->
 *       0x6FF4, three dwords) and 32-bit interrupt gate 0x46 (DPL3) CPL3 ->
 *       CPL0 (ESP 0x6000 -> 0x5FEC, five dwords): the pre-fix-correct shapes
 *       must be byte-identical to before.
 *
 * (Case 6 of the finding -- the paged wrap variant -- is a documented
 * residual; see manifest.json.)
 *
 * Memory plan (NO paging):
 *   GDT @ 0x500: null; 0x08 code32 DPL0 base 0xF0000; 0x10 data32 DPL0 flat;
 *                0x18 code16 DPL0 base 0xF0000 (D=0); 0x20 code32 DPL3 base
 *                0xF0000; 0x28 data32 DPL3 flat; 0x30 data16 DPL0 (B=0, the
 *                case-5 wrap stack); 0x38 TSS (base 0x4000); 0x48 code32 DPL3
 *                NOT PRESENT (case 4's #NP target); 0x50 code32 DPL0 limit
 *                0x100 (case 2's offset-past-limit #GP(0) target)
 *   IDT @ 0x1000: 0x40 16int -> h16_c1; VECTOR 13 (#GP) 16trap -> h16_c2;
 *                0x42 16int DPL3 -> h16_c3; VECTOR 11 (#NP) 16trap -> h16_c4;
 *                0x44 16int DPL3 -> h16_c5; 0x45 32int -> h_c7;
 *                0x46 32int DPL3 -> h_c7x
 *   TSS @ 0x4000 (SS0:ESP0 = 0x10:0x6000 initially; ring-3 rewrites for case 5)
 *   CPL0 stack 0x7000, TSS0 stack 0x6000, ring-3 stack 0x5000
 *
 * Exit GPR fold (from ring 3, IOPL=3):
 *   edi = 0x2068  case-5 handler ESP  == 0x0002FFFA  (the wrap witness)
 *   esi = 0x2034  case-3 handler ESP  == 0x00005FF6  (cross-priv 10-byte)
 *   ebp = 0x204C  case-4 handler ESP  == 0x00005FF4  (cross-priv 12-byte)
 *   ecx = 0x2004  case-1 handler SP   == 0x00006FFA  (same-priv 6-byte)
 *   ebx = 0xB16B16B1 iff: case-2 SP == 0x6FF8, case-2 err == 0, case-1 pushed
 *         CS == 0x0008, case-3 pushed SS == 0x2B, case-4 err == 0x0048,
 *         case-5 pushed SP == 0x5000, case-5 pushed SS == 0x2B, case-1
 *         handler FLAGS.IF == 0, case-2 handler FLAGS.IF == 1, case-7 ESP ==
 *         0x6FF4, case-7b ESP == 0x5FEC
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

    /* GDT at 0x0500 (10 entries, limit 0x4F). ALL code segments are based at
     * 0xF0000 so every offset is 16-bit clean (the 16-bit frames push WORD
     * IPs; IRETW must land exactly).                                        */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 base 0xF0000 lim 0xFFFF */
    movl    $0x00409a0f, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 flat */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code16 DPL0 base 0xF0000 (D=0) */
    movl    $0x00009a0f, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 code32 DPL3 base 0xF0000 */
    movl    $0x0040fa0f, 0x0524
    movl    $0x0000ffff, 0x0528        /* 0x28 data32 DPL3 flat */
    movl    $0x00cff200, 0x052c
    movl    $0x0000ffff, 0x0530        /* 0x30 data16 DPL0 base 0 lim 0xFFFF (B=0) */
    movl    $0x00009200, 0x0534
    movl    $0x40000067, 0x0538        /* 0x38 TSS base 0x4000 limit 0x67 access 0x89 */
    movl    $0x00008900, 0x053c
    /* 0x48 code32 DPL3 base 0xF0000 NOT PRESENT (access 0x7A: P=0|DPL3|S|0xA)
     * -- case (4)'s #NP(0x48) target from ring 3 (DPL3==CPL3 passes the
     * privilege check, so the P check is what fires). */
    movl    $0x0000ffff, 0x0548
    movl    $0x00407a0f, 0x054c
    /* 0x50 code32 DPL0 base 0xF0000 limit 0x0100 -- case (2)'s #GP(0) target:
     * offset 0x101 > limit 0x100 (the A4-C02 offset-vs-limit fault class). */
    movl    $0x00000100, 0x0550
    movl    $0x00409a0f, 0x0554

    movw    $0x0057, 0x0480            /* GDT limit = 11*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   _pm32_off                  /* pm_entry - 0xF0000 (CS base 0xF0000) */
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

    /* ---- zero the marker area 0x2000..0x20C0 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $48, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000. 16-bit gate: lo = (sel<<16)|off16, hi = attr<<8 (the
     * high offset word is reserved/0). 32-bit gate: lo = (sel<<16)|off[15:0],
     * hi = off[31:16] | attr<<8. All offsets are (label - 0xF0000).        ---- */
    /* 0x40 @ 0x1200: 16-bit INT  gate (attr 0x86), sel 0x18 -> h16_c1 */
    movl    $_hc1_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1200
    movl    $0x00008600, 0x1204
    /* VECTOR 13 (#GP) @ 0x1068: 16-bit TRAP gate (attr 0x87) -> h16_c2.
     * Case (2)'s #GP(0) fault delivers through ITS OWN vector, not a chosen
     * INT vector. */
    movl    $_hc2_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1068
    movl    $0x00008700, 0x106c
    /* 0x42 @ 0x1210: 16-bit INT  gate DPL3 (attr 0xE6), sel 0x18 -> h16_c3 */
    movl    $_hc3_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1210
    movl    $0x0000e600, 0x1214
    /* VECTOR 11 (#NP) @ 0x1058: 16-bit TRAP gate (attr 0x87) -> h16_c4
     * (case (4)'s #NP(0x48) from ring 3). */
    movl    $_hc4_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1058
    movl    $0x00008700, 0x105c
    /* 0x44 @ 0x1220: 16-bit INT  gate DPL3 (attr 0xE6), sel 0x18 -> h16_c5 */
    movl    $_hc5_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1220
    movl    $0x0000e600, 0x1224
    /* 0x45 @ 0x1228: 32-bit INT  gate (attr 0x8E), sel 0x08 -> h_c7 */
    movl    $_hc7_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1228
    movl    $0x00008e00, 0x122c
    /* 0x46 @ 0x1230: 32-bit INT  gate DPL3 (attr 0xEE), sel 0x08 -> h_c7x */
    movl    $_hc7x_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1230
    movl    $0x0000ee00, 0x1234
    movw    $0x07FF, 0x0490            /* IDT limit */
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- TSS at 0x4000: SS0=0x10 ESP0=0x6000 (cases 3/4/7b), empty I/O map -- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006000, 0x00004004    /* ESP0 */
    movl    $0x00000010, 0x00004008    /* SS0  */
    movw    $0x0068,     0x00004066
    movw    $0x0038, %ax
    ltr     %ax

    /* IOPL = 3 so the ring-3 legs may drive port 0xF4 at the exit. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    /* STI: the interrupt-gate-clears-IF vs trap-gate-preserves-IF semantics
     * must be OBSERVABLE (pintr precedent: no PIC/PIT is programmed, so no
     * external IRQ source exists in either oracle).                        */
    sti

    /* ---- case (1): CPL0, 16-bit INT gate 0x40, software INT (no errcode) -- */
    movl    %esp, 0x00002000           /* pre-INT ESP (0x7000) */
    int     $0x40                      /* -> h16_c1, frame 6 bytes, IRETW here */

    /* ---- case (2): CPL0, #GP(0) (WITH errcode) through the 16-bit TRAP
     * gate at VECTOR 13. The trigger is the A4-C02 fault class: an ljmp to
     * the limit-0x100 code segment 0x50 at offset 0x101 -- QEMU's
     * helper_ljmp_protected and the fixed RTL both raise #GP(0) BEFORE the
     * target installs. 7-byte encoding; the handler advances the saved IP
     * word by 7. (A null-selector trigger is NOT usable: the RTL's S_LJMP
     * descriptor path reads GDT[0] and raises #NP(0) where QEMU/SDM raise
     * #GP(0) -- an unrelated deviation, noted in the manifest.)           -- */
    movl    %esp, 0x00002030           /* pre-fault ESP (0x7000) */
    .byte   0xEA
    .long   0x00000101                 /* offset = limit+1 */
    .word   0x0050                     /* the limit-0x100 code segment */
    /* the handler resumes HERE */

    /* ---- case (7a): CPL0, 32-bit INT gate 0x45 CONTROL (same-priv) ------- */
    int     $0x45                      /* -> h_c7, 12-byte dword frame */

    /* ---- transfer DOWN to ring 3 via the OUTER RETF (pjmpgate's mechanism) */
    pushl   $0x0000002B                /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00005000                /* ESP = the ring-3 stack */
    pushl   $0x00000023                /* CS  = ring-3 code, RPL 3 */
    pushl   $_r3_off                   /* EIP = r3_entry - 0xF0000 */
    lret

    /* ============================ ring 3 ================================== */
    .global r3_entry
r3_entry:
    /* The outer RETF NULLED DS/ES/FS/GS (DPL 0 < CPL 3); reload DS = 0x2B. */
    movw    $0x2B, %ax
    movw    %ax, %ds

    /* ---- case (3): CPL3 -> CPL0, 16-bit INT gate 0x42 (no errcode) ------- */
    int     $0x42                      /* -> h16_c3 on TSS 0x10:0x6000, 10 bytes */
    movw    $0x2B, %ax                 /* the IRETW return NULLED DS again */
    movw    %ax, %ds

    /* ---- case (4): CPL3 -> CPL0, #NP(0x48) (WITH errcode) through the
     * 16-bit TRAP gate at VECTOR 11: ljmp to the NOT-PRESENT DPL3 code
     * descriptor 0x48 (RPL 3). The offset is never reached (the P check
     * fires first); the handler skips the 7-byte ljmp via the saved IP. ---- */
    .byte   0xEA
    .long   0
    .word   0x004B                     /* not-present code32 DPL3 -> #NP(0x48) */
    movw    $0x2B, %ax
    movw    %ax, %ds

    /* ---- case (5) prep: point TSS.SS0:ESP0 at the B=0 wrap stack and give
     * the ring-3 ESP a NONZERO upper half that differs from esp0's (0x0002
     * vs 0x0001) so the ESP-upper-preservation rule is graded exactly. ------ */
    movl    $0x00010004, 0x00004004    /* TSS.ESP0 = 0x00010004 */
    movl    $0x00000030, 0x00004008    /* TSS.SS0  = 0x30 (data16, B=0) */
    movl    $0x00025000, %esp          /* ring-3 ESP: upper half 0x0002 */

    /* ---- case (5): CPL3 -> CPL0, 16-bit INT gate 0x44 onto the wrap stack - */
    int     $0x44                      /* -> h16_c5; stores wrap in the low 16 */
    movw    $0x2B, %ax                 /* DS nulled again; ESP is now 0x5000 */
    movw    %ax, %ds                   /* (the 16-bit frame saved only SP's    */
                                       /*  low word -- the upper half is       */
                                       /*  architecturally lost, both oracles) */

    /* ---- restore the 32-bit TSS stack for the 32-bit cross-priv control --- */
    movl    $0x00006000, 0x00004004
    movl    $0x00000010, 0x00004008

    /* ---- case (7b): CPL3 -> CPL0, 32-bit INT gate 0x46 CONTROL ------------- */
    int     $0x46                      /* -> h_c7x on 0x10:0x6000, 20 bytes */
    movw    $0x2B, %ax
    movw    %ax, %ds

    /* ---- exit: fold the memory witnesses into the GPRs -------------------- */
    xorl    %ebx, %ebx
    cmpl    $0x00006FF8, 0x00002018    /* case (2) SP == 0x7000-8 */
    jne     1f
    cmpl    $0x00000000, 0x0000201C    /* case (2) err == 0 */
    jne     1f
    cmpl    $0x00000008, 0x0000200C    /* case (1) pushed CS == 0x0008 */
    jne     1f
    cmpl    $0x0000002B, 0x00002048    /* case (3) pushed SS == 0x2B */
    jne     1f
    cmpl    $0x00000048, 0x00002050    /* case (4) err word == 0x0048 (#NP sel) */
    jne     1f
    cmpl    $0x00005000, 0x00002078    /* case (5) pushed SP word == 0x5000 */
    jne     1f
    cmpl    $0x0000002B, 0x0000207C    /* case (5) pushed SS == 0x2B */
    jne     1f
    testl   $0x00000200, 0x00002014    /* case (1) handler FLAGS.IF == 0 */
    jnz     1f                         /*  (interrupt gate CLEARED IF) */
    testl   $0x00000200, 0x0000202C    /* case (2) handler FLAGS.IF == 1 */
    jz      1f                         /*  (trap gate PRESERVED IF) */
    cmpl    $0x00006FF4, 0x00002080    /* case (7a) ESP == 0x7000-12 */
    jne     1f
    cmpl    $0x00005FEC, 0x00002090    /* case (7b) ESP == 0x6000-20 */
    jne     1f
    movl    $0xB16B16B1, %ebx
1:
    movl    0x00002068, %edi           /* case (5) handler ESP (0x0002FFFA) */
    movl    0x00002034, %esi           /* case (3) handler ESP (0x00005FF6) */
    movl    0x0000204C, %ebp           /* case (4) handler ESP (0x00005FF4) */
    movl    0x00002004, %ecx           /* case (1) handler SP  (0x00006FFA) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                   /* works only because IOPL==3 */
9:  jmp     9b

    /* ====================== 32-bit gate handlers ========================== */
    /* case (7a) control: same-priv 32-bit INT gate. Frame dwords:
     * 0(%esp)=EIP 4=CS 8=EFLAGS. ESP == 0x7000-12 == 0x6FF4.               */
    .global h_c7
h_c7:
    movl    %esp, 0x00002080
    movl    0(%esp), %eax
    movl    %eax, 0x00002084
    movl    4(%esp), %eax
    movl    %eax, 0x00002088
    movl    8(%esp), %eax
    movl    %eax, 0x0000208C
    iretl

    /* case (7b) control: cross-priv 32-bit INT gate. Frame dwords:
     * 0=EIP 4=CS 8=EFLAGS 12=ESP 16=SS. ESP == 0x6000-20 == 0x5FEC.        */
    .global h_c7x
h_c7x:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %esp, 0x00002090
    movl    0(%esp), %eax
    movl    %eax, 0x00002094
    movl    4(%esp), %eax
    movl    %eax, 0x00002098
    movl    8(%esp), %eax
    movl    %eax, 0x0000209C
    movl    12(%esp), %eax
    movl    %eax, 0x000020A0
    movl    16(%esp), %eax
    movl    %eax, 0x000020A4
    iretl

    /* ====================== 16-bit gate handlers ==========================
     * All run in the 16-bit code segment 0x18 (D=0, base 0xF0000): .code16,
     * BP-relative WORD frame reads (BP defaults to SS), IRETW returns.
     * Marker stores use plain 16-bit absolute addressing (all slots are
     * below 0x10000).                                                       */
    .code16
    .section .text16pm,"ax"

    /* case (1): same-priv 16-bit INT gate, no errcode.
     * Frame words at SS:SP: [0]=IP [2]=CS [4]=FLAGS. SP == 0x6FFA.        */
    .global h16_c1
h16_c1:
    movw    %sp, %bp
    movw    %sp, 0x2004                /* handler SP (0x6FFA) */
    movw    0(%bp), %ax
    movw    %ax, 0x2008                /* pushed IP word */
    movw    2(%bp), %ax
    movw    %ax, 0x200C                /* pushed CS word (0x0008) */
    movw    4(%bp), %ax
    movw    %ax, 0x2010                /* pushed FLAGS word (IF=1) */
    pushfw
    popw    %ax
    movw    %ax, 0x2014                /* handler live FLAGS (IF CLEARED) */
    iretw

    /* case (2): same-priv 16-bit TRAP gate, WITH errcode.
     * Frame words: [0]=err [2]=IP [4]=CS [6]=FLAGS. SP == 0x6FF8.         */
    .global h16_c2
h16_c2:
    movw    %sp, %bp
    movw    %sp, 0x2018                /* handler SP (0x6FF8) */
    movw    0(%bp), %ax
    movw    %ax, 0x201C                /* error code word (0) */
    movw    2(%bp), %ax
    movw    %ax, 0x2020                /* pushed IP word (the null ljmp) */
    movw    4(%bp), %ax
    movw    %ax, 0x2024                /* pushed CS word */
    movw    6(%bp), %ax
    movw    %ax, 0x2028                /* pushed FLAGS word */
    pushfw
    popw    %ax
    movw    %ax, 0x202C                /* handler live FLAGS (IF PRESERVED) */
    addw    $7, 2(%bp)                 /* resume past the 7-byte null ljmp */
    addw    $2, %sp                    /* pop the error code word */
    iretw

    /* case (3): cross-priv 16-bit INT gate, no errcode.
     * Frame words: [0]=IP [2]=CS [4]=FLAGS [6]=SP [8]=SS. ESP == 0x5FF6.  */
    .global h16_c3
h16_c3:
    movw    $0x10, %ax                 /* flat CPL0 data for the markers */
    movw    %ax, %ds
    movw    %sp, %bp
    movl    %esp, 0x2034               /* full ESP (0x00005FF6) */
    movw    0(%bp), %ax
    movw    %ax, 0x2038                /* IP */
    movw    2(%bp), %ax
    movw    %ax, 0x203C                /* CS (0x0023) */
    movw    4(%bp), %ax
    movw    %ax, 0x2040                /* FLAGS */
    movw    6(%bp), %ax
    movw    %ax, 0x2044                /* old SP (0x5000) */
    movw    8(%bp), %ax
    movw    %ax, 0x2048                /* old SS (0x002B) */
    iretw                              /* cross-priv 16-bit IRET: 5 words */

    /* case (4): cross-priv 16-bit TRAP gate, WITH errcode.
     * Frame words: [0]=err [2]=IP [4]=CS [6]=FLAGS [8]=SP [10]=SS.
     * ESP == 0x5FF4.                                                     */
    .global h16_c4
h16_c4:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %sp, %bp
    movl    %esp, 0x204C               /* full ESP (0x00005FF4) */
    movw    0(%bp), %ax
    movw    %ax, 0x2050                /* err (0) */
    movw    2(%bp), %ax
    movw    %ax, 0x2054                /* IP (the null ljmp) */
    movw    4(%bp), %ax
    movw    %ax, 0x2058                /* CS */
    movw    6(%bp), %ax
    movw    %ax, 0x205C                /* FLAGS */
    movw    8(%bp), %ax
    movw    %ax, 0x2060                /* old SP */
    movw    10(%bp), %ax
    movw    %ax, 0x2064                /* old SS */
    addw    $7, 2(%bp)                 /* resume past the 7-byte null ljmp */
    addw    $2, %sp                    /* pop the error code word */
    iretw

    /* case (5): cross-priv 16-bit INT gate onto the B=0 wrap stack.
     * TSS.SS0:ESP0 = 0x30:0x00010004; the five PUSHW stores landed at
     * (sp & 0xFFFF): IP@0xFFFA CS@0xFFFC FLAGS@0xFFFE SP@0x0000 SS@0x0002.
     * Handler ESP == 0x0002FFFA (upper = OLD ring-3 ESP's 0x0002). BP =
     * SP = 0xFFFA; the BP-relative reads at +6/+8 wrap through EA 0x0000 /
     * 0x0002 and must find the SP/SS words -- proving the stores wrapped. */
    .global h16_c5
h16_c5:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %sp, %bp
    movl    %esp, 0x2068               /* full ESP (0x0002FFFA) -- THE witness */
    movw    0(%bp), %ax
    movw    %ax, 0x206C                /* IP     (EA 0xFFFA) */
    movw    2(%bp), %ax
    movw    %ax, 0x2070                /* CS     (EA 0xFFFC) */
    movw    4(%bp), %ax
    movw    %ax, 0x2074                /* FLAGS  (EA 0xFFFE) */
    movw    6(%bp), %ax
    movw    %ax, 0x2078                /* old SP (EA wraps to 0x0000) = 0x5000 */
    movw    8(%bp), %ax
    movw    %ax, 0x207C                /* old SS (EA wraps to 0x0002) = 0x002B */
    iretw                              /* pops wrap the same way; ESP=0x5000 */

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
