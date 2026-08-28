/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test (see pxc04f.S for the full story). On top
 * of it this image converts the old xc04 reachability probe for producer S_LGDT
 * (the 6-byte GDTR pseudo-descriptor read) into a CORRECTNESS gate, differential
 * against QEMU (whose helper_lgdt reads the limit and base through the softmmu --
 * each crossing access looked up on BOTH pages before use -- and only then
 * commits env->gdt):
 *
 *   Case A (no partial commit on a faulting READ): the pseudo-descriptor sits at
 *       linear 0x2FFE (limit word on page 2, base dword at 0x3000 on page 3) with
 *       page 3 NOT PRESENT. The lgdt must #PF with CR2=0x3000 and GDTR must be
 *       UNCHANGED by the rejected read: the #PF handler proves it behaviourally
 *       (SGDT is decoder-scoped to !paging_on) -- a GS := 0x18 load through the
 *       ACTIVE GDTR + a gs:0x20F0 read returns the 0xDEADBEEF sentinel only if
 *       GDTR still names the boot table -> marker 0x2038 = 0x600DF00D. The
 *       handler maps page 3 -> phys 0x600000 and IRETs; the lgdt RESTARTS and
 *       completes.
 *   Case B (correctness, non-contiguous frames): page 2 identity, page 3 ->
 *       phys 0x600000 (the base dword is planted there through the 0x402000
 *       alias while page 3 is NP; phys 0x3000 is pre-poisoned with 0x0B0B0B0B).
 *       After the restart the loaded GDTR is USED: the new GDT (6 entries at
 *       linear 0x400000 -> phys 0x800000, incl. a code32 at 0x08 so IDT
 *       deliveries keep working, a data32 at 0x10, and a data segment at 0x18
 *       with base 0x20F0) serves a DS load + a read of the sentinel 0xDEADBEEF
 *       (marker 0x2048), and a GS := 0x28 load (idx 5, INSIDE limit 0x2F) must
 *       commit (marker 0x203C) while the pfault #GP case (selector 0x38) faults
 *       past it -- together proving base AND limit landed from the two frames.
 *
 * Exit-record witnesses:
 *   ecx = 4 (two #PF + #GP + #UD), edx = 0x004000F4 (CR2 0x401000, dx
 *   clobbered by the 0xF4 port),
 *   esi = 0xCAFEBABE (pfault flow), edi = 0x600DF00D (case A: GDTR unchanged),
 *   ebx = 0x600DF00D (case B: in-limit selector 0x28 committed), ebp =
 *   0xDEADBEEF (case B: sentinel read through the new GDT's 0x18 descriptor).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan: GDT @0x500, IDT @0x1000, markers @0x2000..0x2060 (the 0xDEADBEEF
 * sentinel lives at 0x20F0, OUTSIDE the zeroed range), stack @0x90000,
 * PD @0x11000, PT0 @0x12000 (identity + PT0[3]: linear 0x3000 -> phys 0x600000
 * starting NOT-PRESENT), PT1 @0x13000 (0x400000 -> phys 0x800000 present = the
 * new GDT, 0x401000 NP = the pfault demand-page target, 0x402000 -> phys
 * 0x600000 present = the setup alias for page 3's NP phase).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04.ld; objcopy -O binary,
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

    /* --- build the boot GDT (6 entries = 48 bytes) at linear 0x0500 --- */
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

    /* zero the marker area at 0x2000..0x2060 (the sentinel at 0x20F0 is OUTSIDE) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $24, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* the case-B sentinel: read through the NEW GDT's 0x18 descriptor (base
     * 0x20F0) after the crossing LGDT. Paging is still OFF -> physical write. */
    movl    $0xDEADBEEF, 0x000020F0

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

    /* PT1 @ 0x13000: the 4 MiB window */
    movl    $0x00013000, %edi
    movl    $0x00800003, 0(%edi)        /* PT1[0] linear 0x400000 -> phys 0x800000 P|RW (new GDT) */
    movl    $0x00801002, 4(%edi)        /* PT1[1] linear 0x401000 -> phys 0x801000 P=0 (demand-page target) */
    movl    $0x00600003, 8(%edi)        /* PT1[2] linear 0x402000 -> phys 0x600000 P|RW (setup alias) */

    /* PD @ 0x11000 */
    movl    $0x00011000, %edi
    movl    $0x00012003, 0(%edi)        /* PD[0] -> PT0 | P|RW (identity low 1 MiB) */
    movl    $0x00013003, 4(%edi)        /* PD[1] -> PT1 | P|RW (the 4 MiB window) */

    /* physical pre-seeds for the crossing window (paging still OFF) */
    movl    $0x0B0B0B0B, %eax
    movl    %eax, 0x00003000            /* poison the WRONG adjacent frame */
    movl    %eax, 0x00003004

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ==== REVIEW1_Aug3 R2-C03: S_LGDT page-crossing CORRECTNESS ================
     * The 6-byte pseudo-descriptor at linear 0x2FFE: limit word on page 2
     * (identity), base dword at 0x3000 on page 3 (phys 0x600000, starting NOT
     * PRESENT -- the base is planted through the 0x402000 alias).
     *
     * First build the NEW GDT the descriptor will point at: 6 entries at linear
     * 0x400000 (phys 0x800000): idx1 code32 flat (IDT deliveries read their CS
     * descriptor through the ACTIVE GDT, so the new table must keep 0x08
     * valid), idx2 data32 flat, idx3 (0x18) a data segment with base 0x20F0 /
     * limit 0xFFF (the sentinel segment), idx4/5 flat clones; limit 0x2F so the
     * pfault #GP case (selector 0x38) still faults past the limit. */
    movl    $0x00400000, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x20F00FFF, 24(%ebx)       /* idx3 0x18 data: base 0x20F0, limit 0xFFF */
    movl    $0x00409200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data32 flat clone */
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)       /* idx5 0x28 data32 flat clone */
    movl    $0x00CF9200, 44(%ebx)

    /* plant the pseudo-descriptor: limit on page 2 (identity), base on page 3
     * via the alias (page 3 itself is NP until the #PF handler maps it) */
    movw    $0x002F, 0x00002FFE         /* limit -> 0x2FFE..0x2FFF (page 2, phys 0x2FFE) */
    movl    $0x00400000, 0x00402000     /* base  -> phys 0x600000 == linear 0x3000 (page 3) */

    /* Case A: page 3 NP -> the lgdt #PFs (CR2=0x3000) with GDTR UNCHANGED (the
     * pf_handler SGDTs and checks the base is still 0x500 -> marker 0x2038),
     * maps page 3 present, IRETs -> the lgdt RESTARTS and completes. */
    lgdt    0x00002FFE                  /* ONE 6-byte read across the boundary */

    /* Case B: prove the loaded GDTR actually WORKS (SGDT would be the direct
     * readback, but the decoder deliberately scopes SGDT/SIDT to !paging_on --
     * decode_stages.sv 0F 01 /0-/1 -- so the proof is behavioural).
     * Base+use proof: selector 0x18 names the sentinel segment (base 0x20F0) in
     * the NEW GDT; a correct base makes ds:0 read 0xDEADBEEF. NOTE: with DS
     * base 0x20F0 every absolute reference is offset by the base, so save the
     * readback in ECX and store the marker only AFTER DS is flat again. */
    movw    $0x18, %ax
    movw    %ax, %ds
    movl    0, %eax                     /* linear 0x20F0 via base 0x20F0 */
    movl    %eax, %ecx
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %ecx, 0x00002048            /* want 0xDEADBEEF */
    /* Limit proof: selector 0x28 (idx 5) is INSIDE limit 0x2F and must load
     * cleanly (a short limit #GPs here and the cascade diverges); the pfault
     * #GP case below (selector 0x38) brackets the limit from above. */
    movw    $0x28, %ax
    movw    %ax, %gs
    movl    $0x600DF00D, 0x0000203C     /* reached only if the 0x28 load committed */
    movw    $0x10, %ax
    movw    %ax, %gs

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
    movl    0x00002038, %edi            /* edi = 0x600DF00D (case A: GDTR unchanged) */
    movl    0x0000203C, %ebx            /* ebx = 0x00400000 (case B: SGDT base readback) */
    movl    0x00002048, %ebp            /* ebp = 0xDEADBEEF (case B: sentinel via new GDT) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: dispatch on CR2.  CR2 == 0x3000: the R2-C03 case-A crossing
     * LGDT hit the not-present page 3 on its base dword. The rejected read must
     * NOT have committed anything: SGDT and check GDTR.base is still the boot
     * GDT's 0x500 (marker 0x2038 = 0x600DF00D). Then map PT0[3] -> phys
     * 0x600000 P|RW and IRET (the lgdt restarts).  Otherwise (0x401000): the
     * pfault demand-page case.  Stack on entry (same-priv, with error code):
     * [esp]=errcode, [esp+4]=EIP, [esp+8]=CS, [esp+12]=EFLAGS.               */
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
    /* case A: the rejected crossing read must have left GDTR UNCHANGED. SGDT is
     * decoder-scoped to !paging_on, so prove it behaviourally: load GS := 0x18
     * through the ACTIVE GDTR and read gs:0x20F0. If GDTR still names the BOOT
     * table (base 0x500), GDT[3] is the flat clone -> gs:0x20F0 is linear
     * 0x20F0 -> the 0xDEADBEEF sentinel. If the faulting lgdt had committed the
     * new base, GDT[3] would be the 0x20F0-based sentinel segment and the read
     * would land on linear 0x40E0 (zero) instead. */
    movw    $0x18, %ax
    movw    %ax, %gs
    movl    %gs:0x000020F0, %eax
    cmpl    $0xDEADBEEF, %eax
    jne     1f
    movl    $0x600DF00D, 0x00002038     /* no-partial-commit witness */
1:  movw    $0x10, %ax
    movw    %ax, %gs                    /* restore the flat GS */
    movl    $0x00600003, 0x0001200C     /* PT0[3] := phys 0x600000 | P|RW */
    incl    0x00002028                  /* #PF counter */
    movl    %cr3, %eax
    movl    %eax, %cr3                  /* flush TLB for the restart */
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret                                /* RESTART the faulting lgdt (FAULT) */

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
