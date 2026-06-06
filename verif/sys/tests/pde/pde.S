/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — bare-metal #DE (divide-error) IDT-delivery demonstrator.
 *
 * Closes the divide family's architectural gap (REVIEW_Jun5.md Limit #5 / Action
 * 4): integer DIV/IDIV now raise #DE (vector 0) on divide-by-zero AND on a
 * quotient that overflows the destination width, DELIVERED through the verified
 * S_INT_GATE IDT FSM (FAULT semantics — the faulting EIP is pushed). Previously
 * a zero divisor evaluated native `/`/`%` (X-prone) and an overflowing quotient
 * silently wrapped — both DIVERGED from QEMU, which #DEs.
 *
 * Boots real->protected (NO paging), builds an IDT with a single vector-0 (#DE)
 * interrupt gate, then deliberately triggers TWO #DE conditions:
 *   1. divide-by-zero : DIV by ECX=0.
 *   2. quotient overflow: EDX:EAX = 0x1_0000_0000 / 1 -> quotient 0x100000000
 *      does not fit 32 bits -> #DE.
 * The de_handler counts each, then (like a #GP resume) overwrites the saved EIP
 * with a stashed resume label so IRET resumes PAST the faulting divide instead of
 * re-faulting. The #DE counter (==2) is folded into a deterministic result and
 * the test exits via isa-debug-exit. Same-privilege (CPL 0), interrupt gate (IF
 * cleared on entry). #DE has NO error code.
 *
 * Per-record differential vs qemu-system-i386: #DE is a SYNCHRONOUS exception, so
 * the gdbstub single-step golden delivers it (unlike async INTR). Layout:
 *   GDT @ 0x0500 (null + code32 0x08 + data32 0x10)
 *   IDT @ 0x1000 (vector 0 = #DE gate)
 *   markers @ 0x2000 (DE_CTR, DE_RESUME)
 *   stack @ 0x90000
 */

    .equ DE_CTR,    0x00002000     /* #DE delivery counter */
    .equ DE_RESUME, 0x00002004     /* resume EIP the mainline stashes per divide */

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

    /* flat GDT (null + code32 0x08 + data32 0x10) @ 0x0500 */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* code32 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* data32 */
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* far jmp 0x08:pm32_entry */
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

    /* zero the markers */
    movl    $0x00000000, DE_CTR
    movl    $0x00000000, DE_RESUME

    /* ===================== build the IDT (vector-0 #DE gate) ============== */
    /* gate 0 (#DE): 32-bit INTERRUPT gate (attr 0x8E), selector 0x08. */
    movl    $de_handler, %ebx
    movl    $0x00001000, %edi           /* 0x1000 + 0*8 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* attr 0x8E (32-bit interrupt gate) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492        /* IDT base = 0x1000 */
    lidt    0x0490

    /* ===================== #DE 1: divide-by-zero ========================= */
    movl    $after_div0, DE_RESUME
    movl    $0x00001234, %eax
    xorl    %edx, %edx
    xorl    %ecx, %ecx
    divl    %ecx                        /* EDX:EAX / 0 -> #DE (vector 0) */
after_div0:

    /* ===================== #DE 2: quotient overflow ====================== */
    movl    $after_div1, DE_RESUME
    movl    $0x00000001, %edx           /* dividend = 0x1_0000_0000 */
    xorl    %eax, %eax
    movl    $0x00000001, %ecx           /* / 1 -> quotient 0x100000000 (>32b) -> #DE */
    divl    %ecx
after_div1:

    /* ===================== a NON-faulting divide (sanity) ================ */
    movl    $0x000000FF, %eax           /* 255 / 5 = 51 r 0, fits -> no #DE */
    xorl    %edx, %edx
    movl    $0x00000005, %ecx
    divl    %ecx                        /* EAX=51 (0x33), EDX=0 */

    /* ===================== deterministic result + exit =================== */
    movl    DE_CTR, %esi                /* expect 2 (both #DE delivered) */
    movl    %eax,   %edi                /* the non-faulting quotient = 0x33 */
    movl    %esi,   %edx
    shll    $8,     %edx
    addl    %edi,   %edx                /* edx = (#DE count << 8) | quot = 0x233 */
    movl    %edx,   %ecx                /* mirror for visibility */

    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                    /* isa-debug-exit -> qemu status 133 */
hang:
    hlt
    jmp     hang

    /* ============================== #DE HANDLER =========================== */
    /* Counts the delivery, then resumes PAST the faulting divide (the mainline
     * stashed the post-divide label in DE_RESUME). #DE has NO error code, so the
     * frame is [esp]=EIP,[esp+4]=CS,[esp+8]=EFLAGS; after pushing EAX the saved
     * EIP is at [esp+4]. Interrupt gate -> IF cleared on entry; IRET restores it. */
    .align 16
    .global de_handler
de_handler:
    pushl   %eax
    incl    DE_CTR
    movl    DE_RESUME, %eax
    movl    %eax, 0x04(%esp)            /* overwrite saved EIP -> resume past DIV */
    popl    %eax
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ===================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
