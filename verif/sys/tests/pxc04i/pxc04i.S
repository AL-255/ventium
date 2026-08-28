/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test (see pxc04f.S for the full story). On top
 * of it this image converts the old xc04 reachability probe for producer
 * S_INT_PUSH (the exception-frame write) into a CORRECTNESS gate, differential
 * against QEMU:
 *
 *   ESP := 0x8E002, then UD2 (no error code): the 12-byte frame occupies
 *   0x8DFF6..0x8E001 across the 0x8E000 boundary -- saved EIP @0x8DFF6 and CS
 *   @0x8DFFA on page 0x8D (identity), saved EFLAGS @0x8DFFE STRADDLING: its low
 *   half on phys 0x8DFFE, its high half on phys 0x700000 (page 0x8E is mapped
 *   NON-CONTIGUOUS). Phys 0x8E000 (the wrong, linear-adjacent frame) is
 *   pre-poisoned with 0x0B0B0B0B and phys 0x700000 pre-seeded with 0x5A5A5A5A,
 *   so a wrong-physical-page tail write is observable. The #UD handler
 *   recognizes the crossing frame by its ESP, reads all three dwords back (the
 *   EFLAGS read itself crosses), verifies saved EIP == the ud2 address and
 *   saved CS == 0x08 -> marker 0x2038 = 0x600DF00D, records EFLAGS/CS for the
 *   differential, and resumes the mainline.
 *
 *   NO not-present/atomicity variant for this producer: the frame push IS the
 *   exception-delivery mechanism. A second page that rejects the push faults
 *   the DELIVERY itself; the nested #PF's own frame push crosses into the same
 *   rejecting page (ESP is unchanged by an aborted delivery), so #PF-during-
 *   #PF -> #DF -> triple fault on ANY correct implementation, QEMU included.
 *   "Fault delivers cleanly + page 1 untouched" is architecturally
 *   unobservable for S_INT_PUSH; the correctness of the probe-before-commit
 *   order for writes is covered by pxc04f/pxc04e/pxc04t instead.
 *
 * Exit-record witnesses:
 *   ecx = 4 (#UD crossing + pfault #PF/#GP/#UD), edx = 0x004000F4 (CR2
 *   0x401000, dx clobbered by the 0xF4 port), esi = 0xCAFEBABE (pfault flow),
 *   edi = 0x600DF00D (frame content verified from both pages), ebp = 0x08
 *   (saved CS), ebx = saved EFLAGS (differential-only).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04i.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan: GDT @0x500, IDT @0x1000, markers @0x2000..0x2060, stack
 * @0x90000, PD @0x11000, PT0 @0x12000 (identity; stack region override PT0[0x8E]:
 * linear 0x8E000 -> phys 0x700000), PT1 @0x13000 (0x400000 present, 0x401000 NP
 * = the pfault demand-page target).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04i.ld; objcopy -O binary,
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
    /* stack: PT0[0x8D..0x90] = identity [0x8D000,0x91000), EXCEPT PT0[0x8E]:
     * linear 0x8E000 -> phys 0x700000 (the NON-CONTIGUOUS crossing target) */
    movl    $0x00012234, %edi           /* &PT0[0x8D] = 0x12000 + 0x8D*4 */
    movl    $0x0008D003, %eax           /* frame 0x8D000 | P|RW */
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00700003, 0x00012238     /* PT0[0x8E] := phys 0x700000 | P|RW */
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
    movl    %eax, 0x0008E000            /* poison the WRONG adjacent frame */
    movl    %eax, 0x0008E004
    movl    $0x5A5A5A5A, %eax
    movl    %eax, 0x00700000            /* distinct garbage on the RIGHT frame */
    movl    %eax, 0x00700004

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ==== REVIEW1_Aug3 R2-C03: S_INT_PUSH page-crossing CORRECTNESS ============
     * ESP := 0x8E002, then UD2: the 12-byte no-error-code frame spans
     * 0x8DFF6..0x8E001 across the 0x8E000 boundary. Saved EIP (0x8DFF6) and CS
     * (0x8DFFA) land on page 0x8D (phys 0x8Dxxx); saved EFLAGS (0x8DFFE)
     * STRADDLES: low half phys 0x8DFFE, high half phys 0x700000. The handler
     * verifies the frame from BOTH pages. */
    movl    $ud2x_resume, %eax
    movl    %eax, 0x0000203C            /* resume-EIP slot for the crossing UD2 */
    movl    $0x0008E002, %esp
ud2x:
    ud2                                 /* frame push crosses the boundary */
ud2x_resume:
    movl    $0x00090000, %esp

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
    movl    0x00002028, %eax            /* #PF counter */
    addl    0x0000202C, %eax            /* + #GP counter */
    addl    0x00002024, %eax            /* + #UD counter (2: crossing + pfault) */
    movl    %eax, %ecx                  /* ecx = 4 if all four faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 (0x401000); the exit port load
                                         * below overwrites dx -> exit record 0x004000F4 */
    movl    0x00002038, %edi            /* edi = 0x600DF00D (frame verified from both pages) */
    movl    0x00002044, %ebx            /* ebx = saved EFLAGS (differential record) */
    movl    0x00002048, %ebp            /* ebp = saved CS = 0x08 */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: the pfault demand-page case only (the crossing frame push
     * takes no #PF -- both its pages are present).  Stack on entry (same-priv,
     * with error code): [esp]=errcode, [esp+4]=EIP, [esp+8]=CS, [+12]=EFLAGS. */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    movl    %eax, 0x00002020            /* record CR2 (the faulting linear addr) */
    movl    $0x00801003, %eax
    movl    %eax, 0x00013004            /* PT1[1] := phys 0x801000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting store (FAULT) */

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

    /* #UD handler: dispatch on the frame address. ESP == 0x8DFF6: the R2-C03
     * crossing frame -- [esp]=EIP and [esp+4]=CS are on page 0x8D, [esp+8]
     * (EFLAGS) straddles into phys 0x700000. Verify saved EIP == ud2x and saved
     * CS == 0x08 (marker 0x2038 = 0x600DF00D), record EFLAGS + CS for the
     * differential, resume via the 0x203C slot. Otherwise the pfault #UD case:
     * count + resume via the 0x2034 slot. No error code either way.        */
    .align 16
    .global ud_handler
ud_handler:
    cmpl    $0x0008DFF6, %esp           /* the crossing frame? (BEFORE the push) */
    je      ud_cross
    pushl   %eax
    incl    0x00002024                  /* #UD counter */
    movl    0x00002034, %eax            /* the resume EIP the mainline stashed */
    movl    %eax, 0x04(%esp)            /* overwrite saved EIP -> resume past UD2 */
    popl    %eax
    iret                                /* no error code to discard for #UD */

ud_cross:
    pushl   %eax
    movl    4(%esp), %eax               /* saved EIP (page 0x8D) */
    cmpl    $ud2x, %eax
    jne     1f
    movzwl  8(%esp), %eax               /* saved CS (page 0x8D) */
    cmpw    $0x0008, %ax
    jne     1f
    movl    $0x600DF00D, 0x00002038     /* frame verified across the boundary */
1:  movl    12(%esp), %eax              /* saved EFLAGS: low half phys 0x8DFFE,
                                         * high half phys 0x700000 */
    movl    %eax, 0x00002044
    movzwl  8(%esp), %eax
    movl    %eax, 0x00002048            /* saved CS record */
    incl    0x00002024                  /* #UD counter */
    movl    0x0000203C, %eax            /* the crossing UD2's resume EIP */
    movl    %eax, 0x04(%esp)
    popl    %eax
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
