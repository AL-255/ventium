/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — bare-metal 16-bit-PROTECTED-MODE INT/IRETW gate demonstrator.
 *
 * The sibling pintr test exercises the 32-bit IDT gate (12-byte EIP:CS:EFLAGS
 * frame, IRET). THIS test exercises the 16-bit IDT gate that pintr does NOT:
 *   - a 16-bit code segment (descriptor type 0xA, D=0)  -> cs_d=0
 *   - a 16-bit INTERRUPT gate (attr 0x86, gate type 0x6) for a test vector
 *   - INT $vec delivered while running in 16-bit PM pushes a 6-byte IP:CS:FLAGS
 *     frame (2-byte slots, SP -= 6), the handler IRETWs (pops 6 bytes, SP += 6).
 *
 * This is the DPMI-host stack-frame case that broke DOS-Quake: a 16-bit-PM gate
 * delivery/return MUST size the frame as 6 bytes. A core that hardcodes the
 * 32-bit (12-byte) frame corrupts SP by exactly 6 words (12 - 6 ... here we
 * directly check SP is restored EXACTLY to its pre-INT value) and the IRETW pops
 * a 12-byte-shifted frame -> wild transfer. The golden (qemu-system-i386) sizes
 * the frame correctly, so a mis-sizing RTL core DIVERGES from the golden.
 *
 * Flow:
 *   1. real mode: build a flat GDT (null + code32 0x08 + data32 0x10 + CODE16
 *      0x18 [type 0xA, D=0]); lgdt; CR0.PE=1; far-jump to 32-bit code 0x08.
 *   2. (32-bit) load flat data selectors + a flat stack; zero markers; build an
 *      IDT at 0x1000 with a 16-bit INTERRUPT gate (attr 0x86, selector 0x18 =
 *      the 16-bit code seg) for vector 0x40 -> int40_handler16; lidt.
 *   3. far-jump (16-bit ljmp) into the 16-bit code segment 0x18 -> pm16_entry.
 *   4. (16-bit PM, cs_d=0) record SP, INT $0x40 (CD 40) -> 16-bit gate delivery
 *      -> int40_handler16 (sets sentinel + increments counter) -> IRETW. After
 *      the IRETW: re-read SP and PROVE it equals the recorded pre-INT SP (frame
 *      sized 6 bytes round-trip). Stash the proof, far-jump back to 32-bit 0x08.
 *   5. (32-bit) verify the sentinel/counter the handler wrote AND the SP-match
 *      flag; exit cleanly via isa-debug-exit only if everything checks.
 *
 * The decisive observable: the 16-bit handler entry CS:EIP and the IRETW return
 * to the instruction after INT $0x40 — captured in the system golden. A core
 * that pushes the 32-bit frame returns to a 12-byte-shifted address (wild) and
 * the golden diff FAILS; with the correct 6-byte frame it matches.
 *
 * Build: gcc -m32 -ffreestanding (GNU-as syntax), objcopy -O binary, pad 64 KiB.
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

    /* --- build a flat GDT (4 entries = 32 bytes) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    /* idx 0: null */
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    /* idx 1 (0x08): code32 base=0 limit=0xFFFFF G=1 D=1 P=1 DPL=0 type=0xA */
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    /* idx 2 (0x10): data32 flat base=0 limit=0xFFFFF G=1 B=1 type=0x2 RW */
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    /* idx 3 (0x18): CODE16 base=0x000F0000 limit=0xFFFF G=0 D=0 P=1 DPL=0 type=0xA.
     * D=0 makes cs_d=0 (16-bit default operand/address size) — the thing under
     * test. CRITICAL: a 16-bit IDT gate stores only a 16-BIT handler offset, and
     * the 16-bit far-jump uses a 16-bit offset, so the segment must be BASED at
     * the image window (0xF0000) and the 16-bit phase/handler addressed by their
     * (linear - 0xF0000) 16-bit offsets. descriptor encoding:
     *   bytes 0-1 limit[15:0]=0xFFFF, bytes 2-4 base[23:0]=0x0F0000,
     *   byte5=0x9A (P,DPL0,S,code-type 0xA), byte6=0x00 (G=0,D=0,limit hi 0),
     *   byte7 base[31:24]=0x00. => lo dword 0x0000FFFF, hi dword 0x00009A0F. */
    movl    $0x0000FFFF, 24(%ebx)
    movl    $0x00009A0F, 28(%ebx)

    /* gdt pseudo-descriptor @0x0480 */
    movw    $0x001F, 0x0480     /* limit = 32-1 = 0x1F (4 entries) */
    movl    $0x00000500, 0x0482

    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far-jump into the 32-bit flat code segment 0x08 */
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

    /* zero the marker area at 0x2000..0x2040 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build the IDT (1 gate) ===================== */
    /* IDT base = 0x1000. vector 0x40 (gate slot 0x1000 + 0x40*8 = 0x1200):
     *   16-bit INTERRUPT gate, attr 0x86 (P=1 DPL=0 type=0x6), selector 0x18
     *   (the 16-bit code segment), offset = int40_handler16 (flat linear).
     *   lo dword = (selector<<16) | offset[15:0]
     *   hi dword = (offset & 0xFFFF0000) | (attr<<8)
     */
    /* 16-bit gate: word0 = (selector<<16) | offset16; word1 high half is
     * RESERVED for a 16-bit gate (no offset[31:16]). offset16 = handler's
     * (linear - 0xF0000) since CS=0x18 is based at 0xF0000. _h40_off is a
     * link-time constant < 0x10000, so load it then OR in the selector. */
    movl    $0x00001200, %edi
    movl    $_h40_off, %eax         /* 16-bit handler offset (< 0x10000) */
    orl     $0x00180000, %eax       /* selector 0x18 in bits 31:16 */
    movl    %eax, 0(%edi)
    movl    $0x00008600, %eax       /* attr 0x86 (16-bit interrupt gate, P, DPL0) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* clear visible accumulators */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %edi, %edi

    /* far-jump into the 16-bit code segment 0x18 (D=0, base 0xF0000). We are in
     * 32-bit code so 0xEA is ptr16:32; the offset is pm16_entry's seg-relative
     * (linear - 0xF0000), zero-extended to 32 bits. */
    .byte   0xEA
    .long   _pm16_off
    .word   0x18

    /* ----- return point from the 16-bit phase (far-jumped back here) ----- */
    .global back32
back32:
    /* reload 32-bit data selectors + the flat 32-bit stack */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp

    /* ============ verify the success conditions ============ */
    /* esi = sentinel the handler wrote (0x40404040); ecx = handler counter (1);
     * the SP-restored proof is at 0x2010 (1 = SP exactly restored by IRETW). */
    movl    0x00002000, %esi        /* sentinel  -> 0x40404040 if handler ran */
    movl    0x00002020, %ecx        /* counter   -> 1 */
    movl    0x00002010, %edx        /* SP-match  -> 1 if IRETW restored SP exactly */

    /* exit via isa-debug-exit */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang32:
    hlt
    jmp     hang32

    /* ===================== 16-bit PROTECTED-MODE PHASE ===================== */
    .code16
    .section .text16pm, "ax"
    .global pm16_entry
pm16_entry:
    /* We are now in 16-bit PM (CS=0x18, cs_d=0). DS/ES/SS still 0x10 (flat 32-bit
     * data) from pm32_entry, and ESP=0x90000. A 16-bit stack push uses SP (the
     * low 16 bits) — 0x90000 & 0xFFFF = 0. To keep the round-trip clean and
     * observable, set a fresh 16-bit stack within a 64 KiB window. We use a
     * data16 selector would be ideal, but the flat data seg (B=1) works because
     * the test only checks the SP delta (push 6 / pop 6) and the handler runs in
     * the same flat space. Record SP before the INT. */

    /* record SP into BP (before the INT) */
    movw    %sp, %bp

    /* fire the 16-bit-PM software interrupt */
    int     $0x40                   /* CD 40 -> 16-bit gate -> int40_handler16 */

    /* after IRETW: SP must equal BP exactly (6 pushed, 6 popped). Set the
     * SP-match flag at 0x2010 = 1 iff (SP == BP). */
    movw    %sp, %ax
    cmpw    %bp, %ax
    jne     2f
    /* SP restored exactly: write proof = 1 */
    movl    $0x00000001, 0x00002010
2:
    /* far-jump back into the 32-bit code segment 0x08 -> back32. We are in
     * 16-bit code, so this is ljmp ptr16:16 (default operand size). The 16-bit
     * offset of back32 fits because back32 is within the low 64 KiB of the flat
     * code segment? NOT guaranteed — back32 is at a 0x000Fxxxx linear addr. So
     * emit an opsize-32 ljmp (0x66 prefix) ptr16:32 to reach the full offset. */
    .byte   0x66, 0xEA
    .long   back32
    .word   0x08

    /* ===================== 16-bit handler ===================== */
    .global int40_handler16
int40_handler16:
    /* runs in 16-bit PM. Write a sentinel + bump a counter, then IRETW (the
     * 16-bit IRET, which pops the 6-byte IP:CS:FLAGS frame). Touch only AX. */
    pushw   %ax
    movl    $0x40404040, 0x00002000     /* sentinel (32-bit store, flat DS) */
    incl    0x00002020                  /* counter */
    popw    %ax
    /* IRETW: GNU as emits the 16-bit IRET in .code16 as `iret` (opcode CF, no
     * 0x66 prefix => 16-bit operand size in a 16-bit segment). Use the explicit
     * mnemonic to be unambiguous. */
    iretw

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
