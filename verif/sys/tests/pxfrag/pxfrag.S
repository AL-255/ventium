/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pxfrag — the fragment-engine ABORT regression, differential half (read side).
 * Skeleton = the pxc04 family (pfault-style bare-metal image, paged, non-
 * contiguous frames). The generic page-crossing fragment engine serves the
 * 6-byte GDTR pseudo-descriptor read (producer S_LGDT); this image faults
 * the READ fragment phases and proves the abort/restart contract:
 *
 *   Case A (frag2 abort + stale-frag1 poison): the pseudo-descriptor at
 *       linear 0x2FFE has page 3 (the base dword) NOT PRESENT. Frag1 (the
 *       limit word at 0x2FFE) is read into the engine's low half, then frag2
 *       faults: #PF with CR2=0x3000, GDTR UNCHANGED (proven behaviourally
 *       through the active GDTR, pxc04's trick). The #PF handler then
 *       POISONS the limit word (0x2F -> 0x47) before mapping page 3 and
 *       IRETing: a restart that began anywhere but fragment 1 (or that
 *       merged the aborted sequence's stale frag1 copy) would install the
 *       OLD limit. The restarted lgdt must install limit 0x47: selector 0x40
 *       (idx 8) then loads cleanly (a stale 0x2F limit #GPs it) while 0x48
 *       faults past the new limit -- the bracket proves the re-read.
 *   Case B (frag1 abort): the pseudo-descriptor at linear 0x4FFE has page 4
 *       (the LIMIT word, the first fragment's page) NOT PRESENT. The initial
 *       request misses translation before the engine can engage at all:
 *       #PF with CR2=0x4FFE, nothing staged. The handler maps page 4 and the
 *       restarted lgdt completes -- the proof that a restart begins at
 *       fragment 1 is that the completed GDTR works (its GDT serves a
 *       sentinel read).
 *   Case C (control): the pseudo-descriptor at linear 0x6FFE with both pages
 *       present on NON-CONTIGUOUS physical frames (page 7 -> phys 0x607000):
 *       the crossing read completes on the first attempt and its GDT serves
 *       its sentinel read.
 *
 * Every case's flow is fully differential vs QEMU (helper_lgdt reads
 * limit+base through the softmmu and commits env->gdt only after both
 * succeed). The write-side phases (probe / frag A / frag B) are covered by
 * pxc04e/pxc04f (not-present second page, probe-before-commit atomicity);
 * the fragment engine does not engage for S_LOAD/S_STORE (the older
 * xp_pend/xs split machinery), which is why the producer here is LGDT.
 *
 * Exit witnesses:
 *   ecx = 0x00000201 (two #PF + one #GP delivered),
 *   edx = 0x30004FFE (the two CR2 values: frag2 fault, frag1 fault),
 *   edi = 0x600DF00D (case A: GDTR unchanged by the rejected read),
 *   ebx = 0xFEEDFACE (case A: selector 0x40 committed == the POISONED limit
 *         0x47 was installed by the restart, not the stale 0x2F),
 *   ebp = 0xBEEFCAFE (case B: the restarted-then-completed GDTR works),
 *   esi = 0xC001D00D (case C control).
 *
 * Memory plan: GDT @0x500, IDT @0x1000, markers @0x2000..0x2060, sentinels
 * @0x20F0..0x20FF, stack @0x90000, PD @0x11000, PT0 @0x12000 (identity low
 * window except PT0[3]/PT0[4] NP-start, PT0[5]->phys 0x605000, PT0[7]->phys
 * 0x607000), PT1 @0x13000 (0x400000->0x800000, 0x405000->0x805000,
 * 0x406000->0x806000: the three case GDTs). All pseudo-descriptor halves
 * are planted with PHYSICAL writes before paging is enabled.
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

    /* boot GDT (6 entries) at 0x500 */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* 0x18 data32 flat clone */
    movl    $0x00CF9200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* 0x20 flat clone */
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)       /* 0x28 flat clone */
    movl    $0x00CF9200, 44(%ebx)
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
    movl    $0x00090000, %esp

    /* markers + sentinels (paging still OFF: physical writes) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $24, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0xDEADBEEF, 0x000020F0     /* boot-table sentinel (case-A proof) */
    movl    $0xFEEDFACE, 0x000020F4     /* case-A new-GDT idx8 segment base */
    movl    $0xBEEFCAFE, 0x000020F8     /* case-B sentinel */
    movl    $0xC001D00D, 0x000020FC     /* case-C sentinel */

    /* IDT: #PF(14) -> pf_handler, #GP(13) -> gp_handler (interrupt gates 0x8E) */
    movl    $pf_handler, %ebx
    movl    $0x00001070, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- the three case GDTs (physical writes, paging off) ----------------
     * case A @ phys 0x800000 (linear 0x400000), 10 entries (limit 0x47 after
     * the poison): idx1 code32 flat, idx2 data32 flat, idx3 flat clone,
     * idx8 (0x40) data base 0x20F4 limit 0xFFF (the poison-limit proof).
     * case B @ phys 0x805000 (linear 0x405000), 6 entries limit 0x2F:
     * idx3 (0x18) data base 0x20F8.  case C @ phys 0x806000 (linear
     * 0x406000): idx3 data base 0x20FC. */
    movl    $0x00800000, %ebx           /* case-A GDT */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* 0x18 flat clone */
    movl    $0x00CF9200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* 0x20 flat clone */
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)       /* 0x28 flat clone */
    movl    $0x00CF9200, 44(%ebx)
    movl    $0x0000FFFF, 48(%ebx)       /* 0x30 flat clone */
    movl    $0x00CF9200, 52(%ebx)
    movl    $0x0000FFFF, 56(%ebx)       /* 0x38 flat clone */
    movl    $0x00CF9200, 60(%ebx)
    movl    $0x20F40FFF, 64(%ebx)       /* 0x40 data base 0x20F4 limit 0xFFF */
    movl    $0x00409200, 68(%ebx)

    movl    $0x00805000, %ebx           /* case-B GDT */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x20F80FFF, 24(%ebx)       /* 0x18 data base 0x20F8 limit 0xFFF */
    movl    $0x00409200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)
    movl    $0x00CF9200, 44(%ebx)

    movl    $0x00806000, %ebx           /* case-C GDT */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x20FC0FFF, 24(%ebx)       /* 0x18 data base 0x20FC limit 0xFFF */
    movl    $0x00409200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)
    movl    $0x00CF9200, 44(%ebx)

    /* ---- plant the pseudo-descriptors (physical writes) ---- */
    movw    $0x002F, 0x00002FFE         /* case A limit (handler poisons to 0x47) */
    movl    $0x00400000, 0x00600000     /* case A base  (phys of NP page 3) */
    movw    $0x002F, 0x00604FFE         /* case B limit (phys of NP page 4) */
    movl    $0x00405000, 0x00605000     /* case B base  (phys of page 5) */
    movw    $0x002F, 0x00006FFE         /* case C limit (identity page 6) */
    movl    $0x00406000, 0x00607000     /* case C base  (phys of page 7) */

    /* ---- page tables ---- */
    movl    $0x00012000, %edi           /* PT0: identity [0,0x14000) */
    movl    $0x00000003, %eax
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00600002, 0x0001200C     /* PT0[3]: -> phys 0x600000, NP (case A) */
    movl    $0x00604002, 0x00012010     /* PT0[4]: -> phys 0x604000, NP (case B) */
    movl    $0x00605003, 0x00012014     /* PT0[5]: -> phys 0x605000 (case B base) */
    movl    $0x00607003, 0x0001201C     /* PT0[7]: -> phys 0x607000 (case C base) */
    movl    $0x00012234, %edi           /* stack pages 0x8D..0x90 identity */
    movl    $0x0008D003, %eax
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x000123C0, %edi           /* code window 0xF0..0xFF identity */
    movl    $0x000F0003, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00013000, %edi           /* PT1: the case-GDT window */
    movl    $0x00800003, 0(%edi)        /* 0x400000 -> phys 0x800000 (case A) */
    movl    $0x00805003, 20(%edi)       /* 0x405000 -> phys 0x805000 (case B) */
    movl    $0x00806003, 24(%edi)       /* 0x406000 -> phys 0x806000 (case C) */
    movl    $0x00011000, %edi           /* PD */
    movl    $0x00012003, 0(%edi)
    movl    $0x00013003, 4(%edi)

    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ================= case A: frag2 abort + stale-frag1 poison ============ */
    lgdt    0x00002FFE                  /* frag1 ok, frag2 #PFs (CR2=0x3000);
                                         * the handler poisons the limit word
                                         * 0x2F->0x47 and maps page 3; restart */
    /* the restart must have installed the POISONED limit (0x47): selector
     * 0x40 (idx 8) is in-limit only then. A stale-frag1 merge would leave the
     * limit at 0x2F and #GP here instead. */
    movw    $0x40, %ax
    movw    %ax, %gs
    movl    %gs:0, %eax                 /* -> linear 0x20F4 = 0xFEEDFACE */
    movl    %eax, 0x0000203C
    movw    $0x10, %ax
    movw    %ax, %gs
    /* the upper bracket: selector 0x48 (idx 9) is past limit 0x47 -> #GP */
    movl    $gpa_resume, %eax
    movl    %eax, 0x00002030
    movw    $0x48, %ax
    movw    %ax, %ds                    /* #GP here */
gpa_resume:
    movw    $0x10, %ax
    movw    %ax, %ds

    /* ================= case B: frag1 abort (page 1 not present) ============ */
    lgdt    0x00004FFE                  /* the initial request faults BEFORE the
                                         * engine can engage (CR2=0x4FFE);
                                         * the handler maps page 4; restart */
    movw    $0x18, %ax                  /* the completed GDTR works: case-B */
    movw    %ax, %ds                    /* GDT idx3 base 0x20F8 */
    movl    0, %eax                     /* -> 0xBEEFCAFE */
    movl    %eax, %ebx                  /* keep it: restoring DS clobbers ax */
    movw    $0x10, %ax                  /* restore the flat DS BEFORE the */
    movw    %ax, %ds                    /* marker store (absolute store addr */
    movl    %ebx, 0x00002040            /*  is DS-relative) */

    /* ================= case C: non-contiguous control ====================== */
    lgdt    0x00006FFE                  /* both pages present, page 7 on phys
                                         * 0x607000: completes first try */
    movw    $0x18, %ax
    movw    %ax, %ds
    movl    0, %eax                     /* -> 0xC001D00D */
    movl    %eax, %ebx
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %ebx, 0x00002044

    /* ===================== collect witnesses + exit ======================== */
    movl    0x00002028, %eax            /* #PF count (2) */
    shll    $8, %eax
    addl    0x0000202C, %eax            /* #GP count (1) */
    movl    %eax, %ecx                  /* want 0x00000201 */
    movl    0x00002020, %edx            /* packed CR2s: 0x30004FFE */
    movl    0x00002038, %edi            /* case A: GDTR-unchanged marker */
    movl    0x0000203C, %ebx            /* case A: poisoned-limit proof */
    movl    0x00002040, %ebp            /* case B proof */
    movl    0x00002044, %esi            /* case C control */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

/* #PF handler: dispatch on CR2. Same-priv frame: [esp]=err, +4=EIP, +8=CS,
 * +12=EFLAGS. */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    movl    %cr2, %eax
    cmpl    $0x00003000, %eax
    je      pf_caseA
    /* case B (CR2=0x4FFE): pack the CR2 low half and map page 4 */
    orl     %eax, 0x00002020
    movl    $0x00604003, 0x00012010     /* PT0[4] := phys 0x604000 | P|RW */
    incl    0x00002028
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp
    iret                                /* restart the faulting lgdt */
pf_caseA:
    /* the rejected crossing read must have left GDTR UNCHANGED: GS := 0x18
     * through the ACTIVE GDTR; only the boot table makes gs:0x20F0 read the
     * 0xDEADBEEF sentinel. */
    movw    $0x18, %ax
    movw    %ax, %gs
    movl    %gs:0x000020F0, %eax
    cmpl    $0xDEADBEEF, %eax
    jne     1f
    movl    $0x600DF00D, 0x00002038
1:  movw    $0x10, %ax
    movw    %ax, %gs
    /* the poison: limit 0x2F -> 0x47. A restart that merges the aborted
     * sequence's stale frag1 copy installs 0x2F and the case-A 0x40 load
     * #GPs; a correct restart re-reads fragment 1 and installs 0x47. */
    movw    $0x0047, 0x00002FFE
    movl    $0x00600003, 0x0001200C     /* PT0[3] := phys 0x600000 | P|RW */
    incl    0x00002028
    movl    %cr2, %eax                  /* pack CR2_A into the high half */
    shll    $16, %eax
    movl    %eax, 0x00002020
    movl    %cr3, %eax
    movl    %eax, %cr3
    popl    %eax
    addl    $4, %esp
    iret                                /* restart the faulting lgdt */

/* #GP handler: count + resume past the faulting load. */
    .align 16
    .global gp_handler
gp_handler:
    pushl   %eax
    incl    0x0000202C
    movl    0x00002030, %eax
    movl    %eax, 0x08(%esp)
    popl    %eax
    addl    $4, %esp
    iret

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
