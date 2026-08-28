/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pxwrapm — the wrapped frame-probe WITNESS image (zero bytes written).
 *
 * Companion to pxwrap (which is differential).  Here the CPL3 #PF handler
 * SCANS the frame extent of each denied case BEFORE restoring the PTE and
 * counts the slots whose bytes were written.  This is the one property the
 * differential cannot carry, because the two oracles legitimately differ in
 * memory (oracle gap, measured from the pinned QEMU 8.2.2 source,
 * seg_helper.c do_interrupt_protected: PUSHL/PUSHW store immediately, and
 * the register commit happens only after the last push):
 *
 *   QEMU: pushes slots incrementally; a mid-frame page fault leaves the
 *         first k_fault slots written (a cross-page store is never partial,
 *         cputlb.c mmu_lookup looks up both pages first).
 *   RTL:  S_INT_PROBE walks the whole slot plan BEFORE the SS/CPL commit,
 *         so a rejected frame leaves ZERO bytes on every destination page.
 *
 * Both flows run the same image to the isa-debug-exit.  The golden pins
 * QEMU's partial-push witnesses (step 5f); the RTL side is graded in step
 * 7w: every scanned slot must still hold the 0xCC sentinel (written count
 * ZERO), plus the faultlog and the pre-shutdown final record for the
 * terminal V86 case (below).
 *
 * Cases m0..m5 deny a page whose first-touch slot is NOT slot 0 (k_fault >=
 * 1), so QEMU's count is nonzero and the gate is sensitive.  Cases m6/m7
 * are the V86 9-slot frame on a wrapped B=0 TSS stack: the probe #PF is
 * raised in the V86 context, but delivering it needs the SAME wrapped TSS
 * stack (every V86 interrupt goes to ring 0 through the TSS), so both
 * oracles escalate (#PF -> #DF -> shutdown (RTL) / triple-fault reset
 * (QEMU)) -- the V86 denial is terminal by construction.  QEMU survives
 * via the boot counter @ 0x5100 (m6 -> reset -> m7 -> reset -> exit); the
 * RTL parks in S_SHUTDOWN at m6, graded on the final record (CR2 = the
 * faulting slot, old V86 SS:ESP/EFLAGS intact, accumulators) + the
 * faultlog + the VEN_BWATCH no-write proof.
 *
 * Accumulators live in the RAM mirror @ 0x5110 (survives QEMU's resets):
 *   0x5110 edi = total written slots     0x5114 esi = cases completed
 *   0x5118 ecx = XOR of written masks    0x511C ebp = total slots scanned
 *   0x5120 ebx = last case's written count
 * The V86-entry path loads them into the GPRs so the RTL's shutdown record
 * carries them.
 *
 * Memory plan: identical to pxwrap (GDT 0x6000, IDT 0x1000, TSS 0x3000,
 * PD 0x10000, PT0 0x11000 identity, PT1 0x12000, CPL3 code in code3f 0x48,
 * user stack 0xF000, clean stack 0xA0000, case state 0x5000, mirror 0x5110,
 * V86 task CS=0xF000 SS=0x2000 ESP=0x8000).
 *
 * GNU-as; no nasm.  Flat 64 KiB -bios image; reset F000:FFF0.
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
    movw    $0x9000, %sp

    /* boot counter @ 0x5100: 0 = first boot (m0..m6), 1 = run m7 only,
     * 2 = exit.  RAM survives the QEMU triple-fault resets; the RTL never
     * resets (it parks in S_SHUTDOWN at m6). */
    movl    0x5100, %eax
    cmpl    $2, %eax
    jae     boot_exit16
    incl    %eax
    movl    %eax, 0x5100

    /* GDT @ 0x6000 */
    movl    $0x00000000, 0x6000
    movl    $0x00000000, 0x6004
    movl    $0x0000FFFF, 0x6008         /* 0x08 code0 flat */
    movl    $0x00CF9A00, 0x600C
    movl    $0x0000FFFF, 0x6010         /* 0x10 data0 flat */
    movl    $0x00CF9200, 0x6014
    movl    $0x0000FFFF, 0x6018         /* 0x18 code3 flat */
    movl    $0x00CFFA00, 0x601C
    movl    $0x0000FFFF, 0x6020         /* 0x20 data3 flat */
    movl    $0x00CFF200, 0x6024
    movl    $0x30000067, 0x6028         /* 0x28 TSS32 base 0x3000 */
    movl    $0x00008900, 0x602C
    movl    $0x0000FFFF, 0x6040         /* 0x40 code0f: D=1 DPL0 base 0xF0000 */
    movl    $0x00409A0F, 0x6044
    movl    $0x0000FFFF, 0x6048         /* 0x48 code3f: D=1 DPL3 base 0xF0000 */
    movl    $0x0040FA0F, 0x604C
    movw    $0x0077, 0x0480
    movl    $0x00006000, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

boot_exit16:
    /* QEMU only: reload the mirror into the GPRs and exit (real mode). */
    movl    0x5110, %edi
    movl    0x5114, %esi
    movl    0x5118, %ecx
    movl    0x511C, %ebp
    movl    0x5120, %ebx
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x000A0000, %esp

    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* IDT[14] #PF -> pf3m_handler, CS=0x4B (SAME-priv at CPL3), 0x8F */
    movl    $(pf3m_handler - 0xF0000), %ebx
    movl    $0x8F, %eax
    movl    $0x1070, %edi
    movl    $0x004B, %ecx
    call    write_idt_gate_sel

    /* IDT[0x31] -> setup_handler, CS=0x40, 0xEF */
    movl    $(setup_handler - 0xF0000), %ebx
    movl    $0xEF, %eax
    movl    $0x1188, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movw    $0x0068, 0x00003066
    movl    $0x000A0000, 0x00003004
    movl    $0x00000010, 0x00003008
    movw    $0x0028, %ax
    ltr     %ax

    movl    $0x00011007, 0x00010000
    movl    $0x00012007, 0x00010FFC
    movl    $0x00011000, %edi
    xorl    %eax, %eax
1:  movl    %eax, %edx
    orl    $0x00000007, %edx
    movl    %edx, (%edi)
    addl    $4, %edi
    addl    $0x1000, %eax
    cmpl    $0x00100000, %eax
    jb      1b
    movl    $0x00400007, 0x00012FF8     /* 0xFFFFE000 -> phys 0x400000 */
    movl    $0x00401007, 0x00012FFC     /* 0xFFFFF000 -> phys 0x401000 (the
                                         * 0xB/0xC0000 VGA/ROM hole drops
                                         * writes under QEMU) */

    movl    $0x00010000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* CG param sources (QEMU reads them before the pushes) */
    movl    $31, %ecx
    movl    $0x0000EF00, %edi           /* CG32 dword params at 0xEF00 (the
                                         * #PF frame lands at 0xEFF0..0xEFFF) */
    movl    $0xD0000000, %eax
1:  movl    %eax, (%edi)
    addl    $4, %edi
    incl    %eax
    loop    1b
    movl    $31, %ecx
    movl    $0x0000EE80, %edi           /* CG16 word params at 0xEE80 (the */
    movl    $0x0000D000, %eax           /* CG32 dword area ends at 0xEFFB) */
1:  movw    %ax, (%edi)
    addl    $2, %edi
    incl    %eax
    loop    1b

    /* case state: first boot zeroes everything; the m7 boot keeps the
     * mirror (0x5110..0x5120) accumulated across the reset. */
    movl    0x5100, %eax                /* already incremented (1 or 2) */
    cmpl    $2, %eax
    je      1f
    movl    $0, 0x5000                  /* boot 1: cur_case = 0 (m0) */
    movw    $0x0061, 0x500C             /* the #GP trigger's selector */
    movl    $0, 0x5110
    movl    $0, 0x5114
    movl    $0, 0x5118
    movl    $0, 0x511C
    movl    $0, 0x5120
    jmp     setup_handler
1:  movl    $7, 0x5000                  /* boot 2 (counter was 1): m7 only */
    jmp     setup_handler

write_idt_gate_sel:
    movl    %ebx, %edx
    andl    $0x0000FFFF, %edx
    shll    $16, %ecx
    orl     %ecx, %edx
    movl    %edx, (%edi)
    movl    %ebx, %edx
    andl    $0xFFFF0000, %edx
    shll    $8, %eax
    orl     %eax, %edx
    movl    %edx, 4(%edi)
    ret

/* ================= per-case setup (CPL0, clean stack) ==================== */
    .align 16
    .global setup_handler
setup_handler:
    movw    $0x10, %ax                  /* int31 may have landed on a wrapped */
    movw    %ax, %ss                    /* B=0 stack -- switch to a clean SS */
    movl    $0x000A0000, %esp
    movl    0x5000, %eax
    cmpl    $NCASES, %eax
    jae     all_done
    incl    %eax
    movl    %eax, 0x5000
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %esi
    movb    (%esi), %al
    movb    %al, 0x5004

    movl    4(%esi), %eax
    movl    %eax, 0x00003004
    cmpb    $0, 1(%esi)
    jne     1f
    movl    8(%esi), %eax
    movzwl  %ax, %ebx
    shll    $16, %ebx
    orl     $0x0000FFFF, %ebx
    movl    %ebx, 0x6030
    movl    8(%esi), %eax
    andl    $0x00FF0000, %eax
    shrl    $16, %eax
    movl    8(%esi), %ebx
    andl    $0xFF000000, %ebx
    orl     %ebx, %eax
    orl     $0x008F9200, %eax
    movl    %eax, 0x6034
    movl    $0x00000030, %eax
    jmp     2f
1:  movl    $0x00000010, %eax
2:  movl    %eax, 0x00003008

    /* IDT[14] per kind: m0..m5 -> pf3m (CS=0x4B, same-priv CPL3); V86
     * terminal cases -> v86mon (CS=0x40, DPL0: the #PF delivery from V86
     * re-probes the same wrapped stack and both oracles escalate). */
    movzbl  (%esi), %eax
    cmpl    $4, %eax
    jae     1f
    movl    $(pf3m_handler - 0xF0000), %ebx
    movl    $0x004B, %ecx
    jmp     2f
1:  movl    $(v86mon - 0xF0000), %ebx
    movl    $0x0040, %ecx
2:  movl    $0x8F, %eax
    movl    $0x1070, %edi
    call    write_idt_gate_sel

    /* IDT[13]: GP kind -> gp_catch (never reached: the probe faults first);
     * V86 kinds: the CLI #GP is the trigger -> v86mon (also never reached). */
    movzbl  (%esi), %eax
    cmpl    $2, %eax
    jne     3f
    movl    $(gp_catch - 0xF0000), %ebx
    movl    $0x87, %eax
    movl    $0x1068, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel
    jmp     4f
3:  cmpl    $4, %eax
    jb      4f
    movl    $(v86mon - 0xF0000), %ebx
    movl    $0x8F, %eax
    movl    $0x1068, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel
4:

    /* IDT[0x30] / call gate per kind */
    movzbl  (%esi), %eax
    cmpl    $3, %eax
    je      setup_cgate
    cmpl    $4, %eax
    jae     setup_v86gate
    movzbl  3(%esi), %ebx
    movl    %ebx, %ecx
    andl    $2, %ecx
    movl    $6, %eax                    /* all m-cases use trap/int16 gates */
    testl   %ecx, %ecx
    jnz     5f
    movl    $0xE, %eax
5:  orl     $0xE0, %eax
    movl    $(int_catch - 0xF0000), %ebx
    testl   %ecx, %ecx
    jnz     6f
    movl    $(int_catch - 0xF0000), %ebx
6:  movl    $0x1180, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel
    jmp     setup_fill

setup_cgate:
    movl    $(cg_catch - 0xF0000), %ebx
    movl    $0xEC, %eax
    testb   $2, 3(%esi)
    jz      1f
    movl    $0xE4, %eax
1:  movl    %ebx, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x00400000, %edx
    movl    %edx, 0x6038
    movl    %ebx, %edx
    andl    $0xFFFF0000, %edx
    shll    $8, %eax
    orl     %eax, %edx
    orl     $31, %edx
    movl    %edx, 0x603C
    jmp     setup_fill

setup_v86gate:
    movl    $(v86mon - 0xF0000), %ebx
    movl    $0xEF, %eax
    movl    $0x1180, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel

setup_fill:
    /* sentinel-fill the frame extent with 0xCC.  Skipped for the V86
     * terminal cases (kinds 4/5) so the VEN_BWATCH no-write proof sees only
     * frame pushes, never the fill. */
    movzbl  (%esi), %eax
    cmpl    $4, %eax
    jae     setup_deny
    movzbl  2(%esi), %ecx
    testb   $2, 3(%esi)
    jnz     1f
    shll    $2, %ecx
    jmp     2f
1:  addl    %ecx, %ecx
2:  movl    4(%esi), %edx
    movl    8(%esi), %edi
    cmpb    $0, 1(%esi)
    jne     4f
3:  decl    %edx
    movzwl  %dx, %edx
    movb    $0xCC, (%edi,%edx)
    loop    3b
    jmp     setup_deny
4:  decl    %edx
    movb    $0xCC, (%edi,%edx)
    loop    4b

setup_deny:
    movl    12(%esi), %eax
    cmpl    $0xFFC00000, %eax
    jae     1f
    movl    %eax, %ebx
    shrl    $10, %ebx
    movl    $0, 0x11000(%ebx)
    jmp     2f
1:  movl    %eax, %ebx
    shrl    $10, %ebx
    andl    $0xFFC, %ebx
    movl    $0, 0x12000(%ebx)
2:  movl    %cr3, %eax
    movl    %eax, %cr3

setup_go:
    movzbl  0x5004, %eax
    cmpl    $4, %eax
    jae     v86_enter
    pushl   $0x00000023
    pushl   $0x0000F000
    pushl   $0x00003202
    pushl   $0x0000004B
    pushl   $(cpl3_stub - 0xF0000)
    iretl

/* ======================= V86 entry (terminal cases) ===================== *
 * Loads the mirror accumulators into the GPRs first so the RTL's shutdown
 * record (m6) carries them, then IRETs into the V86 task. */
v86_enter:
    movl    0x5110, %edi
    movl    0x5114, %esi
    movl    0x5118, %ecx
    movl    0x511C, %ebp
    movl    0x5120, %ebx
    pushl   $0x00000000                 /* GS */
    pushl   $0x00000000                 /* FS */
    pushl   $0x00002000                 /* DS */
    pushl   $0x00002000                 /* ES */
    pushl   $0x00002000                 /* SS */
    pushl   $0x00008000                 /* ESP */
    pushl   $0x00023002                 /* EFLAGS: VM | IOPL=3 */
    pushl   $0x0000F000                 /* CS */
    pushl   $(v86_task_int - 0xF0000)
    iretl

/* ============================ CPL3 stub ================================= */
    .align 16
    .global cpl3_stub
cpl3_stub:
    movl    $0x0000F000, %esp
    movw    $0x23, %ax
    movw    %ax, %ds
    movzbl  0x5004, %eax
    cmpl    $3, %eax
    je      trig_cg_setup
    cmpl    $2, %eax
    je      trig_gp
    .global trig_int
trig_int:
    int     $0x30
    .global trig_int_ret
trig_int_ret:
    jmp     trig_done
trig_gp:
    movw    $0x0061, %ax
    .global trig_gp_fault
trig_gp_fault:
    movw    %ax, %ds
    .global trig_gp_after
trig_gp_after:
    jmp     trig_done
trig_cg_setup:
    movl    0x5000, %eax
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %eax
    testb   $2, 3(%eax)
    jz      1f
    movl    $0x0000EFC0, %esp
    jmp     trig_cg
1:  movl    $0x0000EF00, %esp
    .global trig_cg
trig_cg:
    .byte   0x9A
    .long   0
    .word   0x003B
    .global trig_done
trig_done:
    int     $0x31
    jmp     cpl3_stub

/* ================== CPL3 #PF handler (the witness) ====================== *
 * Verifies the probe fault (err=2, pushed CS = 0x4B, pushed EIP = the
 * trigger), SCANS the frame extent for written slots (skipping the denied
 * page, which is unreadable and unwritten by construction), accumulates
 * into the RAM mirror, restores the PTE, and skips the trigger.
 * Scratch registers: eax/edx only; everything else via memory. */
    .align 16
    .global pf3m_handler
pf3m_handler:
    cmpl    $2, 0(%esp)
    jne     fail
    cmpl    $0x4B, 8(%esp)
    jne     fail
    movzbl  0x5004, %eax
    cmpl    $1, %eax
    jne     1f
    cmpl    $(trig_int - 0xF0000), 4(%esp)
    jne     fail
    jmp     3f
1:  cmpl    $2, %eax
    jne     2f
    cmpl    $(trig_gp_fault - 0xF0000), 4(%esp)
    jne     fail
    jmp     3f
2:  cmpl    $3, %eax
    jne     fail
    cmpl    $(trig_cg - 0xF0000), 4(%esp)
    jne     fail
3:  /* desc ptr + scan setup */
    movl    0x5000, %eax
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %eax
    movl    %eax, 0x5130
    movl    $0, 0x5124                  /* k */
    movl    $0, 0x5128                  /* written-slot mask */
    movl    $0, 0x512C                  /* written count */
    movzbl  2(%eax), %edx
    movl    %edx, 0x5134                /* nslots */
    movzbl  3(%eax), %edx
    andl    $2, %edx
    jnz     4f
    movl    $4, 0x5138                  /* unit */
    jmp     5f
4:  movl    $2, 0x5138
5:  movl    $0xFFFFFFFF, 0x513C         /* offset mask */
    cmpb    $0, 1(%eax)
    jne     6f
    movl    $0x0000FFFF, 0x513C
6:  movl    0x5138, %edx
    movl    %edx, 0x5140                /* (k+1)*unit accumulator */
scan_loop:
    movl    0x5124, %eax
    cmpl    0x5134, %eax
    jae     scan_done
    movl    0x5130, %eax
    movl    4(%eax), %edx
    subl    0x5140, %edx
    andl    0x513C, %edx                /* slot offset (wrapped) */
    addl    8(%eax), %edx               /* edx = slot linear address */
    movl    %edx, 0x5144
    movl    %edx, %eax
    andl    $0xFFFFF000, %eax
    movl    0x5130, %edx
    cmpl    12(%edx), %eax              /* first page == denied? */
    je      scan_next
    movl    0x5144, %eax
    addl    0x5138, %eax
    decl    %eax
    andl    $0xFFFFF000, %eax
    cmpl    12(%edx), %eax              /* straddle page == denied? */
    je      scan_next
    movl    0x5144, %edx
    cmpl    $4, 0x5138
    jne     7f
    cmpl    $0xCCCCCCCC, (%edx)
    je      scan_next
    jmp     8f
7:  cmpw    $0xCCCC, (%edx)
    je      scan_next
8:  /* slot written: mask |= 1<<k, count++ */
    movl    $1, 0x5144
    movl    0x5124, %edx
9:  testl   %edx, %edx
    jz      10f
    shll    $1, 0x5144
    decl    %edx
    jmp     9b
10: movl    0x5144, %edx
    orl     %edx, 0x5128
    incl    0x512C
scan_next:
    movl    0x5138, %edx
    addl    %edx, 0x5140
    incl    0x5124
    jmp     scan_loop
scan_done:
    /* accumulate into the mirror */
    movl    0x512C, %eax
    addl    %eax, 0x5110                /* edi: total written */
    movl    0x5128, %eax
    xorl    %eax, 0x5118                /* ecx: mask XOR */
    incl    0x5114                      /* esi: cases done */
    movl    0x5134, %eax
    addl    %eax, 0x511C                /* ebp: total slots scanned */
    movl    0x512C, %eax
    movl    %eax, 0x5120                /* ebx: last written count */
    /* restore the denied PTE */
    movl    0x5130, %eax
    movl    12(%eax), %ebx
    movl    %ebx, %eax
    cmpl    $0xFFC00000, %eax
    jae     11f
    shrl    $10, %ebx
    orl     $0x00000007, %eax
    movl    %eax, 0x11000(%ebx)
    jmp     12f
11: subl    $0xFFFFF000, %eax
    addl    $0x00401007, %eax
    shrl    $10, %ebx
    andl    $0xFFC, %ebx
    movl    %eax, 0x12000(%ebx)
12: /* rewrite the saved EIP to skip the trigger, drop err, return */
    movzbl  0x5004, %eax
    cmpl    $1, %eax
    jne     13f
    movl    $(trig_int_ret - 0xF0000), 4(%esp)
    jmp     15f
13: cmpl    $2, %eax
    jne     14f
    movl    $(trig_gp_after - 0xF0000), 4(%esp)
    jmp     15f
14: movl    $(trig_done - 0xF0000), 4(%esp)
15: addl    $4, %esp
    iretl

/* ===================== catch stubs (never reached) ====================== */
    .align 16
    .global int_catch
int_catch:                              /* would run if a denial was missed */
    movl    $0xDEAD0001, %edi
    jmp     fail
    .global gp_catch
gp_catch:
    movl    $0xDEAD0002, %edi
    jmp     fail
    .global cg_catch
cg_catch:
    movl    $0xDEAD0003, %edi
    jmp     fail
    .global v86mon
v86mon:                                 /* the terminal cases never deliver */
    movl    $0xDEAD0004, %edi
    jmp     fail

/* ============================= exits ==================================== */
    .align 16
    .global all_done
all_done:                               /* QEMU: m0..m6 done on boot 1 would
                                         * come here; with the terminal m6
                                         * the exit is boot_exit16 instead. */
    movl    0x5110, %edi
    movl    0x5114, %esi
    movl    0x5118, %ecx
    movl    0x511C, %ebp
    movl    0x5120, %ebx
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .global fail
fail:
    movb    $0x99, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

/* ============================ V86 task ================================== */
    .align 16
    .code16
    .global v86_task
v86_task:
    cli
    .global v86_task_int
v86_task_int:
    int     $0x30
    int     $0x31
9:  jmp     9b
    .code32

/* ===================== 16-bit reset stub @ 0xFFF0 ======================= */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000

#include "pxwrapm_cases.inc"
