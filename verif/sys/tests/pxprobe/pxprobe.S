/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-C04 — the cross-privilege delivery frame-extent probe
 * (S_INT_PROBE). THIS IS A WITNESS GATE, NOT A DIFFERENTIAL ONE. Measured
 * oracle behaviour (2026-08-04, pinned qemu-system 8.2.2): QEMU does NOT
 * cascade -- it raises the frame-push #PF with the OLD context too (old
 * SS:ESP, CPL3, EFLAGS unmodified; it faults on the first push and unwinds
 * the half-done switch), so this image runs to the isa-debug-exit under
 * QEMU. The differential still cannot be used, because the two oracles
 * differ in exactly two fields of every post-fault record (measured with
 * compare.py --mode func --all over the full 3502-record stream):
 *   - CR2: QEMU reports 0x8100C (the address of the FIRST frame push that
 *     faults -- silicon semantics); the RTL's extent probe reports 0x8100F
 *     (int_new_esp - 1, the LAST byte of the frame -- the probe address).
 *   - the #PF ERROR CODE (the handler reads it into edi): QEMU reports 2
 *     ({US=0,W=1,P=0} -- the stack-switch push is a SUPERVISOR access, which
 *     is the silicon behaviour); the RTL reports 6 ({US=1,W=1,P=0}) because
 *     S_INT_PROBE is classified as a USER access (core_bus_driver.svh:375-377
 *     sets cur_seg_rel while cpl_r is still 3, so acc_usr=1 at core.sv:6029).
 * Both divergences are properties of the probe AS IMPLEMENTED, not of the
 * probe-before-commit ordering this test grades, so the RTL side is graded
 * by witnesses (faultlog + final-record GPRs/CRs) exactly like piretgp0.
 * NOTE the US-bit class has a sharper consequence, measured with a variant
 * image (bottom frame page supervisor-only, top page present): the RTL probe
 * FALSELY faults #PF(7) on a delivery that silicon/QEMU completes (qemu runs
 * the CPL0 handler, exit 133) -- the probe requires the new stack pages to be
 * USER-accessible+writable, which no normal OS kernel stack is. Flagged as a
 * latent deviation; this test pins the implemented semantics (see the
 * manifest's oracle_gaps).
 * The fixed RTL raises the #PF with the OLD context fully intact, so the
 * #PF is delivered SAME-PRIVILEGE to the CPL3 handler installed below, which
 * records the witnesses and exits.
 *
 * THE SCENARIO (paged protected mode, 4 KiB pages, identity map):
 *   - TSS.SS0:ESP0 = 0x10:0x00081010. A CPL3->CPL0 delivery through a 32-bit
 *     trap gate pushes the 5-word frame (old SS, old ESP, EFLAGS, CS, EIP --
 *     20 bytes, no error code for INT n), i.e. linear [0x80FFC, 0x8100F]:
 *     it STRADDLES the page boundary at 0x81000.
 *   - The frame's BOTTOM page (0x80000) is present + user + writable; the
 *     frame's TOP page (0x81000) is NOT PRESENT (PT0[0x81] = 0).
 *   - CPL3 user code runs `int $0x30` through a DPL=3 trap gate targeting a
 *     CPL0 handler.
 *   - Fixed RTL: S_INT_SS stages int_ss_* plus int_frame_base/int_frame_x2
 *     (core_tss_priv.svh:283-307); S_INT_PROBE write-probes the bottom page
 *     (ok), then the top page (core_tss_priv.svh:320-343) -- the walk finds
 *     PT0[0x81] not present and raises #PF (core_walk.svh:107-124) BEFORE
 *     seg_sel/seg_base/seg_limit/seg_attr[SS] and cpl_r are committed (those
 *     writes exist ONLY on the probe-success path, core_tss_priv.svh:329-340).
 *     The error code is {US=1, W=1, P=0} = 6: the probe is an SS-relative
 *     access (core_bus_driver.svh:375-377 cur_seg_rel=1) while cpl_r is still
 *     3, so acc_usr=1 (core.sv:6029) and walk_is_write=1 (the probe is a
 *     write-permission probe, core.sv:6892-6895). CR2 = the probed top-page
 *     address int_new_esp-1 = 0x8100F.
 *   - The #PF is then delivered from CPL3 to IDT[14], a trap gate targeting
 *     the DPL=3 pf3_handler: SAME-privilege (DPL==CPL), NO stack switch, the
 *     [err, EIP, CS, EFLAGS] frame lands on the USER stack, and the handler
 *     observes that the machine is still in the OLD context.
 *
 * WITNESSES (the handler packs them into the GPRs; the exit clobbers EAX/DX;
 * cr2/cs/ss/esp are read off the trace's final record):
 *   edi = #PF error code            -- 0x00000006 (US|W, P=0)
 *   esi = pushed CS                 -- 0x0000001B (the CPL3 code selector:
 *                                      the fault context is the OLD CPL3 one)
 *   ecx = pushed EIP                -- &int30_insn (the faulting int restarts)
 *   ebp = handler-entry ESP         -- 0x0006FFF0 = user ESP 0x70000 - 16
 *                                      (the same-priv #PF frame on the USER
 *                                      stack; the TSS stack was never touched)
 *   ebx = SS at the fault           -- 0x00000023 (the CPL3 data selector)
 *   final record: cr2 = 0x0008100F, cs = 0x1B, ss = 0x23, esp = 0x6FFF0
 *   +ven_faultlog: exactly ONE [FAULT] line, vec=14 err=00000006 depth=0.
 *     No vec=13/vec=8: with the #PF delivered cleanly there is no escalation
 *     cascade at all.
 *
 * PRE-FIX BEHAVIOUR (the defect, for the negative control): S_INT_SS
 * committed SS + CPL before the pushes, so the first S_INT_PUSH beat at
 * 0x8100C #PFs with the NEW context (CPL0, SS=0x10, supervisor error code
 * 0x2). Delivering that #PF from CPL0 to the DPL=3 handler gate is then
 * illegal -> #GP -> (paired with the in-flight #PF) #DF -> a fault during
 * #DF delivery -> S_SHUTDOWN. The machine NEVER reaches an exit: the final
 * record keeps the BAD0C04x sentinels and the trace stops at the quiesce
 * limit. Every witness above fails.
 *
 * NEGATIVE CONTROL actually run (see manifest.json): a pre-fix TB cannot be
 * rebuilt in this checkout, so sensitivity is demonstrated with a variant
 * image whose ONLY change is PT0[0x81] = 0x81007 (the second frame page
 * present + user + writable). The probe then succeeds, the switch commits,
 * the pushes complete, and int0_handler (CPL0) runs and exits with
 * edi=0x11111111 / esi=ecx=ebp=ebx=0 and an EMPTY faultlog -- every primary
 * witness differs, so the gate is sensitive to the probe's verdict. The
 * variant is a temp artifact, deleted after the run.
 *
 * GDT @ 0x500 (6 entries): null + code0 0x08 + data0 0x10 + code3 0x18 (0x1B)
 * + data3 0x20 (0x23) + TSS32 0x28 (base 0x3000, limit 0x67, available).
 * IDT @ 0x1000: #PF(14) -> pf3_handler (trap gate 0x8F DPL0, CS=0x1B),
 *               0x30   -> int0_handler (trap gate 0xEF DPL3, CS=0x08).
 * PD @ 0x10000 (PD[0] -> PT0 P|RW|US), PT0 @ 0x11000 identity-mapping
 * [0, 1 MiB) P|RW|US EXCEPT PT0[0x81] = 0.
 * TSS @ 0x3000 (ESP0=0x81010, SS0=0x10, IOPB=0x68). Stacks: CPL0 boot
 * 0x90000, CPL3 user 0x70000, TSS int stack top 0x81010.
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
    movw    $0x7000, %sp

    /* GDT (6 entries) at 0x500 -- all bases/limits static, built once here. */
    movl    $0x00000000, 0x0500         /* idx0 null */
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508         /* idx1 0x08 code0 flat */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510         /* idx2 0x10 data0 flat */
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518         /* idx3 0x18 code3 flat (DPL3) */
    movl    $0x00CFFA00, 0x051C
    movl    $0x0000FFFF, 0x0520         /* idx4 0x20 data3 flat (DPL3) */
    movl    $0x00CFF200, 0x0524
    movl    $0x30000067, 0x0528         /* idx5 0x28 TSS32: limit 0x67, base[15:0]=0x3000 */
    movl    $0x00008900, 0x052C         /* access 0x89 (P|available 32-bit TSS), base[31:16]=0 */
    movw    $0x002F, 0x0480
    movl    $0x00000500, 0x0482
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
    movl    $0x00090000, %esp           /* CPL0 boot stack */

    /* ---- IDT @ 0x1000: zero all 256 gates, then install the two used ---- */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx                  /* 256 gates * 8 bytes = 512 dwords */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* IDT[14] #PF -> pf3_handler, CS=0x1B (code3 DPL3: SAME-priv delivery at
     * CPL3), 32-bit TRAP gate 0x8F DPL0 (HW faults bypass the gate DPL check).
     * Slot @ 0x1000 + 14*8 = 0x1070. */
    movl    $pf3_handler, %eax
    movl    %eax, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x001B0000, %edx
    movl    %edx, 0x00001070
    movl    %eax, %edx
    andl    $0xFFFF0000, %edx
    orl     $0x00008F00, %edx
    movl    %edx, 0x00001074

    /* IDT[0x30] -> int0_handler, CS=0x08 (code0 DPL0: CROSS-priv from CPL3),
     * 32-bit TRAP gate 0xEF DPL3 (so `int $0x30` at CPL3 passes DPL>=CPL).
     * Slot @ 0x1000 + 0x30*8 = 0x1180. */
    movl    $int0_handler, %eax
    movl    %eax, %edx
    andl    $0x0000FFFF, %edx
    orl     $0x00080000, %edx
    movl    %edx, 0x00001180
    movl    %eax, %edx
    andl    $0xFFFF0000, %edx
    orl     $0x0000EF00, %edx
    movl    %edx, 0x00001184

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- TSS @ 0x3000: SS0:ESP0 = 0x10:0x00081010 ------------------------
     * ESP0 = 0x81010 puts the 20-byte cross-priv frame at [0x80FFC, 0x8100F]:
     * it STRADDLES the 0x81000 page boundary. */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00081010, 0x00003004     /* ESP0 */
    movl    $0x00000010, 0x00003008     /* SS0 = data0 */
    movw    $0x0068, 0x00003066         /* I/O map base >= limit: empty map */
    movw    $0x0028, %ax
    ltr     %ax

    /* ---- page tables: PD @ 0x10000, PT0 @ 0x11000 identity [0,1MiB) -------
     * Every page the paged machine touches is P|RW|US (0x7): CPL3 fetches the
     * image window 0xF0xxx and runs on user stacks, and the S_INT_PROBE write
     * probe is classified as a USER access (acc_usr=1 while cpl_r is still 3),
     * so the frame's BOTTOM page must be user-writable for the probe to pass
     * it. The frame's TOP page 0x81000 is left NOT PRESENT -- the fault the
     * test is about. */
    movl    $0x00011007, 0x00010000     /* PD[0] -> PT0 | P|RW|US */
    movl    $0x00011000, %edi
    xorl    %eax, %eax
1:  movl    %eax, %edx
    orl     $0x00000007, %edx
    movl    %edx, (%edi)
    addl    $4, %edi
    addl    $0x1000, %eax
    cmpl    $0x00100000, %eax
    jb      1b
    /* PT0[0x81] = 0: linear 0x81000 NOT PRESENT (the second frame page).
     * NEGATIVE-CONTROL KNOB: 0x00081007 here makes the delivery succeed. */
    movl    $0x00000000, 0x00011204

    movl    $0x00010000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* paging ON (identity low window) */

    /* ---- transfer DOWN to CPL3 (inter-priv IRET) ---- */
    pushl   $0x00000023                 /* SS = data3 RPL3 */
    pushl   $0x00070000                 /* ESP = user stack */
    pushl   $0x00003002                 /* EFLAGS: IOPL=3 (CPL3 may out 0xF4) */
    pushl   $0x0000001B                 /* CS = code3 */
    pushl   $cpl3_entry
    iret

    .global cpl3_entry
cpl3_entry:
    /* Sentinel-fill the witness registers: any exit that still carries these
     * means the #PF handler never ran (the cascade/shutdown path). */
    movl    $0xBAD0C04A, %edi
    movl    $0xBAD0C04B, %esi
    movl    $0xBAD0C04C, %ecx
    movl    $0xBAD0C04D, %ebp
    movl    $0xBAD0C04E, %ebx
    .global int30_insn
int30_insn:
    int     $0x30                       /* cross-priv delivery onto the bad stack */
    /* Unreachable in the fixed RTL (the #PF handler exits) and in the
     * pre-fix RTL (the machine shuts down). */
9:  jmp     9b

    /* ============================ handlers ================================ *
     * pf3_handler (the R2-C04 witness): reached ONLY if the #PF was raised
     * with the OLD context (CPL3, user SS:ESP). Same-priv frame:
     * [esp]=err, +4=EIP, +8=CS, +12=EFLAGS, on the USER stack. */
    .align 16
    .global pf3_handler
pf3_handler:
    movl    0(%esp), %edi               /* #PF error code  (want 6) */
    movl    8(%esp), %esi               /* pushed CS       (want 0x1B) */
    movl    4(%esp), %ecx               /* pushed EIP      (want int30_insn) */
    movl    %esp, %ebp                  /* handler ESP     (want 0x6FFF0) */
    movw    %ss, %ax
    movzwl  %ax, %eax
    movl    %eax, %ebx                  /* SS at the fault (want 0x23) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* CPL==IOPL==3 */
9:  jmp     9b

    /* int0_handler (the control): reached ONLY if the frame probe passed and
     * the switch COMMITTED -- i.e. the writable-page negative-control variant
     * (or a probe that fails to fault). Runs at CPL0 on the TSS stack. */
    .align 16
    .global int0_handler
int0_handler:
    movl    $0x11111111, %edi           /* "the CPL0 handler ran" */
    xorl    %esi, %esi
    xorl    %ecx, %ecx
    xorl    %ebp, %ebp
    xorl    %ebx, %ebx
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* CPL0: always permitted */
9:  jmp     9b

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
