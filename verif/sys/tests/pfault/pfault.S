/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator.
 *
 * This is the M2S.3 pfault gate test: it bootstraps real->protected + PAGING
 * (reusing the M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD
 * handlers, and then DELIBERATELY triggers each fault so the M2S.1 segmentation
 * fault DECISION (#GP) and the M2S.2 paging fault DECISION (#PF + CR2 + error
 * code) — which prior stages only COMPUTE — now actually DELIVER through the IDT.
 *
 *   #PF (vector 14): touch a NOT-PRESENT page.  Handler reads CR2 (the faulting
 *       linear addr), MAPS the page (sets its PTE present), increments a counter,
 *       and IRETs.  #PF is a FAULT -> the pushed EIP is the FAULTING instruction;
 *       after the handler maps the page, IRET RESTARTS it and it now succeeds.
 *   #GP (vector 13): load a data segment with a selector PAST the GDT limit
 *       (selector 0x38 when the GDT holds only 6 entries -> last valid byte 0x2F).
 *       Handler increments a counter and RESUMES past the faulting instruction
 *       (a #GP fault pushes the faulting EIP, so re-executing would re-fault; the
 *       handler overwrites the saved EIP with a precomputed resume label).
 *   #UD (vector 6): execute UD2 (0F 0B), the architecturally-undefined opcode.
 *       Handler increments a counter and RESUMES past UD2 (same EIP-skip as #GP).
 *
 * The #PF case has an ERROR CODE pushed (vector 14, present/write/user bits) and
 * sets CR2; #GP (vector 13) has an error code (the selector index, 0 here for a
 * non-external #GP carrying the bad selector); #UD (vector 6) has NO error code.
 * SAME-PRIVILEGE delivery only (handlers at CPL 0 — cross-privilege via TSS is
 * M2S.4).  Interrupt gates clear IF.
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pfault.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Physical/linear memory plan (machine -m 32 => 32 MiB phys; targets fit):
 *   GDT  @ 0x00000500  (null + code32 0x08 + data32 0x10 + a 5th/6th entry so the
 *                       OUT-OF-LIMIT selector 0x38 is genuinely past the limit)
 *   IDT  @ 0x00001000  (256 gates; only #PF/#GP/#UD filled)
 *   markers @ 0x00002000 (per-vector counters + the #PF CR2 capture + resume EIP)
 *   stack   @ 0x00090000
 *   Page tables (built BEFORE CR0.PG, i.e. physical writes):
 *     PD  @ 0x00011000 : PD[0]->PT0 (identity low), PD[1]->PT1 (4 MiB window)
 *     PT0 @ 0x00012000 : identity-map the CODE window [0xF0000,0x100000) + the
 *                        low structures (GDT/IDT/markers/stack/page-tables) so
 *                        every linear the running code touches is mapped.
 *     PT1 @ 0x00013000 : the demand-paging window for linear [4 MiB, 8 MiB):
 *        PT1[0] linear 0x400000 -> phys 0x800000  P|RW (0x3)  (present)
 *        PT1[1] linear 0x401000 -> phys 0x801000  NOT PRESENT (0x2: RW, P=0)
 *                                  ^ the #PF target; handler sets P -> 0x3.
 *
 * Flow (each fault observable in the golden as a CS:EIP jump into the handler
 * gate target and a return via IRET):
 *   1. real mode: flat GDT (+ extra entries) + lgdt; CR0.PE=1; far-jump to 0x08.
 *   2. flat data selectors + stack; zero markers; build IDT (#PF/#GP/#UD) + lidt.
 *   3. build PD + PT0 (identity) + PT1 (one present, one not-present); CR3; CR0.PG.
 *   4. #PF: write to linear 0x401000 (PTE not present) -> #PF -> pf_handler maps
 *      it (PT1[1] |= P) + records CR2 -> IRET -> the store RESTARTS and succeeds;
 *      read it back to prove the page is now present and mapped.
 *   5. #GP: load DS with selector 0x38 (past the GDT limit) -> #GP -> gp_handler
 *      counts + resumes past the faulting MOV.
 *   6. #UD: execute UD2 -> #UD -> ud_handler counts + resumes past UD2.
 *   7. accumulate the three counters (must be 3) + the restarted-store proof;
 *      exit via isa-debug-exit (out 0xf4, 0x42 -> qemu status 133).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pfault.ld; objcopy -O binary,
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

    /* zero the marker area at 0x2000..0x2040 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $16, %ecx
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
     * Each PTE = frame | P|RW (0x3); identity: frame == linear page.  The two
     * PT0 slots are written directly; per-region short loops fill the rest.   */
    /* low data + page tables: PT0[0x00..0x13] = identity [0,0x14000) */
    movl    $0x00012000, %edi           /* &PT0[0] */
    movl    $0x00000003, %eax           /* frame 0 | P|RW */
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
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

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

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
    /* read it back -> proves the page is now present + mapped to phys 0x801000 */
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
    movl    0x00002028, %eax            /* #PF counter */
    addl    0x0000202C, %eax            /* + #GP counter */
    addl    0x00002024, %eax            /* + #UD counter */
    movl    %eax, %ecx                  /* ecx = 3 if all three faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 from the #PF (0x401000) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: read CR2 (faulting linear), map PT1[1] present, count, IRET.
     * Stack on entry (same-priv, with error code): [esp]=errcode, [esp+4]=EIP,
     * [esp+8]=CS, [esp+12]=EFLAGS.  We save EAX first (so +4 to those).        */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
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
