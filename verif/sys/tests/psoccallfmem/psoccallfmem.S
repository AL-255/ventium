/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * psoccallfmem — memory-indirect far CALL (FF /3) regression: the mode split
 * between the real/V86 route (the far pointer's second word is a SEGMENT
 * VALUE, base = sel<<4, no descriptor table is involved) and the protected
 * route (selector bounded, descriptor probed and validated before the
 * return frame is committed). Fully differential vs the QEMU golden.
 *
 * Real-mode cases (the silicon-audit shape: SeaBIOS `lcall *0(%bp)` with a
 * stack-built option-ROM-style far pointer -- there C000:0003 -- into a
 * routine in another real segment). The far pointer here is 0x2000:0x0003,
 * NOT literal C000:0003: under the harness's QEMU machine the 0xC0000
 * option-ROM window is read-only shadow (guest writes are dropped, reads
 * return zeros -- probed via QMP), so a callee copied there cannot exist
 * for the oracle. Segment 0x2000 is plain RAM in both environments, and
 * the mechanism under test is identical: as a selector, 0x2000 names GDT
 * index 0x400, far past the limit, so a descriptor-table interpretation
 * faults exactly as 0xC000 would.
 *   R1  m16:16 via DS:SI        lcall *(%si)        -> 0x2000:0x0003
 *   R2  m16:16 via BP/SS        lcall *0(%bp)  (encoding FF 5E 00, pointer
 *                               built on the stack) -> 0x2000:0x0003
 *   R3  m16:32 (0x66 prefix)    lcall *(%si) with a 6-byte pointer
 *                               -> 0x2000:0x0070, 32-bit return frame
 *   R4  m16:16 top-of-stack wrap: SS=0x1000 SP=2 -- the CS push lands at
 *       offset 0x0000 and the IP push at 0xFFFE (wraps at 64 KiB); the ESP
 *       high half must survive
 *   R5  m16:32 wrap variant: SS=0x1000 ESP=...0004 -- CS dword at 0x0000,
 *       EIP dword at 0xFFFC
 *   R6  R2 repeated with IF=1: the IVT is installed, the PIC is present
 *       (unmasked out of reset) and the PIT free-runs, but its first IRQ0
 *       transition is ~27.5 ms of guest time out -- orders beyond the
 *       trace window -- so the run stays deterministic.
 * Every real-mode case enters CS=0x2000 (a DIFFERENT real segment), the
 * callee reads its return frame back through BP (making the pushed bytes
 * visible to the differential, which traces registers, not memory), lret's
 * back, and the caller proves exact CS/SP/ESP restoration plus the callee
 * hit count. A descriptor-table interpretation of 0x2000 (the defect this
 * regresses) faults #GP and dies in the IVT[13] fail exit.
 *
 * Protected-mode controls (the split must not bypass validation):
 *   P1  positive: m16:32 indirect far CALL through a valid code descriptor
 *       (0x18) still transfers, executes, and RETFs back.
 *   P2  negative: an indirect far CALL whose selector (0x0F00) lies beyond
 *       the GDT limit faults #GP with the bounded error code BEFORE any
 *       return-frame push (ESP unchanged across the delivery).
 *
 * V86 case (seg_real = real_mode || v86):
 *   V1  a V86 task (CS=0xF000, in-image) does the R2 stack-built m16:16
 *       shape and an m16:32 lcall *(%si); both must take the real-mode
 *       route. Return to the CPL0 monitor via INT 0x30 (IOPL=3, gate
 *       DPL=3), which grades the V86 witnesses and exits.
 *
 * Exit codes (out 0xF4): 0x42 pass. Per-case fail codes:
 *   R1 11 sp 12 cs 13 count 14 ret-IP 15 ret-CS        (R2: 21..25 same)
 *   R3 31 esp 32 cs 33 count 34 eip-lo 35 eip-hi 36 cs-lo 37 cs-hi
 *   R4 44 esp 45 frame-IP 46 frame-CS 47 count
 *   R5 54 esp 55 eip-lo 56 eip-hi 57 cs-lo 58 cs-hi 59 count
 *   R6 64 sp 65 cs 66 count 67 IF-lost
 *   P1 71 esp 72 target-never-ran 73 frame-CS 74 ret-EIP
 *   P2 78 no-#GP 79 wrong-err 7A esp-moved
 *   V1 81 sentinel (in-V86 check fails ride marker 0x2054: 82 sp 83 cs
 *      84 countA 85 countB)
 *   7C #SS  7D #GP  7E #UD (real-mode IVT fail exits; 7D also the V86-phase
 *   IDT[13] fail exit)
 *
 * Memory plan (NO paging; linear == physical): IVT @0, GDT @0x500 (code32
 * 0x08, data32 0x10, code32 0x18 = the P1 target, TSS32 0x20 base 0x3000),
 * IDT @0x1000, far pointers + markers @0x2000..0x213F, TSS @0x3000, PM
 * stack top 0x7000, monitor (TSS.SS0) stack top 0x8000, wrap-case stacks
 * in segment 0x1000 (phys 0x10000..0x1FFFF), V86 stack segment 0x2000,
 * callee blobs copied to 0x20000 (entry 0x2000:0x0003) and 0x20040, image at
 * 0xF0000. GNU-as; no nasm. Flat 64 KiB -bios image.
 */

.set IDT,   0x00001000

/* ============================ 16-bit entry =============================== */
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

    /* IVT @0: every vector -> the benign iret stub; the fault vectors then
     * get fail exits. A real-mode #GP from a misrouted far call must be
     * LOUD, not a wild EIP. */
    movw    $(iret_stub - _start16), %bx
    xorw    %di, %di
    movw    $256, %cx
1:  movw    %bx, %es:(%di)
    movw    $0xF000, %es:2(%di)
    addw    $4, %di
    loop    1b
    movw    $(rmfail_ud - _start16), %es:(6*4)
    movw    $(rmfail_ss - _start16), %es:(12*4)
    movw    $(rmfail_gp - _start16), %es:(13*4)

    /* zero the pointer/marker area 0x2000..0x2140 */
    movw    $0x2000, %di
    xorw    %ax, %ax
    movw    $160, %cx
1:  movw    %ax, %es:(%di)
    addw    $2, %di
    loop    1b

    /* copy the callee blob to 0x20000: pad + m16:16 callee (entry
     * 0x2000:0x0003), its wrap-return variant at +0x30, the m16:32
     * callee at +0x70, its wrap-return variant at +0xB0 */
    movw    $0xF000, %ax
    movw    %ax, %ds
    movw    $0x2000, %ax
    movw    %ax, %es
    movw    $(c000_blob - _start16), %si
    xorw    %di, %di
    movw    $(c000_blob_end - c000_blob), %cx
    rep movsb
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es

    /* ======================= R1: m16:16 via DS:SI ======================== */
    movw    $3, 0x2000                  /* ptr: off 3, seg 0x2000 */
    movw    $0x2000, 0x2002
    movw    0x210C, %bx                 /* callee-A count snapshot */
    movw    %sp, 0x2018
    movw    $0x2000, %si
    lcall   *(%si)
post_r1:
    cmpw    0x2018, %sp
    je      1f
    movl    $0x11, %edi
    jmp     rmfail
1:  movw    %cs, %ax
    cmpw    $0xF000, %ax
    je      2f
    movl    $0x12, %edi
    jmp     rmfail
2:  movw    0x210C, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      3f
    movl    $0x13, %edi
    jmp     rmfail
3:  movw    $(post_r1 - _start16), %ax  /* the return IP the callee saw */
    cmpw    %ax, 0x2104
    je      4f
    movl    $0x14, %edi
    jmp     rmfail
4:  cmpw    $0xF000, 0x2108             /* ... and the return CS */
    je      5f
    movl    $0x15, %edi
    jmp     rmfail
5:

    /* ======================= R2: m16:16 via BP (FF 5E 00) =============== */
    movw    0x210C, %bx
    movw    %sp, 0x2018
    pushw   $0x2000                     /* the stack-built far pointer */
    pushw   $3
    movw    %sp, %bp
    lcall   *0(%bp)
post_r2:
    addw    $4, %sp
    cmpw    0x2018, %sp
    je      1f
    movl    $0x21, %edi
    jmp     rmfail
1:  movw    %cs, %ax
    cmpw    $0xF000, %ax
    je      2f
    movl    $0x22, %edi
    jmp     rmfail
2:  movw    0x210C, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      3f
    movl    $0x23, %edi
    jmp     rmfail
3:  movw    $(post_r2 - _start16), %ax
    cmpw    %ax, 0x2104
    je      4f
    movl    $0x24, %edi
    jmp     rmfail
4:  cmpw    $0xF000, 0x2108
    je      5f
    movl    $0x25, %edi
    jmp     rmfail
5:

    /* ======================= R3: m16:32 (0x66 FF /3) ===================== */
    movl    $0x00000070, 0x2008         /* ptr: off32 0x70, seg 0x2000 */
    movw    $0x2000, 0x200C
    movw    0x2124, %bx                 /* callee-B count snapshot */
    movl    %esp, 0x201C
    movw    $0x2008, %si
    .byte   0x66
    lcall   *(%si)
post_r3:
    movl    0x201C, %eax
    cmpl    %eax, %esp
    je      1f
    movl    $0x31, %edi
    jmp     rmfail
1:  movw    %cs, %ax
    cmpw    $0xF000, %ax
    je      2f
    movl    $0x32, %edi
    jmp     rmfail
2:  movw    0x2124, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      3f
    movl    $0x33, %edi
    jmp     rmfail
3:  movw    $(post_r3 - _start16), %ax  /* 32-bit frame: return EIP low */
    cmpw    %ax, 0x2114
    je      4f
    movl    $0x34, %edi
    jmp     rmfail
4:  cmpw    $0, 0x2118                  /* return EIP high word */
    je      5f
    movl    $0x35, %edi
    jmp     rmfail
5:  cmpw    $0xF000, 0x211C             /* return CS low word */
    je      6f
    movl    $0x36, %edi
    jmp     rmfail
6:  cmpw    $0, 0x2120                  /* return CS high word */
    je      7f
    movl    $0x37, %edi
    jmp     rmfail
7:

    /* ======================= R4: m16:16 stack-top wrap ===================
     * SS=0x1000, ESP=0x11110002: the CS push lands at offset 0x0000 and the
     * IP push wraps to 0xFFFE. 16-bit stack ops must preserve ESP[31:16].
     * The callee (0x2000:0x0030) reads the split frame back through BP --
     * 16-bit effective addresses wrap, so [bp+2] reads offset 0x0000 -- and
     * returns via an indirect far JMP: the far-RETURN pop across the
     * boundary is a QEMU oracle gap (its A0 increment is not re-masked to
     * the 16-bit stack size), so the return leg is normalized on purpose. */
    movw    0x210C, %bx
    movw    $0x30, 0x2010                 /* ptr: off 0x30, seg 0x2000 */
    movw    $0x2000, 0x2012
    movw    $0x1000, %ax
    movw    %ax, %ss
    movl    $0x11110002, %esp
    movw    $0x2010, %si                  /* DS still 0 */
    lcall   *(%si)
post_r4:
    movl    $0x11110002, %eax
    cmpl    %eax, %esp
    je      1f
    movl    $0x44, %edi
    jmp     rmfail
1:  movw    $0x1000, %ax                /* read the wrapped frame back */
    movw    %ax, %es
    movw    $(post_r4 - _start16), %ax
    cmpw    %ax, %es:0xFFFE             /* return IP at the wrapped offset */
    je      2f
    movl    $0x45, %edi
    jmp     rmfail
2:  cmpw    $0xF000, %es:0x0000         /* return CS at offset 0x0000 */
    je      3f
    movl    $0x46, %edi
    jmp     rmfail
3:  xorw    %ax, %ax
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x7000, %esp
    movw    0x210C, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      4f
    movl    $0x47, %edi
    jmp     rmfail
4:

    /* ======================= R5: m16:32 stack-top wrap ===================
     * SS=0x1000, ESP=0x22220004: the CS dword lands at 0x0000, the EIP
     * dword wraps to 0xFFFC. Same normalized-return shape as R4. */
    movw    0x2124, %bx
    movl    $0x000000B0, 0x2030           /* ptr: off32 0xB0, seg 0x2000 */
    movw    $0x2000, 0x2034
    movw    $0x1000, %ax
    movw    %ax, %ss
    movl    $0x22220004, %esp
    movw    $0x2030, %si
    .byte   0x66
    lcall   *(%si)
post_r5:
    movl    $0x22220004, %eax
    cmpl    %eax, %esp
    je      1f
    movl    $0x54, %edi
    jmp     rmfail
1:  movw    $0x1000, %ax
    movw    %ax, %es
    movw    $(post_r5 - _start16), %ax
    cmpw    %ax, %es:0xFFFC             /* return EIP low at the wrap */
    je      2f
    movl    $0x55, %edi
    jmp     rmfail
2:  cmpw    $0, %es:0xFFFE              /* return EIP high */
    je      3f
    movl    $0x56, %edi
    jmp     rmfail
3:  cmpw    $0xF000, %es:0x0000         /* return CS low */
    je      4f
    movl    $0x57, %edi
    jmp     rmfail
4:  cmpw    $0, %es:0x0002              /* return CS high */
    je      5f
    movl    $0x58, %edi
    jmp     rmfail
5:  xorw    %ax, %ax
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x7000, %esp
    movw    0x2124, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      6f
    movl    $0x59, %edi
    jmp     rmfail
6:

    /* ======================= R6: IF=1 (PIC present, timer live) ==========
     * sti with the IVT installed; the PIT free-runs and the PIC is unmasked
     * out of reset, but the first IRQ0 transition is ~27.5 ms of guest time
     * out, far past this window, so nothing asynchronous lands. */
    sti
    movw    0x210C, %bx
    movw    %sp, 0x2018
    pushw   $0x2000
    pushw   $3
    movw    %sp, %bp
    lcall   *0(%bp)
post_r6:
    addw    $4, %sp
    cmpw    0x2018, %sp
    je      1f
    movl    $0x64, %edi
    jmp     rmfail
1:  movw    %cs, %ax
    cmpw    $0xF000, %ax
    je      2f
    movl    $0x65, %edi
    jmp     rmfail
2:  movw    0x210C, %ax
    subw    %bx, %ax
    cmpw    $1, %ax
    je      3f
    movl    $0x66, %edi
    jmp     rmfail
3:  pushf
    popw    %ax
    testw   $0x0200, %ax                /* IF survived the round trip */
    jne     4f
    movl    $0x67, %edi
    jmp     rmfail
4:  cli                                 /* the interrupt-enabled window ends
                                         * here: the PM/V86 phases run IF=0
                                         * (the harness's QEMU free-run has
                                         * no IDT entry for the timer vector) */

    /* ======================= enter protected mode =======================
     * GDT @ 0x500: null, 0x08 code32, 0x10 data32, 0x18 code32 (the P1
     * target segment), 0x20 TSS32 (base 0x3000). All flat base 0. */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508         /* 0x08 code32 */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510         /* 0x10 data32 */
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518         /* 0x18 code32 -- P1 target */
    movl    $0x00CF9A00, 0x051C
    movl    $0x30000067, 0x0520         /* 0x20 TSS32 avail, base 0x3000 */
    movl    $0x00008900, 0x0524
    movw    $0x0027, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

/* ============================ 32-bit body ================================ */
    .code32
    .section .text32, "ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00007000, %esp

    /* IDT @ 0x1000: zero all gates; 13 -> pm_gp_handler (DPL0), 0x30 ->
     * v86mon_handler (DPL3, the V86 task's way back to the monitor). */
    movl    $IDT, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $pm_gp_handler, %ebx
    movl    $(IDT + 13*8), %edi
    call    set_gate0
    movl    $v86mon_handler, %ebx
    movl    $(IDT + 0x30*8), %edi
    call    set_gate3
    movw    $0x07FF, 0x0490
    movl    $IDT, 0x0492
    lidt    0x0490

    /* ======================= P1: PM indirect far CALL, valid descriptor == */
    movl    $pm_ind_target, 0x2020      /* ptr: off32 target, sel 0x18 */
    movw    $0x0018, 0x2024
    movl    %esp, 0x201C
    lcall   *0x2020
post_p1:
    movl    0x201C, %eax
    cmpl    %eax, %esp
    je      1f
    movl    $0x71, %edi
    jmp     pmfail
1:  cmpl    $0x00000018, 0x2134         /* the target ran, and saw CS=0x18 */
    je      2f
    movl    $0x72, %edi
    jmp     pmfail
2:  cmpw    $0x0008, 0x213C             /* the frame's return CS word */
    je      3f
    movl    $0x73, %edi
    jmp     pmfail
3:  movl    $post_p1, %eax
    cmpl    %eax, 0x2138                /* the frame's return EIP */
    je      4f
    movl    $0x74, %edi
    jmp     pmfail
4:

    /* ======================= P2: PM indirect far CALL, bad selector ======
     * Selector 0x0F00 is past the GDT limit: the transfer must fault
     * #GP(0x0F00) BEFORE any return-frame push. */
    movl    $0xDEAD0000, 0x2028         /* ptr: off32 poison, sel 0x0F00 */
    movw    $0x0F00, 0x202C
    movl    %esp, 0x201C
    lcall   *0x2028
post_p2:                                /* the handler resumes us here */
    cmpl    $1, 0x2128                  /* exactly one #GP */
    je      1f
    movl    $0x78, %edi
    jmp     pmfail
1:  cmpl    $0x00000F00, 0x212C         /* err = sel & 0xFFFC */
    je      2f
    movl    $0x79, %edi
    jmp     pmfail
2:  movl    0x201C, %eax
    cmpl    %eax, 0x2130                /* ESP at the fault == pre-call ESP */
    je      3f
    movl    $0x7A, %edi
    jmp     pmfail
3:

    /* ======================= V1: V86-mode indirect far CALL ==============
     * TSS @0x3000 (SS0=0x10, ESP0=0x8000 monitor stack); IDT[13] becomes
     * the V86-phase fail exit; IRET into the in-image V86 task (CS=0xF000)
     * with VM=1, IOPL=3 (IF stays 0 -- see the R6 note). */
    movl    $0x3000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00008000, 0x3004         /* TSS.ESP0 */
    movl    $0x00000010, 0x3008         /* TSS.SS0 (word field, high zeroed) */
    movw    $0x20, %ax
    ltr     %ax

    movl    $v86gp_handler, %ebx        /* V86-phase #GP = loud fail */
    movl    $(IDT + 13*8), %edi
    call    set_gate0

    pushl   $0x00000000                 /* GS */
    pushl   $0x00000000                 /* FS */
    pushl   $0x00000000                 /* DS = 0 (marker area is direct) */
    pushl   $0x00000000                 /* ES = 0 */
    pushl   $0x00002000                 /* SS = 0x2000 */
    pushl   $0x00001000                 /* ESP = 0x1000 */
    pushl   $0x00023002                 /* EFLAGS: VM | IOPL=3 | bit1 */
    pushl   $0x0000F000                 /* CS = 0xF000 (in-image V86 task) */
    pushl   $v86_task_off               /* EIP = the task's image offset */
    iretl

    .align 16
    .global pm_ind_target
pm_ind_target:                          /* P1 target, entered via CS=0x18 */
    movw    %cs, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x2134
    movl    (%esp), %eax                /* the frame's return EIP */
    movl    %eax, 0x2138
    movzwl  4(%esp), %eax               /* the frame's return CS */
    movl    %eax, 0x213C
    lret                                /* 32-bit far return */

    .align 16
    .global pm_gp_handler
pm_gp_handler:                          /* P2: frame = err, EIP, CS, EFLAGS */
    incl    0x2128
    movl    (%esp), %eax
    movl    %eax, 0x212C                /* the error code */
    movl    %esp, %eax
    addl    $16, %eax                   /* ESP as the faulting insn saw it */
    movl    %eax, 0x2130
    addl    $6, 4(%esp)                 /* skip the 6-byte lcall *disp32 */
    addl    $4, %esp                    /* discard the error code */
    iretl

    .align 16
    .global v86mon_handler
v86mon_handler:                         /* INT 0x30 from the V86 task */
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    0x2054, %eax                /* in-V86 check fail code, if any */
    testl   %eax, %eax
    je      1f
    movl    %eax, %edi
    jmp     pmfail
1:  cmpl    $0x00860860, 0x2050         /* the V86 completion sentinel */
    je      2f
    movl    $0x81, %edi
    jmp     pmfail
2:  cmpl    $5, 0x210C                  /* callee A: R1,R2,R4,R6,V1 = 5 */
    je      3f
    movl    $0x84, %edi
    jmp     pmfail
3:  cmpl    $3, 0x2124                  /* callee B: R3,R5,V1 = 3 */
    je      4f
    movl    $0x85, %edi
    jmp     pmfail
4:  movl    $0x42, %edi                 /* PASS */
    jmp     pmfail

    .align 16
    .global v86gp_handler
v86gp_handler:                          /* a #GP in the V86 phase = fail */
    movl    $0x7D, %edi
    jmp     pmfail

    .align 16
    .global pmfail
pmfail:                                 /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

set_gate0:                              /* EBX = handler offset, EDI = gate */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, (%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    ret

set_gate3:                              /* same, DPL=3 (V86-callable) */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl    $0x00080000, %eax
    movl    %eax, (%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 4(%edi)
    ret

/* ============================ V86 task ===================================
 * Runs in the image at CS=0xF000 with VM=1: the same two indirect far-CALL
 * shapes the real-mode cases use. seg_real covers V86, so both must take
 * the real-mode route -- a descriptor-table interpretation of 0x2000 #GPs
 * into the V86-phase fail exit. */
    .code16
    .section .textv86, "ax"
    .global v86_task
v86_task:
    pushw   $0x2000                     /* the R2 stack-built shape */
    pushw   $3
    movw    %sp, %bp
    lcall   *0(%bp)
    addw    $4, %sp
    cmpw    $0x1000, %sp                /* the task's stack top was 0x1000 */
    je      1f
    movl    $0x82, %eax
    movl    %eax, 0x2054
    int     $0x30
1:  movw    %cs, %ax
    cmpw    $0xF000, %ax
    je      2f
    movl    $0x83, %eax
    movl    %eax, 0x2054
    int     $0x30
2:  movl    $0x00000070, 0x2040         /* m16:32 pointer: off 0x70, seg 0x2000 */
    movw    $0x2000, 0x2044
    movw    $0x2040, %si
    .byte   0x66
    lcall   *(%si)
    movl    $0x00860860, 0x2050         /* the completion sentinel */
    int     $0x30
9:  hlt                                 /* the monitor never returns here */
    jmp     9b

/* ============================ real-mode helpers ========================== */
    .code16
    .section .text16, "ax"
    .align 16
    .global iret_stub
iret_stub:                              /* every non-fail IVT vector */
    iret

    .align 16
rmfail_gp:
    movl    $0x7D, %edi
    jmp     rmfail
    .align 16
rmfail_ss:
    movl    $0x7C, %edi
    jmp     rmfail
    .align 16
rmfail_ud:
    movl    $0x7E, %edi
    jmp     rmfail
    .align 16
    .global rmfail
rmfail:                                 /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

/* ============================ callee blob ================================
 * Copied to 0x20000 at boot and entered via real far CALLs. Each callee
 * reads its return frame back through BP (the differential traces registers,
 * not memory -- this makes the pushed bytes visible) and counts its hits.
 * ES=0 in every caller, and the callees rely on it for the marker writes.
 * The blob is 16-aligned in the image, so the .align boundaries below hold
 * at the copy destination too.
 *   +0x03  c000_a   m16:16 callers, lret return        (the seg:0003 shape)
 *   +0x30  c000_a2  m16:16 wrap callers, normalized far-JMP return
 *   +0x70  c000_b   m16:32 callers, 32-bit lret return
 *   +0xB0  c000_b2  m16:32 wrap callers, normalized far-JMP return
 * The wrap variants return with an indirect far JMP through a scratch
 * pointer (0x2130 / 0x2134) after setting SP to the architecturally correct
 * post-return value: a far-RETURN pop across the 64 KiB boundary is a QEMU
 * oracle gap (the TCG A0 increment between the two pops is not re-masked to
 * the 16-bit stack size), so the boundary-crossing leg is the CALL's pushes
 * only, which both oracles wrap identically. */
    .align 16
    .global c000_blob
c000_blob:
    nop                                 /* entry pad: the seg:0003 shape */
    nop
    nop
c000_a:                                 /* m16:16 callers (frame: IP, CS) */
    movw    %sp, %bp
    pushw   %ax
    movw    $0, %ax
    movw    %ax, %es
    movw    %cs, %ax
    movw    %ax, %es:0x2100             /* the callee's CS (0x2000) */
    movw    (%bp), %ax
    movw    %ax, %es:0x2104             /* return IP off the stack */
    movw    2(%bp), %ax
    movw    %ax, %es:0x2108             /* return CS off the stack */
    incw    %es:0x210C
    popw    %ax
    lret

    .align 16
c000_a2:                                /* m16:16 wrap callers (+0x30) */
    movw    %sp, %bp
    pushw   %ax
    movw    $0, %ax
    movw    %ax, %es
    movw    %cs, %ax
    movw    %ax, %es:0x2100
    movw    (%bp), %ax
    movw    %ax, %es:0x2104
    movw    2(%bp), %ax
    movw    %ax, %es:0x2108
    incw    %es:0x210C
    movw    (%bp), %ax                  /* scratch return pointer: */
    movw    %ax, %es:0x2130             /*   off = the frame's return IP */
    movw    2(%bp), %ax
    movw    %ax, %es:0x2132             /*   seg = the frame's return CS */
    popw    %ax
    movw    $2, %sp                     /* the post-return SP (wrap: 2) */
    ljmp    *0x2130                     /* m16:16 indirect far JMP home */

    .align 16
c000_b:                                 /* m16:32 callers (+0x70, frame: EIP, CS dwords) */
    movw    %sp, %bp
    pushw   %ax
    movw    $0, %ax
    movw    %ax, %es
    movw    %cs, %ax
    movw    %ax, %es:0x2110
    movw    (%bp), %ax
    movw    %ax, %es:0x2114             /* return EIP low */
    movw    2(%bp), %ax
    movw    %ax, %es:0x2118             /* return EIP high */
    movw    4(%bp), %ax
    movw    %ax, %es:0x211C             /* return CS low */
    movw    6(%bp), %ax
    movw    %ax, %es:0x2120             /* return CS high */
    incw    %es:0x2124
    popw    %ax
    .byte   0x66                        /* 32-bit far return (pop EIP, CS) */
    lret

    .align 16
c000_b2:                                /* m16:32 wrap callers (+0xB0) */
    movw    %sp, %bp
    pushw   %ax
    movw    $0, %ax
    movw    %ax, %es
    movw    %cs, %ax
    movw    %ax, %es:0x2110
    movw    (%bp), %ax
    movw    %ax, %es:0x2114
    movw    2(%bp), %ax
    movw    %ax, %es:0x2118
    movw    4(%bp), %ax
    movw    %ax, %es:0x211C
    movw    6(%bp), %ax
    movw    %ax, %es:0x2120
    incw    %es:0x2124
    movw    (%bp), %ax                  /* scratch m16:32 return pointer: */
    movw    %ax, %es:0x2134             /*   off32 low */
    movw    2(%bp), %ax
    movw    %ax, %es:0x2136             /*   off32 high */
    movw    4(%bp), %ax
    movw    %ax, %es:0x2138             /*   seg16 */
    popw    %ax
    movw    $4, %sp                     /* the post-return SP (wrap: 4) */
    .byte   0x66
    ljmp    *0x2134                     /* m16:32 indirect far JMP home */
    .global c000_blob_end
c000_blob_end:

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
