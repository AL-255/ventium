/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — HARDWARE TASK SWITCH whose INCOMING task is a VIRTUAL-8086 task
 * (EFLAGS.VM=1).  This is the rigorous differential for the DOS-Quake #DE root
 * cause: qemu switch_tss_ra does `if (new_eflags & VM_MASK) load_seg_vm(...)` —
 * for a V86 incoming task it loads FLAT real-mode segments (base = sel<<4, limit
 * 0xFFFF, CPL3, D/B=0), NOT a GDT descriptor walk.  Ventium's S_TSW_SEG used to
 * load all 6 segments as PM descriptors UNCONDITIONALLY, ignoring the incoming
 * task's VM flag, so a V86 incoming CS=0x2000 (a real-mode paragraph) was decoded
 * as a GDT selector -> CS base became garbage (or a #GP), and the very first
 * fetch / `mov es,0x2593` in the V86 task diverged from real hardware / qemu.
 *
 * The fix adds the `if (tsw_eflags[17])` (VM) branch in core_tsw.svh S_TSW_SEG
 * that loads flat real-mode segments (base = sel<<4, limit 0xFFFF, CPL3, cs_d=0),
 * mirroring the V86-return IRET tail (core_iret.svh) and qemu load_seg_vm.
 *
 * This image reproduces EXACTLY that structure deterministically and is diffed
 * RTL-vs-qemu by verif/sys/run-sys-golden.sh:
 *   - A CPL0 protected-mode task (TASK-A, TSS sel 0x60, LTR'd) builds TSS-B (sel
 *     0x70) with EFLAGS.VM=1 and CS=DS=ES=SS = real-mode PARAGRAPHS 0x2000 (so the
 *     base must become 0x20000), EIP=0.
 *   - TASK-A does `ljmp $0x70,$0` — the HARDWARE TASK SWITCH into the V86 task.
 *     The CPU must load FLAT real-mode segments (CS.base=0x20000, CPL=3, cs_d=0).
 *   - The V86 task runs the exact instruction class that faults in the real bug:
 *       mov bx,0x2593 ; mov es,bx ; mov al,[es:0]
 *     With the fix, ES.base becomes 0x25930 (sel<<4) and the read returns the
 *     sentinel byte 0x5A planted there -> AL=0x5A (a POSITIVE proof in a graded
 *     trace field; eax).  Without the fix, the switch loads a wrong CS base and the
 *     V86 task's first fetch comes from the wrong linear address -> the RTL trace
 *     DIVERGES from the qemu golden (the gate FAILS).
 *   - The V86 task then `int $0x20` (IOPL=0 < 3 -> #GP(0) -> the CPL0 monitor),
 *     which performs the isa-debug-exit (out 0xf4, 0x42 -> qemu status 133).
 *
 * NO paging (linear == physical), flat 64 KiB -bios image; reset F000:FFF0.
 *
 * Memory plan (machine -m 32):
 *   GDT  @ 0x00000500   (15 entries; idx1 0x08 code0, idx2 0x10 data0,
 *                        idx12 sel 0x60 TSS-A base 0x3000, idx14 sel 0x70 TSS-B
 *                        base 0x4000; both 32-bit available TSS DPL0 acc 0x89)
 *   IDT  @ 0x00001000   (vector 13 #GP -> gp_handler, 32-bit interrupt gate DPL0)
 *   markers @ 0x00002000 (unused scratch; reserved)
 *   TSS-A @ 0x00003000  (TASK-A, current via LTR; CPU saves outgoing state here)
 *   TSS-B @ 0x00004000  (the V86 INCOMING task image: EFLAGS.VM=1, SS0:ESP0 set)
 *   V86 task code @ 0x00020000 (segment 0x2000; copied from the BIOS image)
 *   sentinel byte @ 0x00025930 (= ES.base 0x25930 + 0; value 0x5A)
 *   stacks: CPL0 task @ 0x90000 ; CPL0 #GP-monitor (TSS-B.SS0:ESP0) @ 0x88000
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

    /* --- build the GDT (15 entries = 120 bytes) at linear 0x0500 ---
     * Zero all 120 bytes first, then fill idx1/idx2/idx12/idx14. */
    movl    $0x00000500, %edi
    xorl    %eax, %eax
    movl    $30, %ecx                   /* 30 dwords = 120 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $0x00000500, %ebx
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 flat DPL0 (0x9A/0xCF) */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 flat DPL0 (0x92/0xCF) */
    movl    $0x00CF9200, 20(%ebx)
    /* idx12 sel 0x60 TSS-A: base 0x00003000, limit 0x67, access 0x89 (avail TSS DPL0) */
    movl    $0x30000067, 0x60(%ebx)
    movl    $0x00008900, 0x64(%ebx)
    /* idx14 sel 0x70 TSS-B: base 0x00004000, limit 0x67, access 0x89 (avail TSS DPL0) */
    movl    $0x40000067, 0x70(%ebx)
    movl    $0x00008900, 0x74(%ebx)

    movw    $0x0077, 0x0480             /* GDT limit = 120-1 = 0x77 (15 entries) */
    movl    $0x00000500, 0x0482        /* GDT base = 0x0500 */
    lgdt    0x0480

    /* --- build a minimal IDT @ 0x1000 with the #GP gate (vector 13) --- */
    /* (low RAM is zero-initialised, so all other gates are not-present; only the
     * #GP gate is ever taken — by the V86 INT-n redirect.) */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 = 0x1068 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 in bits 31:16 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* attr 0x8E (32-bit interrupt gate, P, DPL0) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490            /* IDT limit = 256*8 - 1 */
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
    movl    $0x00090000, %esp           /* TASK-A (current) CPL0 stack */

    /* --- copy the V86 task blob down to linear 0x00020000 (segment 0x2000) --- */
    movl    $_v86_lma, %esi             /* source: image-resident blob (high) */
    movl    $0x00020000, %edi           /* dest:   V86 task run window (CS<<4) */
    movl    $_v86_blob_len, %ecx
    addl    $3, %ecx
    shrl    $2, %ecx                    /* dword count (ceil) */
1:  movl    (%esi), %eax
    movl    %eax, (%edi)
    addl    $4, %esi
    addl    $4, %edi
    loop    1b

    /* --- plant the sentinel byte 0x5A at linear 0x00025930 (= ES.base 0x25930) --- */
    movb    $0x5A, 0x00025930

    /* --- zero + init TSS-A @ 0x3000 (current task; CPU saves outgoing state here) --- */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 26 dwords = 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movw    $0x0068, 0x00003066         /* I/O map base */

    /* --- zero + init TSS-B @ 0x4000 (the V86 INCOMING task) --- */
    movl    $0x00004000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00004004     /* ESP0 = 0x88000 (CPL0 #GP-monitor stack) */
    movl    $0x00000010, 0x00004008     /* SS0  = 0x10 */
    movl    $0x00000000, 0x0000401C     /* CR3 = 0 (paging off) */
    movl    $0x00000000, 0x00004020     /* EIP = 0 (V86 task offset) */
    movl    $0x00020002, 0x00004024     /* EFLAGS = VM(bit17) | reserved(bit1), IOPL=0 */
    movl    $0x0000F000, 0x00004038     /* ESP = 0xF000 (V86 stack offset) */
    movl    $0x00002000, 0x00004048     /* ES = 0x2000  (real-mode paragraph) */
    movl    $0x00002000, 0x0000404C     /* CS = 0x2000  (base must become 0x20000) */
    movl    $0x00002000, 0x00004050     /* SS = 0x2000 */
    movl    $0x00002000, 0x00004054     /* DS = 0x2000 */
    movl    $0x00000000, 0x00004058     /* FS = 0 */
    movl    $0x00000000, 0x0000405C     /* GS = 0 */
    movl    $0x00000000, 0x00004060     /* LDTR = 0 */
    movw    $0x0068,     0x00004066     /* I/O map base */

    /* LTR TASK-A (selector 0x60): TR -> current task TSS-A. */
    movw    $0x0060, %ax
    ltr     %ax

    /* ===================== THE HARDWARE TASK SWITCH ====================== *
     * Far JMP into TSS-B (sel 0x70).  Because TSS-B.EFLAGS has VM=1, the CPU must
     * load FLAT real-mode segments for the incoming task (CS.base=0x20000, CPL=3,
     * cs_d=0) -- NOT decode CS=0x2000 as a GDT selector.  This is the exact path
     * the core_tsw.svh V86 branch fixes.                                          */
    ljmp    $0x70, $0                   /* -> TSS-B (the V86 task at 0x2000:0) */

    /* (unreachable: the V86 task exits via the #GP monitor) */
hang0:
    hlt
    jmp     hang0

    /* ===================== CPL0 #GP MONITOR (vector 13) =================== *
     * Reached at CPL0 when the V86 task's `int $0x20` (IOPL=0 < 3) raises #GP(0)
     * and the CPU delivers cross-priv to TSS-B.SS0:ESP0 (= 0x10:0x88000) with the
     * 9-word V86 frame.  This monitor just performs the isa-debug-exit.           */
    .align 16
    .global gp_handler
gp_handler:
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
ehang:
    hlt
    jmp     ehang

    /* ============================ V86 TASK BODY ========================= *
     * Assembled as 16-bit code at run-VMA 0x00020000 (segment 0x2000, offset 0);
     * stored high in the BIOS image (its LMA) and copied down by pm32_entry.  Runs
     * at CPL3 in V86 mode after the task switch.  Executes the EXACT instruction
     * class that faults in the real DOS-Quake #DE bug: load a real-mode paragraph
     * into ES (mov es,0x2593 -> ES.base 0x25930) then read [es:0].                 */
    .code16
    .section .text_v86, "ax"
    .global v86_entry
v86_entry:
    movw    $0x2593, %bx                /* bb 93 25 */
    movw    %bx, %es                    /* 8e c3 : ES.base must become 0x25930 */
    movb    %es:0x0, %al                /* read [es:0] -> AL = 0x5A (the sentinel) */
    /* AL=0x5A is the POSITIVE proof (a graded eax field) that ES.base=0x25930
     * (sel<<4) was loaded by the V86-aware MOV-sreg path after a CORRECT V86 task
     * switch.  Now terminate: INT 0x20 at IOPL=0 -> #GP -> the CPL0 monitor. */
    int     $0x20                       /* cd 20 -> #GP(0) -> gp_handler -> exit */
v86_hang:
    jmp     v86_hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
