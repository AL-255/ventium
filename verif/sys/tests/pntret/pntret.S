/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 H-08: an IRET with EFLAGS.NT=1 must TASK-SWITCH through the current
 * TSS's backlink. This core does not implement that -- IRET never examines NT -- so
 * such an IRET is treated as an ordinary return and the machine keeps running in the
 * wrong task, silently.
 *
 * This image REACHES that path, which nothing in verif/sys/ did: 0 NT returns across
 * 61 images. It exists so the gap is PROVEN reachable rather than inferred, and so the
 * implementation has something to be graded against when it is written.
 *
 * SETUP: TSS_A (0x18, base 0x3000) is the running task; its BACKLINK at offset 0 names
 * TSS_B (0x20, base 0x3100), a BUSY 32-bit TSS whose EIP points at nt_land. NT is then
 * set in EFLAGS and an IRET executed.
 *
 *   implemented   the switch happens -> nt_land runs -> ebp = 0x07000001
 *   TODAY         IRET ignores NT, pops the stack frame as an ordinary return, and
 *                 nt_land is never reached -> ebp keeps its pre-IRET value 0x07000000
 *
 * The core prints [VEN-NTRET] when it sees this, and run-unimpl-gate.sh counts that
 * across the corpus. THIS image is deliberately EXCLUDED from that sweep -- it is the
 * probe, so its count is 1 by construction; the sweep asserts that no ORDINARY test
 * reaches the path. Same split as pxc04* versus the seg gate's PAGING/C-0 sweep.
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

    /* --- GDT (7 entries = 56 bytes) at linear 0x0500 ---
     * idx0 null
     * idx1 0x08 code32 flat DPL0        access 0x9A gran 0xCF
     * idx2 0x10 data32 flat DPL0        access 0x92 gran 0xCF
     * idx3 0x18 code32 flat DPL3        access 0xFA gran 0xCF
     * idx4 0x20 data32 flat DPL3        access 0xF2 gran 0xCF
     * idx5 0x28 TSS32 available, base 0x3000, LIMIT 0x0007  <- TRUNCATED
     * idx6 0x30 code32 flat DPL3 CONFORMING  access 0xFE gran 0xCF
     *
     * idx6 is what makes the fault reportable: a #TS taken at CPL3 whose handler CS
     * is non-conforming DPL0 would itself be a cross-privilege delivery, would need
     * the same broken TSS, and would escalate instead of being observed. A conforming
     * DPL3 target keeps CPL=3 and pushes on the current stack.
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 code3 */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data3 */
    movl    $0x00CFF200, 36(%ebx)
    /* idx5 0x28 TSS_A: base 0x3000, limit 0x67, access 0x89 (AVAILABLE 32-bit TSS) */
    movl    $0x30000067, 40(%ebx)
    movl    $0x00008900, 44(%ebx)
    /* idx6 0x30 TSS_B: base 0x3100, limit 0x67, access 0x8B (BUSY -- it is the
     * suspended OUTER task an NT return goes back to, and a busy TSS is exactly what
     * a backlink names) */
    movl    $0x31000067, 48(%ebx)
    movl    $0x00008b00, 52(%ebx)
    /* NOTE: idx6 used to be written a SECOND time here as a conforming code segment,
     * left over from the image this test was derived from. It silently clobbered the
     * TSS_B descriptor above, so selector 0x30 was S=1 CODE, the core took the ordinary
     * far-jump path instead of the task-switch path, and the run ended with cs=0x0030 --
     * which reads exactly like "the NT return was ignored" and cost an implementation
     * round. The descriptor a backlink names must be a TSS. */

    movw    $0x0037, 0x0480             /* GDT limit = 56-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
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
    movl    $0x00090000, %esp

    /* ---- TSS_A @ 0x3000 (running) and TSS_B @ 0x3100 (the suspended outer task) ---
     * The field that matters is TSS_A's BACKLINK at offset 0: an NT return goes back
     * to the task it names. TSS_B needs enough state to be entered. */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    /* 128 dwords = 0x3000..0x31FF. 52 was WRONG: it stops at 0x30D0 and never reaches
     * TSS_B at 0x3100, so the switch read TSS_B's GPRs, selectors and LDTR out of
     * whatever was in memory. Symptom was #UD at pc=0x508 -- a garbage EIP -- which
     * looked like an RTL fault and was mine. */
    movl    $128, %ecx                  /* zero BOTH TSSes: 0x3000..0x31FF */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $0x00000030, 0x00003000     /* TSS_A.backlink = 0x30 (idx6 = TSS_B, BUSY) */
    movw    $0x0068, 0x00003066

    /* TSS_B: CR3@0x1C, EIP@0x20, EFLAGS@0x24, ESP@0x38, ES/CS/SS/DS@0x48/4C/50/54 */
    movl    %cr3,        %eax
    movl    %eax,        0x0000311C
    movl    $nt_land,    0x00003120
    movl    $0x00000002, 0x00003124
    movl    $0x00008000, 0x00003138
    movl    $0x00000010, 0x00003148
    movl    $0x00000008, 0x0000314C
    movl    $0x00000010, 0x00003150
    movl    $0x00000010, 0x00003154
    movw    $0x0068,     0x00003166

    movw    $0x0028, %ax
    ltr     %ax                         /* TR -> TSS_A */

    movl    $0x07000000, %ebp           /* witness: the NT return did NOT happen */

    /* Set EFLAGS.NT (bit 14) and IRET. With NT set, IA-32 makes this a TASK RETURN
     * through TSS_A's backlink and it does NOT pop a frame. This core never examines
     * NT, so it pops the frame below as an ordinary IRET, nt_land is never reached,
     * and ebp keeps 0x07000000. */
    pushfl
    orl     $0x00004000, (%esp)
    popfl

    pushl   $0x00000002
    pushl   $0x00000008
    pushl   $nt_fell_through
    iret

nt_fell_through:
    jmp     nt_exit                     /* today's behaviour: NT ignored */

nt_land:
    movl    $0x07000001, %ebp           /* only reachable via a real NT task return */

nt_exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
