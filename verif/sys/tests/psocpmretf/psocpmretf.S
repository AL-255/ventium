/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — PROTECTED-mode far CALL (0x9A) + far RETF (0xCB) firmware
 * (psocpmretf.bin).
 *
 * This is the protected-mode counterpart of psocfarcall (which covers the
 * real-mode forms). It is the smallest exerciser of the PM far CALL / PM far RETF
 * micro-sequences: in PM a far CALL pushes CS:EIP then walks the GDT descriptor of
 * the target selector to load CS (S_LCALL -> S_LJMP), and a far RETF pops EIP:CS
 * then walks the GDT descriptor of the popped CS selector to load CS
 * (S_RETF -> S_LJMP). The PM far RETF was the DOS-Quake blocker after the PM
 * pop-sreg fix: CWSDPMI's DPMI dispatch far-returns in protected mode (cs=0x2b,
 * a 16-bit ring-3 code segment), which previously HALTed loudly (S_HALT) because
 * SYS_RETF only routed real-mode (seg_real && !paging_on) to S_RETF.
 *
 * Flow (each step observable in the system-mode golden trace):
 *   1. real mode: load a flat GDT (null/code32/data32), set CR0.PE, far-jump to a
 *      32-bit code segment (0x08).
 *   2. in 32-bit PM: set up DS/SS and a stack, then far-CALL $0x08:far_routine.
 *      The CALL pushes CS(=0x08):EIP(=ret_site) and the S_LCALL -> S_LJMP path
 *      re-reads the 0x08 GDT descriptor to load CS -> jump into far_routine.
 *   3. far_routine writes an observable marker (ECX) and far-RETFs (0xCB). The
 *      S_RETF -> S_LJMP path pops EIP:CS, re-reads the popped 0x08 GDT descriptor,
 *      loads CS, and returns to ret_site.
 *   4. ret_site writes a second marker (EBX) and exits via isa-debug-exit.
 *
 * cr0 = 0x60000011 in PM (PE set, no paging). Same-privilege far CALL/RETF (RPL 0
 * == CPL 0), exactly the structural transfer CWSDPMI uses (it is at RPL 3, but the
 * S_LCALL/S_RETF -> S_LJMP path is privilege-agnostic for a same-CPL return). The
 * far CALL / RETF are emitted as explicit opcode bytes so the selector:offset
 * operands are pinned.
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

    /* --- copy a flat GDT (3 entries = 24 bytes) into 0x0500 --- */
    movl    $0x00000500, %ebx
    /* null descriptor @0x0500 */
    movl    $0x00000000, (%ebx)
    movl    $0x00000000, 4(%ebx)
    /* code32 @0x08: base=0 limit=0xFFFFF G=1 D=1 P=1 DPL=0 type=0xA -> 0x9A */
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    /* data32 @0x10: base=0 limit=0xFFFFF G=1 B=1 P=1 DPL=0 type=0x2 -> 0x92 */
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)

    /* --- gdt pseudo-descriptor @0x0480: limit(2) base(4) --- */
    movw    $0x0017, 0x0480     /* limit = 24-1 = 0x17 */
    movl    $0x00000500, 0x0482 /* base = 0x0500 */
    lgdt    0x0480

    /* --- enter protected mode --- */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    /* far jump to the 32-bit code segment (0x08) at pm32_entry (flat, base 0) */
    .byte   0x66, 0xEA          /* opsize-32 ljmp ptr16:32 */
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    /* reload data segments + a 32-bit stack */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00090000, %esp

    movl    $0x55550000, %eax   /* observable pre-call marker */

    /* PM far CALL $0x08:far_routine (9A off32 sel16). In this 32-bit (D=1) code
     * segment the default operand size is 32-bit, so the bare 0x9A is the 32-bit
     * far CALL: it pushes CS(=0x08):EIP(=ret_site) and S_LCALL -> S_LJMP loads CS
     * from the 0x08 GDT descriptor and jumps into far_routine. */
    .byte   0x9A                /* far CALL ptr16:32 (32-bit default opsize) */
    .long   far_routine         /* 32-bit offset (flat, base 0) */
    .word   0x08                /* code selector */
ret_site:
    /* control returns HERE after far_routine's RETF */
    movl    $0x11111111, %ebx   /* observable post-return marker */

    /* exit via isa-debug-exit: out 0xf4, al=0x42 -> status (0x42<<1)|1 = 133 */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

    /* ---- the PM far-called routine (same 0x08 code segment) ------------- */
    .global far_routine
far_routine:
    movl    $0x22222222, %ecx   /* observable inside the called routine */
    /* PM far RETF (32-bit default opsize in this D=1 segment): pop EIP then CS;
     * S_RETF -> S_LJMP re-reads the popped 0x08 GDT descriptor, loads CS, returns
     * to ret_site. This is the opcode that previously HALTed in PM. */
    .byte   0xCB                 /* RETF (pop EIP:CS) */

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                 /* ljmp ptr16:16 */
    .word   _start16_off         /* 16-bit offset within segment 0xF000 */
    .word   0xF000               /* segment */
