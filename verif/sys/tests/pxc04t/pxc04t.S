/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.3 — bare-metal HARDWARE-FAULT (IDT delivery) demonstrator, extended
 * for REVIEW1_Aug3 R2-C03 (the generic page-crossing FRAGMENT ENGINE).
 *
 * Skeleton = the M2S.3 pfault gate test (see pxc04f.S for the full story). On top
 * of it this image converts the old xc04 reachability probe for producer
 * S_TSW_SAVE (the hardware-task-switch outgoing state save) into a CORRECTNESS
 * gate, differential against QEMU:
 *
 *   TSS1 (the OUTGOING task, selector 0x18) is based at linear 0x2FDE so the
 *   saved-state block (TSS offsets 0x20..0x63) starts at 0x2FFE: the saved-EIP
 *   dword STRADDLES the 0x3000 boundary (low half phys 0x2FFE, high half phys
 *   0x600000) and everything above it (EFLAGS 0x3002, EAX 0x3006, ESP 0x3016,
 *   CS 0x302A, ...) lands on the NON-CONTIGUOUS frame phys 0x600000 (page 3).
 *   Phys 0x3000 (the wrong, linear-adjacent frame) is pre-poisoned with
 *   0x0B0B0B0B and phys 0x600000 pre-seeded with 0x5A5A5A5A. The incoming task
 *   (TSS2, selector 0x20, based at identity-linear 0x6000) reads the saved
 *   fields back THROUGH PAGING and verifies EIP == the resume point, EAX ==
 *   the live 0x1A1A1A1A, ESP == 0x90000, CS == 0x08 -> marker 0x2038 =
 *   0x600DF00D; saved EIP/EFLAGS are recorded for the differential.
 *
 *   NO not-present/atomicity variant for this producer: QEMU's switch_tss_ra
 *   pre-touches the outgoing TSS with dummy byte accesses at tr.base and
 *   tr.base+0x67 ("we must avoid memory exceptions during the task switch"),
 *   so under QEMU an NP second page faults at the dummy access (CR2=0x3045)
 *   while the RTL's per-fragment probe faults at the actual save write
 *   (CR2=0x3000). The fault-and-restart completes identically in both, but
 *   CR2 IS architecturally visible in the trace and genuinely differs (the
 *   RTL does not emulate QEMU's dummy-access hack, and the SDM pins no CR2 for
 *   a fault mid-task-switch) -- an oracle gap, so the atomicity property for
 *   TSS saves is covered structurally by the pxc04f/pxc04e pattern instead.
 *
 * Exit-record witnesses:
 *   ecx = 3 (pfault #PF/#GP/#UD), edx = 0x004000F4 (CR2 0x401000, dx clobbered
 *   by the 0xF4 port), esi = 0xCAFEBABE, edi = 0x600DF00D (saved fields
 *   verified across the split), ebx = 0x1A1A1A1A (saved EAX read back from phys
 *   0x600006), ebp = saved EIP (differential-only).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pxc04t.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan: GDT @0x500 (idx3 0x18 = TSS1 base 0x2FDE, idx4 0x20 = TSS2 base
 * 0x6000, both limit 0x67 access 0x89), IDT @0x1000, markers @0x2000..0x2060,
 * stack @0x90000, PD @0x11000, PT0 @0x12000 (identity EXCEPT PT0[3]: linear
 * 0x3000 -> phys 0x600000), PT1 @0x13000 (0x400000 present, 0x401000 NP = the
 * pfault demand-page target).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxc04t.ld; objcopy -O binary,
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
     * idx3 0x18 -> TSS1 base 0x00002FDE (the OUTGOING task; base chosen so the
     *              S_TSW_SAVE of EIP at TSS offset 0x20 lands on linear 0x2FFE
     *              and straddles the 0x3000 page boundary).
     * idx4 0x20 -> TSS2 base 0x00006000 (the INCOMING task, identity-linear).
     * Descriptor: limit 0x67, access 0x89 (available 32-bit TSS), gran 0.
     * The GDT limit stays 0x2F so the pfault #GP selector 0x38 is past it.   */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x2FDE0067, 24(%ebx)       /* idx3 0x18 TSS1 base[15:0]=0x2FDE lim=0x67 */
    movl    $0x00008900, 28(%ebx)
    movl    $0x60000067, 32(%ebx)       /* idx4 0x20 TSS2 base[15:0]=0x6000 lim=0x67 */
    movl    $0x00008900, 36(%ebx)
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
    /* PT0[3]: linear 0x3000 -> phys 0x600000, PRESENT (non-contiguous) */
    movl    $0x00600003, 0x0001200C
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
    movl    $0x5A5A5A5A, %eax           /* distinct garbage on the RIGHT frame: */
    movl    %eax, 0x00600000            /* an unwritten saved field reads back */
    movl    %eax, 0x00600004            /* 0x5A5A5A5A, never the expected value */
    movl    %eax, 0x00600008
    movl    %eax, 0x0060000C

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ==== REVIEW1_Aug3 R2-C03: S_TSW_SAVE page-crossing CORRECTNESS ============
     * Zero + stage the INCOMING TSS2 at linear 0x6000 (identity), LTR the
     * OUTGOING TSS1 (base 0x2FDE), set a recognizable live EAX, then far-JMP to
     * TSS2. The switch SAVES the outgoing state into TSS1: EIP at linear 0x2FFE
     * STRADDLES (low half phys 0x2FFE, high half phys 0x600000), EFLAGS/EAX/
     * ESP/CS/... above it all land on phys 0x600002+. The incoming task
     * verifies the saved fields through paging. */
    movl    $0x00006000, %edi           /* zero TSS2 (104 bytes) */
    movl    $26, %ecx
    xorl    %eax, %eax
1:  movl    %eax, (%edi); addl $4, %edi; loop 1b
    /* TSS2: CR3@0x1C, EIP@0x20, EFLAGS@0x24, ESP@0x38, ES/CS/SS/DS/FS/GS
     * @0x48..0x5C, LDTR@0x60 (left 0 = null) */
    movl    %cr3, %eax
    movl    %eax,        0x0000601C
    movl    $tsw_land,   0x00006020
    movl    $0x00000002, 0x00006024
    movl    $0x0008F000, 0x00006038     /* incoming ESP (identity stack page) */
    movl    $0x00000010, 0x00006048
    movl    $0x00000008, 0x0000604C
    movl    $0x00000010, 0x00006050
    movl    $0x00000010, 0x00006054
    movl    $0x00000010, 0x00006058
    movl    $0x00000010, 0x0000605C

    movw    $0x0018, %ax
    ltr     %ax                         /* TR -> TSS1 (base 0x2FDE) */
    movl    $0x1A1A1A1A, %eax           /* the live EAX the save must capture */
    .byte   0xEA                        /* ljmp $0x20,$0 -> task switch */
    .long   0
    .word   0x0020
tsw_land:
    /* INCOMING task. Verify the OUTGOING save across the split:
     * saved EIP @0x2FFE (straddling) == tsw_land; saved EAX @0x3006 ==
     * 0x1A1A1A1A; saved ESP @0x3016 == 0x90000; saved CS @0x302A == 0x08. */
    cmpl    $tsw_land, 0x00002FFE
    jne     1f
    cmpl    $0x1A1A1A1A, 0x00003006
    jne     1f
    cmpl    $0x00090000, 0x00003016
    jne     1f
    cmpw    $0x0008, 0x0000302A
    jne     1f
    movl    $0x600DF00D, 0x00002038     /* save verified across the boundary */
1:  movl    0x00002FFE, %eax            /* saved EIP record (crossing readback) */
    movl    %eax, 0x00002048
    movl    0x00003006, %eax            /* saved EAX record (phys 0x600006) */
    movl    %eax, 0x0000203C
    movl    0x00003002, %eax            /* saved EFLAGS record (phys 0x600002) */
    movl    %eax, 0x00002044

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
    addl    0x00002024, %eax            /* + #UD counter */
    movl    %eax, %ecx                  /* ecx = 3 if all three faults delivered */
    movl    0x00002020, %edx            /* edx = captured CR2 (0x401000); the exit port load
                                         * below overwrites dx -> exit record 0x004000F4 */
    movl    0x00002038, %edi            /* edi = 0x600DF00D (save verified across the split) */
    movl    0x0000203C, %ebx            /* ebx = 0x1A1A1A1A (saved EAX, phys 0x600006) */
    movl    0x00002048, %ebp            /* ebp = saved EIP (differential record) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */

    /* #PF handler: the pfault demand-page case (the task-switch save takes no
     * #PF -- both its pages are present).  Stack on entry (same-priv, with
     * error code): [esp]=errcode, [esp+4]=EIP, [esp+8]=CS, [+12]=EFLAGS.    */
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
