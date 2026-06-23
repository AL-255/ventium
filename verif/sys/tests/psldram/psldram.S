/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — PAGED store->load RAW (read-after-write) regression guard.
 *
 * Background (task #102 / DOS-Quake): a prior forward-diff CLAIMED the first
 * Ventium<->qemu divergence was a store->load hazard inside CWSDPMI's PM
 * exception dispatcher — `POP word [m]` writing a value that the immediately
 * following `SUB word ptr [m], imm` (an RMW) then read STALE. A cycle-level
 * trace (VEN_BWATCH on the BFM mem port) DISPROVED that: the RMW load reads
 * EXACTLY the value the prior store wrote. This test PINS that behaviour as a
 * permanent regression guard: a back-to-back store -> same-address RMW-load
 * (incl. 16-bit operand forms) into a FRESHLY-mapped page that was never read
 * before (so no cache line could carry a stale copy), differentially checked
 * record-for-record against qemu-system-i386.
 *
 * If a real store->load forwarding / write-allocate stale-line bug ever appears,
 * the read-back GPRs here diverge from qemu and the gate FAILS.
 *
 * Boots real->protected, builds a NON-IDENTITY 2-level paging map (so a
 * "no-translation" bug is also caught), enables paging, then runs the RAW
 * sequence through the paged window and exits via isa-debug-exit.
 *
 * Memory plan (mirrors ppage; -m 32 => 32 MiB phys, all targets fit):
 *   GDT  @ phys 0x0500 (null + code32 0x08 + data32 0x10)
 *   PD   @ phys 0x11000 ; PT0 @ 0x12000 (identity code window) ; PT1 @ 0x13000
 *   PT1[0] linear 0x00400000 -> phys 0x00900000  P|RW|US  (FRESH data page)
 *
 * RAW sequence (all on the FRESH paged page @ linear 0x400000 -> phys 0x900000):
 *   A. 32-bit:  mov  dword [0x400000], 0x12345678
 *               sub  dword [0x400000], 0x00010001   ; RMW load reads 0x12345678
 *               mov  eax, [0x400000]                ; eax = 0x12335677
 *   B. 16-bit:  mov  word  [0x400010], 0xC57C       ; matches the CWSDPMI POP
 *               sub  word  [0x400010], 0x3A84       ; RMW load reads 0xC57C
 *               movzx ebx, word [0x400010]          ; ebx = 0x8AF8
 *   C. byte:    mov  byte  [0x400020], 0xAA
 *               add  byte  [0x400020], 0x11         ; RMW load reads 0xAA
 *               movzx ecx, byte [0x400020]          ; ecx = 0xBB
 *   D. push/pop->mem then RMW (the exact CWSDPMI shape: POP word [m]; SUB word [m]):
 *               push word 0x3B48
 *               pop  word [0x400030]                ; store 0x3B48 via pop-to-mem
 *               sub  word [0x400030], 0x3A84        ; RMW load reads 0x3B48
 *               movzx edx, word [0x400030]          ; edx = 0x00C4
 *
 * The four read-back GPRs (eax/ebx/ecx/edx) are the differential signal. Build:
 * gcc -m32 -ffreestanding -nostdlib (see Makefile), objcopy -O binary, 64 KiB.
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

    /* --- flat GDT (3 entries) @ linear 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* 0x08 code32 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* 0x10 data32 */
    movl    $0x00CF9200, 20(%ebx)

    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
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

    /* --- PT0 @ 0x12000: identity-map the code window [0x000F0000,0x00100000) --- */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0003, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* Also identity-map the 32-bit STACK window so the post-paging PUSH/POP (part D)
     * has a valid page. ESP=0x90000 -> a pushw touches linear 0x8FFFE (page 0x8F000),
     * so map PT0[0x8E..0x90] (three pages around the stack top). */
    movl    $0x00012238, %edi           /* &PT0[0x8E] = 0x12000 + 0x8E*4 */
    movl    $0x0008E003, %eax           /* identity PTE for frame 0x0008E000 | P|RW */
    movl    $3, %ecx                    /* 0x8E, 0x8F, 0x90 */
2:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    2b

    /* --- PT1 @ 0x13000: the FRESH non-identity data page --- */
    movl    $0x00013000, %edi
    /* PT1[0] linear 0x400000 -> phys 0x900000  P|RW|US (0x7) */
    movl    $0x00900007, 0(%edi)

    /* --- PD @ 0x11000 --- */
    movl    $0x00011000, %edi
    movl    $0x00012003, 0(%edi)        /* PD[0] -> PT0 | P|RW */
    movl    $0x00013007, 4(%edi)        /* PD[1] -> PT1 | P|RW|US (@4 MiB) */

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* =================== A. 32-bit store -> same-addr RMW load =================== */
    movl    $0x12345678, 0x00400000     /* store (fills/fault-walks the FRESH page) */
    subl    $0x00010001, 0x00400000     /* RMW: load 0x12345678, sub, store */
    movl    0x00400000, %eax            /* read back -> eax = 0x12335677 */

    /* =================== B. 16-bit store -> same-addr RMW load =================== */
    movw    $0xC57C, 0x00400010
    subw    $0x3A84, 0x00400010         /* RMW: load 0xC57C, sub -> 0x8AF8 */
    movzwl  0x00400010, %ebx            /* ebx = 0x00008AF8 */

    /* =================== C. byte store -> same-addr RMW load ===================== */
    movb    $0xAA, 0x00400020
    addb    $0x11, 0x00400020           /* RMW: load 0xAA, add -> 0xBB */
    movzbl  0x00400020, %ecx            /* ecx = 0x000000BB */

    /* ====== D. POP word [m] -> SUB word [m] (the exact CWSDPMI shape) =========== */
    pushw   $0x3B48
    popw    0x00400030                  /* store 0x3B48 to [m] via pop-to-memory */
    subw    $0x3A84, 0x00400030         /* RMW: load 0x3B48, sub 0x3A84 -> 0x00C4 */
    movzwl  0x00400030, %edx            /* edx = 0x000000C4 */

    /* ====================== clean exit via isa-debug-exit ====================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
