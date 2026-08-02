/* ============================================================================
 * REVIEW2 C-06 WORK-IN-PROGRESS -- THIS TEST DOES NOT YET FAULT. DO NOT TRUST IT.
 * ============================================================================
 * Intent: cross the 64 KiB based-segment limit from the OUTSIDE (pseg only ever
 * probes it from the inside) so an absent segment-limit check becomes visible.
 *
 * RESOLVED (UPDATE 350): QEMU ITSELF DOES NOT RAISE THE #GP. Confirmed with every
 * intermediate layer removed -- the exit status now encodes the #GP counter, so no
 * gdbstub, no trace parsing and no QMP are involved:
 *     qemu-system-i386 -bios pseglim.bin  ->  exit 133  (== counter 0, NO #GP)
 *                                             exit 135 would mean the #GP fired
 * Everything about the test was verified first: descriptor bytes identical to pseg's
 * working idx3; LSL reports the effective limit as 0x0000FFFF; es = 0x0018 at the
 * access; and the LINKED image disassembles to
 *     f01d3: 26 8b 15 00 00 01 00   mov %es:0x10000,%edx
 * So offset 0x10000 vs limit 0xFFFF must #GP per the SDM, and this QEMU does not.
 *
 * CONSEQUENCE: the DIFFERENTIAL oracle CANNOT grade segment-limit enforcement. C-06
 * has to be verified by a SELF-CHECK against the SDM, exactly like the FNSTENV
 * exception-masking gate (make fenv, UPDATE 333) where QEMU is likewise incomplete.
 * This file is already that harness: it asserts via the EXIT STATUS, so once C-06 is
 * implemented the gate is simply "exit == 135". Until then it would fail, so it is
 * deliberately NOT wired into any gate.
 *
 * Earlier status text, kept for the trail:
 * it BUILDS, runs to isa-debug-exit, and RTL == QEMU -- but the #GP is
 * NEVER DELIVERED, by either. Measured from the golden trace:
 *     final ecx (the #GP counter) = 0
 *     edx        0xDEADBEEF -> 0x0ff1ce00   (the load COMPLETED)
 *     es         = 0x0018 at the access, so the selector IS loaded
 * QEMU enforces segment limits, so a non-faulting access means the offset is
 * somehow WITHIN the limit -- i.e. the test is wrong, not the DUT.
 *
 * ALREADY ELIMINATED (do not re-check):
 *   - the descriptor bytes: 0x0000FFFF / 0x00409202 are byte-identical to pseg's
 *     working idx3 (base 0x00020000, limit 0xFFFF, G=0, D/B=1, P=1 DPL=0 type=0x92);
 *   - the ES override encoding: `movl %es:0x00010000, %edx` assembles to
 *     26 8b 15 00 00 01 00 -- the 0x26 prefix IS emitted.
 *
 * NOT in RTL_SYS_TESTS on purpose: a test that passes without exercising its path
 * is a false green, which is the exact failure class this tree has been cleaned of.
 * Re-add it ONLY once `ecx == 1` proves the #GP was actually delivered.
 * ============================================================================ */

/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.1 — bare-metal protected-mode SEGMENTATION-ONLY demonstrator.
 *
 * This is the M2S.1 gate test: it exercises the real->protected transition and
 * protected-mode SEGMENTATION *without* paging (paging is M2S.2 and is what the
 * M2S.0 pmode test added).  It is a freestanding "BIOS" image loaded with
 *   qemu-system-i386 -bios pseg.bin
 * QEMU maps a -bios image so its LAST byte sits at 0x000FFFFF (also aliased at
 * the top of the 32-bit space); the i386 reset vector is CS:EIP = F000:FFF0,
 * i.e. linear 0x000FFFF0 — 16 bytes before the end of a 64 KiB image.  So a
 * 16-bit reset stub at image offset 0xFFF0 jumps back to the real start.
 *
 * Flow (every step observable in the system-mode golden trace):
 *   1. real mode (cr0.PE=0): build a GDT in low RAM and lgdt it.  The GDT has:
 *        idx 0  null
 *        idx 1  (sel 0x08) 32-bit flat code   base 0      limit 4GiB  type=0xA
 *        idx 2  (sel 0x10) 32-bit flat data   base 0      limit 4GiB  type=0x92
 *        idx 3  (sel 0x18) 32-bit BASED data  base 0x20000 limit 64KiB type=0x92
 *        idx 4  (sel 0x20) 32-bit READ-ONLY data base 0   limit 4GiB  type=0x90
 *   2. set CR0.PE=1, far-jump to the 32-bit flat code segment (0x08)
 *        -> cr0.PE 0->1, then cs 0xf000 -> 0x08  (two atomic retire records)
 *   3. load DS/ES/SS/FS/GS with the flat data selector (0x10)
 *   4. a few flat segment-relative loads / stores (esp. push/pop through SS)
 *   5. SEGMENTATION proper: load DS with the BASED selector (0x18, base 0x20000)
 *      and store/load through it.  A store of X to DS-offset O writes physical
 *      0x20000+O; reading it back flat (ES base 0, offset 0x20000+O) must see X.
 *      This indirectly pins the hidden base: a wrong segment base => wrong
 *      physical address => the flat read-back GPR diverges (caught by compare.py,
 *      which does not see the hidden base directly).
 *   6. BENIGN type/limit cases that do NOT fault:
 *        - load DS with the read-only data selector (0x20) and only READ from it
 *          (reading a read-only segment is legal; writing would #GP — we don't).
 *        - a load at the very top byte still inside the 64KiB based-segment limit
 *          (offset 0xFFFC, dword) — in-bounds, no fault.
 *   7. exit cleanly via isa-debug-exit: `out 0xf4, al` with al=0x42
 *        -> qemu exits with status ((0x42)<<1)|1 = 0x85 = 133.
 *
 * NO PAGING: CR0.PG stays 0, CR3/CR4 untouched.  Linear == physical throughout.
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pseg.ld (see Makefile), then
 * objcopy -O binary, padded to exactly 64 KiB.  GNU-as syntax; no nasm.
 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld

    /* zero segment registers / set a real-mode stack in low RAM */
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp        /* real-mode stack below the GDT copy */

    /* --- build the GDT (5 entries = 40 bytes) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    /* idx 0: null descriptor */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    /* idx 1 (0x08): code32 base=0 limit=0xFFFFF G=1 D=1 P=1 DPL=0 type=0xA
     *   low  = 0x0000FFFF ; high = 0x00CF9A00                                */
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    /* idx 2 (0x10): data32 flat base=0 limit=0xFFFFF G=1 B=1 type=0x2 RW
     *   low  = 0x0000FFFF ; high = 0x00CF9200                                */
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    /* idx 3 (0x18): data32 BASED base=0x00020000 limit=0xFFFF (64KiB, G=0)
     *   B=1 P=1 DPL=0 S=1 type=0x2 (RW).
     *   low  = base15:0(0000) limit15:0(FFFF) = 0x0000FFFF
     *   high = base31:24(00) G=0 B=1 0 AVL=0 limit19:16(0) | access(0x92) |
     *          base23:16(02)  -> 0x00409202                                  */
    movl    $0x0000FFFF, 24(%ebx)
    movl    $0x00409202, 28(%ebx)
    /* idx 4 (0x20): data32 READ-ONLY base=0 limit=0xFFFFF G=1 B=1 type=0x0
     *   access byte = P=1 DPL=0 S=1 type=0x0 (read-only, accessed clear) = 0x90
     *   low  = 0x0000FFFF ; high = 0x00CF9000                                */
    movl    $0x0000FFFF, 32(%ebx)
    movl    $0x00CF9000, 36(%ebx)
    /* idx 5 (0x28): data32 BASED #2 base=0x00040000 limit=0xFFFF (64KiB, G=0)
     *   B=1 P=1 DPL=0 S=1 type=0x2 (RW).  Used for the CROSS-BASE check below:
     *   a DIFFERENT base (0x40000 vs idx3's 0x20000) so a base corruption that
     *   does not shift the two descriptors identically is caught even though the
     *   readback goes through ES (see the cross-base section).
     *   low  = 0x0000FFFF ; high = base31:24(00) G=0 B=1 limit19:16(0) |
     *          access(0x92) | base23:16(04) -> 0x00409204                     */
    movl    $0x0000FFFF, 40(%ebx)
    movl    $0x00409204, 44(%ebx)

    /* --- gdt pseudo-descriptor @0x0480: limit(2) base(4) --- */
    movw    $0x002F, 0x0480     /* limit = 48-1 = 0x2F (6 entries) */
    movl    $0x00000500, 0x0482 /* base  = 0x0500     */

    lgdt    0x0480

    /* --- enter protected mode: set CR0.PE (PG stays 0 — NO paging) --- */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far-jump to flush + load CS with the 32-bit flat code selector (0x08).
     * Encode the 32-bit far pointer by hand: 66 EA <off32> <sel16>.  Target is
     * pm32_entry as a flat linear address (code base 0 => offset == linear). */
    .byte   0x66, 0xEA          /* opsize-32 ljmp ptr16:32 */
    .long   pm32_entry          /* 32-bit offset (flat, base 0) */
    .word   0x08                /* 32-bit code selector */

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    /* reload the data segments with the flat 32-bit data selector (0x10) */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp   /* a flat 32-bit stack in low RAM */

    /* ============ REVIEW2 C-06: minimal IDT with a #GP (vector 13) gate ========
     * pseg has no IDT because every case it covers is BENIGN -- it probes the
     * 64 KiB based segment only from the INSIDE ("the very top byte still inside
     * the limit"). To test the limit from the OUTSIDE the fault must be catchable.
     * NO PAGING here, so linear == physical and the IDT can sit at a fixed low
     * address. 32-bit interrupt gate:
     *   low  = selector<<16 | offset[15:0]
     *   high = offset[31:16] | 0x8E00   (P=1, DPL=0, type=0xE) */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* IDT base 0x1000 + 13*8 = 0x1068 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* code selector 0x08 in the high half */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492         /* IDT base */
    lidt    0x0490
    movl    $0, 0x00000700              /* #GP counter */

    /* --- a handful of flat protected-mode instructions (GPR changes) --- */
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    addl    %eax, %ebx          /* ebx = 0x33333333 */
    movl    $0xDEAD0000, %ecx
    orl     $0x0000BEEF, %ecx   /* ecx = 0xDEADBEEF */
    xorl    %edx, %edx
    incl    %edx                /* edx = 1 */
    pushl   %ecx
    popl    %esi                /* esi = 0xDEADBEEF, exercises SS push/pop */

    /* --- flat DS-relative store + load (DS base 0, linear == offset) --- */
    movl    $0xA5A5A5A5, %eax
    movl    %eax, 0x00088000    /* flat store at linear 0x00088000 */
    movl    0x00088000, %edi    /* edi = 0xA5A5A5A5 (flat read-back) */

    /* ====================== SEGMENTATION proper ======================= */
    /* Load DS with the BASED data selector (0x18): hidden base = 0x00020000.
     * A DS-relative access to offset O now hits physical 0x00020000 + O.       */
    movw    $0x18, %ax
    movw    %ax, %ds            /* DS.base hidden := 0x00020000 (limit 64KiB) */

    /* store 0xCAFEBABE to DS:0x1000 -> physical 0x00021000 */
    movl    $0xCAFEBABE, %eax
    movl    %eax, 0x00001000    /* ds-relative: linear = 0x20000 + 0x1000 */

    /* in-bounds top-of-segment access (offset 0xFFFC, dword) -> phys 0x2FFFC.
     * 0xFFFC+3 = 0xFFFF == limit, so this is the last legal dword: NO #GP. */
    movl    $0x600D600D, %eax
    movl    %eax, 0x0000FFFC    /* ds-relative: linear = 0x20000 + 0xFFFC */

    /* Read both back FLAT via ES (base 0): if DS.base was applied correctly the
     * flat absolute addresses 0x00021000 / 0x0002FFFC hold the written values.
     * A wrong hidden base => these GPRs diverge from the golden (indirect check
     * of the hidden segment base, which the gdbstub does not expose directly). */
    movl    %es:0x00021000, %ebp    /* ebp = 0xCAFEBABE  (flat read-back) */
    movl    %es:0x0002FFFC, %esi    /* esi = 0x600D600D  (flat read-back) */

    /* ---------------- CROSS-BASE check (strengthens the hidden-base test) -----
     * The flat read-backs above are MASKED against a base error applied UNIFORMLY
     * (identically) to every descriptor-loaded segment: the based store and the
     * ES read-back shift together and cancel (a fundamental limit of any in-guest
     * round-trip, since x86 always adds a segment base; only a direct hidden-base
     * diff via HMP would catch it — deferred).  But the realistic RTL bug class is
     * a base-EXTRACTION error (e.g. desc_base() dropping the base[23:16] byte),
     * which corrupts segments with DIFFERENT base bytes by DIFFERENT amounts.  We
     * catch that here: store a sentinel through the SECOND based segment (idx 5,
     * base 0x40000, base[23:16]=0x04) at the SAME offset 0x1000 -> phys 0x41000,
     * which differs from idx 3's 0x21000 by exactly 0x20000.  A base-extraction
     * bug that collides/swaps the two bases makes these two flat read-backs alias
     * (or land wrong), diverging the GPRs from the golden. */
    movw    $0x28, %ax
    movw    %ax, %ds                /* DS := based #2 (hidden base 0x00040000) */
    movl    $0x1DEA1DEA, %eax
    movl    %eax, 0x00001000        /* ds-relative: linear = 0x40000 + 0x1000 = 0x41000 */
    movl    %es:0x00041000, %edx    /* edx = 0x1DEA1DEA (flat read-back of the idx5 store) */
    /* re-read idx3's store too, AFTER the idx5 store, to confirm the two based
     * segments addressed DISTINCT physical memory (no aliasing): idx3 store at
     * 0x21000 must still hold 0xCAFEBABE, unperturbed by the 0x41000 store. */
    movl    %es:0x00021000, %ebp    /* ebp = 0xCAFEBABE still (distinct from 0x41000) */

    /* ----- benign TYPE case: read-only data segment, READ only (no #GP) ----- */
    /* First seed a known value at flat 0x00030000 (still via ES base 0). */
    movl    $0x0FF1CE00, %eax
    movl    %eax, %es:0x00030000
    /* Load DS with the READ-ONLY selector (0x20, type=0x0) and READ from it.
     * Reading a read-only segment is legal; we never write through it (a write
     * would #GP — deliberately avoided so this test does not fault).            */
    movw    $0x20, %ax
    movw    %ax, %ds            /* DS := read-only flat data segment */
    movl    0x00030000, %ebx    /* ebx = 0x0FF1CE00  (legal read of RO seg) */

    /* ---------------- POP Sreg (07/17/1F) PROTECTED-MODE base walk ---------
     * task #102 regression: `pop ds/es/ss` in protected mode must walk the GDT
     * descriptor for the popped selector, NOT compute base = sel<<4 like real
     * mode.  CWSDPMI's DPMI reflector does `pop ds` with a BASED selector; the
     * sel<<4 shortcut stored the dispatch vector at the wrong linear (0x330 vs
     * the GDT base 0x2b570) and the CPL0 read-back saw 0 -> "Division by Zero".
     * Here: push the BASED selector 0x18 (GDT base 0x00020000), `pop %ds`, then
     * store through DS:0x2000.  If the base was walked, the write lands at flat
     * physical 0x00022000; if the buggy sel<<4 path runs, DS.base = 0x18<<4 =
     * 0x180 and the write lands at 0x02180 instead -> the flat read-back below
     * diverges from the golden.  esp is also restored by the pop (+2).          */
    movw    $0x10, %ax
    movw    %ax, %ds                /* DS := flat (so the pushw uses a known base) */
    movw    $0x18, %ax
    pushw   %ax                     /* selector 0x18 (based, GDT base 0x00020000) */
    popw    %ds                     /* POP DS in PM -> must GDT-walk -> base 0x20000 */
    movl    $0x9A9A9A9A, %eax
    movl    %eax, 0x00002000        /* ds-relative: linear = 0x20000 + 0x2000 = 0x22000 */
    movl    %es:0x00022000, %ecx    /* ecx = 0x9A9A9A9A iff POP-DS walked the descriptor */

    /* ============ REVIEW2 C-06: cross the limit from the OUTSIDE ============
     * ES = 0x18 (base 0x20000, limit 0xFFFF, byte-granular). pseg already proves
     * the top byte INSIDE the limit is fine (offset 0xFFFC, dword). Offset 0x10000
     * is one byte PAST it and must raise #GP(0) BEFORE any memory is touched.
     * A core with no limit check quietly reads linear 0x20000+0x10000 = 0x30000. */
    /* OBSERVE FIRST: LSL reads back the limit the CPU actually sees for 0x18.
     * Three attempts at this test have failed on hypotheses; this asks the machine
     * instead. ebx = the effective limit. If it is 0xFFFF the descriptor is being
     * read as intended and the fault should be due; anything else explains the
     * non-fault directly. Graded by the ordinary GPR diff, so QEMU answers too. */
    /* (the LSL probe that confirmed limit==0xFFFF has been removed: Ventium does not
     * implement LSL, so it HALTED the RTL run at that instruction and the test never
     * reached the violation below. It served its purpose under QEMU.) */
    /* REVIEW1_Aug2 C-01: restore a FLAT DS before the violation block. The pop-DS
     * test above leaves DS = 0x18 (base 0x20000), and everything below -- the resume
     * EIP at 0x704, the #GP counter at 0x700, the witness at 0x30000 -- is addressed
     * DS-relative. With a based DS the mainline writes linear 0x20704 while the
     * handler (which loads a flat DS so its own accesses are well-defined) reads
     * 0x704, so the handler IRETed to garbage: measured as a #UD at pc=0x00000508
     * followed by the #NP/#DF cascade. The violating accesses below all use explicit
     * %es: overrides, so a flat DS does not weaken the test at all. */
    movw    $0x10, %ax
    movw    %ax, %ds

    movl    $seglim_resume, %eax
    movl    %eax, 0x00000704            /* resume EIP for the handler */
    movw    $0x18, %ax
    movw    %ax, %es
    movl    $0xDEADBEEF, %edx           /* witness: must survive (no commit on fault) */
    movl    %es:0x00010000, %edx        /* #GP(0) here -- one byte past the limit */
seglim_resume:

    /* ---- REVIEW1_Aug2 C-01: the faulting access must not REACH MEMORY ------
     * The load above proves a #GP is raised. It cannot prove the access was
     * SUPPRESSED: a load leaves no trace, and the old test checked only the fault
     * counter. seg_access_fault was consumed by the FSM but was absent from the bus
     * driver's squash list, so the same clock both delivered #GP(13) and presented
     * mem_req/mem_we to memory -- a limit-violating STORE committed before faulting.
     *
     * So: seed a witness at the linear address the violating store would hit
     * (ES.base 0x20000 + offset 0x10000 = 0x30000, one byte past the 0xFFFF limit),
     * perform the store, and read the witness back through the FLAT DS afterwards.
     * It must still be the seed. A store is used deliberately -- it is the case that
     * corrupts memory, and the only one that leaves evidence. */
    /* DS is still the LIMITED selector here (the mainline restores it only at the
     * end), so the seed store must set a flat DS first -- writing 0x30000 through a
     * base-0x20000/limit-0xFFFF DS is itself a violation and loops. Measured the hard
     * way: 81 faults at the seed instruction. */
    movw    $0x10, %ax                  /* flat ES for the seeding (DS is already flat) */
    movw    %ax, %es
    movl    $0x5EEDF00D, 0x00030000     /* the witness, written through the FLAT map */

    movl    $seglim_store_resume, %eax
    movl    %eax, 0x00000704            /* resume EIP for the handler */
    movw    $0x18, %ax                  /* the LIMITED ES again (limit 0xFFFF) */
    movw    %ax, %es
    movl    $0xCAFEBABE, %ebx
    movl    %ebx, %es:0x00010000        /* #GP(0): a limit-violating STORE. If the
                                         * access is not suppressed this overwrites
                                         * the witness at linear 0x30000. */
seglim_store_resume:
    movw    $0x10, %ax                  /* restore a flat ES */
    movw    %ax, %es
    movl    0x00030000, %ebp            /* ebp = the witness: MUST still be 0x5EEDF00D */
    movl    0x00000700, %ecx            /* ecx = 2 iff BOTH #GPs were delivered */

    /* restore DS to the flat RW selector so the final state is well-defined */
    movw    $0x10, %ax
    movw    %ax, %ds

    /* ====================== clean exit via isa-debug-exit ================== */
    /* DIRECT OBSERVATION (REVIEW2 C-06): encode the #GP counter into the EXIT
     * STATUS, so QEMU answers "did the limit violation fault?" with no gdbstub,
     * no trace parsing and no QMP -- every layer I have been second-guessing is
     * removed. isa-debug-exit gives status (v<<1)|1:
     *     counter == 0  -> v=0x42 -> 133   NO #GP was raised
     *     counter != 0  -> v=0x43 -> 135   a #GP WAS raised
     * (REVIEW1_Aug2 C-01: the counter is now 2 -- one load violation, one STORE
     *  violation -- and ebp carries the witness that proves the store never reached
     *  memory. The exit status only distinguishes zero from non-zero; the seg gate
     *  checks the exact count and the witness.) */
    movl    0x00000700, %eax
    testl   %eax, %eax
    jz      1f
    movl    $0x43, %eax
    jmp     2f
1:  movl    $0x42, %eax
2:
    movw    $0xF4, %dx
    outb    %al, %dx
    /* (unreached) original exit below */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx            /* qemu exits: status = (0x42<<1)|1 = 0x85 */

hang:
    hlt
    jmp     hang

    /* ========================= #GP handler ================================ */
    /* TEST BUG, fixed: this handler is written in 32-bit syntax (pushl/incl/movl,
     * %esp) and runs in the 32-bit code segment 0x08 -- but a `.code16` directive
     * for the reset stub was left IN FORCE above it, so the assembler emitted
     * 16-bit-mode encodings. Executed with D=1 the same bytes mean something else:
     *     66 ff 06 00 07   ->  incw (0x0700)   as assembled (16-bit)
     *                      ->  inc dword [esi] as executed  (32-bit)
     * ESI holds garbage on entry, so the handler dereferenced it and took a
     * GENUINE segment-limit #GP before it could do anything -- looping forever at
     * 0x000f020d. That loop was recorded in the previous round as C-06's "third
     * false positive" in the CORE. It was not: the core was right and the test was
     * mis-assembled. Measured with +ven_seglog:
     *     [SEGCHK] st=3 dseg=2 sel=0018 base=00020000 lim=0000ffff
     *              cur_lin=600f600d off=600d600d w=2 pc=000f020d
     * off=0x600d600d is ESI's sentinel contents, i.e. a real out-of-limit access.
     * The reset stub's .code16 now starts AFTER the handler, where it belongs. */
    .global gp_handler
gp_handler:
    pushl   %eax
    /* The handler's own data accesses must not depend on whatever DS the faulting
     * context happened to have. They did: the counter at 0x700 is reached through DS,
     * so a fault taken with the LIMITED DS (base 0x20000) incremented linear 0x20700
     * while one taken with a flat DS incremented 0x700 -- two different counters, and
     * the mainline read only one of them (measured: two #GP deliveries but ecx==1).
     * Load a flat DS and leave it: every violating access in this test uses an
     * explicit %es: override, and the mainline wants a flat DS afterwards anyway.
     * (push/pop %ds was tried first and derailed the handler -- 58 faults.) */
    movw    $0x10, %ax
    movw    %ax, %ds
    incl    0x00000700                  /* #GP counter */
    movl    0x00000704, %eax            /* the resume EIP the mainline stashed */
    movl    %eax, 0x08(%esp)            /* overwrite saved EIP -> skip the faulting insn */
    popl    %eax
    addl    $4, %esp                    /* discard the #GP error code */
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    /* QEMU starts at CS:EIP=F000:FFF0 (CS base 0xFFFF0000 => linear FFFFFFF0 ==
     * the image's last 16 bytes).  Drop into the early 16-bit code at segment
     * 0xF000 (base 0x000F0000, where the image is aliased low).  _start16's image
     * offset == (_start16 VMA - 0xF0000); far-jump to $0xF000:$(that offset),
     * encoded by hand so the 16-bit offset field is the segment-relative value. */
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
