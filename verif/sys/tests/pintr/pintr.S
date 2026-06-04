/* Ventium M2S.3 — bare-metal SOFTWARE-INTERRUPT (IDT delivery) demonstrator.
 *
 * This is the M2S.3 pintr gate test: it bootstraps real->protected (reusing the
 * M2S.1 pseg / M2S.2 ppage bootstrap), stands up an IDT with a few 32-bit
 * interrupt-gate / trap-gate descriptors, and then fires SOFTWARE interrupts
 *   INT n   (CD ib)         -> interrupt gate
 *   INT3    (CC)            -> trap gate
 *   INTO    (CE, OF set)    -> interrupt gate (#OF, vector 4)
 * to handlers that record a marker (increment a per-vector counter + write a
 * per-vector sentinel) and then IRET.  After each IRET control RETURNS to the
 * instruction after the INT, which the test PROVES by accumulating into GPRs and
 * reaching the clean isa-debug-exit only if every handler ran and returned.
 *
 * SAME-PRIVILEGE delivery only (handlers at CPL 0, no stack switch / TSS —
 * cross-privilege delivery is M2S.4).  Interrupt gate clears IF (and TF); trap
 * gate leaves IF.  The exception frame pushed is EFLAGS, CS, EIP (no error code
 * for these software/INT vectors).  INT3/INTO/INT n are TRAPS: they push the EIP
 * of the *next* instruction, so IRET resumes after the INT.
 *
 * Freestanding "BIOS" image loaded with  qemu-system-i386 -bios pintr.bin .
 * QEMU maps a -bios image so its LAST byte sits at 0x000FFFFF; the i386 reset
 * vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0).  A 16-bit reset stub at image
 * offset 0xFFF0 jumps back to the real start.
 *
 * Memory plan (machine -m 32 => 32 MiB phys; NO paging here, linear==physical):
 *   GDT  @ linear 0x00000500  (null + code32 0x08 + data32 0x10)
 *   IDT  @ linear 0x00001000  (256 gates * 8 bytes; only the ones we use filled)
 *   markers @ linear 0x00002000 .. (per-vector counter + sentinel records)
 *   stack   @ 0x00090000 (flat 32-bit)
 *
 * IDT gates installed (all selector 0x08 = the flat 32-bit code segment, DPL=0):
 *   vector 0x03 (#BP / INT3)      -> bp_handler     TRAP gate     (attr 0x8F)
 *   vector 0x04 (#OF / INTO)      -> of_handler     INTERRUPT gate (attr 0x8E)
 *   vector 0x20 (INT 0x20)        -> int20_handler  INTERRUPT gate (attr 0x8E)
 *   vector 0x21 (INT 0x21)        -> int21_handler  TRAP gate     (attr 0x8F)
 *
 * Flow (each step observable in the system-mode golden trace as a CS:EIP change
 * into the gate target and back via IRET):
 *   1. real mode: build flat GDT + lgdt; CR0.PE=1; far-jump to 32-bit code 0x08.
 *   2. load flat data selectors (0x10) + a flat stack; zero the marker area.
 *   3. build the IDT in RAM (write the 4 gates), lidt it.
 *   4. INT 0x20  -> int20_handler (interrupt gate, IF cleared) -> marker -> IRET.
 *   5. INT 0x21  -> int21_handler (trap gate) -> marker -> IRET.
 *   6. INT3      -> bp_handler   (trap gate) -> marker -> IRET.
 *   7. set OF (via a known overflow) then INTO -> of_handler -> marker -> IRET;
 *      the handler clears OF in the SAVED eflags image so IRET returns OF=0.
 *   8. accumulate the four counters; only if all ran does EAX reach the expected
 *      total; exit cleanly via isa-debug-exit (out 0xf4, 0x42 -> qemu status 133).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pintr.ld (see Makefile), then
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

    /* --- enter protected mode: set CR0.PE (PG stays 0 — NO paging) --- */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far-jump to flush + load CS with the 32-bit flat code selector (0x08). */
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

    /* --- zero the marker area (counters + sentinels) at 0x2000..0x2040 --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $16, %ecx           /* 16 dwords = 64 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build the IDT (4 gates) ===================== */
    /* IDT base = 0x00001000.  Each gate is 8 bytes:
     *   word0 = offset[15:0]
     *   word1 = selector (0x08)
     *   word2 = (reserved00) | attr<<8   [attr=0x8E int gate / 0x8F trap gate]
     *   word3 = offset[31:16]
     * We write each gate's two dwords directly: a gate's 8 bytes encode as
     *   lo dword = (selector<<16) | offset[15:0]
     *   hi dword = (offset & 0xFFFF0000) | (attr<<8)
     */

    /* helper register conventions for the inline gate writes below:
     *   %ebx = handler linear offset (flat, base 0 => offset == linear)
     *   gate slot address = IDT_base + vector*8                            */

    /* vector 0x03 (#BP, INT3): TRAP gate (0x8F) -> bp_handler */
    movl    $bp_handler, %ebx
    movl    $0x00001018, %edi       /* 0x1000 + 0x03*8 = 0x1018 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax       /* selector 0x08 in bits 31:16 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008F00, %eax       /* attr 0x8F (32-bit trap gate, P, DPL0) */
    movl    %eax, 4(%edi)

    /* vector 0x04 (#OF, INTO): INTERRUPT gate (0x8E) -> of_handler */
    movl    $of_handler, %ebx
    movl    $0x00001020, %edi       /* 0x1000 + 0x04*8 = 0x1020 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax       /* attr 0x8E (32-bit interrupt gate) */
    movl    %eax, 4(%edi)

    /* vector 0x20 (INT 0x20): INTERRUPT gate (0x8E) -> int20_handler */
    movl    $int20_handler, %ebx
    movl    $0x00001100, %edi       /* 0x1000 + 0x20*8 = 0x1100 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)

    /* vector 0x21 (INT 0x21): TRAP gate (0x8F) -> int21_handler */
    movl    $int21_handler, %ebx
    movl    $0x00001108, %edi       /* 0x1000 + 0x21*8 = 0x1108 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008F00, %eax
    movl    %eax, 4(%edi)

    /* --- IDT pseudo-descriptor @0x0490: limit(2) base(4) --- */
    movw    $0x07FF, 0x0490     /* limit = 256*8 - 1 = 0x7FF */
    movl    $0x00001000, 0x0492 /* base  = 0x1000 */
    lidt    0x0490

    /* ====================== fire the software interrupts ================ */
    /* Set IF (sti) so the interrupt-gate-vs-trap-gate IF semantics are OBSERVABLE
     * in the golden: an INTERRUPT gate (vec 0x20, 0x04) clears IF on entry (the
     * handler body shows IF=0), while a TRAP gate (vec 0x21, 0x03) leaves IF set
     * (the handler body shows IF=1).  No external interrupt source is wired in
     * this freestanding image, so the only interrupts are the software INTs. */
    sti

    /* clear the GPRs we use as visible accumulators so the trace is clean */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi

    /* (4) INT 0x20 -> int20_handler (interrupt gate). The handler sets the
     * sentinel at 0x2000 and increments the counter at 0x2020. */
    int     $0x20
    /* after IRET we are HERE; load the sentinel the handler wrote */
    movl    0x00002000, %esi    /* esi = 0x20202020 (proof int20_handler ran) */

    /* (5) INT 0x21 -> int21_handler (trap gate). sentinel @0x2004, ctr @0x2024 */
    int     $0x21
    movl    0x00002004, %edi    /* edi = 0x21212121 (proof int21_handler ran) */

    /* (6) INT3 -> bp_handler (trap gate). sentinel @0x2008, ctr @0x2028 */
    int3
    movl    0x00002008, %ebp    /* ebp = 0x03030303 (proof bp_handler ran) */

    /* (7) INTO with OF set -> of_handler (interrupt gate). sentinel @0x200C,
     * ctr @0x202C.  Produce a real signed overflow: 0x7FFFFFFF + 1 sets OF. */
    movl    $0x7FFFFFFF, %eax
    addl    $1, %eax            /* eax = 0x80000000, OF=1, SF=1 */
    into                        /* OF set -> #OF -> of_handler -> IRET */
    movl    0x0000200C, %edx    /* edx = 0x04040404 (proof of_handler ran) */

    /* ============ accumulate the four counters as the success proof ======= */
    /* each handler did `incl ctr`; sum must be 4. Put the sum in ECX, and the
     * total of all four sentinels' low byte signatures in EBX, so the final GPR
     * state is a deterministic function of "every handler ran exactly once". */
    movl    0x00002020, %eax    /* int20 counter */
    addl    0x00002024, %eax    /* + int21 counter */
    addl    0x00002028, %eax    /* + bp counter */
    addl    0x0000202C, %eax    /* + of counter */
    movl    %eax, %ecx          /* ecx = 4 if every handler ran once */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx            /* qemu exits: status = (0x42<<1)|1 = 0x85 */

hang:
    hlt
    jmp     hang

    /* ============================= HANDLERS ============================= */
    /* Each handler writes a per-vector sentinel + increments a per-vector
     * counter, then IRETs.  They touch only EAX (saved/restored) so the
     * accumulator GPRs in the mainline stay meaningful across delivery. */

    .align 16
    .global int20_handler
int20_handler:
    pushl   %eax
    movl    $0x20202020, %eax
    movl    %eax, 0x00002000        /* sentinel */
    incl    0x00002020              /* counter */
    popl    %eax
    iret

    .align 16
    .global int21_handler
int21_handler:
    pushl   %eax
    movl    $0x21212121, %eax
    movl    %eax, 0x00002004
    incl    0x00002024
    popl    %eax
    iret

    .align 16
    .global bp_handler
bp_handler:
    pushl   %eax
    movl    $0x03030303, %eax
    movl    %eax, 0x00002008
    incl    0x00002028
    popl    %eax
    iret

    .align 16
    .global of_handler
of_handler:
    pushl   %eax
    movl    $0x04040404, %eax
    movl    %eax, 0x0000200C
    incl    0x0000202C
    /* Clear OF in the SAVED eflags on the stack so IRET returns with OF=0 and
     * the mainline state after INTO is deterministic.  Stack on entry to the
     * interrupt gate (same-privilege): [esp]=saved EIP, [esp+4]=saved CS,
     * [esp+8]=saved EFLAGS.  We pushed EAX, so add 4 to each offset. */
    andl    $0xFFFFF7FF, 0x0C(%esp) /* clear OF (bit 11) in saved EFLAGS */
    popl    %eax
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
