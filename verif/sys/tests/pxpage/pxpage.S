/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.2 — bare-metal 2-level PAGING demonstrator (NON-IDENTITY map).
 *
 * This is the focused M2S.2 paging gate test: real->protected (reusing the
 * M2S.1 pseg bootstrap), then build a 2-level page directory + page tables and
 * enable paging with a NON-IDENTITY mapping (linear != physical) so that a
 * "base-only" / "no-translation" RTL bug — where the MMU just passes the linear
 * address through as physical — is CAUGHT.  Freestanding "BIOS" image loaded with
 *   qemu-system-i386 -bios pxpage.bin
 * QEMU maps a -bios image so its LAST byte sits at 0x000FFFFF (also aliased at
 * the top of the 32-bit space); the i386 reset vector is CS:EIP = F000:FFF0,
 * i.e. linear 0x000FFFF0 — 16 bytes before the end of a 64 KiB image.  A 16-bit
 * reset stub at image offset 0xFFF0 jumps back to the real start.
 *
 * Physical/linear memory plan (machine has -m 32 => 32 MiB phys; all targets fit):
 *   Page tables (low RAM, identity-reachable so the walk can read them):
 *     PD   @ phys 0x00011000   (page directory, 4 KiB)
 *     PT0  @ phys 0x00012000   (page table for linear [0, 4 MiB) == IDENTITY)
 *     PT1  @ phys 0x00013000   (page table for linear [4 MiB, 8 MiB) NON-IDENTITY)
 *   PD entries:
 *     PD[0] -> PT0 | P|RW         (identity covers code @0x000Fxxxx, GDT, stack,
 *                                  the page tables themselves -> EIP stays valid)
 *     PD[1] -> PT1 | P|RW|US      (the non-identity 4 MiB window @ linear 4 MiB)
 *   PT1 entries (each a 4 KiB page; the WHOLE point is linear != physical):
 *     PT1[0]  linear 0x00400000 -> phys 0x00800000   P|RW|US  (0x7)
 *     PT1[1]  linear 0x00401000 -> phys 0x00800000   P|RW     (0x3)  ALIAS of [0]
 *     PT1[2]  linear 0x00402000 -> phys 0x00801000   P|US     (0x5)  READ-ONLY
 *     PT1[4]  linear 0x00404000 -> phys 0x00801000   P|RW     (0x3)  RW alias of [2]
 *     PT1[3]  linear 0x00403000 -> phys 0x00802000   P|RW     (0x3)  SUPERVISOR-only
 *
 * Flow (each step observable in the system-mode golden trace):
 *   1. real mode (cr0.PE=0): build a flat GDT (null + code32 0x08 + data32 0x10)
 *      and lgdt it.
 *   2. set CR0.PE=1, far-jump to the 32-bit flat code segment (0x08)
 *        -> cr0.PE 0->1, then cs 0xf000 -> 0x08  (two atomic retire records)
 *   3. load DS/ES/SS/FS/GS with the flat data selector (0x10); set a flat stack.
 *   4. build PD + PT0 (identity [0,4MiB)) + PT1 (non-identity [4MiB,8MiB)) in RAM.
 *   5. load CR3 = PD base, set CR0.PG=1  -> cr3 load, cr0.PG 0->1  (paging ON).
 *      (CR4.PSE is deliberately NOT set — these are 4 KiB pages, the core M2S.2
 *      path; 4 MiB PSE pages are a deferred corner.)
 *   6. NON-IDENTITY proof: store a sentinel through linear 0x00400000 (-> phys
 *      0x00800000) and read it back through the ALIAS linear 0x00401000 (also ->
 *      phys 0x00800000).  If translation works both hit the SAME physical page so
 *      the read-back equals the sentinel; a no-translation bug sends 0x400000 and
 *      0x401000 to DIFFERENT physical pages and the read-back GPR diverges.
 *   7. DISTINCT-permission pages (all clean / non-faulting at CPL=0):
 *        - READ-ONLY page (US=1,RW=0): seed it through its RW alias linear
 *          0x00404000, then READ it through the read-only linear 0x00402000
 *          (a read of a read-only page is always legal).
 *        - SUPERVISOR page (US=0,RW=1): store + load through linear 0x00403000 at
 *          CPL=0 (a supervisor access to a supervisor page is legal).
 *      These exercise the P/RW/US permission DECISION (US 0/1, RW 0/1) without
 *      tripping a #PF (fault DELIVERY is M2S.3; this test never faults).
 *   8. exit cleanly via isa-debug-exit: `out 0xf4, al` with al=0x42
 *        -> qemu exits with status ((0x42)<<1)|1 = 0x85 = 133.
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pxpage.ld (see Makefile), then
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

    /* --- build a flat GDT (3 entries = 24 bytes) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    /* idx 0: null descriptor */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    /* idx 1 (0x08): code32 base=0 limit=0xFFFFF G=1 D=1 P=1 DPL=0 type=0xA */
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    /* idx 2 (0x10): data32 flat base=0 limit=0xFFFFF G=1 B=1 type=0x2 RW */
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)

    /* --- gdt pseudo-descriptor @0x0480: limit(2) base(4) --- */
    movw    $0x0017, 0x0480     /* limit = 24-1 = 0x17 (3 entries) */
    movl    $0x00000500, 0x0482 /* base  = 0x0500     */

    lgdt    0x0480

    /* --- enter protected mode: set CR0.PE (PG still 0) --- */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far-jump to flush + load CS with the 32-bit flat code selector (0x08).
     * Encode the 32-bit far pointer by hand: 66 EA <off32> <sel16>. */
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

    /* a couple of plain PM instructions so the pre-paging GPR state is observable */
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    addl    %eax, %ebx          /* ebx = 0x33333333 */

    /* ===================== build the 2-level page tables ===================== */
    /* We set ONLY the entries the paged code actually walks through; every other
     * entry stays untouched (its linear is never accessed, so the MMU never reads
     * it -> no zeroing pass needed, which keeps the single-stepped trace short). */

    /* --- PT0 @ 0x12000: identity-map the CODE window linear [0x000F0000,
     * 0x00100000) as 4 KiB pages.  After CR0.PG=1 the only identity-mapped
     * linears the code touches are its own instruction fetches at 0x000Fxxxx
     * (the GDT/stack/page-tables are written BEFORE paging, i.e. as physical
     * accesses, and are not touched again once paging is on).  PT0 index for
     * linear 0x000Fx000 is (lin>>12)&0x3FF = 0xF0..0xFF -> 16 entries.
     *   PTE = (frame phys) | P|RW (0x3); identity: frame == 0x000Fx000.        */
    movl    $0x000123C0, %edi   /* &PT0[0xF0] = 0x12000 + 0xF0*4 = 0x123C0 */
    movl    $0x000F0003, %eax   /* identity PTE for frame 0x000F0000 | P|RW */
    movl    $16, %ecx           /* 16 entries cover [0x000F0000, 0x00100000) */
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax       /* next 4 KiB identity frame */
    addl    $4, %edi
    loop    1b

    /* --- PT1 @ 0x13000: the NON-IDENTITY window for linear [4 MiB, 8 MiB) ---
     * Only the handful of entries we use are filled; the rest stay 0 (not P). */
    movl    $0x00013000, %edi   /* PT1 base */
    /* PT1[0]  linear 0x400000 -> phys 0x800000  P|RW|US (0x7) */
    movl    $0x00800007, 0(%edi)
    /* PT1[1]  linear 0x401000 -> phys 0x900000  P|RW (0x3)  NON-ADJACENT to [0].
     * THIS IS THE POINT OF THE TEST (REVIEW2 C-02). Linear 0x400000 and 0x401000 are
     * CONSECUTIVE virtual pages, but their frames (0x800000 and 0x900000) are 1 MiB
     * apart. An access straddling linear 0x401000 must take its low bytes from
     * 0x800xxx and its high bytes from 0x900000. A core that translates only the
     * FIRST page instead reads straight on into phys 0x801000 -- a DIFFERENT frame
     * that belongs to another mapping entirely. */
    movl    $0x00900003, 4(%edi)
    /* PT1[2]  linear 0x402000 -> phys 0x801000  P|US   (0x5)  READ-ONLY */
    movl    $0x00801005, 8(%edi)
    /* PT1[3]  linear 0x403000 -> phys 0x802000  P|RW   (0x3)  SUPERVISOR-only */
    movl    $0x00802003, 12(%edi)
    /* PT1[4]  linear 0x404000 -> phys 0x801000  P|RW   (0x3)  RW alias of [2] */
    movl    $0x00801003, 16(%edi)

    /* --- PD @ 0x11000: two present directory entries --- */
    movl    $0x00011000, %edi   /* PD base */
    /* PD[0] -> PT0 (0x12000) | P|RW (0x3) : the identity window */
    movl    $0x00012003, 0(%edi)
    /* PD[1] -> PT1 (0x13000) | P|RW|US (0x7) : the non-identity window @4 MiB */
    movl    $0x00013007, 4(%edi)

    /* ---- seed the three frames that tell a correct split from the C-02 bug ----
     * All three writes happen with paging OFF, so they are PHYSICAL accesses.
     *   phys 0x800FFE = 0xAAAA  -> the LOW half of the straddling dword
     *   phys 0x900000 = 0xBBBB  -> the CORRECT high half (second page's frame)
     *   phys 0x801000 = 0xCCCC  -> the WRONG high half (what reading straight on
     *                              past the end of the first frame produces)
     * A correct core reads 0xBBBBAAAA; a core with C-02 reads 0xCCCCAAAA. */
    movw    $0xAAAA, 0x00800FFE
    movw    $0xBBBB, 0x00900000
    movw    $0x9999, 0x00900002   /* so the second page's DWORD is deterministic */
    movw    $0xCCCC, 0x00801000

    /* ===================== enable paging (4 KiB pages) ===================== */
    /* load CR3 with the page-directory base (observable cr3 load) */
    movl    $0x00011000, %eax
    movl    %eax, %cr3

    /* set CR0.PG (bit 31) -> paging ON (observable cr0.PG 0->1).  Code keeps
     * executing from the identity-mapped low window so EIP stays valid.       */
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ================== REVIEW2 C-02: THE PAGE-CROSSING READ ================= */
    /* Linear 0x400FFE..0x401001 -- an unaligned dword straddling the page boundary
     * between two CONSECUTIVE virtual pages whose frames are NOT adjacent.
     *   correct : ESI = 0xBBBBAAAA   (low from phys 0x800FFE, high from 0x900000)
     *   C-02 bug: ESI = 0xCCCCAAAA   (high taken from phys 0x801000 -- wrong frame)
     * This is graded by the ordinary verify-sys GPR diff against QEMU, so no special
     * checker is needed: QEMU translates both pages, Ventium (today) does not. */
    movl    0x00400FFE, %esi

    /* ==== REVIEW1_Aug2 C-03: the split must work in S_LOAD2, not just S_LOAD ====
     * The crossing predicate was bound to S_LOAD, so every OTHER multi-byte access
     * translated only its starting page. S_LOAD2 is the reachable one: CMPS's second
     * operand, BOUND's and CMPXCHG8B's high word, and both far-pointer reads all use
     * it.
     *
     * CMPSD compares [ESI] (an S_LOAD) against [EDI] (an S_LOAD2). Point EDI at the
     * SAME straddling address the load phase above used, and ESI at a scratch dword
     * holding the value a CORRECT split produces. The [EDI] read then crosses inside
     * S_LOAD2:
     *   correct : [EDI] = 0xBBBBAAAA -> equal -> ZF=1 -> EBP = 1
     *   C-03 bug: [EDI] = 0xCCCCAAAA -> not equal -> ZF=0 -> EBP = 0
     * ZF is graded by the ordinary GPR/EFLAGS diff against QEMU, and EBP makes the
     * outcome visible as a register too. Both pointers are DS/ES-relative with flat
     * bases, so this adds no segmentation variable. */
    cld
    movl    $0xBBBBAAAA, 0x00403000  /* scratch: linear 0x403000 -> phys 0x802000 (PT1[3],
                                      * RW, and collides with none of the sentinels --
                                      * 0x402000 maps to phys 0x801000, the READ-ONLY
                                      * page holding the 0xCCCC witness the earlier
                                      * phases depend on) */
    movl    $0x00403000, %esi        /* [ESI]: the expected value  (S_LOAD) */
    movl    $0x00400FFE, %edi        /* [EDI]: the STRADDLING dword (S_LOAD2) */
    cmpsl                            /* compares [ESI] with [EDI] */
    movl    $0, %ebp
    jne     1f
    movl    $1, %ebp                 /* EBP = 1 iff the S_LOAD2 side split correctly */
1:

    /* ============ NON-IDENTITY proof: store @0x400000, read @0x401000 ======== */
    /* store a sentinel through linear 0x00400000 (-> phys 0x00800000) */
    movl    $0xCAFEBABE, %eax
    movl    %eax, 0x00400000        /* linear 0x400000 -> phys 0x800000 */
    /* read it back through the ALIAS linear 0x00401000 (also -> phys 0x800000).
     * Equal iff translation actually happened; a no-translation bug diverges. */
    movl    0x00400000, %ebx        /* ebx = 0xCAFEBABE (plain non-identity read) */

    /* a SECOND distinct value through the non-identity window to be thorough:
     * store @0x400000+0x40 = phys 0x800040, read back via alias @0x401040. */
    movl    $0x600DF00D, %ebx
    movl    %ebx, 0x00400040        /* phys 0x800040 */
    movl    0x00400040, %edi        /* edi = 0x600DF00D (read-back, same page) */

    /* ================= distinct-permission pages (non-faulting) ============== */
    /* READ-ONLY page: seed phys 0x801000 through its RW alias (linear 0x404000),
     * then READ through the read-only linear 0x402000 (reading RO is legal).    */
    movl    $0x0FF1CE00, %eax
    movl    %eax, 0x00404000        /* RW alias -> phys 0x801000 */
    movl    0x00402000, %ebp        /* ebp = 0x0FF1CE00 (legal read of RO page) */

    /* SUPERVISOR page (US=0): store + load through linear 0x403000 at CPL=0.
     * A supervisor access to a supervisor page is legal -> no #PF.             */
    movl    $0x5005500F, %eax
    movl    %eax, 0x00403000        /* -> phys 0x802000 (supervisor page) */
    movl    0x00403000, %ecx        /* ecx = 0x5005500F (supervisor read-back) */

    /* re-read the first non-identity value AFTER all the other stores to confirm
     * the pages addressed DISTINCT physical memory (no aliasing of distinct PTEs):
     * phys 0x800000 must still hold 0xCAFEBABE. */
    movl    0x00400000, %edx        /* edx = 0xCAFEBABE still (distinct phys) */

    /* ============ REVIEW2 C-02, STORE half: a crossing STORE ================= */
    /* Same straddle, now as a WRITE. The low 2 bytes belong in the first page's
     * frame (phys 0x800FFE); the high 2 bytes belong in the SECOND page's frame
     * (phys 0x900000) -- NOT in phys 0x801000, which is where a first-page-only
     * translation puts them.
     *   correct : [0x401000] reads 0x99991234  (0x1234 landed in phys 0x900000)
     *   C-02 bug: [0x401000] reads 0x9999BBBB  (0x900000 untouched; 0x1234 went to
     *                                           phys 0x801000 -- a foreign frame)
     * Graded by the ordinary verify-sys GPR diff, like the load half. */
    movl    $0x12345678, %eax
    movl    %eax, 0x00400FFE        /* the crossing STORE */
    movl    0x00401000, %ebp        /* second page: proves where the high bytes went */
    /* REVIEW_aug2 C-01: also prove the FOREIGN, physically-adjacent frame was NOT
     * touched. phys 0x801000 sits immediately after the first page's frame
     * (0x800000+0x1000) and belongs to a DIFFERENT mapping; it was seeded 0xCCCC
     * before paging. A store that writes its full width through page 1's translation
     * before splitting corrupts it, and the two checks above CANNOT see that -- they
     * only look at the two intended frames. Reach it via PT1[4] (linear 0x404000 ->
     * phys 0x801000, RW).
     *   correct : esi = 0x0000CCCC   (seed intact, nothing spilled)
     *   C-01 bug: esi = 0x0000????   (the crossing store's high half landed here) */
    movl    0x00404000, %esi

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx            /* qemu exits: status = (0x42<<1)|1 = 0x85 */

hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    /* QEMU starts at CS:EIP=F000:FFF0 (CS base 0xFFFF0000 => linear FFFFFFF0 ==
     * the image's last 16 bytes).  Drop into the early 16-bit code at segment
     * 0xF000 (base 0x000F0000, where the image is aliased low). */
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
