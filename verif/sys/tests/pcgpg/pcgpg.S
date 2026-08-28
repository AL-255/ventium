/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-H05 (image 3 of 3) — the PAGED forms: call-gate parameter
 * copy across PAGE BOUNDARIES (the fx fragment engine + S_INT_PROBE + the
 * S_CG_PRD source reads) and the OLD-CONTEXT fault cases. Differential vs
 * the QEMU golden (helper_lcall_protected + the pxprobe-measured "QEMU
 * unwinds a half-done stack switch and faults in the OLD context").
 *
 * Paged protected mode, 4 KiB pages, identity map [0,1MiB) P|RW|US. All four
 * phases use a 32-bit call gate (type 0xC, DPL 3) with param count 2 from a
 * CPL3 caller to a CPL0 callee (frame = 16 + 4*2 = 24 bytes):
 *
 *   phase A: DESTINATION frame straddles a page boundary WITHIN one push
 *     beat: TSS.ESP0 = 0x8100E (unaligned), frame [0x80FF6,0x8100D]; the
 *     param[0] push at 0x80FFE spans pages 0x80/0x81 (fx split write). Both
 *     pages present: the transfer completes, the callee verifies every frame
 *     slot via flat absolute reads and returns with `lret $8`.
 *   phase B: parameter SOURCE straddles: caller ESP = 0x70FFE, so S_CG_PRD's
 *     param[0] read at 0x70FFE spans pages 0x70/0x71 (fx split read, both
 *     present). Destination frame on page 0x83 (no straddle). The callee
 *     then TEARS DOWN page 0x81 and page 0x71 (PTE <- 0, CR3 reload) and
 *     points TSS.ESP0 back at the phase-A geometry.
 *   phase C: destination frame's TOP page NOT PRESENT -> the S_INT_PROBE
 *     extent probe must raise #PF BEFORE the SS/CPL commit, in the OLD
 *     context: err = 2 ({US=0,W=1,P=0} -- the frame pushes are implicit
 *     SUPERVISOR writes), CR2 = 0x8100A (the first push's address, the
 *     probe_ppush form). QEMU faults on the very first push; both oracles
 *     deliver the #PF same-privilege to the CPL3 pf3_handler, which records
 *     the frame, points TSS.ESP0 at page 0x82/0x83 for phase D, skips the
 *     7-byte lcall and IRETs back.
 *   phase D: parameter SOURCE page NOT PRESENT (param[1] read at 0x71000):
 *     the S_CG_PRD read raises #PF in the OLD context with ZERO frame bytes
 *     written: err = 0 (supervisor READ, P=0), CR2 = 0x71000. (QEMU reads
 *     the highest-address param first and faults on the same access; its
 *     earlier SS/ESP pushes on the new stack are invisible to the trace and
 *     never read back.) Same pf3_handler path; then the CPL3 exit.
 *
 * CR2 cannot be read at CPL3, so it is graded by the full-stream diff (every
 * post-fault record carries it): cr2 = 0x8100A after phase C, 0x71000 in the
 * final record after phase D.
 *
 * PRE-FIX BEHAVIOUR (negative control, HEAD build): any param count != 0
 * cross-privilege gate hit the 0xDA loud-HALT -- the machine freezes at
 * phase A's lcall.
 *
 * GDT @ 0x500 (10 entries): code0 0x08 / data0 0x10 / code3 0x18 / data3 0x20
 *   / TSS 0x28 (base 0x3000) / gateA 0x30 -> cA / gateB 0x38 -> cB
 *   / gateC 0x40 -> cA / gateD 0x48 -> cA (all 32-bit, DPL3, pcount 2)
 * IDT @ 0x1000: #PF(14) -> pf3_handler (trap 0x8F DPL0, CS=0x1B: SAME-priv
 *   at CPL3), #GP(13) -> gp_catch (diagnostic exit with sentinels)
 * markers @ 0x2000; TSS @ 0x3000; PD @ 0x10000; PT0 @ 0x11000;
 * user stack ~0x70000; TSS stack pages 0x80-0x83; ring0 boot stack 0x90000.
 *
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    /* GDT (10 entries, limit 0x4F) at 0x500. */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508        /* 0x08 code0 flat */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510        /* 0x10 data0 flat */
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518        /* 0x18 code3 flat DPL3 */
    movl    $0x00CFFA00, 0x051C
    movl    $0x0000FFFF, 0x0520        /* 0x20 data3 flat DPL3 */
    movl    $0x00CFF200, 0x0524
    movl    $0x30000067, 0x0528        /* 0x28 TSS32: base 0x3000, limit 0x67 */
    movl    $0x00008900, 0x052C
    movw    $0x004F, 0x0480            /* 10 entries (0x00..0x48) */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp          /* CPL0 boot stack */

    /* ---- zero markers 0x2000..0x2140 + IDT @ 0x1000 ---------------------- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $80, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0xBAD0FF13, 0x000020F0    /* "gp_catch ran" sentinel */

    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* IDT[13] #GP -> gp_catch (trap 0x8F DPL0, CS=0x08: cross-priv from CPL3,
     * diagnostic exit) */
    movl    $gp_catch, %eax
    movl    %eax, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x00080000, %edx
    movl    %edx, 0x00001068
    movl    %eax, %edx
    andl    $0xFFFF0000, %edx
    orl     $0x00008F00, %edx
    movl    %edx, 0x0000106C

    /* IDT[14] #PF -> pf3_handler (trap 0x8F DPL0, CS=0x1B: SAME-priv at CPL3;
     * HW faults bypass the gate DPL check) */
    movl    $pf3_handler, %eax
    movl    %eax, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x001B0000, %edx
    movl    %edx, 0x00001070
    movl    %eax, %edx
    andl    $0xFFFF0000, %edx
    orl     $0x00008F00, %edx
    movl    %edx, 0x00001074

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- the four 32-bit call gates (type 0xC, DPL 3, param count 2) ----- */
    movl    $cA, %eax                  /* 0x30: gateA -> cA */
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0530
    movl    $cA, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec02, %eax
    movl    %eax, 0x0534

    movl    $cB, %eax                  /* 0x38: gateB -> cB */
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0538
    movl    $cB, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec02, %eax
    movl    %eax, 0x053c

    movl    $cA, %eax                  /* 0x40: gateC -> cA (never reached) */
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0540
    movl    $cA, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec02, %eax
    movl    %eax, 0x0544

    movl    $cA, %eax                  /* 0x48: gateD -> cA (never reached) */
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0548
    movl    $cA, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec02, %eax
    movl    %eax, 0x054c

    /* ---- TSS @ 0x3000: SS0=0x10, ESP0=0x8100E (phase A geometry) ---------
     * ESP0 = 0x8100E puts the 24-byte frame at [0x80FF6, 0x8100D]: it
     * STRADDLES the 0x81000 boundary, and the UNALIGNED param[0] push at
     * 0x80FFE straddles WITHIN one beat (the fx fragment engine's split).  */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x0008100E, 0x00003004    /* ESP0 (phase A) */
    movl    $0x00000010, 0x00003008    /* SS0 = data0 */
    movw    $0x0068, 0x00003066
    movw    $0x0028, %ax
    ltr     %ax

    /* ---- page tables: PD @ 0x10000, PT0 @ 0x11000 identity [0,1MiB) ------
     * All pages P|RW|US (0x7) so the CPL3 legs, the user-classified data
     * accesses and the supervisor-classified probes all pass where a page is
     * present; cB punches the phase C/D holes mid-test (PTE <- 0 at CPL0 +
     * CR3 reload) so the fault phases are ordered after the success phases. */
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
    movl    %eax, %cr0                 /* paging ON */

    /* ---- down to CPL3 (inter-privilege IRET, pxprobe's form; the EFLAGS
     * image carries IOPL=3 so the ring-3 exit may drive port 0xF4) --------- */
    pushl   $0x00000023                /* SS = data3 */
    pushl   $0x00070000                /* ESP = user stack (reset per phase) */
    pushl   $0x00003002                /* EFLAGS: IOPL=3 */
    pushl   $0x0000001B                /* CS = code3 */
    pushl   $r3pg
    iret

    /* ============================ ring 3 ================================== */
    .global r3pg
r3pg:
    movw    $0x23, %ax                 /* the outer RETF nulled DS */
    movw    %ax, %ds

    /* ---- phase A: destination frame straddles (both pages present) ------- */
    movl    $0xA5000000, 0x00070000    /* param[0] */
    movl    $0xA5000001, 0x00070004    /* param[1] */
    movl    $0x00070000, %esp
    .byte   0x9A
    .long   0
    .word   0x0033                     /* gateA | RPL 3 */
afterA:
    movl    %esp, %eax                 /* 0x70000 + 8 (imm applied to the
                                        * restored outer ESP too -- QEMU) */
    cmpl    $0x00070008, %eax
    jne     1f
    movl    $0xC6A0000A, 0x00002038
1:

    /* ---- phase B: parameter SOURCE straddles (both pages present) -------- */
    movl    $0xA5000010, 0x00070FFE    /* param[0] at an UNALIGNED straddle */
    movl    $0xA5000011, 0x00071002    /* param[1] */
    movl    $0x00070FFE, %esp
    .byte   0x9A
    .long   0
    .word   0x003B                     /* gateB | RPL 3 */
afterB:
    movl    %esp, %eax                 /* 0x70FFE + 8 */
    cmpl    $0x00071006, %eax
    jne     1f
    movl    $0xC6A0000B, 0x0000203C
1:

    /* ---- phase C: destination frame's top page NOT PRESENT ---------------
     * #PF(err=2, CR2=0x8100A) in the OLD context; pf3_handler records, arms
     * phase D's TSS.ESP0, skips the lcall, IRETs back.                     */
    movl    $0xA5000020, 0x00070000
    movl    $0xA5000021, 0x00070004
    movl    $0x00070000, %esp
    .byte   0x9A
    .long   0
    .word   0x0043                     /* gateC | RPL 3 */
afterC:

    /* ---- phase D: parameter SOURCE page NOT PRESENT ----------------------
     * param[0] at 0x70FFC (page 0x70, present); the param[1] read at
     * 0x71000 faults (page 0x71 torn down by cB): #PF(err=0, CR2=0x71000)
     * in the OLD context. Do NOT store param[1] -- the store would #PF in
     * the caller.                                                          */
    movl    $0xA5000030, 0x00070FFC
    movl    $0x00070FFC, %esp
    .byte   0x9A
    .long   0
    .word   0x004B                     /* gateD | RPL 3 */
afterD:

    /* ---- exit: witnesses into the GPRs (eax/dx die at the out) ----------- */
    movl    0x00002100, %edi           /* phase C #PF err (want 2) */
    movl    0x00002110, %esi           /* phase D #PF err (want 0) */
    movl    0x00002008, %ecx           /* phase A param[0] (want 0xA5000000) */
    movl    0x00002024, %ebp           /* phase B param[0] (want 0xA5000010) */
    movl    0x00002038, %ebx           /* phase A return flag (want 0xC6A0000A) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                   /* CPL==IOPL==3 */
9:  jmp     9b

    /* ===================== CPL0 callees ====================================
     * cA (phase A): frame [0x80FF6, 0x8100D] straddling pages 0x80/0x81:
     *   [0x80FF6]=retEIP [0x80FFA]=CS [0x80FFE]=p0 [0x81002]=p1
     *   [0x81006]=old ESP [0x8100A]=old SS; ESP = 0x80FF6, SS = 0x10.       */
    .align 16
    .global cA
cA:
    movl    0x00080FF6, %eax
    movl    %eax, 0x00002000           /* retEIP (want afterA) */
    movl    0x00080FFA, %eax
    movl    %eax, 0x00002004           /* ret CS (want 0x1B) */
    movl    0x00080FFE, %eax
    movl    %eax, 0x00002008           /* param[0] (want 0xA5000000) */
    movl    0x00081002, %eax
    movl    %eax, 0x0000200C           /* param[1] (want 0xA5000001) */
    movl    0x00081006, %eax
    movl    %eax, 0x00002010           /* old ESP (want 0x70000) */
    movl    0x0008100A, %eax
    movl    %eax, 0x00002014           /* old SS (want 0x23) */
    movl    %esp, %eax
    movl    %eax, 0x00002018           /* new ESP (want 0x80FF6) */
    movw    %ss, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x0000201C           /* new SS (want 0x10) */
    movl    $0x00084000, 0x00003004    /* TSS.ESP0 for phase B (page 0x83) */
    lret    $8

    /* cB (phase B): frame [0x83FE8, 0x83FFF] on page 0x83:
     *   [0x83FE8]=retEIP [0x83FEC]=CS [0x83FF0]=p0 [0x83FF4]=p1
     *   [0x83FF8]=old ESP [0x83FFC]=old SS; ESP = 0x83FE8.
     * Then the TEARDOWN for phases C/D: PT0[0x81] <- 0 (phase C's frame top
     * page), PT0[0x71] <- 0 (phase D's param-source page), CR3 reload (TLB
     * flush), TSS.ESP0 back to the phase-A geometry. The frame + return pops
     * stay on page 0x83, which REMAINS present.                            */
    .align 16
    .global cB
cB:
    movl    0x00083FE8, %eax
    movl    %eax, 0x00002020           /* retEIP (want afterB) */
    movl    0x00083FF0, %eax
    movl    %eax, 0x00002024           /* param[0] (want 0xA5000010) */
    movl    0x00083FF4, %eax
    movl    %eax, 0x00002028           /* param[1] (want 0xA5000011) */
    movl    0x00083FF8, %eax
    movl    %eax, 0x0000202C           /* old ESP (want 0x70FFE) */
    movl    0x00083FFC, %eax
    movl    %eax, 0x00002030           /* old SS (want 0x23) */
    movl    %esp, %eax
    movl    %eax, 0x00002034           /* new ESP (want 0x83FE8) */
    movl    $0x00000000, 0x00011204    /* PT0[0x81] <- 0 (phase C) */
    movl    $0x00000000, 0x000111C4    /* PT0[0x71] <- 0 (phase D) */
    movl    %cr3, %eax
    movl    %eax, %cr3                 /* TLB flush */
    movl    $0x0008100E, 0x00003004    /* TSS.ESP0 for phase C */
    lret    $8

    /* ===================== #PF witness handler (CPL3) ======================
     * Reached ONLY because the fault was raised with the OLD context fully
     * intact (CPL3, user SS:ESP) -- same-privilege delivery, no stack
     * switch, [err, EIP, CS, EFLAGS] on the USER stack. Records the frame
     * into 0x2100 + phase*16, arms phase D's TSS.ESP0, skips the 7-byte
     * lcall, IRETs back. CR2 is privileged state; the stream diff grades it. */
    .align 16
    .global pf3_handler
pf3_handler:
    movl    0x000020FC, %eax           /* phase counter (0 = C, 1 = D) */
    shll    $4, %eax
    leal    0x2100(%eax), %edx
    movl    0(%esp), %eax              /* #PF error code */
    movl    %eax, 0(%edx)              /* want 2 (phase C) / 0 (phase D) */
    movl    4(%esp), %eax              /* pushed EIP = the faulting lcall */
    movl    %eax, 4(%edx)
    movl    8(%esp), %eax              /* pushed CS (want 0x1B: OLD context) */
    movl    %eax, 8(%edx)
    movl    %esp, %eax                 /* handler ESP on the USER stack */
    movl    %eax, 12(%edx)             /* want 0x6FFF0 (C) / 0x70FEC (D) */
    movl    0x000020FC, %eax
    incl    %eax
    movl    %eax, 0x000020FC
    movl    $0x00083000, 0x00003004    /* TSS.ESP0 for phase D (page 0x82) */
    addl    $7, 4(%esp)                /* skip the faulting lcall */
    addl    $4, %esp                   /* pop the error code */
    iretl

    /* ===================== diagnostic #GP catcher ========================= */
    .align 16
    .global gp_catch
gp_catch:
    movl    (%esp), %eax               /* #GP error code */
    movl    %eax, 0x000020F0
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                   /* CPL0 after the cross-priv delivery */
9:  jmp     9b

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
