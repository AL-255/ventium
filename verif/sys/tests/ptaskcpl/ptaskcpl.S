/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — HARDWARE TASK SWITCH where the OUTGOING task is running at CPL3
 * (the CWSDPMI 0x60<->0x70 co-routine pattern), built to settle ONE question
 * DEFINITIVELY: does Ventium's TSS save/restore handle a task suspended at a
 * CPL3 code selector (RPL=3) bit-identically to qemu-system-i386?
 *
 * The DOS-Quake #DE is: CWSDPMI's dispatch task (TSS 0x60) is suspended while
 * running at cs=0x2b (a DPL3 code-segment ALIAS of the CPL0 dispatch code, same
 * base, RPL=3), then resumed by a far-JMP task switch -> it comes back at cs=0x2b
 * (CPL3). The question is whether the CPU's save (CS<-live 0x2b into TSS) and
 * restore (resume CS=0x2b, CPL=CS.RPL=3) are architecturally correct, or whether
 * Ventium diverges from real hardware / qemu.
 *
 * This test reproduces EXACTLY that structure deterministically:
 *   - TASK1 (TSS1, current via LTR): starts at CPL0 (cs=0x08), transitions DOWN
 *     to CPL3 via an inter-priv IRET into a DPL3 code alias cs=0x1B (same base
 *     as 0x08, RPL=3) -- so at this point cs=0x1B, CPL=3 (mirrors guest cs=0x2b).
 *   - While at CPL3, TASK1 does the HARDWARE TASK SWITCH: `ljmp $0x33,$0` to TSS2
 *     (TSS2 descriptor DPL=3, so a CPL3 task may JMP to it). The CPU SAVES TASK1's
 *     live state into TSS1, INCLUDING cs=0x1B (the CPL3 selector) at TSS1+0x4C.
 *     ==> this is the exact "save a CPL3 CS into the outgoing TSS" step.
 *   - TASK2 (TSS2 image, CPL0 cs=0x08) runs, records markers, then switches BACK
 *     with `ljmp $0x28,$0` (TSS1, DPL0 -- reachable since TASK2 is CPL0).
 *     ==> TASK1 RESUMES from its SAVED TSS1 image: CS=0x1B, CPL=CS.RPL=3.
 *         This is the exact "restore a CPL3 CS from the TSS" step.
 *   - TASK1 RESUMED (now back at CPL3, cs=0x1B) records PROOF markers: its live
 *     CS selector (read via `mov %cs,..` -> expect 0x1B) and that it is at CPL3
 *     (the marker store works because the CPL3 data segment 0x23 is loaded). It
 *     then traps to CPL0 via INT 0x40 (a DPL3 gate -> CPL0 handler) which does the
 *     isa-debug-exit.
 *
 * The differential is the golden-trace diff (verif/sys/run-sys-golden.sh): the
 * SAME image runs under qemu-system-i386 (--system golden) AND the Ventium RTL
 * (--system). If the resumed-task CS:EIP + CPL + the saved-TSS CS BYTE match the
 * golden, Ventium's CPL3 task-switch save/restore is bit-exact (=> the DOS-Quake
 * #DE is a guest cadence race, no CPU bug). If they diverge, this localizes the
 * bug to the TSS save/restore of a CPL3 selector.
 *
 * NO paging (linear == physical), flat 64 KiB -bios image; reset F000:FFF0.
 *
 * Memory plan (machine -m 32):
 *   GDT  @ 0x00000500
 *     idx0 null
 *     idx1 0x08 code32 flat DPL0   (access 0x9A, gran 0xCF)
 *     idx2 0x10 data32 flat DPL0   (access 0x92, gran 0xCF)
 *     idx3 0x1B code32 flat DPL3   (access 0xFA, gran 0xCF)  [RPL3 alias of 0x08]
 *     idx4 0x23 data32 flat DPL3   (access 0xF2, gran 0xCF)  [RPL3]
 *     idx5 0x28 TSS1 (DPL0, base 0x3000, limit 0x67, access 0x89)
 *     idx6 0x33 TSS2 (DPL3, base 0x4000, limit 0x67, access 0xE9)  [RPL3]
 *   IDT  @ 0x00001000   gate 0x40 (DPL3 int gate -> CPL0 exit handler)
 *   markers @ 0x00002000
 *   TSS1 @ 0x00003000   (TASK1; LTR'd; SS0:ESP0 for cross-priv; CPU saves here)
 *   TSS2 @ 0x00004000   (TASK2 image, CPL0)
 *   stacks: CPL0 task1 @ 0x90000 ; CPL3 user @ 0x88000 ; CPL0 INT @ 0x80000 ;
 *           task2 @ 0x70000
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

    /* --- build the GDT (7 entries = 56 bytes) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 (0x9A/0xCF) */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 (0x92/0xCF) */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18->sel 0x1B code3 DPL3 (0xFA/0xCF) */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20->sel 0x23 data3 DPL3 (0xF2/0xCF) */
    movl    $0x00CFF200, 36(%ebx)
    /* idx5 0x28 TSS1: base 0x00003000, limit 0x67, access 0x89 (32-bit avail TSS DPL0) */
    movl    $0x30000067, 40(%ebx)
    movl    $0x00008900, 44(%ebx)
    /* idx6 0x30->sel 0x33 TSS2: base 0x00004000, limit 0x67, access 0xE9 (avail TSS DPL3) */
    movl    $0x40000067, 48(%ebx)
    movl    $0x0000E900, 52(%ebx)

    movw    $0x0037, 0x0480             /* GDT limit = 56-1 = 0x37 (7 entries) */
    movl    $0x00000500, 0x0482        /* GDT base = 0x0500 */
    lgdt    0x0480

    /* --- build a minimal IDT @ 0x1000 with gate 0x40 (DPL3 int gate -> CPL0) --- */
    /* zero 0x41 gates (0x208 bytes) first */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movw    $0x0082, %cx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    /* gate 0x40 @ 0x1000 + 0x40*8 = 0x1200: target sel 0x08, off=exit_handler,
     * access 0xEE (P=1,DPL=3,32-bit interrupt gate). */
    movl    $0x00001200, %ebx
    movl    $exit_handler, %eax
    movw    %ax, 0(%ebx)               /* offset[15:0] */
    movw    $0x0008, 2(%ebx)           /* selector 0x08 */
    movw    $0xEE00, 4(%ebx)           /* 0x00 ist/reserved, attr 0xEE (DPL3 int gate) */
    shrl    $16, %eax
    movw    %ax, 6(%ebx)               /* offset[31:16] */

    movw    $0x020F, 0x0490            /* IDT limit = 0x41*8 - 1 = 0x207 -> use 0x20F (66 gates) */
    movl    $0x00001000, 0x0492       /* IDT base = 0x1000 */
    lidt    0x0490

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 -> 0x08:pm32_entry */
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
    movl    $0x00090000, %esp           /* task1 (current) CPL0 stack */

    /* --- zero marker area 0x2000..0x2060 --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $24, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* --- zero both TSS images (0x3000, 0x4000) --- */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $52, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* TSS1: SS0:ESP0 = the CPL0 INT stack (for the cross-priv INT 0x40 later),
     * I/O map base 0x68. TSS1+0x08 = ESP0, TSS1+0x0C = SS0. */
    movl    $0x00080000, 0x00003008     /* ESP0 = 0x80000 (CPL0 INT stack) */
    movl    $0x00000010, 0x0000300C     /* SS0  = 0x10 */
    movw    $0x0068,     0x00003066     /* I/O map base */

    /* --- pre-init TSS2 (the INCOMING task, runs at CPL0) --- */
    movl    $0x00000000, 0x0000401C     /* CR3 = 0 */
    movl    $task2,      0x00004020     /* EIP = task2 */
    movl    $0x00000002, 0x00004024     /* EFLAGS = 0x2 (IF=0) */
    movl    $0xAAAAAAAA, 0x00004028     /* EAX marker */
    movl    $0x00000000, 0x0000402C     /* ECX */
    movl    $0x00000000, 0x00004030     /* EDX */
    movl    $0xBBBBBBBB, 0x00004034     /* EBX marker */
    movl    $0x00070000, 0x00004038     /* ESP = task2 stack */
    movl    $0x00000000, 0x0000403C     /* EBP */
    movl    $0x00000000, 0x00004040     /* ESI */
    movl    $0x00000000, 0x00004044     /* EDI */
    movl    $0x00000010, 0x00004048     /* ES = 0x10 */
    movl    $0x00000008, 0x0000404C     /* CS = 0x08 (CPL0) */
    movl    $0x00000010, 0x00004050     /* SS = 0x10 */
    movl    $0x00000010, 0x00004054     /* DS = 0x10 */
    movl    $0x00000010, 0x00004058     /* FS = 0x10 */
    movl    $0x00000010, 0x0000405C     /* GS = 0x10 */
    movl    $0x00000000, 0x00004060     /* LDTR = 0 */
    movw    $0x0068,     0x00004066     /* I/O map base */

    /* LTR TSS1 (selector 0x28): TR -> current task TSS1. */
    movw    $0x0028, %ax
    ltr     %ax

    movl    $0x11111111, 0x00002000     /* "task1 reached CPL0 setup" */

    /* ===================== transition DOWN to CPL3 ======================= *
     * Build an inter-priv IRET frame on the current (CPL0) stack to drop to
     * cs=0x1B (DPL3 code alias), ss=0x23 (DPL3 data), eip=cpl3_entry, a CPL3
     * stack at 0x88000.  IRET pops EIP,CS,EFLAGS,ESP,SS (cross-priv).         */
    pushl   $0x23                       /* SS  (DPL3 data, RPL3) */
    pushl   $0x00088000                 /* ESP (CPL3 stack top) */
    pushl   $0x00003002                 /* EFLAGS (IF=0, IOPL=3 so CPL3 can OUT) */
    pushl   $0x1B                       /* CS  (DPL3 code alias, RPL3) */
    pushl   $cpl3_entry                 /* EIP */
    iret                                /* -> CPL3 */

    /* (unreachable: the outgoing-save resume of pm32 mainline never happens) */
hang0:
    hlt
    jmp     hang0

    /* ===================== CPL3 mainline (TASK1 @ CPL3) =================== *
     * Now cs=0x1B, CPL=3 (mirrors the guest's cs=0x2b dispatch).  Load CPL3
     * data segs, then perform the HARDWARE TASK SWITCH to TSS2 (sel 0x33, DPL3
     * so a CPL3 task may JMP to it).  The CPU SAVES TASK1 state into TSS1
     * INCLUDING cs=0x1B (the CPL3 selector) at TSS1+0x4C.                      */
    .align 16
    .global cpl3_entry
cpl3_entry:
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss                    /* (SS already 0x23 from the IRET) */
    movl    $0x22222222, 0x00002004     /* "task1 reached CPL3 (pre-switch)" */
    movl    $0x3C3C3C3C, %eax           /* live EAX the outgoing save records */

    /* THE HARDWARE TASK SWITCH (outgoing task is at CPL3): */
    ljmp    $0x33, $0                   /* -> TSS2 (CPL0 task2); saves cs=0x1B into TSS1 */

    /* TASK1 RESUMES HERE after task2 switches back.  At this point the CPU has
     * reloaded TASK1's saved TSS1 image -> cs=0x1B, CPL=3, the resume EIP is the
     * instruction after the ljmp.  Record PROOF that we are back at CPL3 with
     * cs=0x1B.                                                                  */
task1_resumed:
    /* reload CPL3 data seg (the switch reloaded it from TSS1's saved image, but
     * make the marker store robust). */
    movw    $0x23, %ax
    movw    %ax, %ds
    xorl    %eax, %eax
    movw    %cs, %ax                    /* live CS selector (expect 0x001B) */
    movl    %eax, 0x00002008            /* PROOF: resumed CS selector */
    movl    $0x44444444, 0x0000200C     /* "task1 RESUMED at CPL3 (post-switch)" */
    /* read back the CS byte the CPU SAVED into TSS1 (TSS1+0x4C = 0x304C).
     * NOTE: 0x304C is a CPL0 (DPL0) data region; at CPL3 with ds=0x23 (flat DPL3)
     * the read is allowed (the data seg spans all of RAM, base 0). expect 0x001B. */
    movl    0x0000304C, %eax
    movl    %eax, 0x00002010            /* PROOF: TSS1 saved CS = the CPL3 selector */
    /* isa-debug-exit DIRECTLY from CPL3 (IOPL=3 in EFLAGS permits OUT):
     * out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 0x85 = 133. */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

    /* unreachable */
hang1:
    hlt
    jmp     hang1

    /* ============================== TASK2 =============================== *
     * INCOMING task, entered by the hardware task switch with the TSS2 image:
     * cs=0x08 (CPL0), EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x70000.  Records the
     * reload markers + the SAVED TASK1 CS (TSS1+0x4C), then switches BACK to
     * TASK1 (ljmp $0x28 -> TSS1, DPL0, reachable from CPL0).                    */
    .align 16
    .global task2
task2:
    movl    %eax, 0x00002014            /* expect 0xAAAAAAAA (reloaded) */
    movl    %ebx, 0x00002018            /* expect 0xBBBBBBBB (reloaded) */
    movl    $0x55555555, 0x0000201C     /* "task2 ran" */
    /* read the CS byte the CPU saved for TASK1 into TSS1 (0x304C); expect 0x1B */
    movzbl  0x0000304C, %eax
    movl    %eax, 0x00002020            /* SAVED TASK1 CS byte seen from task2 */
    /* switch BACK to TASK1 -> TASK1 resumes at its saved CPL3 CS. */
    ljmp    $0x28, $0                   /* -> TSS1 (TASK1 resumes at cs=0x1B) */

    /* unreachable */
hang2:
    hlt
    jmp     hang2

    /* ===================== CPL0 exit handler (INT 0x40) =================== *
     * Reached by the CPL3 TASK1 (resumed) via INT 0x40 (cross-priv to CPL0).
     * Does the isa-debug-exit: out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 0x85. */
    .align 16
    .global exit_handler
exit_handler:
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hangE:
    hlt
    jmp     hangE

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
