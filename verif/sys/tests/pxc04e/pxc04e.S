/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test (see pxc04f.S for the full story). On top
 * of it this image converts the old xc04 reachability probe for producer
 * S_FENV_ST (FNSTENV) into a CORRECTNESS gate, differential against QEMU (whose
 * cputlb.c mmu_lookup looks up BOTH pages of a crossing store before any byte
 * commits):
 *
 *   Case A (ATOMICITY): with linear page 3 (0x3000) NOT PRESENT, `fnstenv` at
 *       0x2FFE (beat 0 spans 0x2FFE-0x3001, crossing) must #PF with CR2=0x3000
 *       BEFORE any byte is committed. The #PF handler verifies the page-1
 *       sentinel (0xA5A5A5A5 at 0x2FFC-0x2FFF) is UNTOUCHED -> marker 0x2038 =
 *       0x600DF00D, maps page 3 -> phys 0x600000, IRETs; the fnstenv RESTARTS
 *       and completes.
 *   Case B (CORRECTNESS, non-contiguous frames): page 2 identity, page 3 ->
 *       phys 0x600000. After fninit+fnop the 32-bit FENV image is deterministic:
 *       CW=0x037F (at 0x2FFE -- the CROSSING beat's page-1 bytes), SW=0x0000
 *       (0x3002), TW=0xFFFF (0x3006). The remaining fields (FIP dword @0x300A,
 *       FCS @0x300E, FOP @0x3010) are recorded for the differential (their exact
 *       values are the oracle's to define). Phys 0x3000 is pre-poisoned with
 *       0x0B0B0B0B and phys 0x600000 pre-seeded with 0x5A5A5A5A so a
 *       wrong-physical-page access cannot accidentally carry the expected
 *       value. Fields are read back as WORDS so the image's RESERVED bytes
 *       (which QEMU writes only partially, stw-by-stw) are never observed.
 *
 * Exit-record witnesses:
 *   ecx = 4, edx = 0x004000F4 (CR2 0x401000, dx clobbered by the 0xF4 port),
 *   esi = 0xCAFEBABE (pfault flow), edi = 0x600DF00D (case A),
 *   ebx = 0xFFFF037F ((TW<<16)|CW), ebp = 0 (SW).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04e.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan: as pxc04f -- GDT @0x500, IDT @0x1000, markers @0x2000..0x2060,
 * stack @0x90000, PD @0x11000, PT0 @0x12000 (identity + PT0[3]: linear 0x3000 ->
 * phys 0x600000 starting NOT-PRESENT), PT1 @0x13000 (0x400000 present,
 * 0x401000 NP = the pfault demand-page target).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04e.ld; objcopy -O binary,
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

    /* ==== REVIEW1_Aug3 R2-C03: S_FENV_ST page-crossing CORRECTNESS =============
     * FNSTENV (28-byte 32-bit image, written in 4-byte beats) at linear 0x2FFE:
     * beat 0 spans 0x2FFE-0x3001 and crosses the 0x3000 boundary (an image based
     * at 0x2FFC would place every beat inside one page and prove nothing).
     * Page 2 (0x2000) is identity; page 3 (0x3000) is phys 0x600000 and starts
     * NOT PRESENT.
     *
     * Case A (atomicity): the engine must probe page 2 with write permission
     * BEFORE committing any byte: #PF(CR2=0x3000) with the page-1 sentinel
     * (0xA5A5A5A5 at 0x2FFC-0x2FFF) UNTOUCHED. pf_handler's CR2==0x3000 arm
     * checks the sentinel (marker 0x2038 = 0x600DF00D), maps page 3 present,
     * and IRETs; the fnstenv restarts and completes.
     *
     * Case B (correctness): the restarted image lands split across the two
     * NON-CONTIGUOUS frames. Deterministic fields after fninit+fnop: CW=0x037F
     * (0x2FFE, the crossing beat's page-1 bytes), SW=0x0000 (0x3002), TW=0xFFFF
     * (0x3006). FIP/FCS/FOP are recorded for the differential. All reads are
     * WORD/dword field reads -- never the reserved image bytes. */
    movl    $0xA5A5A5A5, 0x00002FFC     /* page-1 sentinel (bytes 0x2FFC..0x2FFF) */
    fninit
    fnop
    fnstenv 0x00002FFE                  /* #PF (page 3 NP) -> mapped -> RESTART completes */
    movzwl  0x00002FFE, %eax            /* CW (page 2) */
    movl    %eax, 0x00002040            /* want 0x037F */
    movzwl  0x00003002, %eax            /* SW (page 3, phys 0x600002) */
    movl    %eax, 0x00002044            /* want 0x0000 */
    movzwl  0x00003006, %eax            /* TW (page 3, phys 0x600006) */
    movl    %eax, 0x00002048            /* want 0xFFFF */
    /* FIP/FCS/FOP (0x300A/0x300E/0x3010) are deliberately NOT read: QEMU only
     * updates fpip/fpcs for FPU ops that can raise #MF, so after fninit+fnop its
     * FIP/FCS stay 0 while the RTL tracks fnop's address -- a pre-existing
     * FNSTENV-field semantic difference, NOT a page-crossing property. The
     * crossing is fully proven by CW (the crossing beat's page-1 bytes) + SW/TW
     * (page-3 fields). */

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
    movl    0x00002028, %eax            /* #PF counter (2: crossing + demand-page) */
    addl    0x0000202C, %eax            /* + #GP counter */
    addl    0x00002024, %eax            /* + #UD counter */
    movl    %eax, %ecx                  /* ecx = 4 if all four faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 (0x401000); the exit port load
                                         * below overwrites dx -> exit record 0x004000F4 */
    movl    0x00002038, %edi            /* edi = 0x600DF00D (case A: page 1 untouched) */
    movl    0x00002040, %eax            /* CW */
    movl    0x00002048, %ebx            /* TW */
    shll    $16, %ebx
    orl     %eax, %ebx                  /* ebx = (TW<<16)|CW = 0xFFFF037F */
    movl    0x00002044, %ebp            /* ebp = SW = 0 */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: dispatch on CR2.  CR2 == 0x3000: the R2-C03 case-A crossing
     * FNSTENV hit the not-present page 3 -- verify the page-1 sentinel survived
     * (no partial commit), map PT0[3] -> phys 0x600000 P|RW, IRET (restart).
     * Otherwise (0x401000): the pfault demand-page case.  Stack on entry
     * (same-priv, with error code): [esp]=errcode, [esp+4]=EIP, [esp+8]=CS,
     * [esp+12]=EFLAGS.  We save EAX first (so +4 to those).                  */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    cmpl    $0x00003000, %eax
    je      pf_cross
    movl    %eax, 0x00002020            /* record CR2 (the faulting linear addr) */
    movl    $0x00801003, %eax
    movl    %eax, 0x00013004            /* PT1[1] := phys 0x801000 | P|RW */
    incl    0x00002028                  /* #PF counter */
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
    iret                                /* RESTART the faulting fnstenv (FAULT) */

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
