/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pxdplan — the frame PAGE-PLAN probe regression (witness gate).
 *
 * The cross-privilege delivery probe stages a deduplicated <=4-entry PAGE
 * plan at S_INT_SS and validates it one beat per distinct page (never per
 * slot), capturing each page's physical frame and D bit; clean pages are
 * D-marked in a second pass while the OLD context is still installed, and
 * the pushes then translate through the captured frames, never the DTLB.
 * This image grades that contract:
 *
 *   C1 (deny the LATER page, D=0 start): a B=0 wrapped 16-bit frame on
 *       SS.base=0x80010 with ESP0=4 touches pages 0x80000 and 0x90000 --
 *       exactly 64 KiB apart, hence the SAME direct-mapped DTLB index
 *       (lin[15:12]=0). Page 0x90000 is not present. The probe must fault
 *       pre-commit with CR2=0x9000E (the first denied-page slot in push
 *       order), zero frame bytes written, and -- the graded property -- the
 *       VALIDATED page 0x80000's PTE must still have D=0 (validation is not
 *       a write). QEMU 8.2.2 pushes incrementally: it writes slots 0/1 and
 *       D-marks page 0x80000 -- the pinned oracle gap.
 *   C2 (deny the FIRST page): page 0x80000 not present. The fault lands on
 *       the first plan entry (CR2=0x80012), nothing is written anywhere,
 *       page 0x90000's PTE keeps D=0 -- oracle-identical.
 *   C3 (collision success): same geometry, both pages present with D=0.
 *       The D-mark pass must set D on BOTH pages pre-commit, the delivery
 *       completes with every frame byte correct, and the pushes perform NO
 *       page walk (graded by the +ven_frmpglog counter: the colliding pages
 *       evict each other from the DTLB between probe and push, so any push
 *       translation through the DTLB would walk).
 *   C4..C7 (probe-beat counting, all pages pre-dirtied): the +ven_frmpglog
 *       print per delivery must show one validation beat per distinct page:
 *       C4 32-bit int frame (5 dword slots, 1 page) -> val=1;
 *       C5 16-bit int frame (5 word slots, 2 colliding pages) -> val=2;
 *       C6 V86 9-slot frame (36 bytes, 3 pages) -> val=3;
 *       C7 pcount=31 32-bit call gate (35 slots, 140 bytes, 3 pages) ->
 *       val=3 (NOT 35).
 *
 * The image runs to the isa-debug-exit under BOTH oracles. The golden pins
 * QEMU's incremental-push witnesses (step 5f); the RTL side is graded in
 * step 7w (zero bytes, D bits, plus the ordered FRMPG counter sequence).
 *
 * Memory plan: GDT @0x6000 (code0f 0x40 / code3f 0x48 based at the image so
 * 16-bit frames carry offsets; ss16 0x30 built per case; call gate 0x38),
 * IDT @0x1000 ([14] pf3 same-priv CPL3, [0x30] per case, [0x31] setup CPL0),
 * TSS @0x3000, PD @0x10000, PT0 @0x11000 identity [0,1MiB), user stack
 * 0xF000, clean CPL0 stack 0xA0000, case state @0x5000, mirror @0x5110,
 * per-slot extent buffer @0x5200, CG32 param source @0xEF00, wrapped stack
 * base 0x80010.
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
    movw    $0x9000, %sp

    /* GDT @ 0x6000 */
    movl    $0x00000000, 0x6000         /* 0x00 null */
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

    /* IDT @ 0x1000 */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    /* [14] #PF -> pf3, CS=0x4B (same-priv at CPL3), 0x8F */
    movl    $(pf3_handler - 0xF0000), %ebx
    movl    $0x8F, %eax
    movl    $0x1070, %edi
    movl    $0x004B, %ecx
    call    write_idt_gate_sel
    /* [0x31] -> setup_handler, CS=0x40, 0xEF */
    movl    $(setup_handler - 0xF0000), %ebx
    movl    $0xEF, %eax
    movl    $0x1188, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* TSS @ 0x3000 */
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

    /* page tables: PD @0x10000, PT0 @0x11000 identity [0,1MiB), all
     * P|RW|US with A=0 D=0 (the D-bit witnesses start clean) */
    movl    $0x00011007, 0x00010000
    movl    $0x00011000, %edi
    xorl    %eax, %eax
1:  movl    %eax, %edx
    orl     $0x00000007, %edx
    movl    %edx, (%edi)
    addl    $4, %edi
    addl    $0x1000, %eax
    cmpl    $0x00100000, %eax
    jb      1b
    movl    $0x00010000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* CG32 param source: dword i at 0xEF00+4i = 0xD0000000+i */
    movl    $31, %ecx
    movl    $0x0000EF00, %edi
    movl    $0xD0000000, %eax
1:  movl    %eax, (%edi)
    addl    $4, %edi
    incl    %eax
    loop    1b

    movl    $0, 0x5000                  /* cur_case */
    movl    $0, 0x5110                  /* mirror: edi/esi/ecx/ebp/ebx */
    movl    $0, 0x5114
    movl    $0, 0x5118
    movl    $0, 0x511C
    movl    $0, 0x5120
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
    /* record the CR2 the previous deny case left (CPL3 cannot read cr2) */
    movl    0x5000, %eax
    testl   %eax, %eax
    jz      1f
    movl    %cr2, %eax
    cmpl    $1, 0x5000
    jne     0f
    movl    %eax, 0x511C                /* C1's CR2 -> ebp */
    jmp     1f
0:  cmpl    $2, 0x5000
    jne     1f
    movl    %eax, 0x5120                /* C2's CR2 -> ebx */
1:
    movl    0x5000, %eax
    cmpl    $NCASES, %eax
    jae     all_done
    incl    %eax
    movl    %eax, 0x5000
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %esi
    movb    (%esi), %al
    movb    %al, 0x5004                 /* cur_kind */

    /* TSS.ESP0/SS0 (+ the ss16 descriptor when B=0) */
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
    orl     $0x008F9200, %eax           /* access 0x92, gran 0x8F (G=1,B=0) */
    movl    %eax, 0x6034
    movl    $0x00000030, %eax
    jmp     2f
1:  movl    $0x00000010, %eax
2:  movl    %eax, 0x00003008

    /* IDT[0x30] / the call gate, per kind */
    movzbl  (%esi), %eax
    cmpl    $3, %eax
    je      setup_cgate
    cmpl    $4, %eax
    jae     setup_v86gate
    cmpl    $2, %eax
    je      setup_i32
    movl    $(int0h16 - 0xF0000), %ebx  /* kind 1: 16-bit trap gate DPL3 */
    movl    $0xE7, %eax
    jmp     3f
setup_i32:
    movl    $(int0h32 - 0xF0000), %ebx  /* kind 2: 32-bit trap gate DPL3 */
    movl    $0xEF, %eax
3:  movl    $0x1180, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel
    jmp     setup_extent
setup_cgate:
    movl    $(cg32_callee - 0xF0000), %ebx   /* 32-bit call gate, pcount 31 */
    movl    %ebx, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x00400000, %edx
    movl    %edx, 0x6038
    movl    %ebx, %edx
    andl    $0xFFFF0000, %edx
    orl     $0x0000EC00, %edx           /* 32-bit call gate DPL3 */
    orl     $31, %edx
    movl    %edx, 0x603C
    jmp     setup_extent
setup_v86gate:
    movl    $(v86mon - 0xF0000), %ebx
    movl    $0xEF, %eax
    movl    $0x1180, %edi
    movl    $0x0040, %ecx
    call    write_idt_gate_sel

setup_extent:
    /* pre-dirty page 0x8F000 when the frame can reach it (the 3-page cases) */
    movzbl  2(%esi), %eax
    cmpl    $9, %eax
    jb      1f
    movb    $0, 0x0008F000
1:
    /* snapshot the frame extent into the per-slot buffer at 0x5200:
     * slot k at base + ((esp0-(k+1)*unit) & mask), unit = gate16 ? 2 : 4 */
    movzbl  2(%esi), %eax
    movl    %eax, 0x5134                /* nslots */
    movzbl  3(%esi), %edx
    andl    $2, %edx
    jnz     2f
    movl    $4, 0x5138                  /* unit 4 */
    jmp     3f
2:  movl    $2, 0x5138                  /* unit 2 */
3:  movl    $0xFFFFFFFF, 0x513C         /* offset mask */
    cmpb    $0, 1(%esi)
    jne     4f
    movl    $0x0000FFFF, 0x513C
4:  movl    $0, 0x5148                  /* k */
    movl    0x5138, %edx
    movl    %edx, 0x5140                /* (k+1)*unit */
extent_loop:
    movl    0x5148, %eax
    cmpl    0x5134, %eax
    jae     extent_done
    movl    4(%esi), %edx               /* esp0 */
    subl    0x5140, %edx
    andl    0x513C, %edx                /* slot offset */
    addl    8(%esi), %edx               /* slot linear address */
    /* buffer slot k at 0x5200 + k*unit */
    movl    0x5148, %eax
    movzbl  3(%esi), %ecx
    andl    $2, %ecx
    jnz     5f
    shll    $2, %eax
    movl    (%edx), %ecx
    movl    %ecx, 0x5200(%eax)
    jmp     6f
5:  addl    %eax, %eax
    movzwl  (%edx), %ecx
    movw    %cx, 0x5200(%eax)
6:  movl    0x5138, %edx
    addl    %edx, 0x5140
    incl    0x5148
    jmp     extent_loop
extent_done:

    /* deny the case's page (0xFFFFFFFF = none) */
    movl    12(%esi), %eax
    cmpl    $0xFFFFFFFF, %eax
    je      setup_go
    movl    %eax, %ebx
    shrl    $10, %ebx
    movl    $0, 0x11000(%ebx)
    movl    %cr3, %eax                  /* flush stale translations */
    movl    %eax, %cr3

setup_go:
    movzbl  0x5004, %eax
    cmpl    $4, %eax
    jae     v86_enter
    pushl   $0x00000023
    pushl   $0x0000F000
    pushl   $0x00003202                 /* IF=1 IOPL=3 */
    pushl   $0x0000004B
    pushl   $(cpl3_stub - 0xF0000)
    iretl

/* ======================= V86 entry (C6) ================================== */
v86_enter:
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
    .global trig_int
trig_int:
    int     $0x30
    .global trig_int_ret
trig_int_ret:
    jmp     trig_done
trig_cg_setup:
    movl    $0x0000EF00, %esp           /* 31 dword params above the lcall */
    .global trig_cg
trig_cg:
    .byte   0x9A                        /* lcall ptr16:32 through gate 0x38 */
    .long   0
    .word   0x003B
    .global trig_done
trig_done:
    int     $0x31                       /* back to CPL0 for the next case */
    jmp     cpl3_stub

/* ================== CPL3 #PF handler (C1/C2 witness) ==================== *
 * Same-priv frame: [esp]=err, +4=EIP, +8=CS, +12=EFLAGS. Verifies the probe
 * fault (err=2, old context, EIP=the trigger), scans every frame slot
 * against the pre-read buffer (skipping the denied page, which is
 * unreadable and unwritten by construction), reads the D bits, restores the
 * denied PTE with A=1/D=0 (so the success case still exercises the D-mark
 * pass), and skips the trigger. Scratch: eax/edx + memory temps only. */
    .align 16
    .global pf3_handler
pf3_handler:
    cmpl    $2, 0(%esp)                 /* err = {US=0,W=1,P=0} */
    jne     fail
    cmpl    $0x4B, 8(%esp)
    jne     fail
    cmpl    $(trig_int - 0xF0000), 4(%esp)
    jne     fail
    /* scan setup */
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
    jnz     1f
    movl    $4, 0x5138
    jmp     2f
1:  movl    $2, 0x5138
2:  movl    $0xFFFFFFFF, 0x513C
    cmpb    $0, 1(%eax)
    jne     3f
    movl    $0x0000FFFF, 0x513C
3:  movl    0x5138, %edx
    movl    %edx, 0x5140                /* (k+1)*unit */
scan_loop:
    movl    0x5124, %eax
    cmpl    0x5134, %eax
    jae     scan_done
    movl    0x5130, %eax
    movl    4(%eax), %edx
    subl    0x5140, %edx
    andl    0x513C, %edx
    addl    8(%eax), %edx               /* slot linear address */
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
    /* compare the slot against the buffer (0x5200 + k*unit) */
    movl    0x5124, %eax
    cmpl    $4, 0x5138
    jne     4f
    shll    $2, %eax
    movl    0x5200(%eax), %eax
    movl    0x5144, %edx
    cmpl    %eax, (%edx)
    je      scan_next
    jmp     5f
4:  addl    %eax, %eax
    movzwl  0x5200(%eax), %eax
    movl    0x5144, %edx
    cmpw    %ax, (%edx)
    je      scan_next
5:  /* slot written: mask |= 1<<k, count++ */
    movl    $1, 0x5144
    movl    0x5124, %edx
6:  testl   %edx, %edx
    jz      7f
    shll    $1, 0x5144
    decl    %edx
    jmp     6b
7:  movl    0x5144, %edx
    orl     %edx, 0x5128
    incl    0x512C
scan_next:
    movl    0x5138, %edx
    addl    %edx, 0x5140
    incl    0x5124
    jmp     scan_loop
scan_done:
    movl    0x512C, %eax
    addl    %eax, 0x5110                /* edi: total written slots */
    incl    0x5114                      /* esi: deny cases handled */
    /* D-bit witnesses: C1 reads PT0[0x80] (the validated early page), C2
     * reads PT0[0x90] (the untouched later page) -> mirror ecx bit0/bit1 */
    movl    0x5000, %eax
    cmpl    $1, %eax
    jne     8f
    movl    0x00011200, %eax            /* PT0[0x80] */
    andl    $0x40, %eax
    jz      9f
    orl     $0x1, 0x5118
    jmp     9f
8:  cmpl    $2, %eax
    jne     9f
    movl    0x00011240, %eax            /* PT0[0x90] (D90: untouched by C2) */
    andl    $0x40, %eax
    jz      9f
    orl     $0x2, 0x5118
9:
    /* restore the denied PTE with A=1, D=0 (the success case still runs the
     * D-mark pass) */
    movl    0x5130, %eax
    movl    12(%eax), %ebx
    movl    %ebx, %eax
    shrl    $10, %ebx
    orl     $0x00000027, %eax           /* P|RW|US|A, D=0 */
    movl    %eax, 0x11000(%ebx)
    /* the int $0x31 return must use the CLEAN stack, or its frame would
     * land on the wrapped pages and D-dirty them (polluting C2's witness) */
    movl    $0x000A0000, 0x00003004
    movl    $0x00000010, 0x00003008
    addl    $4, %esp                    /* drop err; saved EIP = trig_int */
    movl    $(trig_done - 0xF0000), %eax/* skip the trigger */
    movl    %eax, 0(%esp)
    iretl

/* ==================== CPL0 delivery handlers ============================ *
 * Frame-slot reads compute the wrapped offset by hand (an explicit
 * [esp+disp] effective address does not wrap at the B=0 64 KiB boundary;
 * only true stack operations do). Each handler re-arms the clean SS0:ESP0
 * for the stub's int $0x31. */
    .align 16
    .global int0h16
int0h16:                                /* 16-bit frame: IP CS FL SP SS */
    movl    0x5000, %eax
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %eax
    movl    8(%eax), %edx               /* ss_base */
    movzwl  %sp, %eax
    movzwl  (%eax,%edx), %eax
    cmpl    $(trig_int_ret - 0xF0000), %eax
    jne     fail
    movl    %esp, %eax
    addl    $2, %eax
    movzwl  %ax, %eax
    movzwl  (%eax,%edx), %eax
    cmpl    $0x4B, %eax
    jne     fail
    movl    %esp, %eax
    addl    $4, %eax
    movzwl  %ax, %eax
    movzwl  (%eax,%edx), %eax
    andl    $0x00003302, %eax           /* IOPL|IF|bit1: status bits are live */
    cmpl    $0x3202, %eax
    jne     fail
    movl    %esp, %eax
    addl    $6, %eax
    movzwl  %ax, %eax
    movzwl  (%eax,%edx), %eax
    cmpl    $0xF000, %eax
    jne     fail
    movl    %esp, %eax
    addl    $8, %eax
    movzwl  %ax, %eax
    movzwl  (%eax,%edx), %eax
    cmpl    $0x23, %eax
    jne     fail
    /* C3 additionally proves the D-mark pass set D on BOTH destination
     * pages before the commit */
    movl    0x5000, %eax
    cmpl    $3, %eax
    jne     1f
    movl    0x00011200, %eax            /* PT0[0x80] */
    andl    $0x40, %eax
    jz      fail                        /* D=0 after a completed delivery?! */
    orl     $0x4, 0x5118
    movl    0x00011240, %eax            /* PT0[0x90] */
    andl    $0x40, %eax
    jz      fail
    orl     $0x8, 0x5118
1:  movl    $0x000A0000, 0x00003004
    movl    $0x00000010, 0x00003008
    iretw

    .align 16
    .global int0h32
int0h32:                                /* 32-bit frame (B=1 flat stack) */
    cmpl    $(trig_int_ret - 0xF0000), 0(%esp)
    jne     fail
    cmpl    $0x4B, 4(%esp)
    jne     fail
    movl    8(%esp), %eax
    andl    $0x00003302, %eax
    cmpl    $0x3202, %eax
    jne     fail
    cmpl    $0xF000, 12(%esp)
    jne     fail
    cmpl    $0x23, 16(%esp)
    jne     fail
    movl    $0x000A0000, 0x00003004
    movl    $0x00000010, 0x00003008
    iretl

    .align 16
    .global v86mon
v86mon:                                 /* 9-slot V86 frame on the wrapped stack */
    movw    $0x10, %ax                  /* V86 delivery zeroed DS/ES/FS/GS */
    movw    %ax, %ds
    movl    0x5000, %eax
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %eax
    movl    8(%eax), %esi               /* ss_base */
    movzwl  %sp, %eax
    movzwl  (%eax,%esi), %eax
    cmpl    $(v86_task_int + 2 - 0xF0000), %eax
    jne     fail
    movl    %esp, %eax
    addl    $4, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0xF000, %eax
    jne     fail
    movl    %esp, %eax
    addl    $8, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x00023002, %eax
    jne     fail
    movl    %esp, %eax
    addl    $12, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x8000, %eax
    jne     fail
    movl    %esp, %eax
    addl    $16, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x2000, %eax
    jne     fail
    movl    %esp, %eax
    addl    $20, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x2000, %eax               /* ES */
    jne     fail
    movl    %esp, %eax
    addl    $24, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x2000, %eax               /* DS */
    jne     fail
    movl    %esp, %eax
    addl    $28, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    testl   %eax, %eax                  /* FS */
    jne     fail
    movl    %esp, %eax
    addl    $32, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    testl   %eax, %eax                  /* GS */
    jne     fail
    movl    $0x000A0000, 0x00003004     /* clean SS0:ESP0 for int $0x31 */
    movl    $0x00000010, 0x00003008
    iretl

    .align 16
    .global cg32_callee
cg32_callee:                            /* 140-byte frame: EIP CS p0..p30 ESP SS */
    movl    0x5000, %eax
    decl    %eax
    shll    $4, %eax
    leal    case_table(%eax), %eax
    movl    8(%eax), %esi               /* ss_base */
    movzwl  %sp, %eax
    movl    (%eax,%esi), %eax
    cmpl    $(trig_done - 0xF0000), %eax
    jne     fail
    movl    %esp, %eax
    addl    $4, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x4B, %eax
    jne     fail
    movl    $31, %ecx
    movl    $0xD0000000, %edx
    movl    $8, %ebx
1:  movl    %esp, %eax
    addl    %ebx, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    %edx, %eax
    jne     fail
    addl    $4, %ebx
    incl    %edx
    loop    1b
    movl    %esp, %eax
    addl    $132, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0xEF00, %eax
    jne     fail
    movl    %esp, %eax
    addl    $136, %eax
    movzwl  %ax, %eax
    movl    (%eax,%esi), %eax
    cmpl    $0x23, %eax
    jne     fail
    movl    $0x000A0000, 0x00003004
    movl    $0x00000010, 0x00003008
    lret    $124

/* ============================= exits ==================================== */
    .align 16
    .global all_done
all_done:
    movl    0x5110, %edi                /* written slots (QEMU 2 / RTL 0) */
    movl    0x5114, %esi                /* deny cases handled (2) */
    movl    0x5118, %ecx                /* D-bit witness pack */
    movl    0x511C, %ebp                /* C1 CR2 (0x0009000E) */
    movl    0x5120, %ebx                /* C2 CR2 (0x00080012) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .global fail
fail:
    movb    $0x99, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* exit status 307 != 133: loud */
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

/* case table: kind, ss_b32, nslots, flags, esp0, ss_base, deny_page */
.section .rodata
.align 4
.equ NCASES, 7
case_table:
  /* C1: deny the later colliding page (0x90000) */
  .byte 1, 0, 5, 2
  .long 0x00000004
  .long 0x00080010
  .long 0x00090000
  /* C2: deny the first page (0x80000) */
  .byte 1, 0, 5, 2
  .long 0x00000004
  .long 0x00080010
  .long 0x00080000
  /* C3: collision success (D=0 start, D-mark pass) */
  .byte 1, 0, 5, 2
  .long 0x00000004
  .long 0x00080010
  .long 0xFFFFFFFF
  /* C4: 32-bit int frame, one page (0x9F000, pre-dirtied by the boot stack;
   * NOT 0xA0000+: the 0xA0000-0xBFFFF VGA hole is MMIO under QEMU) */
  .byte 2, 1, 5, 0
  .long 0x000A0000
  .long 0x00000000
  .long 0xFFFFFFFF
  /* C5: 16-bit int frame, two colliding pages */
  .byte 1, 0, 5, 2
  .long 0x00000008
  .long 0x00080010
  .long 0xFFFFFFFF
  /* C6: V86 9-slot frame, three pages */
  .byte 4, 0, 9, 0
  .long 0x00000008
  .long 0x00080010
  .long 0xFFFFFFFF
  /* C7: pcount=31 call gate, 35 slots / 140 bytes, three pages */
  .byte 3, 0, 35, 0
  .long 0x00000008
  .long 0x00080010
  .long 0xFFFFFFFF
