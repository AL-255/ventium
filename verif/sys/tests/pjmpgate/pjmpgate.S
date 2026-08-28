/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 C-04 — far JMP vs far CALL through a CALL GATE.
 *
 * The defect: the call-gate resolver sets gate_via for BOTH far JMP and far
 * CALL, and the cross-privilege branch checked only
 * `gate_via && target_DPL < CPL` -- never lcall_pend. A far JMP through a call
 * gate to a MORE privileged NONCONFORMING code segment therefore entered the
 * CALL stack-switch path and pushed a return frame. IA-32 forbids a JMP from
 * raising privilege through a call gate: it must raise #GP(gate selector).
 * (A CONFORMING target is not a privilege change at all: both JMP and CALL to
 * it keep CPL.)
 *
 * Three cases in one image, all from CPL3, all differential against the QEMU
 * golden:
 *
 *   (a) ljmp  through gate 0x28 (DPL 3) -> target 0x08 (code32 DPL 0,
 *       NONCONFORMING): must raise #GP(0x28). The #GP handler records the
 *       vector (13) and the error code (0x28 & 0xFFFC = the GATE selector),
 *       skips the 7-byte ljmp, and IRETs back to ring 3.
 *       With the defect the JMP wrongly enters the CALL path: no #GP, a frame
 *       is pushed, and k0_entry runs -- observably different from the first
 *       record on.
 *   (b) lcall through the SAME gate 0x28 -> the same target: SUCCEEDS. Stack
 *       switches to TSS.SS0:ESP0, k0_entry runs at CPL0 (witness: SS == 0x10,
 *       the TSS stack segment, and the caller's ESP recovered from the gate
 *       frame), then lret returns to ring 3 through the pushed frame.
 *   (c) ljmp  through gate 0x30 (DPL 3) -> target 0x38 (code32 DPL 0,
 *       CONFORMING): SUCCEEDS and CPL is KEPT at 3 (conforming is not a
 *       privilege change for JMP or CALL). conf_entry proves CPL: CS.RPL reads
 *       back 3 (the selector is loaded as 0x38|3 = 0x3B) and the exit OUT to
 *       0xF4 only works because IOPL==3 at CPL==3.
 *
 * Memory plan (NO paging -- the JMP/CALL intent defect is paging-independent;
 * C-02's paged variants are ptaskpg/pretfoutpg):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + code3 0x18 + data3 0x20
 *                       + callgate_nonconf 0x28 + callgate_conf 0x30
 *                       + code0_conforming 0x38 + TSS 0x40
 *   IDT  @ 0x00001000   gate 13 (#GP) -> gp_handler (interrupt gate, CPL0)
 *   markers @ 0x00002000
 *   TSS  @ 0x00004000   SS0=0x10 ESP0=0x6000
 *   ring0 stack 0x7000, ring3 stack 0x5000, TSS0 stack 0x6000
 *
 * WITNESSES (marker page, pulled into GPRs at the exit for the differential):
 *   0x2000  0x0000000D -- the #GP vector the handler saw (case a fired)
 *   0x2004  error code & 0xFFFC == 0x0008 -- the fault names the TARGET code
 *           selector (QEMU/SDM behaviour; the gate resolver had already
 *           substituted it by the time the fault is raised)
 *   0x2008  k0_entry's SS == 0x0010 -- case (b) switched to the TSS stack
 *           (read into EBP at the exit: the out sequence clobbers EAX/DX)
 *   0x200C  caller ESP recovered from the gate frame at 8(%esp) == the ring-3
 *           stack pointer at the lcall (0x5000-ish)
 *   0x2010  0x00000003 -- conf_entry's CS.RPL: CPL KEPT at 3 across the JMP
 *           through the gate to the conforming segment
 *   0x2014  0xBBBBBBBB -- case (b) returned to ring 3 via the pushed frame
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

    /* GDT at 0x0500 (9 entries, limit 0x47):
     *   0x08 code0 nonconforming (0x9A)   0x10 data0 (0x92)
     *   0x18 code3 nonconforming (0xFA)   0x20 data3 (0xF2)
     *   0x28 call gate -> 0x08 (built in pm_entry: needs a 32-bit label)
     *   0x30 call gate -> 0x38 (built in pm_entry)
     *   0x38 code0 CONFORMING (0x9E)      0x40 TSS (built in pm_entry) */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 nonconforming */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code32 DPL3 -> 0x1B */
    movl    $0x00cffa00, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data32 DPL3 -> 0x23 */
    movl    $0x00cff200, 0x0524
    /* 0x38 code32 DPL0 CONFORMING: access 0x9E (P|S|type 0xE), gran 0xCF */
    movl    $0x0000ffff, 0x0538
    movl    $0x00cf9e00, 0x053c

    movw    $0x0047, 0x0480            /* GDT limit = 9*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
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

    /* ---- zero the marker area 0x2000..0x2020 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $8, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: gate 13 (#GP) -> gp_handler, interrupt gate CPL0 ----
     * low = {sel 0x08}<<16 | off[15:0]; high = off[31:16] | 0x8E00 (P|int32). */
    movl    $gp_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1068               /* 0x1000 + 13*8 */
    movl    $gp_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax
    movl    %eax, 0x106c
    movw    $0x07FF, 0x0490            /* IDT limit */
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- GDT[5] = 0x28: CALL GATE -> 0x08 (NONCONFORMING DPL0 code), DPL 3,
     * param count 0 ---- */
    movl    $k0_entry, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0528
    movl    $k0_entry, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec00, %eax          /* P|DPL3|type 0xC, param count 0 */
    movl    %eax, 0x052c

    /* ---- GDT[6] = 0x30: CALL GATE -> 0x38 (CONFORMING DPL0 code), DPL 3 ---- */
    movl    $conf_entry, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00380000, %eax
    movl    %eax, 0x0530
    movl    $conf_entry, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec00, %eax
    movl    %eax, 0x0534

    /* ---- GDT[8] = 0x40: 32-bit TSS, base 0x4000, limit 0x67, access 0x89 --- */
    movl    $0x40000067, 0x0540
    movl    $0x00008900, 0x0544

    /* ---- TSS at 0x4000: SS0=0x10, ESP0=0x6000, empty I/O map ---- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006000, 0x00004004    /* ESP0 */
    movl    $0x00000010, 0x00004008    /* SS0  */
    movw    $0x0068,     0x00004066

    movw    $0x0040, %ax
    ltr     %ax

    /* IOPL = 3 so the ring-3 legs may drive port 0xF4. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    /* ---- out to ring 3 via the OUTER RETF (pretfout's mechanism) ---------- */
    pushl   $0x00000023                /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00005000                /* ESP = the ring-3 stack */
    pushl   $0x0000001B                /* CS  = ring-3 code, RPL 3 */
    pushl   $r3_entry                  /* EIP */
    lret

    /* ============================ ring 3 ================================== */
    .global r3_entry
r3_entry:
    /* The outer RETF NULLED DS/ES/FS/GS (DPL 0 < new CPL 3 -- both oracles do
     * this; the golden shows ds=0 in ring 3). Reload DS with the ring-3 data
     * selector before ANY data access: a null-DS store is architecturally
     * #GP-worthy and the VEN_SEG_ENFORCE build (make seg) rightly rejects it. */
    movw    $0x23, %ax
    movw    %ax, %ds
    /* ---- case (a): far JMP through gate 0x28 to a MORE privileged
     * NONCONFORMING target -> must raise #GP(0x28). Hand-encoded ljmp
     * ptr16:32 (7 bytes; the #GP handler skips exactly this length).     */
    .byte   0xEA
    .long   0                          /* offset ignored for a gate */
    .word   0x002B                     /* gate 0x28 | RPL 3 */
    /* the handler resumes HERE (it advanced the saved EIP by 7) */

    /* ---- case (b): far CALL through the SAME gate -> SUCCEEDS: stack
     * switch to TSS.SS0:ESP0, k0_entry runs at CPL0, lret returns here. ---- */
    .byte   0x9A
    .long   0
    .word   0x002B

    /* the lret that returned here NULLED DS again (DPL 0 < CPL 3) -- reload */
    movw    $0x23, %ax
    movw    %ax, %ds
    movl    $0xBBBBBBBB, 0x00002014    /* "case (b) returned to ring 3" */

    /* ---- case (c): far JMP through gate 0x30 to a MORE privileged
     * CONFORMING target -> SUCCEEDS, CPL KEPT (conf_entry exits). -------- */
    .byte   0xEA
    .long   0
    .word   0x0033                     /* gate 0x30 | RPL 3 */

    /* unreachable (conf_entry exits) */
    movl    $0xDEAD0001, 0x00002018
9:  jmp     9b

    /* ============================ CPL0 callee (case b) ==================== */
    .global k0_entry
k0_entry:
    /* CPL 0 on the TSS stack; DS is still the nulled ring-0-before value --
     * reload it (see r3_entry).
     * Gate frame with param count 0:
     *   0(%esp) = return EIP   4(%esp) = return CS
     *   8(%esp) = caller ESP  12(%esp) = caller SS                          */
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %ss, %eax
    andl    $0x0000ffff, %eax
    movl    %eax, 0x00002008           /* expect 0x10 (SS0: the TSS stack) */
    movl    8(%esp), %eax
    movl    %eax, 0x0000200C           /* caller ESP from the frame (~0x5000) */
    lret                               /* back to ring 3 via the pushed frame */

    /* ===================== conforming target (case c) ===================== */
    .global conf_entry
conf_entry:
    /* Reached by a JMP through the gate: the target is CONFORMING, so CPL is
     * KEPT at 3 -- CS was loaded as 0x38|CPL = 0x3B. Read it back. DS is
     * still null here (never reloaded after the outer RETF); reload 0x23.   */
    movw    $0x23, %ax
    movw    %ax, %ds
    movl    %cs, %eax
    andl    $0x00000003, %eax          /* CS.RPL = the kept CPL */
    movl    %eax, 0x00002010           /* expect 3 */

    /* exit: pull the witnesses into the GPRs for the final-record compare.
     * NOTE: the exit sequence itself clobbers EAX (0x42) and DX (0xF4), so no
     * 32-bit witness may live in edx at the out -- ebp carries the SS one.   */
    movl    0x00002000, %edi           /* #GP vector (13) */
    movl    0x00002004, %esi           /* #GP error code & 0xFFFC (0x08) */
    movl    0x00002008, %ebp           /* k0_entry SS (0x10) */
    movl    0x0000200C, %ecx           /* caller ESP from the gate frame */
    movl    0x00002014, %ebx           /* 0xBBBBBBBB (case b returned) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                   /* works only because CPL==IOPL==3 */
9:  jmp     9b

    /* ============================ #GP handler ============================= */
    .global gp_handler
gp_handler:
    /* #GP frame (cross-priv, CPL3->0): 0(%esp)=err 4=EIP 8=CS 12=EFLAGS
     * 16=ESP 20=SS. Record the vector + the error code, skip the 7-byte
     * ljmp (case a), IRET back to ring 3. DS is null on entry (the outer
     * RETF nulled it) -- reload the ring-0 data selector before storing.    */
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    $0x0000000D, 0x00002000    /* vector 13 */
    movl    (%esp), %eax
    andl    $0x0000fffc, %eax
    movl    %eax, 0x00002004           /* expect 0x08 (the TARGET selector --
                                        * QEMU and the SDM name the target
                                        * code segment, not the gate) */
    addl    $7, 4(%esp)                /* resume past the ljmp */
    addl    $4, %esp                   /* pop the error code */
    iretl

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
