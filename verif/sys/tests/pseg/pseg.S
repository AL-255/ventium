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

    /* restore DS to the flat RW selector so the final state is well-defined */
    movw    $0x10, %ax
    movw    %ax, %ds

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
     * 0xF000 (base 0x000F0000, where the image is aliased low).  _start16's image
     * offset == (_start16 VMA - 0xF0000); far-jump to $0xF000:$(that offset),
     * encoded by hand so the 16-bit offset field is the segment-relative value. */
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
