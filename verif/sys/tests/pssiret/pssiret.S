/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* pssiret — REVIEW_aug2 C-07: an inter-privilege IRET must VALIDATE the outer SS,
 * and must commit NOTHING until it has.
 *
 * WHAT WAS WRONG
 * --------------
 * An inter-privilege IRET committed its frame in three places, in the order the
 * bytes happened to arrive off the bus:
 *      S_IRET beat 4    -> EIP, EFLAGS   (+ ESP from the gpr writeback driver)
 *      S_INT_CS_RET     -> CS, CPL
 *      S_IRET_SS        -> SS  (base/limit/attr installed with NO checks at all)
 * So a frame naming an unusable SS had already redirected EIP, replaced EFLAGS
 * and *lowered CPL* before anything looked at the stack selector. Worse, the SS
 * install had no validation whatsoever: any descriptor the frame named became the
 * stack segment -- a read-only one, a CPL0 one, a not-present one, a code segment.
 *
 * WHAT THIS TEST GRADES
 * ---------------------
 * Three malformed frames, each of which must raise a fault BEFORE any part of the
 * frame commits, and one well-formed frame that must still work:
 *
 *   case A   SS -> a DPL3 READ-ONLY data descriptor      => #GP(0x30)
 *   case B   SS -> a DPL0 writable descriptor, RPL3      => #GP(0x38)   (DPL != CPL)
 *   case C   SS -> a DPL3 writable but NOT-PRESENT one   => #SS(0x40)  [see ORACLE GAP]
 *   case D   SS -> the good DPL3 stack                   => returns to CPL3, exits
 *
 * The interesting evidence is not "a fault happened" -- it is the CONTENT of the
 * fault frame, because that is what distinguishes "rejected the frame" from
 * "committed the frame and then noticed":
 *
 *   saved CS  must be 0x08  (the CPL0 code segment).  If CS had committed it would
 *             be 0x1B and the fault would have been delivered FROM CPL3.
 *   handler SS/ESP must be the CPL0 boot stack (SS=0x10, ESP ~0x0008FFxx).  A fault
 *             taken at CPL3 is a CROSS-privilege delivery and would run on the TSS
 *             stack at ~0x00088000 instead.  These two ranges do not overlap, so
 *             the handler's own ESP alone decides whether CPL had already dropped.
 *   saved EFLAGS must have IF=0 (the mainline runs under CLI).  Every frame below
 *             sets IF in its PUSHED image, so IF=1 in the saved EFLAGS would mean
 *             EFLAGS had already committed.
 *   saved EIP must point at the faulting IRET (0x000Fxxxx), not at user_entry.
 *
 * All four are recorded per case and checked in sys_exit.
 *
 * ORACLE: unlike pseglim (segment limits, which QEMU does not enforce), QEMU DOES
 * implement the IRET SS checks -- helper_ret_protected() in target/i386/tcg/
 * seg_helper.c validates the selector, RPL, writability, DPL and presence, in that
 * order, before loading anything, and raises the fault with (sel & 0xfffc). So this
 * test is graded DIFFERENTIALLY against the golden, and the golden also pins the
 * fault-frame contents above.
 *
 * ORACLE GAP (measured 2026-08-02, qemu-system-i386 10.2.1): for the NOT-PRESENT
 * stack segment QEMU raises #NP (vector 11), not #SS (vector 12):
 *     seg_helper.c helper_ret_protected():
 *         if (!(ss_e2 & DESC_P_MASK)) {
 *             raise_exception_err_ra(env, EXCP0B_NOSEG, new_ss & 0xfffc, retaddr);
 *         }
 *     observed: `1: v=0b e=0040 i=0 cpl=0 IP=0008:...`
 * The SDM is unambiguous the other way -- Vol.2A IRET, RETURN-TO-OUTER-PRIVILEGE-
 * LEVEL: "IF stack segment is not present THEN #SS(SS selector)", and Vol.3A 6.15
 * lists "RET or IRET to a different privilege level" under #SS. Ventium follows the
 * SDM. To keep case C differentially gradable in spite of that, vectors 11 and 12
 * share one IDT entry (below), so both oracles run an identical instruction stream;
 * the vector number itself is graded against the RTL fault log by the runner.
 *
 * Layout follows pcpl (same bootstrap, same -bios image shape):
 *   GDT  @ 0x0500   10 entries (see build_gdt below)
 *   IDT  @ 0x1000   vectors 12 (#SS), 13 (#GP) DPL0; vector 0x40 DPL3 (exit syscall)
 *   markers @ 0x2000
 *   TSS  @ 0x3000   SS0=0x10, ESP0=0x00088000
 *   CPL0 boot stack @ 0x00090000 ; CPL3 user stack @ 0x00080000
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

    /* --- build the GDT (10 entries = 80 bytes) at linear 0x0500 ---
     * idx0        null
     * idx1  0x08  code32 flat DPL0        access 0x9A gran 0xCF
     * idx2  0x10  data32 flat DPL0 W      access 0x92 gran 0xCF
     * idx3  0x18  code32 flat DPL3        access 0xFA gran 0xCF
     * idx4  0x20  data32 flat DPL3 W      access 0xF2 gran 0xCF   <- the GOOD SS
     * idx5  0x28  TSS32 base 0x3000 lim 0x67  access 0x89 gran 0x00
     * idx6  0x30  data32 flat DPL3 READ-ONLY  access 0xF0 gran 0xCF  <- BAD (not W)
     * idx7  0x38  data32 flat DPL0 W          access 0x92 gran 0xCF  <- BAD (DPL0)
     * idx8  0x40  data32 flat DPL3 W, P=0     access 0x72 gran 0xCF  <- BAD (P=0)
     * idx9  0x48  data32 flat DPL3 W          access 0xF2 gran 0xCF  (spare)
     *
     * Access byte = P(7) DPL(6:5) S(4) type(3:0); for data type = 0,E,W,A.
     *   0xF0 = P|DPL3|S|type 0000 -> data, expand-up, READ-ONLY   (W bit clear)
     *   0x72 = P=0|DPL3|S|type 0010 -> data, writable, NOT PRESENT
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 code3 (DPL3) */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data3 (DPL3, writable) */
    movl    $0x00CFF200, 36(%ebx)
    movl    $0x30000067, 40(%ebx)       /* idx5 0x28 TSS32: limit 0x0067, base[15:0]=0x3000 */
    movl    $0x00008900, 44(%ebx)       /*      base[23:16]=0, access 0x89, gran 0, base[31:24]=0 */
    movl    $0x0000FFFF, 48(%ebx)       /* idx6 0x30 data3 READ-ONLY */
    movl    $0x00CFF000, 52(%ebx)
    movl    $0x0000FFFF, 56(%ebx)       /* idx7 0x38 data0 writable (DPL0) */
    movl    $0x00CF9200, 60(%ebx)
    movl    $0x0000FFFF, 64(%ebx)       /* idx8 0x40 data3 writable, NOT PRESENT */
    movl    $0x00CF7200, 68(%ebx)
    movl    $0x0000FFFF, 72(%ebx)       /* idx9 0x48 data3 writable (spare) */
    movl    $0x00CFF200, 76(%ebx)

    movw    $0x004F, 0x0480             /* GDT limit = 80-1 = 0x4F (10 entries) */
    movl    $0x00000500, 0x0482         /* GDT base  = 0x0500 */
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
    movl    $0x00090000, %esp           /* CPL0 boot/main stack */

    /* zero the marker area 0x2000..0x2100 (64 dwords) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $64, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- TSS @ 0x3000: SS0=0x10, ESP0=0x00088000 ---- */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00003004     /* ESP0 */
    movl    $0x00000010, 0x00003008     /* SS0  */
    movw    $0x0068, 0x00003066         /* I/O map base = limit+1 => empty map */
    movw    $0x0028, %ax
    ltr     %ax

    /* ---- IDT @ 0x1000 ----
     * vectors 11 (#NP) and 12 (#SS) -> stk_handler  attr 0x8E (32-bit int gate, DPL0)
     * vector 13 (#GP) -> gp_handler   attr 0x8E
     * vector 0x40     -> sys_exit     attr 0xEE (DPL3: reachable from CPL3)
     * All target CS 0x08. */
    /* ORACLE GAP (measured, see the header): vectors 11 and 12 share ONE entry.
     * The SDM requires #SS(12) for a not-present stack segment on an outer-level
     * IRET; QEMU raises #NP(11) instead (seg_helper.c helper_ret_protected: the
     * final `if (!(ss_e2 & DESC_P_MASK)) raise ... EXCP0B_NOSEG`). Pointing both
     * gates at the same handler makes the two oracles execute a byte-identical
     * instruction stream -- same error code, same frame, same handler -- so case C
     * stays DIFFERENTIALLY graded for everything C-07 actually claims, and the
     * vector number itself is graded separately against the RTL fault log. */
    movl    $stk_handler, %ebx
    movl    $0x00001058, %edi           /* 0x1000 + 11*8  (#NP -- QEMU's choice) */
    call    set_gate0
    movl    $stk_handler, %ebx
    movl    $0x00001060, %edi           /* 0x1000 + 12*8  (#SS -- the SDM's) */
    call    set_gate0
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 */
    call    set_gate0
    movl    $sys_exit, %ebx
    movl    $0x00001200, %edi           /* 0x1000 + 0x40*8 */
    call    set_gate3

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ============================ CASE A ================================
     * SS = 0x33 (idx6 RPL3) = a DPL3 READ-ONLY data descriptor.
     * A stack segment must be writable => #GP(0x30).                       */
    movl    $caseB, 0x00002080          /* where the fault handler resumes */
    movl    $0x00000030, 0x00002084     /* the error code we expect */
    pushl   $0x00000033                 /* SS  (idx6, RPL3) -- read-only */
    pushl   $0x00080000                 /* ESP */
    pushfl
    orl     $0x00000200, (%esp)         /* set IF in the PUSHED image only */
    pushl   $0x0000001B                 /* CS  (code3, RPL3) */
    pushl   $user_entry                 /* EIP */
    iret                                /* must #GP(0x30) with NOTHING committed */

    /* ============================ CASE B ================================
     * SS = 0x3B (idx7 RPL3) = a writable data descriptor with DPL 0.
     * On an outer return SS.DPL must equal the new CPL (3) => #GP(0x38).    */
    .align 16
caseB:
    movl    $caseC, 0x00002080
    movl    $0x00000038, 0x00002084
    pushl   $0x0000003B                 /* SS  (idx7, RPL3) -- DPL0 */
    pushl   $0x00080000
    pushfl
    orl     $0x00000200, (%esp)
    pushl   $0x0000001B
    pushl   $user_entry
    iret                                /* must #GP(0x38) */

    /* ============================ CASE C ================================
     * SS = 0x43 (idx8 RPL3) = writable DPL3 but P=0 => #SS(0x40), not #GP.  */
    .align 16
caseC:
    movl    $caseD, 0x00002080
    movl    $0x00000040, 0x00002084
    pushl   $0x00000043                 /* SS  (idx8, RPL3) -- not present */
    pushl   $0x00080000
    pushfl
    orl     $0x00000200, (%esp)
    pushl   $0x0000001B
    pushl   $user_entry
    iret                                /* must #SS(0x40) */

    /* ============================ CASE D ================================
     * The WELL-FORMED frame: SS = 0x23 (idx4 RPL3), a present writable DPL3
     * stack.  This must succeed exactly as it did before -- the point of the
     * three cases above is that they are rejected, not that IRET stops working.
     */
    .align 16
caseD:
    movl    $0xD0D0D0D0, 0x00002088     /* "reached case D" */
    pushl   $0x00000023                 /* SS  (idx4, RPL3) -- the good stack */
    pushl   $0x00080000
    pushfl
    orl     $0x00000200, (%esp)
    pushl   $0x0000001B
    pushl   $user_entry
    iret                                /* -> CPL3 at user_entry */

hang0:
    jmp     hang0

    /* ---- IDT gate builders (EBX = handler offset, EDI = gate slot) ---- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret
set_gate3:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax           /* P, DPL3, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    /* ============================ CPL3 USER TASK ======================== */
    .align 16
    .global user_entry
user_entry:
    movw    $0x0023, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movl    $0xC3C3C3C3, 0x0000208C     /* "CPL3 reached" (only case D may set this) */
    xorl    %eax, %eax
    movw    %ss, %ax
    movl    %eax, 0x00002090            /* user SS (expect 0x0023) */
    int     $0x40                       /* trap to CPL0 to report + exit */
uhang:
    jmp     uhang

    /* ============================== HANDLERS =============================
     * gp_handler / ss_handler — SAME-PRIVILEGE delivery (the faulting IRET runs
     * at CPL0 and, if C-07 holds, CPL is still 0 when the fault is raised), so
     * the frame is 4 words and NO stack switch happens:
     *   [esp+ 0] error code   [esp+ 4] EIP   [esp+ 8] CS   [esp+12] EFLAGS
     * Each handler records the frame + its own SS:ESP into a per-case slot, then
     * resumes the mainline at the address the mainline staged at 0x2080.
     *
     * If the frame had been committed before the fault (the C-07 defect), CPL
     * would already be 3 and this would instead be a CROSS-privilege delivery on
     * the TSS stack at ~0x00088000 with a 5-word frame -- which the recorded
     * handler ESP and saved CS below both detect.                             */
    .align 16
    .global gp_handler
gp_handler:
    movl    $13, 0x00002094             /* last vector = #GP */
    jmp     fault_common
    .align 16
    .global stk_handler
stk_handler:
    movl    $0x00000B0C, 0x00002094     /* the not-present-SS path (11 or 12; see above) */
    jmp     fault_common

    .align 16
fault_common:
    pushl   %eax
    pushl   %ebx
    /* frame fields are now at +8 (two pushes) */
    movl    0x08(%esp), %eax            /* error code */
    movl    %eax, 0x00002098
    movl    0x0C(%esp), %eax            /* saved EIP */
    movl    %eax, 0x0000209C
    movl    0x10(%esp), %eax            /* saved CS  -- must be 0x08, NOT 0x1B */
    movl    %eax, 0x000020A0
    movl    0x14(%esp), %eax            /* saved EFLAGS -- IF must be 0 */
    movl    %eax, 0x000020A4
    movl    %esp, %eax                  /* handler ESP -- must be ~0x0008FFxx, */
    movl    %eax, 0x000020A8            /*  NOT the TSS stack near 0x00088000  */
    xorl    %eax, %eax
    movw    %ss, %ax
    movl    %eax, 0x000020AC            /* handler SS -- must be 0x0010 */

    /* accumulate the pass/fail evidence across all three cases:
     *   0x20B0 = fault count
     *   0x20B4 = count of faults whose error code matched the expected one
     *   0x20B8 = count of faults that arrived with NOTHING committed
     *            (saved CS == 0x08 AND saved EFLAGS.IF == 0 AND handler SS == 0x10
     *             AND handler ESP >= 0x0008F000, i.e. the CPL0 boot stack)      */
    incl    0x000020B0
    movl    0x00002098, %eax
    cmpl    0x00002084, %eax
    jne     1f
    incl    0x000020B4
1:
    movl    0x000020A0, %eax            /* saved CS */
    cmpl    $0x00000008, %eax
    jne     2f
    movl    0x000020A4, %eax            /* saved EFLAGS */
    testl   $0x00000200, %eax           /* IF must be CLEAR */
    jnz     2f
    movl    0x000020AC, %eax            /* handler SS */
    cmpl    $0x00000010, %eax
    jne     2f
    movl    0x000020A8, %eax            /* handler ESP -- CPL0 boot stack? */
    cmpl    $0x0008F000, %eax
    jb      2f
    incl    0x000020B8
2:
    /* resume the mainline at the staged address; drop the error code. */
    movl    0x00002080, %eax
    movl    %eax, 0x0C(%esp)            /* overwrite the saved EIP */
    popl    %ebx
    popl    %eax
    addl    $4, %esp                    /* discard the error code */
    iret

    /* sys_exit — the CPL0 "syscall" the CPL3 task traps into (INT 0x40) to
     * report and perform the isa-debug-exit.  Reached CROSS-privilege from CPL3,
     * so this delivery DOES switch to the TSS stack -- which is the control
     * proving the handler-ESP discriminator above is meaningful.               */
    .align 16
    .global sys_exit
sys_exit:
    movl    0x000020B0, %ebp            /* EBP = faults taken            (want 3) */
    movl    0x000020B4, %ebx            /* EBX = error codes correct     (want 3) */
    movl    0x000020B8, %ecx            /* ECX = frames NOT pre-committed(want 3) */
    movl    0x0000208C, %edx            /* EDX = CPL3 reached sentinel (0xC3C3C3C3) */
    movl    0x00002090, %esi            /* ESI = user SS               (want 0x23) */
    movl    0x00002094, %edi            /* EDI = last fault path (want 0x0B0C = the
                                         *  not-present-SS handler, i.e. case C did NOT
                                         *  come through #GP) */

    movl    $0x42, %eax                 /* isa-debug-exit -> qemu status 133 */
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
