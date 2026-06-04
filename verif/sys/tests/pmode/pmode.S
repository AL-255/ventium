/* Ventium M2S.0 — bare-metal protected-mode + paging demonstrator.
 *
 * This is a freestanding "BIOS" image (loaded with qemu-system-i386 -bios).
 * QEMU maps a -bios image so its LAST byte sits at 0x000FFFFF (and aliases the
 * top of the 32-bit space), and the i386 reset vector is CS:EIP = F000:FFF0,
 * i.e. linear 0x000FFFF0 — 16 bytes before the end of a 64 KiB image.  So we
 * place a 16-bit reset stub at offset 0xFFF0 of the image that jumps back to the
 * real start of our code.
 *
 * Flow (each step is observable in the system-mode golden trace):
 *   1. real mode (cr0.PE=0): load a flat 4 GiB GDT
 *   2. set CR0.PE=1, far-jump to a 32-bit code segment  -> cr0.PE 0->1, cs changes
 *   3. a handful of 32-bit protected-mode instructions   (flat segmentation)
 *   4. build a tiny IDENTITY page directory + page table covering the low 4 MiB
 *      via a single 4 MiB PSE large page (set CR4.PSE, set CR3, set CR0.PG)
 *                                                         -> cr3 load, cr0.PG 0->1
 *   5. a few more instructions with paging on
 *   6. exit cleanly via isa-debug-exit: `out 0xf4, al` with al = 0x42
 *      -> qemu exits with status ((0x42)<<1)|1 = 0x85 = 133
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pmode.ld ... (see Makefile),
 * then objcopy -O binary, padded to exactly 64 KiB.
 *
 * NOTE: addresses below are LINEAR/PHYSICAL addresses inside the low 1 MiB.
 * The GDT/page tables live in low RAM (0x1000..) which we write at runtime;
 * the code itself executes from the BIOS alias high in the address space but the
 * far-jump targets are 32-bit flat (base 0) linear == physical here.
 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld

    /* Load GDT.  lgdt operand is the 6-byte pseudo-descriptor at gdt_desc.
     * In real mode DS=0 at reset on QEMU's pc machine; the descriptor lives in
     * the image which is aliased low, but lgdt needs a *real-mode* addressable
     * operand.  We copy the GDT + descriptor into low RAM first so the protected
     * mode flat segments (base 0) can also see them, then lgdt from there.    */

    /* zero segment registers / set a stack in low RAM */
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp        /* real-mode stack below the code copy */

    /* --- copy the GDT (3 entries = 24 bytes) into 0x0500 --- */
    /* We hardcode the flat GDT here in real mode by writing dwords. */
    /* null descriptor @0x0500 */
    movl    $0x00000500, %ebx
    movl    $0x00000000, (%ebx)
    movl    $0x00000000, 4(%ebx)
    /* code32: base=0 limit=0xFFFFF G=1 D=1 P=1 DPL=0 type=0xA (exec/read) */
    /* low  = 0x0000FFFF (limit15:0=FFFF, base15:0=0000)                  */
    /* high = 0x00CF9A00 (base31:24=00, G=1 D=1 0 AVL=0, limit19:16=F,    */
    /*         P=1 DPL=0 S=1 type=A -> 0x9A, base23:16=00)                */
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    /* data32: base=0 limit=0xFFFFF G=1 B=1 type=0x2 (read/write) -> 0x92 */
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)

    /* --- build the gdt pseudo-descriptor @0x0480: limit(2) base(4) --- */
    movw    $0x0017, 0x0480     /* limit = 24-1 = 0x17 */
    movl    $0x00000500, 0x0482 /* base = 0x0500 */

    /* load it */
    lgdt    0x0480

    /* --- enter protected mode: set CR0.PE --- */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far jump to flush the prefetch + load CS with the 32-bit code selector
     * (0x08 = GDT index 1, RPL 0).  Target is pm32_entry as a linear address
     * (flat code segment base 0 => offset == linear == VMA).  Encode the 32-bit
     * far pointer by hand so the assembler does not try to truncate the VMA. */
    .byte   0x66, 0xEA          /* opsize-32 ljmp ptr16:32 */
    .long   pm32_entry          /* 32-bit offset (flat, base 0) */
    .word   0x08                /* 32-bit code selector */

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    /* reload the data segments with the 32-bit data selector (0x10) */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp   /* a 32-bit stack in low RAM */

    /* --- a handful of protected-mode instructions (observable GPR changes) --- */
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    addl    %eax, %ebx          /* ebx = 0x33333333 */
    movl    $0xDEAD0000, %ecx
    orl     $0x0000BEEF, %ecx   /* ecx = 0xDEADBEEF */
    xorl    %edx, %edx
    incl    %edx                /* edx = 1 */
    pushl   %ecx
    popl    %esi                /* esi = 0xDEADBEEF, exercises the stack */

    /* ====================== enable paging (PSE 4 MiB) ====================== */
    /* Page directory @ 0x00010000 (4 KiB aligned).  We use one PSE large-page
     * directory entry mapping the first 4 MiB identity (linear==physical), which
     * needs no second-level page table.  PDE = base(4MiB-aligned phys) | flags.
     * flags: P(0x1) RW(0x2) US(0x4) PS(0x80) -> 0x83 ; base 0 -> PDE = 0x00000083 */
    movl    $0x00010000, %edi
    /* zero the whole 4 KiB directory first */
    pushl   %edi
    movl    $1024, %ecx
    xorl    %eax, %eax
    rep stosl
    popl    %edi
    /* entry 0 = identity-map [0, 4MiB) as a large page */
    movl    $0x00000083, (%edi)

    /* enable CR4.PSE (bit 4) so PS in the PDE means a 4 MiB page */
    movl    %cr4, %eax
    orl     $0x10, %eax
    movl    %eax, %cr4

    /* load CR3 with the page-directory base (observable cr3 load) */
    movl    $0x00010000, %eax
    movl    %eax, %cr3

    /* set CR0.PG (bit 31) -> paging ON (observable cr0.PG 0->1) */
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* --- a few more instructions with paging enabled --- */
    movl    $0xCAFE0000, %ebp
    orl     $0x0000F00D, %ebp   /* ebp = 0xCAFEF00D */
    movl    $0x12340000, %eax
    addl    $0x00005678, %eax   /* eax = 0x12345678 */
    movl    %eax, 0x00080000    /* a paged store (identity-mapped) */
    movl    0x00080000, %edi    /* read it back: edi = 0x12345678 */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx            /* qemu exits: status = (0x42<<1)|1 = 0x85 */

    /* should never reach here */
hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    /* QEMU starts at CS:EIP=F000:FFF0.  The linker places this section's bytes
     * at image offset 0xFFF0; the 5-byte far jump steers to _start16 (which the
     * linker resolves to a 16-bit-reachable real-mode address). */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    /* QEMU starts at CS:EIP=F000:FFF0 with CS base 0xFFFF0000 (so linear FFFFFFF0
     * == the image's last 16 bytes).  We want to drop into the early 16-bit code
     * at segment 0xF000 (base 0x000F0000, which is where the image is aliased in
     * the low 1 MiB).  _start16's image offset == (_start16 VMA - 0xF0000), so we
     * far-jump to $0xF000:$(that offset).  Encoded by hand so the 16-bit offset
     * field is the segment-relative value, not the truncated full VMA. */
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
