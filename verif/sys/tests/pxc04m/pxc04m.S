/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test (see pxc04f.S for the full story). On top
 * of it this image converts the old xc04 reachability probe for producer
 * S_INT_GATE (the 8-byte IDT gate read during interrupt delivery) into a
 * CORRECTNESS gate, differential against QEMU.
 *
 * Gates are 8-byte aligned FROM THE IDT BASE and 4096/8 divides exactly, so a
 * crossing gate needs a deliberately misaligned IDT. Two phases:
 *
 *   Phase 1 (correctness, non-contiguous frames): IDT2 base 0x4FCE puts vector
 *       6's gate at 0x4FFE, spanning 0x4FFE-0x5005 across the 0x5000 boundary.
 *       Page 4 is identity; page 5 (0x5000) maps to the NON-ADJACENT phys frame
 *       0x601000. The gate's selector (0x5000-0x5001), attr (0x5003) and
 *       offset[31:16] (0x5004-0x5005) bytes all live on phys 0x601000; phys
 *       0x5000 is pre-poisoned with 0x0B0B0B0B (a gate assembled from the wrong
 *       frame delivers to garbage -> divergence). UD2 must deliver to the REAL
 *       ud_handler -> marker 0x2038 = 0x600DF00D.
 *   Phase 2 (fault-before-completion): IDT3 base 0x4EFC puts vector 32's gate
 *       at 0x4FFC (crossing 0x4FFC-0x5003) while vector 14's gate (0x4F6C) and
 *       everything else the delivery needs stay in present page 4. With page 5
 *       NOT PRESENT, `int $32` must #PF with CR2=0x5000 (the crossing gate read
 *       probes page 2 BEFORE assembling anything); the #PF handler maps page 5
 *       -> phys 0x601000 and IRETs, the int restarts, and the delivery reaches
 *       int32_handler -> marker 0x203C = 0x600DF00D. Then the main IDT is
 *       restored and the pfault flow runs.
 *
 * Exit-record witnesses:
 *   ecx = 5 (phase-1 #UD + phase-2 #PF + pfault #PF/#GP/#UD), edx = 0x004000F4
 *   (CR2 0x401000, dx clobbered by the 0xF4 port), esi = 0xCAFEBABE, edi =
 *   0x600DF00D (phase 1: correct handler through the straddling gate), ebx =
 *   0x600DF00D (phase 2: delivery completed after the NP page was mapped).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04m.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan: GDT @0x500, IDT @0x1000 (main), IDT2 @0x4FCE (phase 1), IDT3
 * @0x4EFC (phase 2), markers @0x2000..0x2060, stack @0x90000, PD @0x11000,
 * PT0 @0x12000 (identity EXCEPT PT0[5]: linear 0x5000 -> phys 0x601000),
 * PT1 @0x13000 (0x400000 present, 0x401000 NP = the pfault demand-page target).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04m.ld; objcopy -O binary,
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

    /* --- build the GDT (6 entries = 48 bytes) at linear 0x0500 --- */
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
    /* low data + page tables: PT0[0x00..0x13] = identity [0,0x14000) */
    movl    $0x00012000, %edi           /* &PT0[0] */
    movl    $0x00000003, %eax           /* frame 0 | P|RW */
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* PT0[5]: linear 0x5000 -> phys 0x601000, PRESENT for now (phase 2 flips NP) */
    movl    $0x00601003, 0x00012014
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
    movl    %eax, 0x00005000            /* poison the WRONG adjacent frame */
    movl    %eax, 0x00005004
    movl    $0x5A5A5A5A, %eax
    movl    %eax, 0x00601000            /* distinct garbage on the RIGHT frame */
    movl    %eax, 0x00601004

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ==== REVIEW1_Aug3 R2-C03: S_INT_GATE page-crossing CORRECTNESS ============
     * PHASE 1: IDT2 base 0x4FCE -> vector 6's gate at 0x4FFE, spanning
     * 0x4FFE-0x5005 across the 0x5000 boundary (dword 0 crosses 2+2; the
     * selector/attr/offset-high bytes are on page 5 = phys 0x601000). UD2's
     * delivery reads the gate across the boundary and must land in the REAL
     * ud_handler. (The gate writes at 0x4FFE/0x5002 go through the S_STORE
     * split machinery and pre-fill the D-TLB for both pages.) */
    movl    $ud_handler, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 in the high half */
    movl    %eax, 0x00004FFE            /* gate dword 0 -> 0x4FFE..0x5001 CROSSES */
    movl    $ud_handler, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* attr 0x8E: P, DPL0, 32-bit interrupt gate */
    movl    %eax, 0x00005002            /* gate dword 1 (all on page 5) */
    movw    $0x0037, 0x00004000         /* IDT2 limit: covers vector 6 (6*8+7 = 0x37) */
    movl    $0x00004FCE, 0x00004002     /* IDT2 base: DELIBERATELY 8-misaligned */
    movl    $ud2m1_resume, %eax
    movl    %eax, 0x00002034            /* resume-EIP slot for the phase-1 UD2 */
    lidt    0x00004000
    ud2                                 /* delivery reads the gate at 0x4FFE */
ud2m1_resume:
    movw    %cs, %ax
    cmpw    $0x0008, %ax
    jne     1f
    movl    $0x600DF00D, 0x00002038     /* phase 1: correct handler, CS intact */

    /* PHASE 2: IDT3 base 0x4EFC -> vector 32's gate at 0x4FFC (crossing
     * 0x4FFC-0x5003), vector 14's gate at 0x4F6C (page 4, present). Flip page 5
     * NOT-PRESENT, then `int $32`: the crossing gate read must #PF with
     * CR2=0x5000 BEFORE any delivery state moves; pf_handler's 0x5000 arm maps
     * page 5 and IRETs; the restarted int delivers to int32_handler. */
1:  movl    $int32_handler, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x00004FFC            /* vec-32 gate dword 0 -> 0x4FFC..0x4FFF */
    movl    $int32_handler, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 0x00005000            /* vec-32 gate dword 1 -> page 5 (phys 0x601000) */
    movl    $pf_handler, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x00004F6C            /* vec-14 gate dword 0 @ 0x4EFC+0x70 */
    movl    $pf_handler, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 0x00004F70            /* vec-14 gate dword 1 */
    movw    $0x0107, 0x00004100         /* IDT3 limit: covers vector 32 (32*8+7) */
    movl    $0x00004EFC, 0x00004102     /* IDT3 base */
    movl    $0x00601002, 0x00012014     /* PT0[5] := phys 0x601000, P=0 (NP phase) */
    movl    %cr3, %eax
    movl    %eax, %cr3                  /* flush TLB so the NP bit is seen */
    lidt    0x00004100
    int     $32                         /* gate read crosses into NP page 5 -> #PF */
    /* ... pf_handler maps page 5, the IRET restarts the int, and the delivery
     * completes through the crossing gate (int32_handler sets marker 0x203C). */
    lidt    0x0000490                   /* restore the main IDT for the pfault flow */

    /* clear the visible accumulator GPRs */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi

    /* ============================= #PF =================================== */
    movl    $0xCAFEBABE, %eax
    movl    %eax, 0x00401000            /* #PF here; restarted after handler maps */
    movl    0x00401000, %esi            /* esi = 0xCAFEBABE (post-#PF-fixup read) */

    /* ============================= #GP =================================== */
    movl    $gp_resume, %eax
    movl    %eax, 0x00002030            /* resume-EIP slot for #GP */
    movw    $0x38, %ax
    movw    %ax, %ds                    /* #GP here; gp_handler resumes at gp_resume */
gp_resume:
    movw    $0x10, %ax
    movw    %ax, %ds

    /* ============================= #UD =================================== */
    movl    $ud_resume, %eax
    movl    %eax, 0x00002034            /* resume-EIP slot for #UD */
    ud2                                 /* #UD here; ud_handler resumes at ud_resume */
ud_resume:

    /* ===================== accumulate the success proof ================== */
    movl    0x00002028, %eax            /* #PF counter (2: gate-NP + demand-page) */
    addl    0x0000202C, %eax            /* + #GP counter */
    addl    0x00002024, %eax            /* + #UD counter (2: phase-1 + pfault) */
    movl    %eax, %ecx                  /* ecx = 5 if all five faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 (0x401000); the exit port load
                                         * below overwrites dx -> exit record 0x004000F4 */
    movl    0x00002038, %edi            /* edi = 0x600DF00D (phase 1: straddling gate ok) */
    movl    0x0000203C, %ebx            /* ebx = 0x600DF00D (phase 2: delivery after map) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: dispatch on CR2.  CR2 == 0x5000: the phase-2 `int $32` gate
     * read hit the not-present page 5 -- map PT0[5] -> phys 0x601000 P|RW and
     * IRET (the int restarts and delivers).  Otherwise (0x401000): the pfault
     * demand-page case.  Stack on entry (same-priv, with error code):
     * [esp]=errcode, [esp+4]=EIP, [esp+8]=CS, [esp+12]=EFLAGS.               */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    cmpl    $0x00005000, %eax
    je      pf_gate
    movl    %eax, 0x00002020            /* record CR2 (the faulting linear addr) */
    movl    $0x00801003, %eax
    movl    %eax, 0x00013004            /* PT1[1] := phys 0x801000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting store (FAULT) */

pf_gate:
    movl    $0x00601003, 0x00012014     /* PT0[5] := phys 0x601000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    movl    %cr3, %eax
    movl    %eax, %cr3                  /* flush TLB for the restart */
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting int (FAULT) */

    /* int32_handler: phase-2 delivery proof. Interrupt gate, no error code. */
    .align 16
    .global int32_handler
int32_handler:
    movl    $0x600DF00D, 0x0000203C     /* delivery completed through the crossing gate */
    iret

    /* #GP handler: count + resume PAST the faulting MOV. */
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
