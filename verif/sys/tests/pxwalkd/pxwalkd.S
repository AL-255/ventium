/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug4 A4-C01 — page-walk Dirty-intent (walk_set_dirty) gate.
 *
 * Skeleton = the pxc04m/pfault bare-metal image (real -> protected -> paging,
 * IDT with a #PF gate, isa-debug-exit). On top of it this image pins the
 * core's distinction between walk_is_write (architectural write class: the
 * W/R permission check + the #PF error code) and walk_set_dirty (may change
 * architectural Dirty state). A crossing STORE first PROBES page 2 (write
 * permission, no data) before writing page 1 and then page 2; the probe walks
 * with walk_is_write=1 but walk_set_dirty=0. The pre-fix core used
 * walk_is_write where walk_set_dirty was meant at three consumers:
 *   (1) with page-2 P|RW|A (D=0) and a COLD DTLB the probe walk neither wrote
 *       back D nor filled the TLB -> infinite walk loop (the test would HANG);
 *   (2) with page-2 P|RW (A=0,D=0) the probe's A-bit writeback also wrote
 *       D=1 -> page 2 architecturally dirtied even when page 1 then faults
 *       and no store byte ever commits.
 *
 * Four cases, each pinned by exit-record witnesses:
 *
 *   Case 1 (4 KiB, clean-leaf probe completion): crossing dword store at
 *       0x400FFE. Page 2 (linear 0x401000, PTE PT1[1]) = P|RW|A, D=0, DTLB
 *       COLD (never touched before). Pre-fix: HANG. Post-fix: finite; the
 *       real write sets D -> PT1[1] = 0x00801063. QEMU reaches the SAME final
 *       PTE (its TLB-fill walk for the second lookup sets A|D at fill time,
 *       excp_helper.c get_physical_address with access_type==MMU_DATA_STORE).
 *       Data readback proves both fragments landed (0xDEADBEEF).
 *   Case 2 (4 KiB, probe does not dirty on fault): page 1 = P (RO), page 2 =
 *       P|RW A=0 D=0. The straddling store at 0x402FFE probes page 2
 *       (permission OK) then faults writing page 1 -> #PF(0x3, CR2=0x402FFE).
 *       The handler tests page-2's PTE with `test` (NO register load, see
 *       ORACLE GAP below): D must be 0, P must be 1.
 *   Case 3 (4 MiB leaf): crossing dword store at 0x7FFFFE; page 2 (linear
 *       0x800000) lives in the 4 MiB PSE page PD[2] = phys 0xC00000 |
 *       P|RW|A|PS, D=0. Completion + the guest reads the PDE back: D must be
 *       set -> PD[2] = 0x00C000E3.
 *   Case 4 (W/R=1 on probe permission fault): page 1 = P|RW|A|D (pre-set --
 *       see ORACLE GAP below), page 2 = P (RO). The straddling store at
 *       0x404FFE probes page 2 -> #PF from the PROBE: error code 0x3
 *       (P=1, W/R=1 -- a STORE fault --, US=0), CR2 = 0x405000 (the page-2
 *       probe address). QEMU agrees: its second lookup faults with
 *       access_type==MMU_DATA_STORE.
 *
 * ORACLE GAP (case 2's A bit, documented like pselnull's oracle_gaps): QEMU
 * 8.2.2's softmmu looks up page 1 BEFORE page 2 (accel/tcg/cputlb.c
 * mmu_lookup: two mmu_lookup1 calls in address order), so its page-1 lookup
 * faults FIRST and page 2 is NEVER probed -> page 2's PTE stays A=0. The
 * RTL's fragment engine probes page 2 FIRST (atomicity: no byte commits
 * unless both pages accept the store), so its probe walk sets A=1 on page 2's
 * PTE before the page-1 fault. Both oracles agree on the architecturally
 * graded facts -- the probe does NOT set D (A4-C01) and the fault is the
 * page-1 #PF(0x3) -- but the raw PTE differs (0x00803003 QEMU vs 0x00803023
 * RTL). The handler therefore reads page-2's PTE ONLY through `test`
 * instructions on the D and P bits (identical EFLAGS in both oracles, no
 * divergent value ever enters a register), and the manifest records the gap
 * in oracle_gaps. (Symmetrically, case 4 pre-sets page 1 P|RW|A|D because
 * QEMU's page-1 TLB fill marks A|D at fill time even though the store then
 * faults on page 2; the RTL's probe faults before page 1 is ever walked.)
 *
 * Exit-record witnesses:
 *   esi = 0x00800063  (case 1 page-1 PTE: A|D set by the real write)
 *   edi = 0x00801063  (case 1 page-2 PTE: the clean-leaf probe COMPLETED and
 *                      the real write set D -- pre-fix: hang)
 *   ebp = 0x00806063  (case 3 page-1 PTE)
 *   ebx = 0x00C000E3  (case 3 4 MiB PDE: D set by the real write)
 *   edx = 0x004000F4  (case 4 CR2 = 0x405000 = the page-2 probe address, dx
 *                      clobbered by the 0xF4 exit-port load)
 *   ecx = 0x01270303  (packed: [7:0]=case-2 err 0x03, [15:8]=case-4 err 0x03,
 *                      bit16=case-2 page-2 D==0, bit17=case-2 page-2 P==1,
 *                      bit18=case-1 data landed, [22:20]=#PF count 2,
 *                      [31:24]=case-4 page-2 PTE is P|RW=0|D=0 -- the faulting
 *                      probe wrote nothing back, checked with `test` only)
 *
 * Memory plan: GDT @0x500, IDT @0x1000 (vector 14), markers @0x2000..0x2060,
 * stack @0x90000, PD @0x11000, PT0 @0x12000 (identity [0,0x14000) + stack +
 * code window), PT1 @0x13000 (window [4 MiB,8 MiB): entries below), PD[2] =
 * 4 MiB PSE page at [8 MiB,12 MiB) -> phys 0xC00000. Build: gcc -m32
 * -ffreestanding -nostdlib -Wl,-T,pxwalkd.ld; objcopy -O binary, padded to
 * exactly 64 KiB. GNU-as syntax; no nasm.
 *
 * Marker slots:
 *   0x2028 #PF counter            0x2040 case-2 error code
 *   0x2030 resume-EIP slot        0x2048 case-2 D==0 proof (1)
 *                                 0x204C case-2 P==1 proof (1)
 *                                 0x2050 case-4 error code
 *                                 0x2054 case-4 CR2
 *                                 0x2058 case-1 data-ok proof (1, byte)
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
    movl    $0x00000500, 0x0482         /* base  = 0x0500 */
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

    /* ===================== build the IDT (one #PF gate) ================= */
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
    movl    $0x00001000, 0x0492         /* IDT base = 0x1000 */
    lidt    0x0490

    /* ===================== build the page tables ================= */
    /* PT0 @ 0x12000: identity [0,0x14000) */
    movl    $0x00012000, %edi
    movl    $0x00000003, %eax           /* frame 0 | P|RW */
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* stack: PT0[0x8D..0x90] = identity [0x8D000,0x91000) */
    movl    $0x00012234, %edi           /* &PT0[0x8D] */
    movl    $0x0008D003, %eax
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* code window: PT0[0xF0..0xFF] = identity [0xF0000,0x100000) */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0003, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* PT1 @ 0x13000: the A4-C01 window [4 MiB, 8 MiB). Each case uses its OWN
     * pages so every page-2 DTLB is COLD (never touched before its store) and
     * no case's TLB state leaks into the next. */
    movl    $0x00800023, 0x00013000     /* PT1[0] case-1 page 1: P|RW|A */
    movl    $0x00801023, 0x00013004     /* PT1[1] case-1 page 2: P|RW|A, D=0 (pin 1) */
    movl    $0x00802001, 0x00013008     /* PT1[2] case-2 page 1: P, RW=0 (RO) */
    movl    $0x00803003, 0x0001300C     /* PT1[3] case-2 page 2: P|RW, A=0 D=0 */
    movl    $0x00804063, 0x00013010     /* PT1[4] case-4 page 1: P|RW|A|D (pre-set) */
    movl    $0x00805001, 0x00013014     /* PT1[5] case-4 page 2: P, RW=0 (RO) */
    movl    $0x00806023, 0x00013FFC     /* PT1[0x3FF] case-3 page 1 (lin 0x7FF000): P|RW|A */

    /* PD @ 0x11000 */
    movl    $0x00012003, 0x00011000     /* PD[0] -> PT0 (identity low 1 MiB) */
    movl    $0x00013003, 0x00011004     /* PD[1] -> PT1 (the [4,8) MiB window) */
    movl    $0x00C000A3, 0x00011008     /* PD[2] 4 MiB PSE: phys 0xC00000 | P|RW|A|PS, D=0 (pin 3) */

    /* CR4.PSE (for the 4 MiB leaf), then CR3 + CR0.PG. CR0.WP is set too:
     * without it a CPL0 store to an RO page does NOT fault (supervisor writes
     * ignore the RW bit when WP=0 -- cases 2 and 4 need the faults). */
    movl    %cr4, %eax
    orl     $0x00000010, %eax
    movl    %eax, %cr4
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80010000, %eax           /* PG | WP */
    movl    %eax, %cr0

    /* ===================== CASE 1: clean-leaf probe completion (4 KiB) ====
     * Crossing dword store at 0x400FFE; page 2's PTE is P|RW|A with D=0 and a
     * COLD DTLB. Pre-fix: the probe walk (walk_is_write=1, walk_set_dirty=0)
     * neither wrote back D nor filled the TLB -> infinite walk loop (HANG).
     * Post-fix: the probe fills the TLB, the real writes set D on both PTEs. */
    movl    $0xDEADBEEF, 0x00400FFE     /* store crosses 0x400FFF/0x401000 */
    movl    0x00400FFE, %eax
    cmpl    $0xDEADBEEF, %eax
    sete    0x00002058                  /* both fragments landed */

    /* ===================== CASE 2: probe does not dirty on fault ==========
     * Page 1 RO, page 2 P|RW A=0 D=0. The store probes page 2 (OK) then
     * faults writing page 1 -> #PF. Page 2's D must stay 0 (the handler
     * checks D and P with `test` only -- the raw PTE's A bit is an oracle
     * gap, see the header). */
    movl    $case2_resume, %eax
    movl    %eax, 0x00002030
    movl    $0x12345678, 0x00402FFE     /* #PF(0x3, CR2=0x402FFE) */
case2_resume:

    /* ===================== CASE 4: W/R=1 on probe permission fault ========
     * Page 1 P|RW|A|D (pre-set), page 2 P (RO). The store's page-2 PROBE
     * faults -> #PF whose error code must have W/R=1 (a store fault):
     * 0x3 = P|W/R. CR2 = 0x405000 (the page-2 probe address). */
    movl    $case4_resume, %eax
    movl    %eax, 0x00002030
    movl    $0x9ABCDEF0, 0x00404FFE     /* #PF(0x3, CR2=0x405000) */
case4_resume:

    /* ===================== CASE 3: 4 MiB leaf variant =====================
     * Crossing dword store at 0x7FFFFE; page 2 (0x800000) is in the 4 MiB PSE
     * page PD[2] (P|RW|A|PS, D=0). Completion + D set in the PDE. */
    movl    $0xCAFED00D, 0x007FFFFE

    /* ===================== pull the witnesses into the GPRs =============== */
    movl    0x00013000, %esi            /* PT1[0]     = 0x00800063 (case 1 pg1) */
    movl    0x00013004, %edi            /* PT1[1]     = 0x00801063 (case 1 pg2) */
    movl    0x00013FFC, %ebp            /* PT1[0x3FF] = 0x00806063 (case 3 pg1) */
    movl    0x00011008, %ebx            /* PD[2]      = 0x00C000E3 (case 3 PDE) */
    movl    0x00002054, %edx            /* case-4 CR2 = 0x00405000 */

    movl    0x00002040, %ecx            /* [7:0]   = case-2 error code (0x03) */
    movl    0x00002050, %eax
    shll    $8, %eax
    orl     %eax, %ecx                  /* [15:8]  = case-4 error code (0x03) */
    movl    0x00002048, %eax
    shll    $16, %eax
    orl     %eax, %ecx                  /* bit16   = case-2 page-2 D==0 */
    movl    0x0000204C, %eax
    shll    $17, %eax
    orl     %eax, %ecx                  /* bit17   = case-2 page-2 P==1 */
    movl    0x00002058, %eax
    shll    $18, %eax
    orl     %eax, %ecx                  /* bit18   = case-1 data landed */
    movl    0x00002028, %eax
    shll    $20, %eax
    orl     %eax, %ecx                  /* [22:20] = #PF count (2) */
    /* case-4 page-2 PTE (PT1[5]): checked with `test` ONLY -- the RTL's
     * FAULTING probe walk sets A on the RO PTE (0x00805021) while QEMU's
     * faulting lookup writes nothing back (0x00805001); D==0, RW==0 and P==1
     * are identical in both oracles (D==0 is the A4-C01 pin: the faulting
     * probe does NOT dirty). */
    xorl    %eax, %eax
    testl   $0x40, 0x00013014           /* D: 0 in BOTH oracles */
    setz    %al
    testl   $0x02, 0x00013014           /* RW: 0 in BOTH oracles */
    setz    %ah
    andb    %ah, %al
    testl   $0x01, 0x00013014           /* P: 1 in BOTH oracles */
    setnz   %ah
    andb    %ah, %al
    movzbl  %al, %eax                   /* 1 iff PTE is P|RW=0|D=0 (mod the A gap) */
    shll    $24, %eax
    orl     %eax, %ecx                  /* [31:24] = 0x01 */
                                        /* ecx = 0x01270303 */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx                  /* edx -> 0x004000F4 */
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= HANDLER ============================= */

    /* #PF handler: dispatch on CR2. CR2 == 0x402FFE: case 2 (page-1 write
     * fault after the page-2 probe) -- record the error code and check page
     * 2's PTE with `test` ONLY: the raw PTE is an oracle gap (QEMU never
     * probes page 2, so its A bit stays 0; the RTL probe sets A), while D=0
     * and P=1 are identical in both oracles and land ONLY in EFLAGS.
     * Otherwise (0x405000): case 4 -- record the error code (must be 0x3:
     * W/R=1 from the probe) and CR2. Both resume PAST the faulting store.
     * Stack on entry (same-priv, with error code), after pushl %eax:
     * [esp]=saved EAX, [esp+4]=errcode, [esp+8]=EIP, [esp+12]=CS,
     * [esp+16]=EFLAGS.                                                   */
    .align 16
    .global pf_handler
pf_handler:
    pushl   %eax
    incl    0x00002028                  /* #PF counter */
    movl    %cr2, %eax
    cmpl    $0x00402FFE, %eax
    je      pf_case2
    movl    4(%esp), %eax               /* case 4: error code (0x3) */
    movl    %eax, 0x00002050
    movl    %cr2, %eax
    movl    %eax, 0x00002054            /* case 4: CR2 (0x405000) */
    jmp     pf_out
pf_case2:
    movl    4(%esp), %eax               /* case 2: error code (0x3) */
    movl    %eax, 0x00002040
    testl   $0x40, 0x0001300C           /* page-2 PTE Dirty: 0 in BOTH oracles */
    setz    %al
    movzbl  %al, %eax
    movl    %eax, 0x00002048            /* 1 iff D==0 (the A4-C01 pin) */
    testl   $0x01, 0x0001300C           /* page-2 PTE Present: 1 in BOTH oracles */
    setnz   %al
    movzbl  %al, %eax
    movl    %eax, 0x0000204C            /* 1 iff P==1 */
pf_out:
    movl    0x00002030, %eax            /* the resume EIP the mainline stashed */
    movl    %eax, 8(%esp)               /* overwrite saved EIP -> resume past */
    popl    %eax
    addl    $4, %esp                    /* discard the #PF error code */
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
