/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test: real->protected + PAGING bootstrap, an
 * IDT with #PF / #GP / #UD handlers, and each fault deliberately triggered so the
 * fault DECISIONS DELIVER through the IDT (see the pfault flow at the bottom).
 *
 * On top of that skeleton this image converts the old xc04 reachability probe for
 * producer S_FSTORE (x87 FSTP m64) into a CORRECTNESS gate. Before the engine,
 * S_FSTORE translated only the page the access STARTED in and the core $fatal'd
 * ("PAGING/C-04 UNSPLIT page-crossing") when a beat straddled. The engine now
 * runs a probe-then-execute fragment sequence for writes: probe page 2 with
 * write permission, then write the page-1 fragment, then the page-2 fragment --
 * no partial commits. This test proves, DIFFERENTIALLY against QEMU (which
 * implements page crossings correctly: cputlb.c mmu_lookup() looks up BOTH
 * pages, "recognizing exceptions from either", before any store byte lands):
 *
 *   Case A (ATOMICITY): with linear page 3 (0x3000) NOT PRESENT, `fstpl` at
 *       0x2FFE (beat 0 spans 0x2FFE-0x3001, crossing the 0x3000 boundary) must
 *       #PF with CR2=0x3000 BEFORE any byte is committed. The #PF handler
 *       verifies the page-1 sentinel (0xA5A5A5A5 at 0x2FFC-0x2FFF) is UNTOUCHED
 *       -> marker 0x2038 = 0x600DF00D, then maps page 3 -> phys 0x600000 and
 *       IRETs; the fstpl RESTARTS and completes.
 *   Case B (CORRECTNESS, non-contiguous frames): linear page 2 (0x2000) is
 *       identity-mapped while linear page 3 (0x3000) is mapped to the
 *       NON-ADJACENT phys frame 0x600000, so a wrong-physical-page tail write
 *       is observable: after the restart the low dword of 1.0 must land at
 *       phys 0x2FFE (linear 0x2FFE) and the high dword at phys 0x600002
 *       (linear 0x3002). Phys 0x3000 (the wrong adjacent frame) is pre-poisoned
 *       with 0x0B0B0B0B and phys 0x600000 pre-seeded with 0x5A5A5A5A so a tail
 *       written to (or a tail read from) the wrong frame cannot accidentally
 *       carry the expected value. The readbacks go to markers 0x2040/0x203C
 *       and into ebp/ebx at exit (want 0x00000000 / 0x3FF00000).
 *
 * Exit-record witnesses (pulled into GPRs; the run-sys-golden.sh step-5f block
 * asserts them on the golden and the step-7 RTL sys-diff compares them
 * record-for-record):
 *   ecx = 4      two #PF (crossing + the pfault demand-page case) + #GP + #UD
 *   edx = 0x401000 (CR2 captured by the pfault demand-page #PF)
 *   esi = 0xCAFEBABE (the restarted pfault store readback)
 *   edi = 0x600DF00D (case A: page 1 untouched by the rejected crossing store)
 *   ebx = 0x3FF00000 (case B: high dword of 1.0 read back through page 3)
 *   ebp = 0x00000000 (case B: low dword of 1.0 read back through page 2)
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04f.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Physical/linear memory plan (machine -m 32 => 32 MiB phys; targets fit):
 *   GDT  @ 0x00000500  (null + code32 0x08 + data32 0x10 + flat clones; limit 0x2F)
 *   IDT  @ 0x00001000  (256 gates; only #PF/#GP/#UD filled)
 *   markers @ 0x00002000 (per-vector counters + CR2 capture + resume EIPs + the
 *                         R2-C03 markers at 0x2038/0x203C/0x2040)
 *   stack   @ 0x00090000
 *   Page tables (built BEFORE CR0.PG, i.e. physical writes):
 *     PD  @ 0x00011000 : PD[0]->PT0 (identity low), PD[1]->PT1 (4 MiB window)
 *     PT0 @ 0x00012000 : identity low structures + stack + code window, EXCEPT
 *        PT0[3] linear 0x3000 -> phys 0x600000, STARTING NOT-PRESENT (0x...02):
 *        the case-A atomicity window; the #PF handler maps it present (0x...03).
 *     PT1 @ 0x00013000 : the demand-paging window for linear [4 MiB, 8 MiB):
 *        PT1[0] linear 0x400000 -> phys 0x800000  P|RW (0x3)  (present)
 *        PT1[1] linear 0x401000 -> phys 0x801000  NOT PRESENT (0x2: RW, P=0)
 *                                  ^ the pfault #PF target; handler sets P -> 0x3.
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04f.ld; objcopy -O binary,
 * padded to exactly 64 KiB.  GNU-as syntax; no nasm.
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

    /* --- build the GDT (6 entries = 48 bytes) at linear 0x0500 ---
     * Only idx 0/1/2 are meaningful; idx 3/4/5 are valid flat-data clones so the
     * GDT limit is 0x2F.  The #GP selector 0x38 (idx 7) is then genuinely PAST the
     * limit (0x38 > 0x2F) and a load of it #GPs on the limit check.            */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 data32 flat clone */
    movl    $0x00CF9200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data32 flat clone */
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)       /* idx5 0x28 data32 flat clone */
    movl    $0x00CF9200, 44(%ebx)

    movw    $0x002F, 0x0480             /* limit = 48-1 = 0x2F (6 entries) */
    movl    $0x00000500, 0x0482        /* base  = 0x0500 */
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
    movl    $0x00090000, %esp

    /* zero the marker area at 0x2000..0x2060 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $24, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build the IDT (3 fault gates) ================= */
    /* IDT base 0x1000.  All gates selector 0x08, DPL=0.  We use INTERRUPT gates
     * (attr 0x8E) for the fault handlers (IF cleared on entry). */

    /* vector 6 (#UD) -> ud_handler */
    movl    $ud_handler, %ebx
    movl    $0x00001030, %edi           /* 0x1000 + 6*8 = 0x1030 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)

    /* vector 13 (#GP) -> gp_handler */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 = 0x1068 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)

    /* vector 14 (#PF) -> pf_handler */
    movl    $pf_handler, %ebx
    movl    $0x00001070, %edi           /* 0x1000 + 14*8 = 0x1070 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492        /* IDT base = 0x1000 */
    lidt    0x0490

    /* ===================== build the 2-level page tables ================= */
    /* PT0 @ 0x12000: identity-map only the regions the running code actually
     * touches after CR0.PG=1, so the single-stepped golden stays short:
     *   - [0x00000, 0x14000)  : 20 PTEs  -> GDT(0x500)/IDT(0x1000)/markers(0x2000)
     *                                       + the page tables themselves (0x11-0x13)
     *   - [0x8D000, 0x91000)  :  4 PTEs  -> the flat stack region (ESP=0x90000,
     *                                       descends as frames are pushed)
     *   - [0xF0000, 0x100000) : 16 PTEs  -> the CODE window 0x000Fxxxx (EIP/handlers)
     * Then TWO overrides for the R2-C03 crossing window:
     *   - PT0[3]: linear 0x3000 -> phys 0x600000, STARTING NOT-PRESENT (RW, P=0).
     *     The crossing FSTP's tail page lives on a NON-CONTIGUOUS physical frame
     *     and begins absent for the atomicity case; the #PF handler maps it.
     * Physical pre-seeds (paging still OFF -> these are physical writes):
     *   - phys 0x3000..0x300F  = 0x0B0B0B0B poison: the WRONG (linear-adjacent)
     *     frame. A tail written there is invisible to the linear readback; a
     *     tail READ from there returns poison, never the expected value.
     *   - phys 0x600000..0x60000F = 0x5A5A5A5A: the RIGHT frame's pre-image, so an
     *     unwritten tail reads back as garbage distinct from the expected
     *     0x00000000 / 0x3FF00000.                                            */
    /* low data + page tables: PT0[0x00..0x13] = identity [0,0x14000) */
    movl    $0x00012000, %edi           /* &PT0[0] */
    movl    $0x00000003, %eax           /* frame 0 | P|RW */
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* PT0[3]: linear 0x3000 -> phys 0x600000, NOT PRESENT (case A) */
    movl    $0x00600002, 0x0001200C
    /* stack: PT0[0x8D..0x90] = identity [0x8D000,0x91000) */
    movl    $0x00012234, %edi           /* &PT0[0x8D] = 0x12000 + 0x8D*4 */
    movl    $0x0008D003, %eax           /* frame 0x8D000 | P|RW */
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* code window: PT0[0xF0..0xFF] = identity [0xF0000,0x100000) */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] = 0x12000 + 0xF0*4 */
    movl    $0x000F0003, %eax           /* frame 0xF0000 | P|RW */
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* PT1 @ 0x13000: the demand-paging window [4 MiB, 8 MiB) */
    movl    $0x00013000, %edi
    movl    $0x00800003, 0(%edi)        /* PT1[0] linear 0x400000 -> phys 0x800000 P|RW */
    movl    $0x00801002, 4(%edi)        /* PT1[1] linear 0x401000 -> phys 0x801000 P=0 (NOT PRESENT) */

    /* PD @ 0x11000 */
    movl    $0x00011000, %edi
    movl    $0x00012003, 0(%edi)        /* PD[0] -> PT0 | P|RW (identity low 1 MiB) */
    movl    $0x00013003, 4(%edi)        /* PD[1] -> PT1 | P|RW (the 4 MiB window) */

    /* physical pre-seeds for the crossing window (paging still OFF) */
    movl    $0x0B0B0B0B, %eax
    movl    %eax, 0x00003000            /* poison the WRONG adjacent frame */
    movl    %eax, 0x00003004
    movl    $0x5A5A5A5A, %eax
    movl    %eax, 0x00600000            /* distinct garbage on the RIGHT frame */
    movl    %eax, 0x00600004

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ==== REVIEW1_Aug3 R2-C03: S_FSTORE page-crossing CORRECTNESS ==============
     * FSTP m64 at linear 0x2FFE: beat 0 spans 0x2FFE-0x3001 and crosses the
     * 0x3000 boundary (at 0x2FFC every beat would sit inside one page and prove
     * nothing -- the beat-vs-object distinction from the old probe stands).
     * Page 2 (0x2000) is identity; page 3 (0x3000) is phys 0x600000 and starts
     * NOT PRESENT.
     *
     * Case A (atomicity): the engine must probe page 2 with write permission
     * BEFORE committing any byte, so this fstpl raises #PF(CR2=0x3000) with the
     * page-1 sentinel (0xA5A5A5A5 at 0x2FFC-0x2FFF) UNTOUCHED. pf_handler's
     * CR2==0x3000 arm checks the sentinel (marker 0x2038 = 0x600DF00D), maps
     * page 3 present, and IRETs; the fstpl restarts and now completes.
     *
     * Case B (correctness): the restarted store's 8 bytes land split across two
     * NON-CONTIGUOUS frames: 0x00000000 at phys 0x2FFE (low half of 1.0) and
     * 0x3FF00000 at phys 0x600002 (high half). Read both back THROUGH PAGING:
     * a tail written to the wrong (adjacent 0x3000) frame never shows up at
     * linear 0x3002 (its phys 0x600002 would still read 0x5A5A5A5A), and a tail
     * read from the wrong frame returns the 0x0B0B0B0B poison. */
    movl    $0xA5A5A5A5, 0x00002FFC     /* page-1 sentinel (bytes 0x2FFC..0x2FFF) */
    fld1
    fstpl   0x00002FFE                  /* #PF (page 3 NP) -> mapped -> RESTART completes */
    movl    0x00002FFE, %eax            /* low dword via page 2 (phys 0x2FFE) */
    movl    %eax, 0x00002040            /* want 0x00000000 */
    movl    0x00003002, %eax            /* high dword via page 3 (phys 0x600002) */
    movl    %eax, 0x0000203C            /* want 0x3FF00000 */

    /* clear the visible accumulator GPRs */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi

    /* ============================= #PF =================================== */
    /* Write a sentinel to linear 0x401000 whose PTE (PT1[1]) is NOT present.
     * -> #PF (vector 14, error code = present(0)|write(1)|user(0) = 0x2), CR2 =
     * 0x401000.  pf_handler sets PT1[1] |= P (0x801003), records CR2, IRETs;
     * the store RESTARTS and now succeeds (writing phys 0x801000).            */
    movl    $0xCAFEBABE, %eax
    movl    %eax, 0x00401000            /* #PF here; restarted after handler maps */
    /* read it back -> proves the page is now present and mapped to phys 0x801000 */
    movl    0x00401000, %esi            /* esi = 0xCAFEBABE (post-#PF-fixup read) */

    /* ============================= #GP =================================== */
    /* Resume label for the #GP skip: the handler will overwrite the saved EIP
     * with this address so IRET resumes PAST the faulting MOV.  We stash it in a
     * marker slot the handler reads. */
    movl    $gp_resume, %eax
    movl    %eax, 0x00002030            /* resume-EIP slot for #GP */
    /* load DS with selector 0x38 (idx 7) -> PAST the GDT limit (0x2F) -> #GP.
     * (The selector is also the #GP error code.) */
    movw    $0x38, %ax
    movw    %ax, %ds                    /* #GP here; gp_handler resumes at gp_resume */
gp_resume:
    /* DS is unchanged (the bad load #GP'd before committing). Restore a known
     * flat DS so the following accesses are well-defined. */
    movw    $0x10, %ax
    movw    %ax, %ds

    /* ============================= #UD =================================== */
    movl    $ud_resume, %eax
    movl    %eax, 0x00002034            /* resume-EIP slot for #UD */
    ud2                                 /* #UD here; ud_handler resumes at ud_resume */
ud_resume:

    /* ===================== accumulate the success proof ================== */
    movl    0x00002028, %eax            /* #PF counter (2: crossing + demand-page) */
    addl    0x0000202C, %eax            /* + #GP counter */
    addl    0x00002024, %eax            /* + #UD counter */
    movl    %eax, %ecx                  /* ecx = 4 if all four faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 (0x401000); the exit port load
                                         * below overwrites dx, so the exit record carries
                                         * 0x004000F4 -- assert exactly that. */
    movl    0x00002038, %edi            /* edi = 0x600DF00D (case A: page 1 untouched) */
    movl    0x0000203C, %ebx            /* ebx = 0x3FF00000 (case B: high dword, phys 0x600002) */
    movl    0x00002040, %ebp            /* ebp = 0x00000000 (case B: low dword, phys 0x2FFE) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: dispatch on CR2.
     * CR2 == 0x3000: the R2-C03 case-A crossing FSTP hit the not-present page 3.
     *     The engine's pre-probe must have rejected the access BEFORE any byte
     *     committed: verify the page-1 sentinel at 0x2FFC-0x2FFF is untouched,
     *     then map PT0[3] -> phys 0x600000 P|RW and IRET (the fstpl restarts).
     * otherwise (0x401000): the pfault demand-page case -- record CR2, map
     *     PT1[1] present, count, IRET (the store restarts).
     * Stack on entry (same-priv, with error code): [esp]=errcode, [esp+4]=EIP,
     * [esp+8]=CS, [esp+12]=EFLAGS.  We save EAX first (so +4 to those).        */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    cmpl    $0x00003000, %eax
    je      pf_cross
    movl    %eax, 0x00002020            /* record CR2 (the faulting linear addr) */
    /* map the faulting page: set P on PT1[1] (linear 0x401000's PTE) */
    movl    $0x00801003, %eax
    movl    %eax, 0x00013004            /* PT1[1] := phys 0x801000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    /* flush TLB so the restart re-walks PT1[1] and sees it present */
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting store (FAULT) */

pf_cross:
    /* case A: the rejected crossing store must have left page 1 UNTOUCHED */
    cmpl    $0xA5A5A5A5, 0x00002FFC
    jne     1f
    movl    $0x600DF00D, 0x00002038     /* atomicity witness: pre-probe rejected first */
1:  movl    $0x00600003, 0x0001200C     /* PT0[3] := phys 0x600000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    movl    %cr3, %eax
    movl    %eax, %cr3                  /* flush TLB for the restart */
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting fstpl (FAULT) */

    /* #GP handler: count + resume PAST the faulting MOV.  Stack on entry has an
     * error code (the selector): [esp]=errcode,[esp+4]=EIP,[esp+8]=CS,[+12]=EFLAGS.
     * After pushing EAX everything shifts +4.  We overwrite the saved EIP slot
     * ([esp+8] after the push) with the precomputed resume label.            */
    .align 16
    .global gp_handler
gp_handler:
    pushl   %eax
    incl    0x0000202C                  /* #GP counter */
    movl    0x00002030, %eax            /* the resume EIP the mainline stashed */
    movl    %eax, 0x08(%esp)            /* overwrite saved EIP -> resume past MOV */
    popl    %eax
    addl    $4, %esp                    /* discard the #GP error code */
    iret

    /* #UD handler: count + resume PAST UD2.  #UD has NO error code, so the stack
     * is [esp]=EIP,[esp+4]=CS,[esp+8]=EFLAGS; after pushing EAX, saved EIP is at
     * [esp+4].                                                                  */
    .align 16
    .global ud_handler
ud_handler:
    pushl   %eax
    incl    0x00002024                  /* #UD counter */
    movl    0x00002034, %eax            /* the resume EIP the mainline stashed */
    movl    %eax, 0x04(%esp)            /* overwrite saved EIP -> resume past UD2 */
    popl    %eax
    iret                                /* no error code to discard for #UD */

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
